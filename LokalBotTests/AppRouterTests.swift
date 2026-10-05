import XCTest
import Combine
import Observation
@testable import LokalBot

/// The router in isolation: restoration, intents, the evidence detour and
/// per-property observation.
@MainActor
final class AppRouterTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppRouterTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func makeRouter(existingInstall: Bool = true) -> AppRouter {
        AppRouter(defaults: defaults, isExistingInstall: existingInstall)
    }

    func testFreshRouterLandsOnTodayWithNothingSelected() {
        let router = makeRouter()
        XCTAssertEqual(router.section, .today)
        XCTAssertEqual(router.settingsTab, .general)
        XCTAssertFalse(router.showingActions)
        XCTAssertNil(router.focusedSettingID)
        XCTAssertNil(router.selectedPersonID)
        XCTAssertNil(router.selectedProjectID)
        XCTAssertNil(router.evidenceMeetingID)
        XCTAssertNil(router.evidenceReturn)
    }

    func testStickyTabsSurviveRelaunch() {
        let router = makeRouter()
        router.selectSettingsTab(.privacy)
        router.selectTypeTab(.cotyping)

        let relaunched = makeRouter()
        XCTAssertEqual(relaunched.settingsTab, .privacy)
        XCTAssertEqual(relaunched.typeTab, .cotyping)
    }

    func testWritingTabDefaultDependsOnInstallAgeAndIsNotPersisted() {
        XCTAssertEqual(makeRouter(existingInstall: true).typeTab, .dictation)
        XCTAssertEqual(makeRouter(existingInstall: false).typeTab, .cotyping)
        XCTAssertNil(defaults.string(forKey: AppRouter.typeTabDefaultsKey),
                     "An unchosen default must not become a stored preference")
    }

    func testUnknownStoredTabsFallBack() {
        defaults.set("bogus", forKey: AppRouter.settingsTabDefaultsKey)
        defaults.set("bogus", forKey: AppRouter.typeTabDefaultsKey)
        let router = makeRouter(existingInstall: false)
        XCTAssertEqual(router.settingsTab, .general)
        XCTAssertEqual(router.typeTab, .cotyping)
    }

    func testSidebarSelectionAbandonsEvidenceAndActions() {
        let router = makeRouter()
        router.openActions()
        XCTAssertEqual(router.section, .today)
        XCTAssertTrue(router.showingActions)

        router.beginEvidence(at: .meetings, preservingMeetingIDs: [])
        XCTAssertEqual(router.evidenceReturnSection, .today)

        router.selectFromSidebar(.today)
        XCTAssertEqual(router.section, .today)
        XCTAssertFalse(router.showingActions, "Today from the sidebar lands on its summary")
        XCTAssertNil(router.evidenceReturn)
    }

    func testSidebarSelectionOfAnotherPageKeepsActionsForReturn() {
        let router = makeRouter()
        router.openActions()
        router.selectFromSidebar(.people)
        XCTAssertEqual(router.section, .people)
        XCTAssertTrue(router.showingActions)
    }

    func testOpenTypeFocusesTheToolPreviewInWritingSettings() {
        let router = makeRouter()
        router.openType(.cotyping)
        XCTAssertEqual(router.section, .settings)
        XCTAssertEqual(router.settingsTab, .writing)
        XCTAssertEqual(router.typeTab, .cotyping)
        XCTAssertEqual(router.focusedSettingID, "settings.autocompletePreview")
        XCTAssertEqual(defaults.string(forKey: AppRouter.typeTabDefaultsKey), "cotyping")

        router.openType(.dictation)
        XCTAssertEqual(router.settingsTab, .dictation)
        XCTAssertEqual(router.focusedSettingID, "settings.dictationPreview")
    }

    func testOpenSettingsClearsSearchFocusAndEvidenceReturn() {
        let router = makeRouter()
        router.focusSetting("settings.retentionDays")
        router.beginEvidence(at: .timeline, preservingMeetingIDs: [])
        router.openSettings()
        XCTAssertEqual(router.section, .settings)
        XCTAssertEqual(router.settingsTab, .general, "No tab keeps the current category")
        XCTAssertNil(router.focusedSettingID)
        XCTAssertNil(router.evidenceReturn)

        router.openSettings(tab: .models)
        XCTAssertEqual(router.settingsTab, .models)
    }

    func testOpenPersonAndProjectSelectThenNavigate() {
        let router = makeRouter()
        router.openPerson("person-1")
        XCTAssertEqual(router.section, .people)
        XCTAssertEqual(router.selectedPersonID, "person-1")
        router.openProject("project-1")
        XCTAssertEqual(router.section, .projects)
        XCTAssertEqual(router.selectedProjectID, "project-1")
        XCTAssertEqual(router.selectedPersonID, "person-1", "Each page keeps its own selection")
    }

    func testEvidenceDetourRecordsOnlyTheFirstHop() {
        let router = makeRouter()
        let origin: Set<Meeting.ID> = [UUID()]
        router.show(.ask)
        router.beginEvidence(at: .meetings, preservingMeetingIDs: origin)
        XCTAssertEqual(router.section, .meetings)
        router.beginEvidence(at: .meetings, preservingMeetingIDs: [UUID()])
        router.beginEvidence(at: .timeline, preservingMeetingIDs: [UUID()])
        XCTAssertEqual(router.evidenceReturnSection, .meetings,
                       "Hopping between evidence pages returns to the last page left")

        let other = makeRouter()
        other.show(.ask)
        other.beginEvidence(at: .meetings, preservingMeetingIDs: origin)
        other.beginEvidence(at: .meetings, preservingMeetingIDs: [UUID()])
        let destination = other.returnFromEvidence()
        XCTAssertEqual(destination, AppRouter.EvidenceReturn(section: .ask, meetingIDs: origin),
                       "A second meeting on the same page keeps the original return")
        XCTAssertEqual(other.section, .ask)
        XCTAssertNil(other.evidenceReturn)
        XCTAssertNil(other.returnFromEvidence(), "Returning twice is a no-op")
    }

    func testDirectReturnOverrideDoesNotRestoreASelection() {
        let router = makeRouter()
        router.setEvidenceReturnSection(.today)
        router.show(.timeline)
        let destination = router.returnFromEvidence()
        XCTAssertEqual(destination?.section, .today)
        XCTAssertNil(destination?.meetingIDs)
        XCTAssertEqual(router.section, .today)
    }

    func testPageSwitchDoesNotNotifySettingsOrSelectionReaders() {
        let router = makeRouter()
        var unrelatedChanges = 0
        withObservationTracking {
            _ = router.settingsTab
            _ = router.focusedSettingID
            _ = router.selectedPersonID
            _ = router.evidenceReturn
            _ = router.showingActions
        } onChange: {
            unrelatedChanges += 1
        }
        let sectionChanged = expectation(description: "Section reader updates")
        withObservationTracking {
            _ = router.section
        } onChange: {
            sectionChanged.fulfill()
        }

        for page: AppRouter.Section in [.settings, .timeline, .meetings, .people, .ask] {
            router.show(page)
        }

        wait(for: [sectionChanged], timeout: 1)
        XCTAssertEqual(unrelatedChanges, 0)
    }

    func testRepeatedSelectionDoesNotNotify() {
        let router = makeRouter()
        router.show(.people)
        router.selectPerson("p")
        router.focusSetting("settings.retentionDays")
        var changes = 0
        withObservationTracking {
            _ = router.section
            _ = router.selectedPersonID
            _ = router.focusedSettingID
            _ = router.settingsTab
        } onChange: {
            changes += 1
        }
        router.show(.people)
        router.selectPerson("p")
        router.focusSetting("settings.retentionDays")
        router.selectSettingsTab(router.settingsTab)
        XCTAssertEqual(changes, 0)
    }
}

