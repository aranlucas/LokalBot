import AppKit
import CoreGraphics

/// Keyboard and mouse hooks (event taps) on this Mac, grouped by the process
/// that holds them. An app that leaves an old tap behind each time it restarts
/// part of itself slows every keystroke once enough pile up, and autocomplete,
/// which draws while you type, takes the blame; Cotypist 2026.4 traced such
/// reports to Karabiner-Elements and Mos. `LokalBot --event-taps` prints this
/// as JSON while the app runs, so a leak, LokalBot's own or another app's, can
/// be checked from a script.
struct EventTapAudit: Encodable, Equatable {
    struct Tap: Equatable, Sendable {
        var processID: pid_t
        var enabled: Bool
    }

    struct Holder: Encodable, Equatable {
        var processID: Int32
        var name: String
        var bundleID: String?
        var taps: Int
        var enabled: Int
        var isLokalBot: Bool
        /// More taps than one app plausibly needs, so most were likely left behind.
        var likelyLeaking: Bool
    }

    /// Autocomplete's key listener, its Tab tap while a suggestion shows, and
    /// dictation's shortcut.
    static let lokalBotMaximum = 3
    static let likelyLeakThreshold = 5

    var holders: [Holder]
    var lokalBotTaps: Int
    var lokalBotWithinMaximum: Bool

    init(taps: [Tap], lokalBotBundleID: String?, describe: (pid_t) -> (name: String, bundleID: String?)) {
        var byProcess: [pid_t: [Tap]] = [:]
        for tap in taps { byProcess[tap.processID, default: []].append(tap) }
        var holders: [Holder] = []
        for (processID, held) in byProcess {
            let description = describe(processID)
            let isLokalBot = lokalBotBundleID != nil && description.bundleID == lokalBotBundleID
            holders.append(Holder(
                processID: processID,
                name: description.name,
                bundleID: description.bundleID,
                taps: held.count,
                enabled: held.filter(\.enabled).count,
                isLokalBot: isLokalBot,
                likelyLeaking: held.count >= Self.likelyLeakThreshold))
        }
        holders.sort { lhs, rhs in
            if lhs.taps != rhs.taps { return lhs.taps > rhs.taps }
            return lhs.name < rhs.name
        }
        self.holders = holders
        var lokalBotTaps = 0
        for holder in holders where holder.isLokalBot { lokalBotTaps += holder.taps }
        self.lokalBotTaps = lokalBotTaps
        lokalBotWithinMaximum = lokalBotTaps <= Self.lokalBotMaximum
    }

    static func installedTaps() -> [Tap] {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
        var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
        return list.prefix(Int(count)).map { Tap(processID: $0.tappingProcess, enabled: $0.enabled) }
    }

    /// `--event-taps`: print the taps installed right now, as JSON.
    static func printCurrent() -> Int32 {
        let audit = EventTapAudit(
            taps: installedTaps(),
            lokalBotBundleID: Bundle.main.bundleIdentifier) { processID in
                let app = NSRunningApplication(processIdentifier: processID)
                return (app?.localizedName ?? "pid \(processID)", app?.bundleIdentifier)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(audit) else { return 1 }
        FileHandle.standardOutput.write(data + Data([10]))
        return 0
    }
}
