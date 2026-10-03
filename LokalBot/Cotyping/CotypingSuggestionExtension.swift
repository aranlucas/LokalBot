import Foundation

/// Rules for topping up a suggestion while it is accepted or typed through, so
/// the ghost stays a few words ahead instead of running out and reappearing.
/// Cotypist does the same: once two words are left it appends the next few,
/// and it stops at the end of the sentence. Pure; the coordinator runs the model.
enum CotypingSuggestionExtension {
    /// A suggestion is topped up once this many words, or fewer, are left.
    static let thresholdWords = 2

    /// Words left at which a top-up starts under `wordLimit`. A one-word limit
    /// never tops up: the user asked for one word at a time.
    static func threshold(wordLimit: Int) -> Int {
        max(0, min(thresholdWords, wordLimit - 1))
    }

    /// Words asked for in one top-up. One fewer than a fresh suggestion, so
    /// the ghost never grows past the limit plus one.
    static func topUpWordLimit(wordLimit: Int) -> Int {
        max(1, wordLimit - 1)
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace)
            .filter { word in word.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    /// Whether model output stopped because it reached the length limit rather
    /// than because the thought was finished. Only such output is continued;
    /// a sentence that ended, or a short answer the model chose to stop at, is
    /// left alone. One word short of the limit still counts, because the token
    /// budget can run out before the last word is whole.
    static func isOpenEnded(_ chunk: String, wordLimit: Int) -> Bool {
        guard !chunk.contains(where: \.isNewline),
              !CotypingSentenceBoundary.endsSentence(chunk) else { return false }
        return wordCount(chunk) >= max(1, wordLimit - 1)
    }

    static func shouldExtend(_ session: CotypingSession, wordLimit: Int) -> Bool {
        let threshold = threshold(wordLimit: wordLimit)
        guard threshold > 0, session.kind == .continuation, session.isOpenEnded,
              !session.isExhausted else { return false }
        return wordCount(session.remainingText) <= threshold
    }

    /// The text the model continues from: what stood before the caret when the
    /// suggestion was made, followed by the whole suggestion.
    static func continuationPrefix(of session: CotypingSession) -> String {
        session.field.precedingText + session.fullText
    }

    /// The part of `output` that may be appended to `suggestion`, or nil when
    /// nothing may. Words already on screen must not change, so the addition
    /// has to start a new word (or attach punctuation) rather than lengthen the
    /// last one, and it must not repeat what the suggestion just said.
    static func addition(from output: String, to suggestion: String) -> String? {
        guard let first = output.first, let last = suggestion.last,
              output.contains(where: { !$0.isWhitespace }),
              !output.contains(where: \.isNewline) else { return nil }
        let lastIsWord = last.isLetter || last.isNumber
        let firstIsWord = first.isLetter || first.isNumber
        guard !(lastIsWord && firstIsWord) else { return nil }
        let said = normalized(suggestion)
        let added = normalized(output)
        guard !added.isEmpty, !said.hasSuffix(added) else { return nil }
        return output
    }

    private static func normalized(_ text: String) -> String {
        text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