/// AppState's navigation handoffs now route through `AppRouter`. These keep
/// the compatibility accessors and cross-surface intents behaving as before
/// while proving routing no longer broadcasts through `objectWillChange`.
@MainActor
final class AppRouterHandoffTests: XCTestCase {
    func testCompatibilityAccessorsForwardToTheRouter() {
        let app = AppState()
        app.navSection = .projects
        app.selectedProjectID = "project"
        app.selectedPersonID = "person"
        app.showingActions = true
        app.evidenceMeetingID = UUID()
        XCTAssertEqual(app.router.section, .projects)
        XCTAssertEqual(app.router.selectedProjectID, "project")
        XCTAssertEqual(app.router.selectedPersonID, "person")
        XCTAssertTrue(app.router.showingActions)
        XCTAssertEqual(app.router.evidenceMeetingID, app.evidenceMeetingID)

        app.router.show(.agent)
        XCTAssertEqual(app.navSection, .agent)
    }

    func testRoutingIntentsDoNotInvalidateEveryAppStateConsumer() {
        let app = AppState()
        let originalTypeTab = app.typeTab
        let originalTab = app.settingsTab
        defer {
            app.typeTab = originalTypeTab
            app.settingsTab = originalTab
        }
        var invalidations = 0
        let subscription = app.objectWillChange.sink { invalidations += 1 }

        app.openActions()
        app.showingActions = false
        app.openPerson("person")
        app.openProject("project")
        app.typeTab = app.typeTab == .dictation ? .cotyping : .dictation
        app.evidenceMeetingID = UUID()
        app.evidenceReturnSection = .ask
        app.returnFromEvidence()

        XCTAssertEqual(invalidations, 0, "Routing must not rebuild unrelated AppState consumers")
        withExtendedLifetime(subscription) {}
    }

