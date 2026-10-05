import XCTest
import Combine
import Observation
@testable import LokalBot

/// The NavSection migration mapping (spec §2.1): capture names from the
/// UI-test host env and deep links resolve to sections, with legacy
/// pre-merge names mapping onto the merged pillars.
final class NavSectionMappingTests: XCTestCase {

    func testCaptureNamesMapToTheirSections() {
        XCTAssertEqual(AppState.NavSection(captureName: "timeline"), .timeline)
        XCTAssertEqual(AppState.NavSection(captureName: "meetings"), .meetings)
        XCTAssertEqual(AppState.NavSection(captureName: "people"), .people)
        XCTAssertEqual(AppState.NavSection(captureName: "Projects"), .projects)
        XCTAssertEqual(AppState.NavSection(captureName: "type"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "ask"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "settings"), .settings)
    }

    /// Spec §2.5: Settings absorbs Models — the legacy "models" capture name
    /// lands on Settings, and the SettingsTab mapping preselects its tab.
    func testLegacyModelsNameMapsToSettings() {
        XCTAssertEqual(AppState.NavSection(captureName: "models"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "Models"), .settings)
    }

    func testSettingsTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.SettingsTab(captureName: "models"), .models)
        XCTAssertEqual(AppState.SettingsTab(captureName: "general"), .general)
        XCTAssertEqual(AppState.SettingsTab(captureName: "recording"), .recording)
        XCTAssertEqual(AppState.SettingsTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.SettingsTab(captureName: "privacy"), .privacy)
        XCTAssertEqual(AppState.SettingsTab(captureName: "advanced"), .advanced)
        XCTAssertNil(AppState.SettingsTab(captureName: "settings"))
        XCTAssertNil(AppState.SettingsTab(captureName: "capture"))
    }

    /// The pre-split merged "capture" section name lands on Timeline.
    func testLegacyCaptureNameMapsToTimeline() {
        XCTAssertEqual(AppState.NavSection(captureName: "capture"), .timeline)
        XCTAssertEqual(AppState.NavSection(captureName: "Capture"), .timeline)
    }

    func testLegacyTypeNamesMapToSettings() {
        XCTAssertEqual(AppState.NavSection(captureName: "dictation"), .settings)
        XCTAssertEqual(AppState.NavSection(captureName: "Cotyping"), .settings)
    }

    func testLegacySearchAndChatNamesMapToAsk() {
        XCTAssertEqual(AppState.NavSection(captureName: "search"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "chat"), .ask)
        XCTAssertEqual(AppState.NavSection(captureName: "Search"), .ask)
    }

    func testUnknownNameIsNil() {
        XCTAssertNil(AppState.NavSection(captureName: "bogus"))
        XCTAssertNil(AppState.NavSection(captureName: ""))
    }

    func testTypeTabCaptureNamesSelectTheTab() {
        XCTAssertEqual(AppState.TypeTab(captureName: "dictation"), .dictation)
        XCTAssertEqual(AppState.TypeTab(captureName: "Cotyping"), .cotyping)
        XCTAssertNil(AppState.TypeTab(captureName: "type"))
        XCTAssertNil(AppState.TypeTab(captureName: "capture"))
    }

    func testTodayCaptureNameMapsToToday() {
        XCTAssertEqual(AppState.NavSection(captureName: "today"), .today)
        XCTAssertEqual(AppState.NavSection(captureName: "Today"), .today)
    }
}

/// Agent Mode's sidebar section (Task 16): the "agent" capture name resolves
/// to its NavSection so deep links and the UI-test host can land on it.
final class NavSectionAgentTests: XCTestCase {
    func testAgentSectionRoundTripsCaptureName() {
        XCTAssertEqual(AppState.NavSection(captureName: "agent"), .agent)
        XCTAssertEqual(AppState.NavSection(captureName: "Agent"), .agent)
    }
}

/// The ruling's landing surface: a fresh state opens on Today, the
/// glanceable summary — not on the forensic Timeline.
@MainActor
final class TodayLandingTests: XCTestCase {
    func testFreshAppStateLandsOnToday() {
        XCTAssertEqual(AppState().navSection, .today)
    }
}

@MainActor
final class SettingsNavigationPerformanceTests: XCTestCase {
    func testPageSwitchOnlyNotifiesNavigationReaders() {
        let app = AppState()
        var invalidations = 0
        let subscription = app.objectWillChange.sink { invalidations += 1 }
        let navigationChanged = expectation(description: "Navigation reader updates")
        withObservationTracking {
            _ = app.navSection
        } onChange: {
            navigationChanged.fulfill()
        }

        let pages: [AppState.NavSection] = [
            .settings, .timeline, .meetings, .people, .projects, .ask, .agent, .today
        ]
        for page in pages { app.navSection = page }

        XCTAssertEqual(invalidations, 0, "Page selection must not invalidate every AppState consumer")
        wait(for: [navigationChanged], timeout: 1)
        XCTAssertEqual(app.navSection, .today)
        withExtendedLifetime(subscription) {}
    }

    func testSettingsReadersStillObserveCategoryAndSearchFocus() {
        let app = AppState()
        let originalTab = app.settingsTab
        defer { app.settingsTab = originalTab }
        app.settingsTab = .general
        let categoryChanged = expectation(description: "Category reader updates")
        let focusChanged = expectation(description: "Search focus reader updates")
        withObservationTracking {
            _ = app.settingsTab
        } onChange: {
            categoryChanged.fulfill()
        }
        withObservationTracking {
            _ = app.focusedSettingID
        } onChange: {
            focusChanged.fulfill()
        }

        app.settingsTab = .writing
        app.focusedSettingID = "settings.dictationPreview"

        wait(for: [categoryChanged, focusChanged], timeout: 1)
        XCTAssertEqual(AppState().settingsTab, .writing, "The selected category must survive relaunch")
    }

