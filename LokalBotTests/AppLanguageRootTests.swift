import AppKit
import SwiftUI
import XCTest
@testable import LokalBot

final class AppLanguageRootTests: XCTestCase {
    /// In-process environment propagation: no window is shown and no input is
    /// sent. Two independently created hosting views share the production root.
    @MainActor
    func testIndependentHostingRootsUpdateInPlaceAndOverrideInheritedLocale() async {
        var initialSettings = AppSettings()
        initialSettings.appLanguage = .english
        let store = SettingsStore(initialSettings: initialSettings)
        let steps = ["English initially", "Chinese after selection", "English after selection"]
            .map { expectation(description: $0) }
        for step in steps { step.expectedFulfillmentCount = 2 }
        var observed = [[String](), [String]()]
        var creations = [0, 0]
        let hosts = ["en", "zh-Hans"].enumerated().map { index, inheritedLocale in
            let probe = LocaleProbe(
                onCreate: { creations[index] += 1 },
                onUpdate: { locale in
                    guard observed[index].last != locale.identifier else { return }
                    observed[index].append(locale.identifier)
                    let step = observed[index].count - 1
                    if steps.indices.contains(step) { steps[step].fulfill() }
                })
            let host = NSHostingView(rootView: probe
                .appLanguageRoot(store)
                .environment(\.locale, Locale(identifier: inheritedLocale)))
            host.frame = NSRect(x: 0, y: 0, width: 100, height: 40)
            host.layoutSubtreeIfNeeded()
            return host
        }
        // Retain the hosts while SwiftUI processes publisher updates.
        defer { _ = hosts }
        await fulfillment(of: [steps[0]], timeout: 3)
        XCTAssertEqual(observed, [["en"], ["en"]])

        store.current.appLanguage = .simplifiedChinese
        await fulfillment(of: [steps[1]], timeout: 3)
        XCTAssertEqual(observed, [["en", "zh-Hans"], ["en", "zh-Hans"]])

        store.current.appLanguage = .english
        await fulfillment(of: [steps[2]], timeout: 3)
        XCTAssertEqual(observed, [["en", "zh-Hans", "en"], ["en", "zh-Hans", "en"]])
        XCTAssertEqual(creations, [1, 1], "Switching language must preserve the hosted content's identity")
        XCTAssertEqual(store.current, initialSettings, "Interface changes must leave every other preference unchanged")
    }
}

private struct LocaleProbe: NSViewRepresentable {
    let onCreate: () -> Void
    let onUpdate: (Locale) -> Void

    func makeNSView(context: Context) -> NSView {
        onCreate()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        onUpdate(context.environment.locale)
    }
}
