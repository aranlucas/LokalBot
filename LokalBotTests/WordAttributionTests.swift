import XCTest
@testable import LokalBot

/// Transcribe-first speaker attribution: forced-aligned words are assigned
/// to diarized turns after whole-track ASR, instead of cutting audio first.
final class WordAttributionTests: XCTestCase {
    private func aligned(_ text: String, start: Double, end: Double,
                         words: [(String, Double, Double)]) -> AttributedTrackTranscriber.AlignedSegment {
        .init(segment: .init(start: start, end: end, speaker: "speaker", text: text, timingPrecision: .span),
              words: words.map { AlignedWordTiming(text: $0.0, start: $0.1, end: $0.2) })
    }

    func testSpeakerChangeSplitsASegmentWithoutRewritingItsText() {
        let segment = aligned("Hello there. Yes, I agree.", start: 0, end: 2.2, words: [
            ("Hello", 0.1, 0.4), ("there.", 0.4, 0.8), ("Yes,", 1.2, 1.5), ("I", 1.5, 1.6), ("agree.", 1.6, 2.0),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 10, turns: [
            .init(start: 0, end: 1.0, speakerId: "A"), .init(start: 1.1, end: 2.5, speakerId: "B"),
        ], source: .system, contentRange: nil)
        XCTAssertEqual(result.map(\.text), ["Hello there.", "Yes, I agree."])
        XCTAssertEqual(result.map(\.speaker), ["them 1", "them 2"])
        XCTAssertEqual(result.map(\.resolvedAttribution.method), [.diarization, .diarization])
        XCTAssertEqual(result.map(\.resolvedAttribution.identity), [.other, .other])
        XCTAssertEqual(result.map(\.timingPrecision), [.token, .token])
        // Each piece widens to its own turn, never into its neighbour.
        XCTAssertEqual(result.map(\.start), [0, 1.1])
        XCTAssertEqual(result.map(\.end), [1.0, 2.5])
    }

    func testOverlapIsUnclearAndTheMicrophoneDefaultMatchesRegions() {
        let segment = aligned("one two three", start: 0, end: 3, words: [
            ("one", 0.2, 0.6), ("two", 1.2, 1.6), ("three", 2.2, 2.6),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 3, turns: [
            .init(start: 0, end: 1.9, speakerId: "A"), .init(start: 1.0, end: 3, speakerId: "B"),
        ], source: .microphone, contentRange: nil)
        XCTAssertEqual(result.map(\.speaker), ["local 1", "local unclear", "local 2"])
        XCTAssertEqual(result.map(\.resolvedAttribution.method), [.diarization, .overlappingSpeech, .diarization])
        XCTAssertEqual(result.map(\.resolvedAttribution.identity), [.user, .unresolved, .user])
        XCTAssertEqual(result.map(\.start), [0, 1.2, 1.6])
        XCTAssertEqual(result.map(\.end), [1.2, 1.6, 3])
    }

    func testWordsNearATurnTakeItsSpeakerAndDistantWordsKeepTheTrackLabel() {
        let segment = aligned("near far", start: 1.1, end: 3.5, words: [("near", 1.2, 1.6), ("far", 3.0, 3.4)])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 5, turns: [
            .init(start: 0, end: 1.0, speakerId: "A"),
        ], source: .system, contentRange: nil)
        XCTAssertEqual(result.map(\.speaker), ["them 1", "them"])
        XCTAssertEqual(result.map(\.resolvedAttribution.method), [.diarization, .track])
        XCTAssertEqual(result.map(\.resolvedAttribution.identity), [.other, .other])
    }

    func testContentRangeDropsWordsOutsideIt() {
        let segment = aligned("before inside after", start: 0, end: 3, words: [
            ("before", 0.2, 0.6), ("inside", 1.2, 1.6), ("after", 2.4, 2.8),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 3, turns: [
            .init(start: 0, end: 3, speakerId: "A"),
        ], source: .system, contentRange: .init(start: 1, end: 2))
        XCTAssertEqual(result.map(\.text), ["inside"])
        XCTAssertEqual(result.map(\.start), [1])
        XCTAssertEqual(result.map(\.end), [2])
        XCTAssertTrue(AttributedTrackTranscriber.attribute([segment], duration: 3, turns: [], source: .system,
                                                           contentRange: .init(start: 2, end: 1)).isEmpty)
    }

    func testUnmatchedOrMissingAlignmentKeepsTheSegmentWhole() {
        let turns: [DiarizedSegment] = [.init(start: 0, end: 5, speakerId: "A")]
        for words in [[("zzz", 0.5, 0.9)], []] {
            let result = AttributedTrackTranscriber.attribute(
                [aligned("Unaligned words stay together.", start: 1, end: 3, words: words)],
                duration: 5, turns: turns, source: .system, contentRange: nil)
            XCTAssertEqual(result.map(\.text), ["Unaligned words stay together."])
            XCTAssertEqual(result.map(\.speaker), ["them 1"])
            XCTAssertEqual(result.map(\.timingPrecision), [.span])
        }
    }

    func testUnspacedTextIsCutAtCharacterBoundaries() {
        let segment = aligned("你好世界。", start: 0, end: 2, words: [
            ("你", 0, 0.2), ("好", 0.2, 0.4), ("世", 1.2, 1.4), ("界。", 1.4, 1.6),
        ])
        let result = AttributedTrackTranscriber.attribute([segment], duration: 2, turns: [
            .init(start: 0, end: 0.8, speakerId: "A"), .init(start: 1.0, end: 2, speakerId: "B"),
        ], source: .system, contentRange: nil)
        XCTAssertEqual(result.map(\.text), ["你好", "世界。"])
    }

    func testPausesAndLongMonologuesStartNewSegments() {
        let turns: [DiarizedSegment] = [.init(start: 0, end: 40, speakerId: "A")]
        let paused = aligned("One two. Three four.", start: 0, end: 5, words: [
            ("One", 0.1, 0.4), ("two.", 0.5, 0.9), ("Three", 2.9, 3.2), ("four.", 3.3, 3.6),
        ])
        XCTAssertEqual(AttributedTrackTranscriber.attribute([paused], duration: 40, turns: turns, source: .system,
                                                            contentRange: nil).map(\.text),
                       ["One two.", "Three four."])

        // 40 back-to-back half-second words: the 15 s cap splits after word 29.
        let words = (0..<40).map { ("w\($0)", Double($0) * 0.5, Double($0) * 0.5 + 0.5) }
        let monologue = aligned(words.map(\.0).joined(separator: " "), start: 0, end: 20, words: words)
        let pieces = AttributedTrackTranscriber.attribute([monologue], duration: 40, turns: turns, source: .system,
                                                          contentRange: nil)
        XCTAssertEqual(pieces.map { $0.text.split(separator: " ").count }, [30, 10])
        XCTAssertEqual(Set(pieces.map(\.speaker)), ["them 1"])
    }

    func testLongContextWindowsJoinShortPausesUpToTheLimit() {
        let spans = [(0.0, 10.0), (11, 20), (26, 30), (30.5, 50), (50.5, 70), (70.5, 90)]
            .map { SpeechSpan(start: $0.0, end: $0.1, timingPrecision: .span) }
        let windows = QwenASREngine.merged(spans, maxGap: 5, maxLength: 60)
        XCTAssertEqual(windows.map(\.start), [0, 26, 70.5])
        XCTAssertEqual(windows.map(\.end), [20, 70, 90])
        XCTAssertTrue(windows.allSatisfy { $0.timingPrecision == .span })
    }

    func testWordStartsMatchLettersPastAdjacentPunctuation() throws {
        let text = "\"Well, state-of-the-art isn't cheap.\""
        let starts = try XCTUnwrap(AttributedTrackTranscriber.wordStarts(
            ["\"Well,", "state-of-the-art", "isn't", "cheap.\""], in: text))
        XCTAssertEqual(starts.map { String(text[$0...].prefix(4)) }, ["Well", "stat", "isn'", "chea"])
        XCTAssertNil(AttributedTrackTranscriber.wordStarts(["missing"], in: text))
    }

    func testQwenTiersAttributeAlignedWordsWithTheirMeasuredWindows() {
        XCTAssertEqual(QwenASREngine.accuracy.speakerAttribution, .alignedWords)
        XCTAssertEqual(QwenASREngine.compact.speakerAttribution, .alignedWords)
        XCTAssertEqual(TranscriptionModelChoice.parakeetV3.engine.speakerAttribution, .regions)
        XCTAssertEqual(QwenASREngine.wordAttributionWindows(for: .accuracy),
                       .init(maxSeconds: 60, maxGapSeconds: 5, disablesRepetitionBlocking: true))
        // 0.6B stays at 15 s: longer windows decoded 5–10× slower for a small gain.
        XCTAssertEqual(QwenASREngine.wordAttributionWindows(for: .compact),
                       .init(maxSeconds: 15, maxGapSeconds: 5, disablesRepetitionBlocking: false))
    }

    func testAlignerLanguagesAndPinnedSnapshot() throws {
        for code in ["en", "zh-Hant", "pt-PT", "yue", "ja"] { XCTAssertTrue(QwenWordAligner.supports(code), code) }
        for code in ["sr", "nl", "ar", ""] { XCTAssertFalse(QwenWordAligner.supports(code), code) }
        XCTAssertEqual(QwenWordAligner.detectedLanguage(of: ["This is an English sentence about the quarterly plan."]), "en")
        XCTAssertNil(QwenWordAligner.detectedLanguage(of: ["Dit is een Nederlandse zin over het kwartaalplan van het team."]))

        let snapshot = QwenWordAligner.snapshot
        XCTAssertEqual(snapshot.repository, "aufklarer/Qwen3-ForcedAligner-0.6B-4bit")
        XCTAssertEqual(snapshot.revision.count, 40)
        let weights = try XCTUnwrap(snapshot.files.first { $0.path == "model.safetensors" })
        XCTAssertFalse(weights.isGitBlob)
        XCTAssertEqual(weights.digest.count, 64)
        XCTAssertEqual(Set(snapshot.files.map(\.path)), ["config.json", "merges.txt", "model.safetensors",
                                                         "quantize_config.json", "tokenizer_config.json", "vocab.json"])
        // Settings and PRIVACY.md describe this download as about 1 GB.
        XCTAssertEqual(Double(snapshot.files.reduce(0) { $0 + $1.bytes }) / 1e9, 1, accuracy: 0.05)
    }

    /// Opt-in hardware check: the pinned digests match the real files, which
    /// load offline and time every word. No network access is allowed.
    func testCachedAlignerVerifiesPinsAndTimesEveryWord() async throws {
        guard let path = ProcessInfo.processInfo.environment["LOKALBOT_QWEN_ALIGNER_TEST_DIR"] else {
            throw XCTSkip("Set LOKALBOT_QWEN_ALIGNER_TEST_DIR to a downloaded Qwen3-ForcedAligner-0.6B-4bit folder")
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try await QwenWordAligner.snapshot.prepare(in: directory) { _ in throw URLError(.notConnectedToInternet) }
        let samples = (0..<48_000).map { Float(sin(Double($0) * 0.05) * 0.1) }
        let words = try await QwenWordAligner(directory: directory)
            .align(samples, text: "Three short words.", language: "en")
        XCTAssertEqual(words.map(\.text), ["Three", "short", "words."])
        XCTAssertTrue(words.allSatisfy { $0.start >= 0 && $0.start <= $0.end && $0.end <= 3.1 })
    }
}
