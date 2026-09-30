import XCTest
@testable import LokalBot

final class HeadlessCommandParseTests: XCTestCase {
    func testParsesExportDiagnostics() {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--export-diagnostics", "/tmp/d.zip"]),
                       .exportDiagnostics(destination: URL(fileURLWithPath: "/tmp/d.zip")))
    }
}
