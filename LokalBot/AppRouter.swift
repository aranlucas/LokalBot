import Foundation
import Observation

/// Main-window routing: which page is visible, the sticky Settings and
/// writing selections, the Today/Actions toggle, People/Projects selections,
/// and the evidence detour's way back.
///
/// Observation is per property, so a page switch only re-renders views that
/// read the page, and never fans out through `AppState.objectWillChange`.
/// Routing is synchronous and in memory; the only side effect is persisting
/// the two sticky tabs to the given defaults.
@MainActor @Observable
final class AppRouter {
    typealias Section = AppState.NavSection
    typealias SettingsTab = AppState.SettingsTab
    typealias TypeTab = AppState.TypeTab

    static let settingsTabDefaultsKey = "lokalbotv3.settings.selectedTab"
    static let typeTabDefaultsKey = "lokalbotv3.type.selectedTab"

    /// Where an evidence detour returns, captured when it begins. A nil
    /// selection leaves the meeting selection as it is on return.
    struct EvidenceReturn: Equatable {
        let section: Section
        let meetingIDs: Set<Meeting.ID>?
    }

    private(set) var section: Section = .today
    private(set) var settingsTab: SettingsTab = .general
    private(set) var typeTab: TypeTab = .dictation
    private(set) var focusedSettingID: String?
    /// Today shows the Actions workspace instead of the summary.
    private(set) var showingActions = false
    private(set) var selectedPersonID: String?
    private(set) var selectedProjectID: String?
    /// The meeting opened as evidence; Meetings keeps it visible past filters.
    private(set) var evidenceMeetingID: Meeting.ID?
    private(set) var evidenceReturn: EvidenceReturn?

    @ObservationIgnored private let defaults: UserDefaults

    /// Restores the sticky tabs. Without a stored writing tab, existing
    /// installs keep Dictation and new installs lead with Autocomplete; that
    /// default is not persisted until the user picks a tab.
    init(defaults: UserDefaults, isExistingInstall: Bool) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.settingsTabDefaultsKey),
           let stored = SettingsTab(rawValue: raw) {
            settingsTab = stored
        }
        if let raw = defaults.string(forKey: Self.typeTabDefaultsKey),
           let stored = TypeTab(rawValue: raw) {
            typeTab = stored
        } else {
            typeTab = isExistingInstall ? .dictation : .cotyping
        }
    }

    var evidenceReturnSection: Section? { evidenceReturn?.section }

    // MARK: - Selections

    func show(_ section: Section) {
        guard self.section != section else { return }
        NavigationTiming.selected("page.\(section)")
        self.section = section
    }

    func selectSettingsTab(_ tab: SettingsTab) {
        guard settingsTab != tab else { return }
        NavigationTiming.selected("settings.\(tab.rawValue)")
        settingsTab = tab
        defaults.set(tab.rawValue, forKey: Self.settingsTabDefaultsKey)
    }

    func selectTypeTab(_ tab: TypeTab) {
        if typeTab != tab { typeTab = tab }
        defaults.set(tab.rawValue, forKey: Self.typeTabDefaultsKey)
    }

    func focusSetting(_ id: String?) {
        guard focusedSettingID != id else { return }
        focusedSettingID = id
    }

    func setShowingActions(_ showing: Bool) {
        guard showingActions != showing else { return }
        showingActions = showing
    }

    func selectPerson(_ id: String?) {
        guard selectedPersonID != id else { return }
        selectedPersonID = id
    }

    func selectProject(_ id: String?) {
        guard selectedProjectID != id else { return }
        selectedProjectID = id
    }

    func setEvidenceMeeting(_ id: Meeting.ID?) {
        guard evidenceMeetingID != id else { return }
        evidenceMeetingID = id
    }

    /// Override or clear the return destination (UI-test capture states and
    /// direct writes through `AppState.evidenceReturnSection`).
    func setEvidenceReturnSection(_ section: Section?, meetingIDs: Set<Meeting.ID>? = nil) {
        let next = section.map { EvidenceReturn(section: $0, meetingIDs: meetingIDs) }
        guard evidenceReturn != next else { return }
        evidenceReturn = next
    }

    // MARK: - Intents

    /// A sidebar row: an explicit destination abandons any evidence detour,
    /// and Today always lands on its summary.
    func selectFromSidebar(_ section: Section) {
        if section == .today { setShowingActions(false) }
        setEvidenceReturnSection(nil)
        show(section)
    }

    func openActions() {
        setShowingActions(true)
        show(.today)
    }

    func openSettings(tab: SettingsTab? = nil) {
        if let tab { selectSettingsTab(tab) }
        focusSetting(nil)
        setEvidenceReturnSection(nil)
        show(.settings)
    }

    /// Legacy writing commands route to Writing settings with the tool's
    /// preview focused.
    func openType(_ tab: TypeTab) {
        selectTypeTab(tab)
        openSettings(tab: .writing)
        focusSetting(tab == .cotyping ? "settings.autocompletePreview" : "settings.dictationPreview")
    }

    func openPerson(_ id: String) {
        selectPerson(id)
        show(.people)
    }

    func openProject(_ id: String) {
        selectProject(id)
        show(.projects)
    }

    /// Detour to evidence at `destination`. The first hop away from another
    /// page records where to return and that page's meeting selection.
    func beginEvidence(at destination: Section, preservingMeetingIDs meetingIDs: Set<Meeting.ID>) {
        if section != destination {
            setEvidenceReturnSection(section, meetingIDs: meetingIDs)
        }
        show(destination)
    }

    /// Ends the detour and returns where it went, or nil when there is
    /// nothing to return to. The caller restores `meetingIDs` when present.
    @discardableResult
    func returnFromEvidence() -> EvidenceReturn? {
        guard let destination = evidenceReturn else { return nil }
        evidenceReturn = nil
        show(destination.section)
        return destination
    }
}
