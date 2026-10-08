import Foundation

/// Whether pasted dictation reached the field, judged from the text before
/// the caret. Apps reformat pasted text (smart quotes, emoji, Markdown), so
/// the check compares the last few words rather than exact characters.
enum DictationInsertionVerdict: Equatable, Sendable {
    case landed
    case missing
    /// The field could not be read; nothing is claimed.
    case unknown
}

enum DictationInsertionCheck {
    /// When to read the field after the paste, in milliseconds. An app can
    /// take a moment to publish the change.
    static let readDelaysMilliseconds = [250, 650, 1_200]

    static func verdict(textBeforeCaret: String?, inserted: String) -> DictationInsertionVerdict {
        guard let textBeforeCaret else { return .unknown }
        let sent = words(in: inserted)
        guard !sent.isEmpty else { return .unknown }
        let probe = Array(sent.suffix(6))
        let field = words(in: String(textBeforeCaret.suffix(inserted.count + 400)))
        guard field.count >= probe.count else { return .missing }
        for start in 0...(field.count - probe.count) where Array(field[start..<start + probe.count]) == probe {
            return .landed
        }
        return .missing
    }

    static func words(in text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

/// Shown when pasted dictation did not arrive, so the text is one click away.
struct DictationDeliveryNotice: Equatable, Sendable {
    let text: String
    var copied = false
}
