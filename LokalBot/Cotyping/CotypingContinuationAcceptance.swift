import Foundation

/// What one accept keypress does to a continuation: how much of the suggestion
/// it consumes and the exact text to put at the caret. The live accept tap and
/// the Settings rehearsal both plan here, so a rehearsed Tab takes the same
/// word or phrase, with the same spacing and punctuation, as Tab in another app.
struct CotypingContinuationAcceptance: Equatable, Sendable {
    /// The acceptance settings that shape a keypress.
    struct Options: Equatable, Sendable {
        var granularity: CotypingAcceptGranularity = .word
        var autoAcceptTrailingPunctuation = false
        var addSpaceAfterAccept = false

        init(granularity: CotypingAcceptGranularity = .word,
             autoAcceptTrailingPunctuation: Bool = false,
             addSpaceAfterAccept: Bool = false) {
            self.granularity = granularity
            self.autoAcceptTrailingPunctuation = autoAcceptTrailingPunctuation
            self.addSpaceAfterAccept = addSpaceAfterAccept
        }

        init(settings: AppSettings) {
            granularity = settings.cotypingAcceptGranularity
            autoAcceptTrailingPunctuation = settings.cotypingAutoAcceptTrailingPunctuation
            addSpaceAfterAccept = settings.cotypingAddSpaceAfterAccept
        }
    }

    /// Characters of the suggestion this keypress consumes.
    let acceptedChunk: String
    /// Text to insert: the chunk with duplicate whitespace removed, a sentence
    /// space added, and the optional trailing space applied.
    let insertionText: String
    /// Characters after the caret that the insertion replaces when the
    /// suggestion completes a word the user is in the middle of.
    let forwardDeleteCount: Int

    /// Returns nil when the keypress would accept nothing.
    static func plan(
        session: CotypingSession,
        scope: CotypingAcceptScope,
        precedingText: String,
        trailingText: String,
        options: Options
    ) -> CotypingContinuationAcceptance? {
        let remaining = session.remainingText
        let baseChunk: String
        switch scope {
        case .whole:
            baseChunk = remaining
        case .chunk:
            switch options.granularity {
            case .word:
                baseChunk = CotypingAcceptanceChunker.nextWord(
                    in: remaining,
                    autoAcceptTrailingPunctuation: options.autoAcceptTrailingPunctuation)
            case .phrase:
                baseChunk = CotypingAcceptanceChunker.nextPhrase(
                    in: remaining,
                    autoAcceptTrailingPunctuation: options.autoAcceptTrailingPunctuation)
            }
        }
        let acceptedChunk = options.addSpaceAfterAccept
            ? CotypingAcceptanceChunker.acceptanceChunkConsumingTrailingSpace(baseChunk, remainingText: remaining)
            : baseChunk
        guard !acceptedChunk.isEmpty else { return nil }
        let insertionChunk = CotypingAcceptanceChunker.insertionChunk(
            forAcceptedChunk: acceptedChunk,
            precedingText: precedingText)
        let insertionText = CotypingAcceptanceChunker.insertionTextApplyingAutoSpace(
            insertionChunk: insertionChunk,
            acceptedChunk: acceptedChunk,
            session: session,
            addSpaceAfterAccept: options.addSpaceAfterAccept)
        let forwardDeleteCount = CotypingMidWord.shouldForceContinuation(
            precedingText: precedingText,
            trailingText: trailingText)
            ? CotypingMidWord.acceptedTrailingOverlapCount(
                acceptedText: insertionText,
                trailingText: trailingText)
            : 0
        return CotypingContinuationAcceptance(
            acceptedChunk: acceptedChunk,
            insertionText: insertionText,
            forwardDeleteCount: forwardDeleteCount)
    }
}