    func testCategorySwitchDoesNotInvalidateTheWholeApp() {
        let app = AppState()
        let originalTab = app.settingsTab
        defer { app.settingsTab = originalTab }
        var invalidations = 0
        let subscription = app.objectWillChange.sink { invalidations += 1 }

        // The same mutations made by the Settings category picker, including
        // clearing a prior search highlight on each selection.
        for category in AppState.SettingsTab.allCases {
            app.settingsTab = category
            app.focusedSettingID = nil
        }

        XCTAssertEqual(invalidations, 0,
                       "Settings navigation must not rebuild unrelated AppState consumers")
        withExtendedLifetime(subscription) {}
    }
}

@MainActor
final class NavigationWorkTests: XCTestCase {
    func testUnchangedDreamMemoryDoesNotPublish() {
        let app = AppState()
        let originalSettings = app.settings
        defer { app.settings = originalSettings }
        app.settings.cotypingUseMeetingMemory = false
        app.settings.cotypingUseScreenMemory = false
        app.refreshDreamMemory()
        var updates = 0
        let observer = app.objectWillChange.sink { updates += 1 }
        app.refreshDreamMemory()
        app.refreshDreamMemory()
        XCTAssertEqual(updates, 0)
        withExtendedLifetime(observer) {}
    }

    func testBackgroundDreamReadRunsOffMainAndPublishesOnlyChanges() async {
        let app = AppState()
        let originalSettings = app.settings
        defer { app.settings = originalSettings }
        app.settings.cotypingUseMeetingMemory = false
        app.settings.cotypingUseScreenMemory = false
        let memory = DreamMemory(updatedAt: .distantPast)
        var updates = 0
        let observer = app.objectWillChange.sink { updates += 1 }
        for _ in 0..<2 {
            await app.refreshDreamMemoryInBackground {
                XCTAssertFalse(Thread.isMainThread, "File reads must not block navigation")
                return memory
            }
        }
        XCTAssertEqual(app.dreamMemory, memory)
        XCTAssertEqual(updates, 1)
        withExtendedLifetime(observer) {}
    }

    func testOlderDreamReadCannotOverwriteANewerRefresh() async {
        let app = AppState()
        let originalSettings = app.settings
        defer { app.settings = originalSettings }
        app.settings.cotypingUseMeetingMemory = false
        app.settings.cotypingUseScreenMemory = false
        let started = expectation(description: "Old read started")
        let release = DispatchSemaphore(value: 0)
        let oldRead = Task {
            await app.refreshDreamMemoryInBackground {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return DreamMemory(updatedAt: .distantPast)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let latest = DreamMemory(updatedAt: Date(timeIntervalSince1970: 1234))
        await app.refreshDreamMemoryInBackground { latest }
        release.signal()
        await oldRead.value
        XCTAssertEqual(app.dreamMemory, latest)
    }

    func testSynchronousRevocationRefreshSupersedesBackgroundRead() async {
        let app = AppState()
        let originalSettings = app.settings
        defer { app.settings = originalSettings }
        app.settings.cotypingUseMeetingMemory = false
        app.settings.cotypingUseScreenMemory = false
        let started = expectation(description: "Read started before revocation")
        let release = DispatchSemaphore(value: 0)
        let oldRead = Task {
            await app.refreshDreamMemoryInBackground {
                started.fulfill()
                _ = release.wait(timeout: .now() + 5)
                return DreamMemory(updatedAt: .distantPast)
            }
        }
        await fulfillment(of: [started], timeout: 2)
        app.refreshDreamMemory()
        let current = app.dreamMemory
        release.signal()
        await oldRead.value
        XCTAssertEqual(app.dreamMemory, current, "An old display read must not restore revoked memory")
    }

    func testSearchTargetWinsOverCategoryScrollReset() {
        let reset = SettingsScrollRequest(category: .dictation, focusedSettingID: nil)
        let search = SettingsScrollRequest(category: .dictation, focusedSettingID: "settings.dictationPreview")
        XCTAssertEqual(reset.targetID, SettingsScrollRequest.topID)
        XCTAssertEqual(search.targetID, "settings.dictationPreview")
        XCTAssertNotEqual(reset, search)
        XCTAssertNotEqual(reset, SettingsScrollRequest(category: .general, focusedSettingID: nil))
    }
}


@MainActor
final class LoginItemPerformanceTests: XCTestCase {
    func testStatusReadNeverRunsOnMainThreadOrDuringRendering() async {
        let read = expectation(description: "One background status read")
        read.assertForOverFulfill = true
        let state = LoginItemState(read: {
            XCTAssertFalse(Thread.isMainThread, "ServiceManagement IPC must not block navigation")
            read.fulfill()
            return true
        }, write: { _ in XCTFail("Opening Settings must not change login registration") })
        XCTAssertFalse(state.isLoaded)
        await state.refresh()
        for _ in 0..<100 { XCTAssertTrue(state.isEnabled) }
        XCTAssertTrue(state.isLoaded)
        XCTAssertFalse(state.isBusy)
        await fulfillment(of: [read], timeout: 1)
    }

    func testFailedWriteRestoresActualStatusAndReportsError() async {
        let state = LoginItemState(read: { false }, write: { _ in
            XCTAssertFalse(Thread.isMainThread)
            throw NSError(domain: "LoginItemTest", code: 1)
        })
        await state.refresh()
        await state.setEnabled(true)
        XCTAssertFalse(state.isEnabled)
        XCTAssertNotNil(state.error)
        XCTAssertFalse(state.isBusy)
    }
}
