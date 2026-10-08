import CoreGraphics
import Foundation

/// Global shortcut watcher for Handy-style dictation. It consumes a key
/// shortcut so the trigger never leaks a stray Space into the focused app. A
/// modifier-only shortcut (⌃⌥) is observed without consuming anything, so
/// other shortcuts that start with the same modifiers keep working.
@MainActor
final class DictationInputMonitor {
    var onStart: (() -> Void)?
    var onStop: (() -> Void)?
    var onToggle: (() -> Void)?
    /// A push-to-talk chord turned out to be another shortcut (⌃⌥ then T).
    var onCancel: (() -> Void)?
    /// Esc while a dictation is starting or recording.
    var onEscape: (() -> Void)?
    /// Whether a dictation is starting or recording. Esc is consumed only
    /// then, and Tap or hold uses it to tell a finishing tap from a start.
    var isDictationActive: () -> Bool = { false }
    /// Tap or hold: a press shorter than this keeps recording after release.
    var tapHoldThreshold: TimeInterval = 0.3
    var triggerModeProvider: () -> DictationTriggerMode = { .pushToTalk }
    var shortcutProvider: () -> DictationShortcut = { .handyDefault }
    /// How long a modifier-only push-to-talk chord is held before dictation
    /// starts, so ⌃⌥ followed quickly by another key never opens the microphone.
    var chordHoldDelay: TimeInterval = 0.2

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isRunning = false
    /// While Settings records a new shortcut, every key passes through so the
    /// current shortcut can be pressed (and recorded) without starting dictation.
    var isSuspended = false {
        didSet { if isSuspended { resetChord(stoppingPushToTalk: true) } }
    }
    private var shortcutIsDown = false
    private var activeTriggerMode: DictationTriggerMode?
    private var activeShortcut: DictationShortcut?
    /// Tap or hold: when the current press began, or nil when that press
    /// finished a running dictation and its release must do nothing.
    private var tapHoldPressedAt: Date?
    /// Esc cancelled while the key shortcut was held; its release is swallowed.
    private var heldShortcutCancelledByEscape = false

    /// Modifier-only chord state.
    private var chordModifiers: CGEventFlags?
    private var chordMode: DictationTriggerMode?
    private var chordInterrupted = false
    private var chordStarted = false
    private var chordPressedAt: Date?
    /// Tap or hold: the chord was pressed while dictating, so a clean
    /// release finishes instead of starting.
    private var chordFinishesOnRelease = false
    private var pendingChordStart: DispatchWorkItem?

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
            | CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: dictationShortcutCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    func stop(releasingHeldShortcut: Bool = false) {
        let shouldStop = releasingHeldShortcut
            && shortcutIsDown
            && (activeTriggerMode == .pushToTalk || (activeTriggerMode == .tapOrHold && tapHoldPressedAt != nil))
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        tap = nil
        source = nil
        shortcutIsDown = false
        activeTriggerMode = nil
        activeShortcut = nil
        heldShortcutCancelledByEscape = false
        resetChord(stoppingPushToTalk: releasingHeldShortcut)
        isRunning = false
        if shouldStop { onStop?() }
    }