/// The rehearsal editor's suggestion, advanced by the same rules as a live
/// field: an accept takes the configured amount and keeps the rest, typing the
/// suggested characters walks through it, and any other edit discards it.
struct CotypingRehearsal: Equatable, Sendable {
    enum Change: Equatable, Sendable {
        /// The edit was the accept itself; the remaining ghost still applies.
        case unchanged
        /// The user typed the next suggested characters; the ghost shortened.
        case advanced
        /// The text moved away from the suggestion; a new one is needed.
        case stale
    }

    private(set) var session: CotypingSession?
    /// Editor text the remaining ghost continues from.
    private(set) var anchor = ""

    /// The part of the suggestion still offered after the caret.
    var ghost: String { session?.remainingText ?? "" }

    /// `wordLimit` is the length limit the suggestion was generated under.
    /// With it, a suggestion the limit cut short can be topped up as it is
    /// accepted, as in a live field.
    mutating func present(_ suggestion: String, after text: String, wordLimit: Int? = nil) {
        guard !suggestion.isEmpty else {
            dismiss()
            return
        }
        var fresh = CotypingSession(field: Self.field(precedingText: text), fullText: suggestion)
        if let wordLimit {
            fresh.isOpenEnded = CotypingSuggestionExtension.isOpenEnded(suggestion, wordLimit: wordLimit)
        }
        session = fresh
        anchor = text
    }

    /// The text a top-up continues from, once the remaining ghost is running
    /// short; nil while there is enough left or the thought is finished.
    func topUpPrefix(wordLimit: Int) -> String? {
        guard let session, CotypingSuggestionExtension.shouldExtend(session, wordLimit: wordLimit) else { return nil }
        return CotypingSuggestionExtension.continuationPrefix(of: session)
    }

    /// Appends model output to the ghost when it still continues the same
    /// suggestion. Returns whether the ghost grew.
    mutating func topUp(with output: String, continuing prefix: String, wordLimit: Int) -> Bool {
        guard let current = session,
              CotypingSuggestionExtension.continuationPrefix(of: current) == prefix,
              let addition = CotypingSuggestionExtension.addition(from: output, to: current.fullText) else {
            return false
        }
        var extended = CotypingSession(
            field: current.field, fullText: current.fullText + addition,
            consumedCount: current.consumedCount)
        extended.isOpenEnded = CotypingSuggestionExtension.isOpenEnded(
            addition, wordLimit: CotypingSuggestionExtension.topUpWordLimit(wordLimit: wordLimit))
        session = extended
        return true
    }

    mutating func dismiss() {
        session = nil
        anchor = ""
    }

    /// One accept keypress with the caret at the end of `text`. Returns the
    /// text the editor should hold afterwards, or nil when nothing was accepted.
    mutating func accept(
        _ scope: CotypingAcceptScope,
        text: String,
        options: CotypingContinuationAcceptance.Options
    ) -> String? {
        guard let current = session, text == anchor,
              let acceptance = CotypingContinuationAcceptance.plan(
                session: current, scope: scope, precedingText: text, trailingText: "",
                options: options) else { return nil }
        let updated = text + acceptance.insertionText
        let advanced = current.advanced(by: acceptance.acceptedChunk.count)
        if advanced.isExhausted {
            dismiss()
        } else {
            session = advanced
            anchor = updated
        }
        return updated
    }

    /// The editor text changed. Call for every change, including the one an
    /// accept produces.
    mutating func textChanged(to text: String) -> Change {
        guard let current = session else { return .stale }
        if text == anchor { return .unchanged }
        guard text.hasPrefix(anchor),
              let advanced = CotypingSessionReconciler.sessionAdvancedByTypedCharacters(
                current, typedCharacters: String(text.dropFirst(anchor.count))),
              !advanced.isExhausted else {
            dismiss()
            return .stale
        }
        session = advanced
        anchor = text
        return .advanced
    }

    private static func field(precedingText: String) -> CotypingField {
        CotypingField(
            appName: "LokalBot", bundleID: nil, processID: 0, role: "AXTextArea",
            precedingText: precedingText, trailingText: "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: false)
    }
}
