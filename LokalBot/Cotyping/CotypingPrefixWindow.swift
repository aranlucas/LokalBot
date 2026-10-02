import Foundation

/// Pure rules for "should we generate, and on how much context." Ported from
/// Cotabby's `SuggestionRequestFactory.shouldGenerateSuggestion` +
/// `truncatedPromptPrefix`.
enum CotypingPrefixWindow {
    /// Generate only when there is at least one non-whitespace character before
    /// the caret (no suggestions on a blank field).
    static func shouldGenerate(for precedingText: String) -> Bool {
        !precedingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Bound the latest text without rewriting paragraph breaks, list indentation,
    /// or the exact whitespace at the caret. These are prediction inputs.
    static func truncatedPrefix(
        from precedingText: String, maxCharacters: Int, maxWords: Int
    ) -> String {
        guard maxCharacters > 0, maxWords > 0 else { return "" }
        let characterWindow = String(precedingText.suffix(maxCharacters))
        let words = characterWindow.split(whereSeparator: { $0.isWhitespace })
        guard words.count > maxWords else { return characterWindow }
        return String(characterWindow[words[words.count - maxWords].startIndex...])
    }
}
