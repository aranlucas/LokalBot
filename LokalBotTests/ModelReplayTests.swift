import XCTest
@testable import LokalBot

/// Real GLM 5.3 Flash / Qwen3.8 Flash answers (recorded nightly), replayed
/// through the real engine and generators.
final class ModelReplayTests: XCTestCase {
    private var server: ModelStubServer!

    override func setUpWithError() throws {
        server = try ModelStubServer()
    }

    override func tearDown() {
        server?.stop()
    }

    private func engine(_ model: String) -> OpenAICompatibleEngine {
        OpenAICompatibleEngine(baseURL: server.baseURL, model: model, apiKey: nil, chatDialect: .openRouter)
    }

    private func recordings(_ caseName: String) throws -> [ModelRecording] {
        let all = try ModelRecording.committed().filter { $0.caseName == caseName }
        guard !all.isEmpty else { throw XCTSkip("no committed \(caseName) recordings") }
        return all
    }

    func testRecordedDigestsCoverMostOfTheSyntheticDay() async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        for recording in try recordings("digest-day") {
            try await server.load(recording.stubRules())
            let result = try await DayDigestOverviewGenerator.generateResult(
                evidence: SyntheticModelPrompts.digestEvidence(calendar: calendar),
                engine: engine(recording.model), customPrompt: "", calendar: calendar, sleep: { _ in })
            XCTAssertGreaterThanOrEqual(try XCTUnwrap(result.coverage?.ratio), 0.6, recording.model)
            XCTAssertTrue(result.summary.localizedCaseInsensitiveContains("cach")
                || result.summary.localizedCaseInsensitiveContains("evict"), recording.model)
        }
    }

    func testRecordedNotesKeepAnActionOwnedByMe() async throws {
        for recording in try recordings("notes-design-review") {
            try await server.load(recording.stubRules())
            let folder = FileManager.default.temporaryDirectory
                .appendingPathComponent("replay-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let result = try await MeetingNotesGenerator.generate(
                transcript: SyntheticModelPrompts.standupTranscript(), engine: engine(recording.model),
                template: .meeting, language: .matchTranscript, context: [], contextTokens: 32_768,
                meetingID: UUID(), folder: folder)
            XCTAssertFalse(result.outcomes.userActionItems.isEmpty,
                          "\(recording.model): the eviction-policy commitment must stay owned by me")
        }
    }
}