    func testOpeningMeetingFromPeopleReturnsWithSelectionRestored() {
        let app = AppState()
        let origin = UUID()
        let evidence = UUID()
        app.openPerson("person")
        app.selectedMeetingIDs = [origin]

        app.openMeeting(evidence, seek: 12)
        XCTAssertEqual(app.navSection, .meetings)
        XCTAssertEqual(app.evidenceMeetingID, evidence)
        XCTAssertEqual(app.evidenceReturnSection, .people)
        XCTAssertEqual(app.selectedMeetingIDs, [evidence])
        XCTAssertEqual(app.navigationHandoff.consumeMeetingEvidence(for: evidence)?.seconds, 12)

        app.returnFromEvidence()
        XCTAssertEqual(app.navSection, .people)
        XCTAssertEqual(app.selectedMeetingIDs, [origin])
        XCTAssertEqual(app.selectedPersonID, "person")
        XCTAssertNil(app.evidenceReturnSection)
    }

    func testScreenEvidenceFromMeetingsReturnsToTheMeeting() {
        let app = AppState()
        let origin = UUID()
        app.navSection = .meetings
        app.selectedMeetingIDs = [origin]

        app.openScreenSnapshot(7)
        XCTAssertEqual(app.navSection, .timeline)
        XCTAssertTrue(app.selectedMeetingIDs.isEmpty)
        XCTAssertEqual(app.evidenceReturnSection, .meetings)

        app.returnFromEvidence()
        XCTAssertEqual(app.navSection, .meetings)
        XCTAssertEqual(app.selectedMeetingIDs, [origin])
    }

    func testSettingsDestinationAbandonsEvidenceDetour() {
        let app = AppState()
        let originalTab = app.settingsTab
        defer { app.settingsTab = originalTab }
        app.navSection = .ask
        app.openMeeting(UUID())
        app.openSettings(tab: .privacy)
        XCTAssertEqual(app.navSection, .settings)
        XCTAssertEqual(app.settingsTab, .privacy)
        XCTAssertNil(app.evidenceReturnSection)
    }

    func testLegacyTypeCommandLandsOnWritingSettings() {
        let app = AppState()
        let originalTypeTab = app.typeTab
        let originalTab = app.settingsTab
        defer {
            app.typeTab = originalTypeTab
            app.settingsTab = originalTab
        }
        app.openType(.dictation)
        XCTAssertEqual(app.navSection, .settings)
        XCTAssertEqual(app.settingsTab, .dictation)
        XCTAssertEqual(app.typeTab, .dictation)
        XCTAssertEqual(app.focusedSettingID, "settings.dictationPreview")
    }
}
