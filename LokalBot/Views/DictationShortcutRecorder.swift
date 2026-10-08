import AppKit
import SwiftUI

/// Click, then press the new dictation shortcut. Esc cancels. While recording,
/// the global shortcut is suspended so the current one can be pressed too.
struct DictationShortcutRecorder: View {
    @Binding var shortcut: DictationShortcut
    /// Suspends or resumes the global shortcut while recording.
    var onRecordingChanged: (Bool) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?
    @State private var problem: DictationShortcut.Problem?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 8) {
                if shortcut != .handyDefault, !isRecording {
                    Button("Reset") { shortcut = .handyDefault }
                        .buttonStyle(.borderless)
                        .accessibilityIdentifier("settings.dictationShortcut.reset")
                }
                Button {
                    isRecording ? stopRecording() : startRecording()
                } label: {
                    Group {
                        if isRecording {
                            Text("Press a shortcut…")
                        } else {
                            Text(verbatim: shortcut.displayLabel)
                        }
                    }
                    .frame(minWidth: 96)
                }
                .accessibilityIdentifier("settings.dictationShortcut")
                .help(isRecording
                      ? LocalizedStringKey("Press the new shortcut, or Esc to cancel.")
                      : LocalizedStringKey("Change the dictation shortcut"))
            }
            if let problem {
                Text(LocalizedStringKey(problem.message))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        problem = nil
        isRecording = true
        onRecordingChanged(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isRecording else { return }
        isRecording = false
        onRecordingChanged(false)
    }

    private func handle(_ event: NSEvent) {
        let candidate = DictationShortcut(
            keyCode: CGKeyCode(event.keyCode),
            modifiers: Self.eventFlags(from: event.modifierFlags))
        if candidate.keyCode == DictationShortcutKeyNames.escape, candidate.modifiers.isEmpty {
            problem = nil
            stopRecording()
            return
        }
        if let issue = candidate.problem {
            problem = issue
            return
        }
        problem = nil
        shortcut = candidate
        stopRecording()
    }

    static func eventFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var result: CGEventFlags = []
        if flags.contains(.control) { result.insert(.maskControl) }
        if flags.contains(.option) { result.insert(.maskAlternate) }
        if flags.contains(.shift) { result.insert(.maskShift) }
        if flags.contains(.command) { result.insert(.maskCommand) }
        return result
    }
}
