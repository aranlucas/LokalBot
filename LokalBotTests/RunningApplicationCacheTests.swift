import AppKit
import XCTest
@testable import LokalBot

/// A live profile on 2026-10-01 showed the meeting detector reading every
/// running app's pid, bundle id, and name through LaunchServices twice per
/// 2-second tick on the main thread (40–70 ms stalls, about 5% of the main
/// thread while idle). Each app is now read once.
final class RunningApplicationCacheTests: XCTestCase {
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.withLock { value } }
        func add() { lock.withLock { value += 1 } }
    }

    func testEachRunningAppIsReadOncePerProcess() throws {
        let reads = Reads()
        let cache = RunningApplicationCache { app in
            reads.add()
            return RunningApp(app)
        }
        let apps = NSWorkspace.shared.runningApplications
        try XCTSkipIf(apps.isEmpty, "no running applications visible to the test host")

        let first = cache.values(for: apps)
        XCTAssertEqual(reads.count, apps.count)
        let second = cache.values(for: apps)
        XCTAssertEqual(reads.count, apps.count, "a later tick reads nothing new")
        XCTAssertEqual(first, second)

        let current = NSRunningApplication.current
        XCTAssertEqual(cache.value(for: current).processIdentifier, ProcessInfo.processInfo.processIdentifier)
    }

    func testQuitAppsLeaveTheCache() throws {
        let reads = Reads()
        let cache = RunningApplicationCache { app in
            reads.add()
            return RunningApp(app)
        }
        let apps = NSWorkspace.shared.runningApplications
        try XCTSkipIf(apps.count < 2, "needs two running applications")
        _ = cache.values(for: apps)
        _ = cache.values(for: Array(apps.prefix(1)))
        _ = cache.values(for: apps)
        XCTAssertEqual(reads.count, apps.count * 2 - 1,
                       "an app that left the list is read again when it reappears")
    }
}
