import Combine
import Foundation

/// Polls the Accessibility-focused field on a timer and publishes a value-type
/// snapshot. Trimmed port of Cotabby's `FocusTracker`/`FocusTrackingModel`: no
/// AXObserver (inconsistent across hosts), just a main-runloop timer plus an
/// out-of-band `refreshNow()` the coordinator calls after a keystroke settles.
/// The timer uses Cotabby's idle backoff: fast after activity, slower after
/// repeated no-change captures.
@MainActor
final class CotypingFocusTracker: ObservableObject {
    @Published private(set) var focus: CotypingFocus = .none

    /// Fired (in addition to the publisher) whenever the focus changes.
    var onChange: ((CotypingFocus) -> Void)?
    var needsVisibleContextValidation: () -> Bool = { false }
    private var lastVisibleContext: CotypingVisibleContext.Snapshot?
    private var lastVisibleContextCapture: UInt64?

    func hasFreshVisibleContext(_ expected: CotypingVisibleContext.Snapshot) -> Bool {
        guard lastVisibleContext == expected, let captured = lastVisibleContextCapture else { return false }
        return DispatchTime.now().uptimeNanoseconds &- captured < 600_000_000
    }

    private var timer: Timer?
    private var baseIntervalMs: Int
    private var scheduledIntervalMs: Int?
    private var pollBackoff = CotypingFocusPollBackoff()
    private var capabilityFlickerGate = CotypingFocusCapabilityFlickerGate()
    private var lastCaptureUptimeNanoseconds: UInt64?
    private let snapshotExecutor: CotypingAXSnapshotExecutor
    private var timerCaptureTask: Task<Void, Never>?
    private var timerCaptureRequested = false
    private var timerCaptureGeneration: UInt64 = 0
    private var captureLifecycleGeneration: UInt64 = 0

    nonisolated static let defaultIntervalMs = 200

    init(
        intervalMs: Int = defaultIntervalMs,
        snapshotExecutor: CotypingAXSnapshotExecutor = .shared
    ) {
        self.baseIntervalMs = intervalMs
        self.snapshotExecutor = snapshotExecutor
    }

    func start() {
        guard timer == nil else { return }
        pollBackoff.reset()
        scheduleTimer()
        requestTimerCapture()
    }

    private var effectiveIntervalMs: Int {
        max(1, baseIntervalMs) * (needsVisibleContextValidation() ? 1 : pollBackoff.captureStride)
    }

    private func scheduleTimer() {
        timer?.invalidate()
        scheduledIntervalMs = effectiveIntervalMs
        let timer = Timer(timeInterval: Double(effectiveIntervalMs) / 1000.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTimerTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func rescheduleTimerIfNeeded() {
        guard timer != nil, scheduledIntervalMs != effectiveIntervalMs else { return }
        scheduleTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureLifecycleGeneration &+= 1
        timerCaptureGeneration &+= 1
        timerCaptureTask?.cancel()
        timerCaptureTask = nil
        timerCaptureRequested = false
        scheduledIntervalMs = nil
        lastCaptureUptimeNanoseconds = nil
        lastVisibleContext = nil
        lastVisibleContextCapture = nil
        pollBackoff.reset()
        capabilityFlickerGate = CotypingFocusCapabilityFlickerGate()
        if focus != .none {
            focus = .none
            onChange?(.none)
        }
    }

    private func handleTimerTick() {
        requestTimerCapture()
    }

    /// Latest-wins timer polling. A slow target app can never build an unbounded
    /// stack of timer tasks while the serialized AX executor is still working.
    private func requestTimerCapture() {
        guard timer != nil else { return }
        if timerCaptureTask != nil {
            timerCaptureRequested = true
            return
        }
        timerCaptureGeneration &+= 1
        let captureGeneration = timerCaptureGeneration
        timerCaptureTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.timerCaptureRequested = false
                let previous = self.focus
                let capture = await self.captureFocus(
                    includeSurface: false,
                    includeURL: false,
                    includeStyle: false,
                    includeVisibleContext: self.needsVisibleContextValidation())
                guard !Task.isCancelled,
                      self.timer != nil,
                      self.timerCaptureGeneration == captureGeneration else { break }
                if capture.completed {
                    self.pollBackoff.recordCapture(didChange: capture.focus != previous)
                    self.rescheduleTimerIfNeeded()
                }
            } while self.timerCaptureRequested
            if self.timerCaptureGeneration == captureGeneration {
                self.timerCaptureTask = nil
            }
        }
    }

