import CoreGraphics
import Foundation

/// How much the primary accept key takes per press. The full-accept key always
/// takes the whole remaining tail, so this has no "whole" case (that would
/// duplicate it) — mirrors Cotabby's `AcceptanceGranularity`.
enum CotypingAcceptGranularity: String, Codable, CaseIterable, Identifiable, Sendable {
    case word
    case phrase

    var id: String { rawValue }
    var label: String {
        switch self {
        case .word: "One word"
        case .phrase: "One phrase"
        }
    }
}

/// The primary accept key (take the next word/phrase). Curated safe choices
/// rather than a free record-shortcut UI.
enum CotypingAcceptKey: Int, Codable, CaseIterable, Identifiable, Sendable {
    case tab = 48
    case rightArrow = 124

    var id: Int { rawValue }
    var keyCode: CGKeyCode { CGKeyCode(rawValue) }
    var label: String {
        switch self {
        case .tab: "Tab"
        case .rightArrow: "Right Arrow"
        }
    }
}

/// The full-accept key (take the entire remaining suggestion), or off.
enum CotypingFullAcceptKey: Int, Codable, Sendable {
    case backtick = 50
    case rightArrow = 124
    case off = -1

    var keyCode: CGKeyCode? { self == .off ? nil : CGKeyCode(rawValue) }
    /// How the key is named in a hint; nil when full accept is off.
    var label: String? {
        switch self {
        case .backtick: "`"
        case .rightArrow: "Right Arrow"
        case .off: nil
        }
    }
}

/// Which accept key fired — the next chunk (word/phrase) or the whole tail.
enum CotypingAcceptScope: Sendable {
    case chunk
    case whole
}

/// One line saying what the accept keys do with the current settings.
enum CotypingAcceptHint {
    static func text(acceptKey: CotypingAcceptKey, fullAcceptKey: CotypingFullAcceptKey,
                     granularity: CotypingAcceptGranularity) -> String {
        var parts = ["\(acceptKey.label) accepts the next \(granularity == .word ? "word" : "phrase")"]
        // The primary key wins when both are bound to the same key.
        if let full = fullAcceptKey.label, fullAcceptKey.rawValue != acceptKey.rawValue {
            parts.append("\(full) accepts the rest")
        }
        parts.append("Esc dismisses")
        return parts.joined(separator: " · ")
    }
}
