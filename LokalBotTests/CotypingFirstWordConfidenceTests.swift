import XCTest
@testable import LokalBot

/// The confidence gate keeps quiet when the model is unsure of a suggestion's
/// first word.
final class CotypingFirstWordConfidenceTests: XCTestCase {
    func testAnUnsureFirstWordStopsGenerationAtOnce() {
        var gate = CotypingFirstWordConfidence(minimum: 0.1)
        XCTAssertFalse(gate.accept(piece: " maybe", probability: 0.05))
    }

    func testTheFirstWordIsWeighedUpToTheTokenThatEndsIt() {
        var gate = CotypingFirstWordConfidence(minimum: 0.1)
        XCTAssertTrue(gate.accept(piece: " fol", probability: 0.5))
        XCTAssertTrue(gate.accept(piece: "low", probability: 0.3))
        XCTAssertFalse(gate.isSettled, "the word could still go on")
        // The token that ends the word counts, as in the measurement the
        // threshold was chosen on: 0.5 × 0.3 × 0.5 = 0.075.
        XCTAssertFalse(gate.accept(piece: " up", probability: 0.5))
    }

    func testLaterWordsAreNotWeighed() {
        var gate = CotypingFirstWordConfidence(minimum: 0.1)
        XCTAssertTrue(gate.accept(piece: " follow", probability: 0.4))
        XCTAssertTrue(gate.accept(piece: " up", probability: 0.5))
        XCTAssertTrue(gate.isSettled)
        XCTAssertTrue(gate.accept(piece: " on", probability: 0.01))
        XCTAssertEqual(gate.probability, 0.2, accuracy: 0.0001)
    }

    func testAZeroMinimumTurnsTheGateOff() {
        var gate = CotypingFirstWordConfidence(minimum: 0)
        XCTAssertTrue(gate.isSettled)
        XCTAssertTrue(gate.accept(piece: " anything", probability: 0))
    }

    func testWhereTheFirstWordEnds() {
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord(" follow up"))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord("42."))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord("(maybe)"))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord(" well-known,"))
        XCTAssertFalse(CotypingFirstWordConfidence.endsFirstWord(" follow"))
        XCTAssertFalse(CotypingFirstWordConfidence.endsFirstWord(" don't"))
        XCTAssertFalse(CotypingFirstWordConfidence.endsFirstWord("  ("))
        XCTAssertTrue(CotypingFirstWordConfidence.endsFirstWord(" šta je"))
    }

    func testTokenProbabilityIsTheSoftmaxOverTheVocabulary() {
        let logits: [Float] = [0, log(2), log(3)]
        var scratch = [Float](repeating: 0, count: logits.count)
        func probability(_ token: Int32) -> Float? {
            logits.withUnsafeBufferPointer { values in
                scratch.withUnsafeMutableBufferPointer { buffer in
                    LlamaCotypingRuntime.probability(of: token, in: values.baseAddress, scratch: buffer)
                }
            }
        }
        XCTAssertEqual(probability(2) ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(probability(0) ?? -1, 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertNil(probability(3), "a token outside the vocabulary has no probability")
    }
}
