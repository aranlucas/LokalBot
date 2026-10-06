import Foundation

/// The confidence gate: stay quiet when the model is unsure, as Cotypist does.
/// A suggestion at the start of a word is dropped when the model's own
/// probability of its first word falls below `minimumProbability`.
///
/// The probability is the product of the emitted tokens' probabilities up to
/// and including the token in which the first word ends. Measured on real
/// replies and the user's own prompts and messages (2026-10-06, E2B): wrong
/// suggestions shown halve for about 1.5 points of keystrokes saved, because a
/// hidden suggestion usually comes back as a completion once the first letter
/// is typed. Suggestions inside a word are not gated: their first token is
/// forced to re-type the fragment, so its probability is not comparable.
struct CotypingFirstWordConfidence: Equatable, Sendable {
    static let minimumProbability: Float = 0.1

    let minimum: Float
    private(set) var probability: Float = 1
    private var text = ""
    /// The first word has ended, or the gate is off: nothing more to weigh.
    private(set) var isSettled: Bool

    init(minimum: Float) {
        self.minimum = minimum
        isSettled = minimum <= 0
    }

    /// Weighs the next emitted token. Returns false once the first word is
    /// known to fall below the minimum; the product only falls, so generation
    /// can stop there.
    mutating func accept(piece: String, probability tokenProbability: Float) -> Bool {
        guard !isSettled else { return true }
        text += piece
        probability *= max(0, tokenProbability)
        guard probability >= minimum else { return false }
        if Self.endsFirstWord(text) { isSettled = true }
        return true
    }

    /// A word character followed by a character that cannot continue a word.
    static func endsFirstWord(_ text: String) -> Bool {
        var inWord = false
        for character in text.drop(while: \.isWhitespace) {
            if character.isLetter || character.isNumber || character == "_" {
                inWord = true
            } else if inWord, !"'’-".contains(character) {
                return true
            }
        }
        return false
    }
}
