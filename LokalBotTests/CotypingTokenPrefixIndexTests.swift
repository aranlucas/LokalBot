import XCTest
@testable import LokalBot

final class CotypingTokenPrefixIndexTests: XCTestCase {
    func testPromptBudgetKeepsCaretAndReservesDecodeRoom() {
        let tokens = (0..<3000).map(Int32.init)
        let bounded = LlamaCotypingRuntime.boundedPromptTokens(tokens, contextSize: 2048, outputReserve: 64)
        XCTAssertEqual(bounded.count, 1983)
        XCTAssertEqual(bounded.last, 2999)
        XCTAssertEqual(bounded, Array(tokens.suffix(1983)))
        XCTAssertEqual(LlamaCotypingRuntime.boundedPromptTokens([1, 2], contextSize: 2048, outputReserve: 64), [1, 2])
    }

    func testFindsMostLikelyCompatibleWordOutsideGlobalTop64() {
        let pieces = Array(repeating: Array(" unrelated".utf8), count: 70)
            + [Array(" Postgre".utf8), Array(" PostgreSQL".utf8), Array(" Postgres".utf8)]
        let index = CotypingTokenPrefixIndex(vocabularySize: Int32(pieces.count)) { pieces[Int($0)] }
        let logits: [Float] = Array(repeating: 10, count: 70) + [1, 3, 2]
        logits.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(index.bestToken(in: buffer.baseAddress!, matching: Array(" Postgre".utf8)[...],
                                           preferWordExtendingOvershoot: true), 71)
        }
    }

    func testSupportsByteFragmentsAndDeterministicTies() {
        let pieces: [[UInt8]] = [[0xBC, 0x72], [0xBC, 0x74], [0xC3, 0xBC]]
        let index = CotypingTokenPrefixIndex(vocabularySize: 3) { pieces[Int($0)] }
        let logits: [Float] = [2, 2, 100]
        logits.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(index.bestToken(in: buffer.baseAddress!, matching: [0xBC][...],
                                           preferWordExtendingOvershoot: false), 0)
            XCTAssertNil(index.bestToken(in: buffer.baseAddress!, matching: [0xAA][...],
                                         preferWordExtendingOvershoot: false))
        }
    }

    func testInvalidLogitsDoNotWin() {
        let index = CotypingTokenPrefixIndex(vocabularySize: 3) { _ in Array(" name".utf8) }
        let logits: [Float] = [.nan, -.infinity, .infinity]
        logits.withUnsafeBufferPointer { buffer in
            XCTAssertEqual(index.bestToken(in: buffer.baseAddress!, matching: Array(" na".utf8)[...],
                                           preferWordExtendingOvershoot: false), 2)
        }
    }
}
