import XCTest
@testable import LokalBot

@MainActor
final class LoginItemStateTests: XCTestCase {
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0

        func increment() -> Int {
            lock.lock()
            defer { lock.unlock() }
            value += 1
            return value
        }

        func snapshot() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    func testConcurrentRefreshesCoalesceWhileStatusReadIsPending() async {
        let readStarted = expectation(description: "status read started")
        let gate = DispatchSemaphore(value: 0)
        let readCount = LockedCounter()

        let state = LoginItemState(read: {
            readCount.increment()
            readStarted.fulfill()
            _ = gate.wait(timeout: .now() + 2)
            return true
        }, write: { _ in })

        let first = Task { await state.refresh() }
        await fulfillment(of: [readStarted], timeout: 1)
        await state.refresh()
        XCTAssertEqual(readCount.snapshot(), 1)
        gate.signal()
        await first.value

        let count = readCount.snapshot()
        XCTAssertEqual(count, 1, "a pending status read must coalesce refresh requests")
        XCTAssertTrue(state.isLoaded)
        XCTAssertTrue(state.isEnabled)
    }

    func testRefreshCannotOverwriteAnInFlightEnableResult() async {
        let writeStarted = expectation(description: "registration started")
        let gate = DispatchSemaphore(value: 0)
        let reads = LockedCounter()

        let state = LoginItemState(read: {
            return reads.increment() > 1
        }, write: { _ in
            writeStarted.fulfill()
            _ = gate.wait(timeout: .now() + 2)
        })

        await state.refresh()
        XCTAssertFalse(state.isEnabled)

        let enable = Task { await state.setEnabled(true) }
        await fulfillment(of: [writeStarted], timeout: 1)
        await state.refresh()
        XCTAssertEqual(reads.snapshot(), 1, "refresh must not read status during registration")
        gate.signal()
        await enable.value

        XCTAssertTrue(state.isEnabled, "a stale refresh must not replace the completed enable result")
        XCTAssertNil(state.error)
        XCTAssertFalse(state.isBusy)
    }
}