    /// Asynchronous background capture. Publishes only on a real change so
    /// SwiftUI surfaces and the coordinator do not churn every tick.
    @discardableResult
    func refreshNow(
        includeSurface: Bool = false,
        includeURL: Bool = false,
        includeStyle: Bool = false,
        includeLearningScope: Bool = false,
        includeVisibleContext: Bool = false
    ) async -> CotypingFocus {
        pollBackoff.reset()
        let latest = await captureFocus(
            includeSurface: includeSurface,
            includeURL: includeURL,
            includeStyle: includeStyle,
            includeLearningScope: includeLearningScope,
            includeVisibleContext: includeVisibleContext).focus
        rescheduleTimerIfNeeded()
        return latest
    }

    @discardableResult
    func refreshIfStale(
        maxAgeMilliseconds: Int,
        includeSurface: Bool = false,
        includeURL: Bool = false,
        includeStyle: Bool = false,
        includeLearningScope: Bool = false,
        includeVisibleContext: Bool = false
    ) async -> CotypingFocus {
        guard Self.shouldRefreshCapture(
            lastCaptureUptimeNanoseconds: lastCaptureUptimeNanoseconds,
            nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds,
            maxAgeMilliseconds: maxAgeMilliseconds) else {
            return focus
        }
        return await refreshNow(
            includeSurface: includeSurface,
            includeURL: includeURL,
            includeStyle: includeStyle,
            includeLearningScope: includeLearningScope,
            includeVisibleContext: includeVisibleContext)
    }

    /// A validation capture fails closed on a whole-snapshot timeout. Callers
    /// that are about to display generated text must not validate against a
    /// cached field after the live target becomes unresponsive.
    func refreshForValidation(
        includeSurface: Bool = false,
        includeURL: Bool = false,
        includeStyle: Bool = false,
        includeLearningScope: Bool = false,
        includeVisibleContext: Bool = false
    ) async -> CotypingFocus? {
        let capture = await captureFocus(
            includeSurface: includeSurface,
            includeURL: includeURL,
            includeStyle: includeStyle,
            includeLearningScope: includeLearningScope,
            includeVisibleContext: includeVisibleContext)
        return capture.completed ? capture.focus : nil
    }

    private func captureFocus(
        includeSurface: Bool,
        includeURL: Bool,
        includeStyle: Bool,
        includeLearningScope: Bool = false,
        includeVisibleContext: Bool = false
    ) async -> (focus: CotypingFocus, completed: Bool) {
        var options: CotypingAXCaptureOptions = []
        if includeSurface { options.insert(.surface) }
        if includeURL { options.insert(.url) }
        if includeStyle { options.insert(.style) }
        if includeLearningScope { options.insert(.learningScope) }
        if includeVisibleContext { options.insert(.visibleContext) }
        let lifecycleGeneration = captureLifecycleGeneration
        let capture = await snapshotExecutor.capture(options: options)
        guard lifecycleGeneration == captureLifecycleGeneration,
              !capture.timedOut,
              let latestRaw = capture.focus else {
            if includeVisibleContext {
                lastVisibleContext = nil
                lastVisibleContextCapture = nil
                onChange?(.none)
            }
            return (focus, false)
        }
        lastCaptureUptimeNanoseconds = DispatchTime.now().uptimeNanoseconds
        if includeVisibleContext {
            lastVisibleContext = latestRaw.field?.visibleContext
            lastVisibleContextCapture = lastCaptureUptimeNanoseconds
        }
        let latest: CotypingFocus
        switch capabilityFlickerGate.evaluate(latestRaw) {
        case .apply:
            latest = latestRaw
        case .suppress:
            latest = focus
        }
        if latest != focus {
            focus = latest
            onChange?(latest)
        }
        return (latest, true)
    }

    nonisolated static func millisecondsSinceCapture(
        lastCaptureUptimeNanoseconds: UInt64?,
        nowUptimeNanoseconds: UInt64
    ) -> Int? {
        guard let lastCaptureUptimeNanoseconds else { return nil }
        guard nowUptimeNanoseconds >= lastCaptureUptimeNanoseconds else { return 0 }
        return Int((nowUptimeNanoseconds - lastCaptureUptimeNanoseconds) / 1_000_000)
    }

    nonisolated static func shouldRefreshCapture(
        lastCaptureUptimeNanoseconds: UInt64?,
        nowUptimeNanoseconds: UInt64,
        maxAgeMilliseconds: Int
    ) -> Bool {
        guard let age = millisecondsSinceCapture(
            lastCaptureUptimeNanoseconds: lastCaptureUptimeNanoseconds,
            nowUptimeNanoseconds: nowUptimeNanoseconds) else {
            return true
        }
        return age > maxAgeMilliseconds
    }
}