    /// Returns true when the original event should be swallowed.
    func handle(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // A disabled event tap can swallow the physical key-up. Treat the
            // disable notification as a fail-safe release before re-enabling,
            // otherwise push-to-talk may record indefinitely.
            let shouldStop = shortcutIsDown && (activeTriggerMode == .pushToTalk
                || (activeTriggerMode == .tapOrHold && tapHoldPressedAt != nil))
            shortcutIsDown = false
            activeTriggerMode = nil
            activeShortcut = nil
            heldShortcutCancelledByEscape = false
            resetChord(stoppingPushToTalk: true)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            if shouldStop { onStop?() }
            return false
        }
        guard !isSuspended else { return false }
        if type == .keyDown, Self.isEscape(event, allowing: heldShortcutModifiers), isDictationActive() {
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                releaseHeldShortcutAfterEscape()
                onEscape?()
            }
            return true
        }
        if type == .flagsChanged {
            handleModifiers(event.flags.dictationRelevantModifiers)
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }

        if type == .keyDown, chordModifiers != nil {
            interruptChord()
        }

        let shortcut = shortcutProvider()
        let isMatchingShortcut = shortcut.matches(event)
        let isHeldShortcutRelease = shortcutIsDown
            && type == .keyUp
            && (activeShortcut ?? shortcut).matchesKeyCode(event)
        guard isMatchingShortcut || isHeldShortcutRelease else { return false }
        if heldShortcutCancelledByEscape, isHeldShortcutRelease {
            heldShortcutCancelledByEscape = false
            shortcutIsDown = false
            activeTriggerMode = nil
            activeShortcut = nil
            return true
        }

        let triggerMode = type == .keyUp
            ? (activeTriggerMode ?? triggerModeProvider())
            : triggerModeProvider()
        switch triggerMode {
        case .pushToTalk:
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !shortcutIsDown && !isRepeat {
                    shortcutIsDown = true
                    activeTriggerMode = .pushToTalk
                    activeShortcut = shortcut
                    onStart?()
                }
            } else {
                if shortcutIsDown {
                    shortcutIsDown = false
                    activeTriggerMode = nil
                    activeShortcut = nil
                    onStop?()
                }
            }
        case .toggle:
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !shortcutIsDown && !isRepeat {
                    shortcutIsDown = true
                    activeTriggerMode = .toggle
                    activeShortcut = shortcut
                    onToggle?()
                }
            } else {
                shortcutIsDown = false
                activeTriggerMode = nil
                activeShortcut = nil
            }
        case .tapOrHold:
            if type == .keyDown {
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                if !shortcutIsDown && !isRepeat {
                    shortcutIsDown = true
                    activeTriggerMode = .tapOrHold
                    activeShortcut = shortcut
                    if isDictationActive() {
                        tapHoldPressedAt = nil
                        onStop?()
                    } else {
                        tapHoldPressedAt = Date()
                        onStart?()
                    }
                }
            } else if shortcutIsDown {
                shortcutIsDown = false
                activeTriggerMode = nil
                activeShortcut = nil
                if let pressedAt = tapHoldPressedAt, Date().timeIntervalSince(pressedAt) >= tapHoldThreshold {
                    onStop?()
                }
                tapHoldPressedAt = nil
            }
        }
        return true
    }

    /// Esc alone, or with only the modifiers of the shortcut being held: Esc
    /// pressed while holding ⌥ Space arrives with ⌥ set.
    static func isEscape(_ event: CGEvent, allowing held: CGEventFlags) -> Bool {
        CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)) == DictationShortcutKeyNames.escape
            && held.isSuperset(of: event.flags.dictationRelevantModifiers)
    }

    /// Modifiers of the shortcut or chord currently held down.
    private var heldShortcutModifiers: CGEventFlags {
        if let chordModifiers { return chordModifiers }
        if shortcutIsDown, let activeShortcut { return activeShortcut.modifiers }
        return []
    }

    /// Esc cancelled the dictation; the shortcut's release must not finish it.
    private func releaseHeldShortcutAfterEscape() {
        if shortcutIsDown {
            heldShortcutCancelledByEscape = true
            tapHoldPressedAt = nil
        }
        if chordModifiers != nil {
            pendingChordStart?.cancel()
            pendingChordStart = nil
            chordInterrupted = true
            chordStarted = false
            chordFinishesOnRelease = false
        }
    }

    // MARK: - Modifier-only chords

    /// Push to talk starts after `chordHoldDelay` and stops on release. Toggle
    /// fires on a clean release, so ⌃⌥ used as part of another shortcut never
    /// toggles dictation.
    private func handleModifiers(_ modifiers: CGEventFlags) {
        if let held = chordModifiers {
            if modifiers.isSuperset(of: held) {
                // Another modifier joined (⌃⌥⌘): a different shortcut, unless
                // dictation is already running from this hold.
                if modifiers != held, !chordStarted { interruptChord() }
                return
            }
            releaseChord()
            return
        }
        let shortcut = shortcutProvider()
        guard shortcut.isModifierOnly, modifiers == shortcut.modifiers else { return }
        chordModifiers = modifiers
        chordInterrupted = false
        chordStarted = false
        chordFinishesOnRelease = false
        chordPressedAt = Date()
        let mode = triggerModeProvider()
        chordMode = mode
        if mode == .tapOrHold, isDictationActive() {
            chordFinishesOnRelease = true
            return
        }
        guard mode == .pushToTalk || mode == .tapOrHold else { return }
        let start = DispatchWorkItem { [weak self] in
            guard let self, self.chordModifiers != nil, !self.chordInterrupted, !self.isSuspended else { return }
            self.pendingChordStart = nil
            self.chordStarted = true
            self.onStart?()
        }
        pendingChordStart = start
        DispatchQueue.main.asyncAfter(deadline: .now() + chordHoldDelay, execute: start)
    }

    private func interruptChord() {
        guard chordModifiers != nil, !chordInterrupted else { return }
        chordInterrupted = true
        pendingChordStart?.cancel()
        pendingChordStart = nil
        if chordStarted, chordMode == .pushToTalk || chordMode == .tapOrHold {
            chordStarted = false
            onCancel?()
        }
    }

    private func releaseChord() {
        let mode = chordMode
        let started = chordStarted
        let clean = !chordInterrupted
        let finishes = chordFinishesOnRelease
        let held = chordPressedAt.map { Date().timeIntervalSince($0) } ?? 0
        resetChord(stoppingPushToTalk: false)
        switch mode {
        case .pushToTalk:
            if started { onStop?() }
        case .toggle:
            if clean { onToggle?() }
        case .tapOrHold:
            if finishes {
                if clean { onStop?() }
            } else if started {
                // A hold finishes on release; a tap keeps recording.
                if held >= tapHoldThreshold { onStop?() }
            } else if clean {
                // Released before the hold delay: a tap, so start now.
                onStart?()
            }
        case nil:
            break
        }
    }

    private func resetChord(stoppingPushToTalk: Bool) {
        let shouldStop = stoppingPushToTalk && chordStarted && (chordMode == .pushToTalk || chordMode == .tapOrHold)
        pendingChordStart?.cancel()
        pendingChordStart = nil
        chordModifiers = nil
        chordMode = nil
        chordInterrupted = false
        chordStarted = false
        chordFinishesOnRelease = false
        chordPressedAt = nil
        if shouldStop { onStop?() }
    }
}

private func dictationShortcutCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<DictationInputMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    let swallow = MainActor.assumeIsolated { monitor.handle(type: type, event: event) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
