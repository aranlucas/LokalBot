import XCTest
@testable import LokalBot

@MainActor
final class MeetingAudioRecoveryTests: XCTestCase {
    private let room = URL(string: "https://meet.google.com/abc-defg-hij")!
    private var candidate: MeetingDetector.DetectedApp {
        .init(name: "Chrome", bundleID: "com.google.Chrome", pid: 42, meetingURL: room)
    }

    func testSourceFoundAfterOldRetryDeadlineAttachesOnceToExistingRecording() async {
        let recovery = MeetingAudioRecovery()
        let recording = UUID()
        let intent = Meeting.CaptureIntent(systemAudioRequested: true, appBundleID: candidate.bundleID, meetingURL: room)
        var elapsed: Double = 0
        var attached: [pid_t] = []
        let done = expectation(description: "late source attached")
        recovery.start(recordingID: recording, intent: intent, find: { _ in
            elapsed >= 137 ? self.candidate : nil
        }, attach: { app in attached.append(app.pid); done.fulfill(); return true }, sleep: { delay in
            elapsed += delay
            await Task.yield()
        })
        await fulfillment(of: [done], timeout: 2)
        XCTAssertGreaterThan(elapsed, 122)
        XCTAssertEqual(attached, [42])
        XCTAssertNil(recovery.recordingID)
    }

    func testVerifiedEventWakesPendingRetryAndRejectsWrongScopeOrStaleGeneration() async {
        let recovery = MeetingAudioRecovery()
        let recording = UUID()
        var attaches = 0
        recovery.start(recordingID: recording,
            intent: .init(systemAudioRequested: true, appBundleID: candidate.bundleID, meetingURL: room),
            find: { _ in nil }, attach: { _ in attaches += 1; return true })
        XCTAssertFalse(recovery.offer(candidate, recordingID: UUID()))
        var otherRoom = candidate
        otherRoom.meetingURL = URL(string: "https://meet.google.com/xyz-uvwx-rst")!
        XCTAssertFalse(recovery.offer(otherRoom, recordingID: recording))
        XCTAssertFalse(recovery.offer(.init(name: "Other", bundleID: "com.other.browser", pid: 9, meetingURL: room),
                                      recordingID: recording))
        XCTAssertTrue(recovery.offer(candidate, recordingID: recording))
        XCTAssertFalse(recovery.offer(candidate, recordingID: recording))
        XCTAssertEqual(attaches, 1)
    }

    func testStopAndMicrophoneOnlyNeverAttachAndStaleTaskCannotFindForNewSession() async {
        let recovery = MeetingAudioRecovery()
        let first = UUID()
        var finds = 0
        var attaches = 0
        let sleeperEntered = expectation(description: "old loop sleeping")
        var resumeOld: CheckedContinuation<Void, Never>?
        recovery.start(recordingID: first, intent: .init(systemAudioRequested: true),
            find: { _ in finds += 1; return self.candidate }, attach: { _ in attaches += 1; return true },
            sleep: { _ in await withCheckedContinuation { resumeOld = $0; sleeperEntered.fulfill() } })
        await fulfillment(of: [sleeperEntered], timeout: 2)
        recovery.cancel()
        recovery.start(recordingID: UUID(), intent: .init(systemAudioRequested: false),
            find: { _ in finds += 1; return self.candidate }, attach: { _ in attaches += 1; return true })
        resumeOld?.resume()
        await Task.yield()
        XCTAssertFalse(recovery.offer(candidate, recordingID: first))
        XCTAssertEqual(finds, 0)
        XCTAssertEqual(attaches, 0)
        XCTAssertNil(recovery.recordingID)
    }

    func testWarningsUseSuccessfulWritesInsteadOfVolume() {
        let now = Date()
        XCTAssertTrue(RecordingController.captureWarnings(systemAudioRequested: true, hasSystemTarget: true,
            microphoneLastWrite: now, systemLastWrite: now, elapsed: 600, now: now).isEmpty)
        XCTAssertFalse(RecordingController.captureWarnings(systemAudioRequested: true, hasSystemTarget: false,
            microphoneLastWrite: now, systemLastWrite: nil, elapsed: 0, now: now).isEmpty)
        XCTAssertTrue(RecordingController.captureWarnings(systemAudioRequested: false, hasSystemTarget: false,
            microphoneLastWrite: now, systemLastWrite: nil, elapsed: 600, now: now).isEmpty)
        XCTAssertEqual(RecordingController.captureWarnings(systemAudioRequested: true, hasSystemTarget: true,
            microphoneLastWrite: now, systemLastWrite: now.addingTimeInterval(-5), elapsed: 600, now: now).count, 1)
    }

    func testReviewedFullRangeSurvivesStaleFinalizationAndMetadataRoundTrip() throws {
        var current = Meeting(id: UUID(), title: "Test", appName: "Chrome", startedAt: Date(), relativePath: "fixture")
        current.contentRangeSource = .userReviewed
        current.captureIntent = .init(systemAudioRequested: true, appBundleID: candidate.bundleID, meetingURL: room)
        var finalized = current
        finalized.contentRange = .init(start: 0, end: 851)
        finalized.contentRangeSource = .confirmedCallEnd
        finalized.recordedDuration = 976
        finalized.endedAt = Date()
        let merged = RecordingController.mergingFinalization(finalized, into: current)
        XCTAssertNil(merged.contentRange)
        XCTAssertEqual(merged.contentRangeSource, .userReviewed)
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(merged))
        XCTAssertEqual(decoded.captureIntent, current.captureIntent)
        XCTAssertEqual(decoded.additionalSavedAudioDuration, 0)
        XCTAssertEqual(finalized.additionalSavedAudioDuration, 125)
    }
}
