import XCTest
@testable import LokalBot

final class HeadlessCommandParseTests: XCTestCase {
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
