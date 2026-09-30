import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit

struct LiveWorkspaceSource: WorkspaceSource {
    func frontmostApplication() -> RunningApp? {
        NSWorkspace.shared.frontmostApplication.map(RunningApp.init)
    }

    func runningApplications() -> [RunningApp] {
        NSWorkspace.shared.runningApplications.map(RunningApp.init)
    }

    func isRunning(processID: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: processID) != nil
    }

    func secondsSinceLastInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }
}

struct LiveAccessibilitySource: AccessibilitySource {
    func isTrusted() -> Bool { AXIsProcessTrusted() }

    func read(processID: pid_t, includeText: Bool) -> AccessibilityRead {
        let snapshot = ScreenAccessibilityReader.resolve(processID: processID, includeText: includeText)
        let failure = snapshot == nil && includeText
            ? ScreenAccessibilityReader.lastTextReadFailure(for: processID) : nil
        return AccessibilityRead(snapshot: snapshot, failure: failure)
    }

    func focusedWindowTitle(processID: pid_t) -> String? {
        FocusedWindowTitleLookup.resolveTitle(processID: processID)
    }

    func browserMeetingSnapshot(processID: pid_t, expectedURL: URL?) -> BrowserMeetingSession.Snapshot? {
        BrowserMeetingSession.liveSnapshot(processID: processID, expectedURL: expectedURL)
    }

    func browserReadIssue(processID: pid_t) -> BrowserMeetingSession.ReadIssue? {
        BrowserMeetingSession.lastReadIssue(processID: processID)
    }
}

/// Keeps the last ScreenCaptureKit window list so a capture uses the same
/// `SCWindow` the selection came from, exactly as before the seam existed.
final class LiveWindowSource: WindowSource, @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [CGWindowID: SCWindow] = [:]

    func screenCaptureGranted() -> Bool { CGPreflightScreenCaptureAccess() }

    func onScreenWindows() async throws -> [ScreenshotCaptureLayout.Window] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        lock.lock()
        windows = Dictionary(content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        lock.unlock()
        return content.windows.compactMap { window in
            guard let application = window.owningApplication else { return nil }
            return ScreenshotCaptureLayout.Window(
                id: window.windowID, processID: application.processID, appName: application.applicationName,
                title: window.title ?? "", frame: window.frame)
        }
    }

    func captureImage(windowID: CGWindowID) async throws -> CGImage {
        lock.lock()
        let window = windows[windowID]
        lock.unlock()
        guard let window else { throw CaptureEnvironmentError.windowUnavailable(windowID) }
        // Bound the source frame before ScreenCaptureKit allocates it. Vision
        // receives this same readable 1,500 px frame in the worker; requesting
        // a native 5K/6K IOSurface only inflated transient memory.
        let configuration = SCStreamConfiguration()
        // This filter contains only the AX-checked window. Display capture,
        // even with app exclusions, can include unchecked background domains.
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let dimensions = ScreenshotCaptureDimensions.bounded(
            pixelWidth: Int(filter.contentRect.width * CGFloat(filter.pointPixelScale)),
            pixelHeight: Int(filter.contentRect.height * CGFloat(filter.pointPixelScale)))
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.showsCursor = false
        configuration.includeChildWindows = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }
}

struct LiveAudioProcessSource: AudioProcessSource {
    func processes() throws -> [AudioProcess] { try CoreAudioUtils.listAudioProcesses() }
    func isProcessRunningInput(processID: pid_t) -> Bool { CoreAudioUtils.isProcessRunningInput(pid: processID) }
}

@MainActor
private final class DispatchCaptureTimer: CaptureTimer {
    private let item: DispatchWorkItem
    init(item: DispatchWorkItem) { self.item = item }
    func cancel() { item.cancel() }
}

@MainActor
private final class FoundationCaptureTimer: CaptureTimer {
    private let timer: Timer
    init(timer: Timer) { self.timer = timer }
    func cancel() { timer.invalidate() }
}

struct LiveCaptureClock: CaptureClock {
    func now() -> Date { Date() }
    func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(seconds)) }

    @MainActor
    func schedule(after seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        let item = DispatchWorkItem { MainActor.assumeIsolated { work() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
        return DispatchCaptureTimer(item: item)
    }

    @MainActor
    func repeating(every seconds: TimeInterval, _ work: @escaping @MainActor () -> Void) -> CaptureTimer {
        let timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: true) { _ in
            MainActor.assumeIsolated { work() }
        }
        return FoundationCaptureTimer(timer: timer)
    }
}
