import XCTest
@testable import LokalBot

final class HeadlessCommandParseTests: XCTestCase {
    func testDictationReplayRequiresExplicitFixtureAndServer() {
        XCTAssertEqual(HeadlessCommand.parse(["app", "--dictation-replay", "/tmp/input.json", "--server-url", "http://127.0.0.1:18973/v1"]),
                       .dictationReplay(input: URL(fileURLWithPath: "/tmp/input.json"), endpoint: URL(string: "http://127.0.0.1:18973/v1")!))
        XCTAssertNil(HeadlessCommand.parse(["app", "--dictation-replay", "/tmp/input.json"]))
    }
    func testCotypingReplayRequiresExplicitFixtureAndModel() {
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--cotyping-replay", "/tmp/fixture.json", "--model-path", "/tmp/model.gguf"]),
            .cotypingReplay(input: URL(fileURLWithPath: "/tmp/fixture.json"), model: URL(fileURLWithPath: "/tmp/model.gguf")))
        XCTAssertNil(HeadlessCommand.parse(["LokalBot", "--cotyping-replay", "/tmp/fixture.json"]))
    }

    func testParsesExportDiagnostics() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--export-diagnostics", "/tmp/d.zip"]),
                       .exportDiagnostics(destination: URL(fileURLWithPath: "/tmp/d.zip")))
    }

    func testParsesHealthWithDayAndJSON() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--health"]), .health(dayKey: nil, json: false))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--health", "--day", "2026-09-29", "--json"]),
                       .health(dayKey: "2026-09-29", json: true))
    }

    func testParsesRecordCaptureWithAnOptionalScenario() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--record-capture", "30"]),
                       .recordCapture(seconds: 30, scenario: "real"))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--record-capture", "45", "--scenario", "meet-join"]),
                       .recordCapture(seconds: 45, scenario: "meet-join"))
        XCTAssertNil(HeadlessCommand.parse(["LokalBot", "--record-capture", "soon"]))
    }
}
