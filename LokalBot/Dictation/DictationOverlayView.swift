import AppKit
import SwiftUI

@MainActor
final class DictationOverlayController {
    private let settingsStore: SettingsStore
    private var panel: NSPanel?
    private var hostingView: NSHostingView<AppLanguageRoot<DictationOverlayView>>?

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    func update(for dictation: DictationCoordinator, visible: Bool) {
        guard visible, dictation.state.isWorking || dictation.isStarting || dictation.deliveryNotice != nil else {
            close()
            return
        }
        let size = Self.size(for: dictation)
        if panel == nil {
            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false)
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.level = .floating
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

            let hosting = NSHostingView(rootView: DictationOverlayView(dictation: dictation)
                .appLanguageRoot(settingsStore))
            hosting.frame = NSRect(origin: .zero, size: size)
            panel.contentView = hosting
            self.panel = panel
            self.hostingView = hosting
        }
        hostingView?.rootView = DictationOverlayView(dictation: dictation)
            .appLanguageRoot(settingsStore)
        hostingView?.frame = NSRect(origin: .zero, size: size)
        positionPanel(size: size)
        panel?.orderFrontRegardless()
    }

    func close() {
        panel?.orderOut(nil)
    }

    private func positionPanel(size: CGSize) {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let frame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 48)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: false)
    }

    private static func size(for dictation: DictationCoordinator) -> CGSize {
        if dictation.shouldShowModelPreparation {
            return CGSize(width: 360, height: 72)
        }
        if dictation.shouldShowLiveTranscriptPanel {
            return CGSize(width: 520, height: 156)
        }
        return CGSize(width: DictationOverlayView.compactWidth(for: dictation), height: 40)
    }
}

