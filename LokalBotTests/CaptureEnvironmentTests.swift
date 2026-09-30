import AppKit
import XCTest
@testable import LokalBot

final class CaptureEnvironmentTests: XCTestCase {
    override func tearDown() {
        CaptureEnvironment.reset()
    }

    func testRunningAppCopiesTheIdentifyingFields() {
        let current = NSRunningApplication.current
        let app = RunningApp(current)
        XCTAssertEqual(app.processIdentifier, current.processIdentifier)
        XCTAssertEqual(app.bundleIdentifier, current.bundleIdentifier)
        XCTAssertEqual(app.localizedName, current.localizedName)
    }

    func testInstallReplacesTheProcessWideEnvironmentAndResetRestoresLive() {
        struct Fixed: WorkspaceSource {
            func frontmostApplication() -> RunningApp? {
                RunningApp(processIdentifier: 42, bundleIdentifier: "com.example.fixed", localizedName: "Fixed")
            }
            func runningApplications() -> [RunningApp] { [] }
            func isRunning(processID: pid_t) -> Bool { processID == 42 }
            func secondsSinceLastInput() -> TimeInterval { 0 }
        }
        var environment = CaptureEnvironment.live
        environment.workspace = Fixed()
        CaptureEnvironment.install(environment)
        XCTAssertEqual(CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier, 42)
        CaptureEnvironment.reset()
        XCTAssertNotEqual(CaptureEnvironment.current.workspace.frontmostApplication()?.processIdentifier, 42)
    }

    @MainActor
    func testLiveClockRunsScheduledWorkOnTheMainActor() async {
        let fired = expectation(description: "fired")
        let timer = CaptureEnvironment.live.clock.schedule(after: 0.05) { fired.fulfill() }
        await fulfillment(of: [fired], timeout: 2)
        timer.cancel()
    }

    func testTraceValueTypesRoundTripThroughJSON() throws {
        let read = AccessibilityRead(
            snapshot: ScreenAccessibilitySnapshot(text: "t", sourceURL: nil, documentName: nil,
                                                  focusedSecureField: nil, windowTitle: "w",
                                                  windowFrame: CGRect(x: 1, y: 2, width: 3, height: 4)),
            failure: .init(reason: "r", isTransient: true))
        XCTAssertEqual(try JSONDecoder().decode(AccessibilityRead.self, from: JSONEncoder().encode(read)), read)
        let snapshot = BrowserMeetingSession.Snapshot(url: URL(string: "https://meet.google.com/bcd-fghj-klm")!,
                                                      state: .present)
        XCTAssertEqual(try JSONDecoder().decode(BrowserMeetingSession.Snapshot.self,
                                                from: JSONEncoder().encode(snapshot)), snapshot)
    }
}
