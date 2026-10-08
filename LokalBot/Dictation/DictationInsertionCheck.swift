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
    /// Letters and digits from the end of the insertion that must appear.
    static let probeLength = 24

    /// The field is read back only when it is the exact field the text was
    /// pasted into and not a secure one. An app-only target (no field
    /// identity) is never read: focus may have moved to another field.
    static func allowsReadBack(boundIdentity: String?, liveIdentity: String?, isSecure: Bool) -> Bool {
        guard let boundIdentity, !boundIdentity.isEmpty, !isSecure else { return false }
        return liveIdentity == boundIdentity
    }

    /// Compares letters and digits only, so spacing, punctuation, emoji and
    /// Markdown changes do not matter, and scripts without spaces between
    /// words (Chinese, Japanese, Thai) match inside a longer run.
    static func verdict(textBeforeCaret: String?, inserted: String) -> DictationInsertionVerdict {
        guard let textBeforeCaret else { return .unknown }
        let sent = significant(inserted)
        guard !sent.isEmpty else { return .unknown }
        let probe = String(sent.suffix(probeLength))
        let field = significant(String(textBeforeCaret.suffix(inserted.count + 400)))
        return field.contains(probe) ? .landed : .missing
    }

    static func significant(_ text: String) -> String {
        String(text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
    }
}

/// Shown when pasted dictation did not arrive, so the text is one click away.
struct DictationDeliveryNotice: Equatable, Sendable {
    let text: String
    var copied = false
}