struct DictationOverlayView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var dictation: DictationCoordinator

    var body: some View {
        Group {
            if dictation.shouldShowModelPreparation {
                modelPreparationPanel
            } else if dictation.shouldShowLiveTranscriptPanel {
                liveTranscriptPanel
            } else {
                compactPanel
            }
        }
        .frame(width: width, height: height)
        .hudCapsule(radius: radius, shadowed: false)
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: dictation.state)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: dictation.isStarting)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: dictation.liveTranscript)
    }

    private var modelPreparationPanel: some View {
        HStack(spacing: 10) {
            ModelPreparationView(
                presentation: dictation.modelPreparationPresentation,
                style: .hud,
                action: dictation.modelPreparationError == nil
                    ? nil
                    : { dictation.retryModelPreparation() })
            cancelButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var compactPanel: some View {
        HStack(spacing: 0) {
            if dictation.isStarting {
                workingRow
            } else {
                switch dictation.state {
                case .idle:
                    if let notice = dictation.deliveryNotice { noticeRow(notice) }
                case .recording:
                    recordingRow
                case .transcribing, .composing:
                    workingRow
                }
            }
        }
        .frame(height: 40)
    }

    private var liveTranscriptPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                if dictation.state.isRecording {
                    PulsingDictationDot(live: dictation.hasMicrophoneAudio)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(dictation.state.isRecording ? "Dictating" : dictation.state.label)
                        .font(.system(size: 12, weight: .semibold))
                    Text(liveStatusText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 10)
                if dictation.state.isRecording {
                    AudioLevelBars(meter: dictation.audioLevelMeter).padding(.trailing, 8)
                }
                cancelButton
            }
            .frame(height: 38)
            .padding(.horizontal, 14)

            Divider()
                .opacity(0.45)

            liveTranscriptBody
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var liveTranscriptBody: some View {
        if dictation.liveTranscript.isEmpty {
            Text("Listening…")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        liveTranscriptText
                            .font(.system(size: 15))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear
                            .frame(height: 1)
                            .id(Self.liveTranscriptEndID)
                    }
                }
                .scrollIndicators(.hidden)
                .onAppear {
                    proxy.scrollTo(Self.liveTranscriptEndID, anchor: .bottom)
                }
                .onChange(of: dictation.liveTranscript) { _, _ in
                    withAnimation(.easeOut(duration: 0.14)) {
                        proxy.scrollTo(Self.liveTranscriptEndID, anchor: .bottom)
                    }
                }
            }
        }
    }

    private static let liveTranscriptEndID = "dictation-live-transcript-end"

    private var liveTranscriptText: Text {
        let committed = dictation.liveTranscript.committed
        let tentative = dictation.liveTranscript.tentative
        if committed.isEmpty {
            return Text(tentative)
                .foregroundColor(.primary)
        }
        if tentative.isEmpty {
            return Text(committed)
                .foregroundColor(.primary)
        }
        return Text(committed + " ")
            .foregroundColor(.primary)
        + Text(tentative)
            .foregroundColor(.secondary)
    }

    private var liveStatusText: String {
        let status: String
        if !dictation.captureStatus.isEmpty {
            status = dictation.captureStatus
        } else {
            status = dictation.livePreviewStatus.isEmpty ? "Listening" : dictation.livePreviewStatus
        }
        return "\(status) \(dictation.timerLabel)"
    }

    /// The waveform moves only while audio arrives, and a microphone problem
    /// replaces it with words: the compact HUD used to animate a fixed wave
    /// while the microphone reconnected, so recording looked fine when it was not.
    private var recordingRow: some View {
        HStack(spacing: 0) {
            PulsingDictationDot(live: dictation.hasMicrophoneAudio)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 15)
            if dictation.captureStatus.isEmpty {
                AudioLevelBars(meter: dictation.audioLevelMeter).padding(.trailing, 8)
            } else {
                Text(dictation.captureStatus)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 8)
            }
            cancelButton
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 40)
    }

    /// Pasted text the field did not show: offer it again instead of losing it.
    private func noticeRow(_ notice: DictationDeliveryNotice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .padding(.leading, 14)
            Text(notice.copied ? "Copied to the clipboard" : "The text may not have been inserted")
                .font(.system(size: 12))
                .lineLimit(1)
            Spacer(minLength: 4)
            if !notice.copied {
                Button("Copy") { dictation.copyDeliveryNoticeText() }
                    .controlSize(.small)
                    .accessibilityIdentifier("dictation.notice.copy")
            }
            Button {
                dictation.dismissDeliveryNotice()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .background(Color.primary.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Dismiss")
            .padding(.trailing, 10)
        }
        .frame(height: 40)
    }

    private var workingRow: some View {
        HStack(spacing: 0) {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
            Text(dictation.isStarting ? "Starting" : dictation.state.label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 8)
            cancelButton
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 10)
        }
        .frame(height: 40)
    }

    private var cancelButton: some View {
        Button {
            dictation.cancel()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(Color.primary.opacity(0.08), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Cancel dictation")
    }

    private var width: CGFloat {
        if dictation.shouldShowModelPreparation { return 360 }
        if dictation.shouldShowLiveTranscriptPanel { return 520 }
        return Self.compactWidth(for: dictation)
    }

    @MainActor
    static func compactWidth(for dictation: DictationCoordinator) -> CGFloat {
        switch dictation.state {
        case .idle where dictation.isStarting:
            return 216
        case .idle:
            return dictation.deliveryNotice == nil ? 172 : 360
        case .recording:
            return dictation.captureStatus.isEmpty ? 172 : 300
        case .transcribing, .composing:
            return 216
        }
    }

    private var height: CGFloat {
        if dictation.shouldShowModelPreparation { return 72 }
        return dictation.shouldShowLiveTranscriptPanel ? 156 : 40
    }

    private var radius: CGFloat {
        if dictation.shouldShowModelPreparation { return 16 }
        if dictation.shouldShowLiveTranscriptPanel { return 14 }
        switch dictation.state {
        case .idle where dictation.isStarting:
            return 18
        case .idle, .recording:
            return 20
        case .transcribing, .composing:
            return 18
        }
    }
}

/// Grey and still until the microphone delivers audio (a Bluetooth headset
/// can take a second to switch), then the pulsing recording dot.
private struct PulsingDictationDot: View {
    var live: Bool

    var body: some View {
        StatusDot(color: live ? Brand.recording : Color.secondary, size: 7, pulses: live)
            .accessibilityLabel(Text(live ? "Recording" : "Starting the microphone"))
    }
}

/// Bars drawn from the microphone's measured loudness, newest on the right.
/// Flat while nothing arrives, so a silent or reconnecting microphone is
/// visible instead of hidden behind a decorative animation.
struct AudioLevelBars: View {
    let meter: AudioLevelMeter
    var barCount = 9
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 18

    var body: some View {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 15.0)) { _ in
            let levels = meter.recent(barCount)
            HStack(alignment: .center, spacing: 3) {
                ForEach(Array(levels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(.tint)
                        .frame(width: barWidth, height: Self.height(for: level, maxHeight: maxHeight))
                }
            }
            .frame(height: maxHeight)
        }
        .accessibilityHidden(true)
    }

    static func height(for level: Float, maxHeight: CGFloat, minHeight: CGFloat = 3) -> CGFloat {
        minHeight + CGFloat(min(max(level, 0), 1)) * (maxHeight - minHeight)
    }
}
