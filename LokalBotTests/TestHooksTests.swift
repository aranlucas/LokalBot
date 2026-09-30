import XCTest
@testable import LokalBot

final class TestHooksTests: XCTestCase {
    func testGoldenEngineReturnsTheTrackTranscriptForTheMeetingSlug() async throws {
        let golden = FileManager.default.temporaryDirectory
            .appendingPathComponent("golden-\(UUID().uuidString)", isDirectory: true)
        let slugFolder = golden.appendingPathComponent("design-review", isDirectory: true)
        try FileManager.default.createDirectory(at: slugFolder, withIntermediateDirectories: true)
        let transcript = Transcript(segments: [
            .init(start: 0, end: 4, speaker: "me", text: "I'll draft the eviction-policy doc by Thursday."),
        ], engine: "golden")
        try JSONEncoder().encode(transcript).write(to: slugFolder.appendingPathComponent("mic.json"))
        let audio = URL(fileURLWithPath: "/tmp/meetings/2026/09/29-design-review/mic.m4a")

        let result = try await GoldenTranscriptionEngine(directory: golden).transcribe(audio: audio, language: nil)
        XCTAssertEqual(result.segments.first?.text, "I'll draft the eviction-policy doc by Thursday.")
    }

    func testMissingGoldenFails() async {
        let engine = GoldenTranscriptionEngine(directory: URL(fileURLWithPath: "/nonexistent"))
        do {
            _ = try await engine.transcribe(audio: URL(fileURLWithPath: "/x/01-a/mic.m4a"), language: nil)
            XCTFail("a missing golden transcript must fail the job, not return nothing")
        } catch {}
    }

    func testParsesSetBoundaries() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--set-boundaries", "/tmp/m", "5", "60"]),
                       .setBoundaries(folder: URL(fileURLWithPath: "/tmp/m", isDirectory: true), start: 5, end: 60))
    }
}
