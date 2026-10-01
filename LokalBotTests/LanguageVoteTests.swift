import XCTest
@testable import LokalBot

/// Auto-detected language handling for Qwen transcripts: a length-weighted
/// vote over segments decides the track's language and whether to pin it.
final class LanguageVoteTests: XCTestCase {
    private let english = [
        "I dropped a question on Discord, so any time just check it out and let me know what you think.",
        "We are polishing the fee extraction pull request and I have a few conflicts to solve now.",
        "Hopefully I have something by next week that we can try integrating into the interface.",
    ]
    private let german = [
        "Wir haben gestern die neue Version veröffentlicht und die ersten Rückmeldungen sind sehr positiv.",
        "Könnten Sie mir bitte die Unterlagen bis Freitag schicken, damit wir alles vorbereiten können?",
    ]

    func testAMisdetectedOpeningDoesNotDecideTheTrack() throws {
        // A Qwen auto-detection misfire from the benchmark's standup meeting.
        let texts = ["abytrował, czyli taki, czyli gadajmyśników."] + english
        let vote = try XCTUnwrap(TranscriptLanguageVote.dominant(in: texts))
        XCTAssertEqual(vote.code, "en")
        XCTAssertGreaterThanOrEqual(vote.share, 0.8)
        XCTAssertEqual(QwenASREngine.pinnedLanguage(for: texts), "en")
        XCTAssertEqual(QwenWordAligner.detectedLanguage(of: texts), "en")
    }

    func testMixedLanguageTracksStayOnPerWindowDetection() {
        let texts = [english[0], german[0], english[1], german[1]]
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: texts))
        // The aligner still gets a dominant language for word splitting.
        XCTAssertNotNil(QwenWordAligner.detectedLanguage(of: texts))
    }

    func testShortRepliesDoNotVote() {
        XCTAssertNil(TranscriptLanguageVote.dominant(in: ["Hahaha.", "呵呵呵。", "Okay yeah."]))
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: ["Hahaha.", "呵呵呵。"]))
    }

    func testLanguagesQwenDoesNotSupportAreNotPinned() {
        let serbian = [
            "Sastanak je pomeren za sledeću nedelju jer su dvojica kolega bolesna.",
            "Molim vas da mi pošaljete dokumenta do petka kako bismo sve pripremili.",
        ]
        XCTAssertNil(QwenASREngine.pinnedLanguage(for: serbian))
        XCTAssertFalse(QwenASREngine.supportedLanguages.contains("sr"))
        XCTAssertTrue(QwenASREngine.supportedLanguages.isSuperset(of: ["en", "zh", "yue", "de", "ja", "mk"]))
    }

    func testBaseCodes() {
        XCTAssertEqual(TranscriptLanguageVote.baseCode("zh-Hant"), "zh")
        XCTAssertEqual(TranscriptLanguageVote.baseCode("pt_PT"), "pt")
        XCTAssertEqual(TranscriptLanguageVote.baseCode("EN"), "en")
    }
}
