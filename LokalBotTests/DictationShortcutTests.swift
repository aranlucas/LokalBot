import AppKit
import Carbon.HIToolbox
import XCTest
@testable import LokalBot

/// The dictation shortcut can be changed in Settings.
final class DictationShortcutTests: XCTestCase {
    private let controlShiftD = DictationShortcut(
        keyCode: CGKeyCode(kVK_ANSI_D), modifiers: [.maskControl, .maskShift])

    func testDefaultStaysOptionSpace() {
        XCTAssertEqual(AppSettings().dictationShortcut, .handyDefault)
        XCTAssertEqual(DictationShortcut.handyDefault.displayLabel, "⌥ Space")
    }

    func testLabelsUseMacModifierOrder() {
        XCTAssertEqual(DictationShortcut(
            keyCode: CGKeyCode(kVK_Return), modifiers: [.maskCommand, .maskShift, .maskControl]).displayLabel,
                       "⌃⇧⌘ Return")
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_F5), modifiers: []).displayLabel, "F5")
        let letter = controlShiftD.displayLabel
        XCTAssertTrue(letter.hasPrefix("⌃⇧ "))
        XCTAssertFalse(letter.contains("Key "), "character keys are named from the keyboard layout")
    }

    func testShortcutsThatWouldBlockTypingAreRejected() {
        let d = CGKeyCode(kVK_ANSI_D)
        XCTAssertEqual(DictationShortcut(keyCode: d, modifiers: []).problem, .needsModifier)
        XCTAssertEqual(DictationShortcut(keyCode: d, modifiers: .maskShift).problem, .needsModifier,
                       "⇧D types a capital D")
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_Space), modifiers: []).problem, .needsModifier)
        XCTAssertEqual(DictationShortcut(keyCode: d, modifiers: .maskCommand).problem, .commandOnly)
        XCTAssertEqual(DictationShortcut(keyCode: CGKeyCode(kVK_Escape), modifiers: .maskAlternate).problem,
                       .reservedForCancel)

        XCTAssertNil(controlShiftD.problem)
        XCTAssertNil(DictationShortcut(keyCode: CGKeyCode(kVK_F5), modifiers: []).problem)
        XCTAssertNil(DictationShortcut(keyCode: CGKeyCode(kVK_Space), modifiers: .maskCommand).problem)
        XCTAssertNil(DictationShortcut.handyDefault.problem)
    }

    func testModifiersOutsideTheShortcutAreIgnored() {
        let withCapsLock = DictationShortcut(
            keyCode: CGKeyCode(kVK_Space), modifiers: [.maskAlternate, .maskAlphaShift])
        XCTAssertEqual(withCapsLock, .handyDefault)
    }

    func testShortcutPersistsWithSettings() throws {
        var settings = AppSettings()
        settings.dictationShortcut = controlShiftD
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.dictationShortcut, controlShiftD)

        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let stored = try XCTUnwrap(json["dictationShortcut"] as? [String: Any])
        XCTAssertEqual(stored["keyCode"] as? Int, kVK_ANSI_D)
        XCTAssertEqual(stored["modifiers"] as? [String], ["control", "shift"])
    }

    func testSettingsWithoutAShortcutOrWithAnUnsafeOneUseTheDefault() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(AppSettings())) as? [String: Any])
        json.removeValue(forKey: "dictationShortcut")
        XCTAssertEqual(try decode(json).dictationShortcut, .handyDefault)

        json["dictationShortcut"] = ["keyCode": kVK_ANSI_D, "modifiers": [String]()]
        XCTAssertEqual(try decode(json).dictationShortcut, .handyDefault,
                       "a bare letter would swallow typing system-wide")
    }

    @MainActor
    func testMonitorFollowsTheConfiguredShortcut() throws {
        let monitor = DictationInputMonitor()
        var shortcut = controlShiftD
        var toggles = 0
        monitor.triggerModeProvider = { .toggle }
        monitor.shortcutProvider = { shortcut }
        monitor.onToggle = { toggles += 1 }

        XCTAssertFalse(monitor.handle(type: .keyDown, event: try keyEvent(
            .handyDefault, down: true)), "⌥ Space passes through once it is not the shortcut")
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try keyEvent(controlShiftD, down: true)))
        XCTAssertTrue(monitor.handle(type: .keyUp, event: try keyEvent(controlShiftD, down: false)))
        XCTAssertEqual(toggles, 1)

        shortcut = .handyDefault
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try keyEvent(.handyDefault, down: true)))
        XCTAssertEqual(toggles, 2)
    }

    @MainActor
    func testRecordingANewShortcutSuspendsTheGlobalOne() throws {
        let monitor = DictationInputMonitor()
        var toggles = 0
        monitor.triggerModeProvider = { .toggle }
        monitor.shortcutProvider = { .handyDefault }
        monitor.onToggle = { toggles += 1 }

        monitor.isSuspended = true
        XCTAssertFalse(monitor.handle(type: .keyDown, event: try keyEvent(.handyDefault, down: true)),
                       "the recorder must receive the key")
        XCTAssertEqual(toggles, 0)
        monitor.isSuspended = false
        _ = monitor.handle(type: .keyUp, event: try keyEvent(.handyDefault, down: false))
        XCTAssertTrue(monitor.handle(type: .keyDown, event: try keyEvent(.handyDefault, down: true)))
        XCTAssertEqual(toggles, 1)
    }

    func testRecorderReadsAppKitModifiers() {
        XCTAssertEqual(DictationShortcutRecorder.eventFlags(from: [.control, .shift, .capsLock]),
                       [.maskControl, .maskShift])
        XCTAssertEqual(DictationShortcutRecorder.eventFlags(from: [.option, .command]),
                       [.maskAlternate, .maskCommand])
    }

    private func decode(_ json: [String: Any]) throws -> AppSettings {
        try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
    }

    private func keyEvent(_ shortcut: DictationShortcut, down: Bool) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(
            keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down))
        event.flags = shortcut.modifiers
        return event
    }
}
