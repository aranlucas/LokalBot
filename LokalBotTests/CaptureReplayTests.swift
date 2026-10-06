import XCTest
@testable import LokalBot

/// Real services on replayed traces. Each test must fail with its bug's fix
/// undone (see the plan's Step 7 for how that was verified).
@MainActor
final class CaptureReplayTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureReplayTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        CaptureEnvironment.reset()
        try? FileManager.default.removeItem(at: root)
    }

    private func replay(_ name: String) throws -> ReplayCaptureEnvironment {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures/capture-traces"))
        let replay = ReplayCaptureEnvironment(trace: try CaptureTrace.load(from: url),
                                              start: Date(timeIntervalSince1970: 1_790_000_000))
        CaptureEnvironment.install(replay.environment)
        // Both outlive a test: the process list is cached by (virtual) time,
        // and capture remembers which sibling last emitted per bundle.
        MeetingDetector.invalidateAudioProcessSnapshot()
        MeetingDetector.resetCaptureTargetMemory()
        return replay
    }

    private func store() -> ActivityStore {
        ActivityStore(databaseURL: DiagnosticsPaths.database(root: root))
    }

    /// #116: Chrome's first read fails while its tree settles; one retry 0.75 s
    /// later must capture the page text instead of skipping.
    func testChromeTextIsCapturedAfterATransientRead() async throws {
        let replay = try replay("chrome-focus-after-tree-read")
        let store = store()
        var settings = AppSettings()
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .accessibleText
        settings.screenshotsEnabled = false
        let service = ScreenshotService(
            store: store, storage: StorageManager(), sampler: ActivitySampler(store: store),
            now: { replay.clock.now() }, settings: { settings })
        await service.captureIfAppropriate(trigger: .appSwitch)
        let captures = store.screenshots(in: nil, includingMissingFiles: true)
        XCTAssertTrue(captures.contains { $0.app == "Google Chrome" },
                      "the transient read must be retried and the text stored")
    }

    private func captureFramedPage(excludingDomains domains: String) async throws -> [ActivityStore.Screenshot] {
        let replay = try replay("chrome-page-with-framed-site")
        let store = store()
        var settings = AppSettings()
        settings.trackingEnabled = true
        settings.screenContextCaptureMode = .accessibleText
        settings.screenshotsEnabled = false
        settings.excludedScreenDomains = domains
        let service = ScreenshotService(
            store: store, storage: StorageManager(), sampler: ActivitySampler(store: store),
            now: { replay.clock.now() }, settings: { settings })
        await service.captureIfAppropriate(trigger: .appSwitch)
        return store.screenshots(in: nil, includingMissingFiles: true).filter { $0.app == "Google Chrome" }
    }

    /// Chrome exposes framed pages as their own web areas; the page keeps its
    /// address under unrelated site exclusions.
    func testFramedPageKeepsItsAddress() async throws {
        let captures = try await captureFramedPage(excludingDomains: "thr.xmpl")
        XCTAssertEqual(captures.first?.sourceURL, "https://dcs.xmpl/d/kd")
    }

    /// An excluded site framed inside another page still keeps the window out.
    func testFramedExcludedSiteKeepsTheWindowOut() async throws {
        let captures = try await captureFramedPage(excludingDomains: "wdgts.xmpl")
        XCTAssertTrue(captures.isEmpty, "the framed site's text would be stored with the page")
    }

    /// #109: a browser window with web content and no readable address keeps
    /// its app name; it must not become Private.
    func testBrowserTimeKeepsItsAppName() async throws {
        let replay = try replay("browser-web-content-without-url")
        let store = store()
        let sampler = ActivitySampler(store: store)
        await sampler.sample()
        await replay.clock.advance(by: 12)
        await sampler.sample()
        sampler.stop()
        let blocks = store.blocks(in: DateInterval(start: replay.clock.now().addingTimeInterval(-3_600),
                                                   duration: 7_200))
        XCTAssertEqual(blocks.first?.app, "Google Chrome")
        XCTAssertFalse(blocks.contains { $0.app == "Private" })
    }

    /// #98: an open call tab whose controls cannot be read keeps the meeting
    /// running for ten minutes; it ends only when the call ends.
    func testMeetCallSurvivesUnreadableControlsUntilItEnds() async throws {
        let replay = try replay("meet-controls-unreadable-tab-open")
        let detector = MeetingDetector()
        var started: [TimeInterval] = []
        var ended: [TimeInterval] = []
        detector.onMeetingStarted = { _ in started.append(replay.clock.elapsed) }
        detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 720, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(started.count, 1, "one meeting starts")
        XCTAssertLessThan(started.first ?? .infinity, 30)
        XCTAssertEqual(ended.count, 1, "the meeting ends once")
        XCTAssertGreaterThanOrEqual(ended.first ?? 0, 630, "must not end while the tab stays open")
        XCTAssertLessThan(ended.first ?? .infinity, 720)
    }

    /// 2026-10-03: Meet's page after the first call was not recognized as an
    /// end, so that call stayed bound but unverified, and the next meeting, in
    /// another room, was never detected. A verified call in another room must
    /// end the stale session and start its own, with its calendar event.
    func testCallInAnotherRoomReplacesAnUnverifiedCall() async throws {
        let replay = try replay("meet-room-change-after-unrecognized-end")
        let detector = MeetingDetector()
        detector.calendar = ReplayCalendar(candidates: [
            meeting("first", from: -77, to: 1_723, room: "bcd-fghj-klm", replay: replay),
            meeting("weekly", from: 1_723, to: 5_323, room: "npq-rstv-wxz", replay: replay),
        ])
        detector.calendarEnabled = true
        var started: [(at: TimeInterval, context: MeetingDetectionContext)] = []
        var ended: [TimeInterval] = []
        var verified: [TimeInterval: Bool] = [:]
        detector.onMeetingStarted = { started.append((replay.clock.elapsed, $0)) }
        detector.onMeetingEnded = { _ in ended.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 1_830, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
            verified[second] = detector.verifiesActiveCall
        }
        XCTAssertEqual(started.count, 2, "the first call, then the call in the other room")
        XCTAssertLessThan(started.first?.at ?? .infinity, 10)
        XCTAssertEqual(ended.count, 1, "the stale session ends once")
        XCTAssertGreaterThanOrEqual(ended.first ?? 0, 1_807, "an unrecognized page alone never ends a call")
        XCTAssertLessThan(ended.first ?? .infinity, 1_815)
        let replacement = try XCTUnwrap(started.last)
        XCTAssertGreaterThanOrEqual(replacement.at, ended.first ?? .infinity)
        XCTAssertEqual(replacement.context.detectedApp?.meetingURL?.absoluteString,
                       "https://meet.google.com/npq-rstv-wxz")
        XCTAssertEqual(replacement.context.calendarEvent?.externalID, "weekly")
        XCTAssertEqual(verified[1_680], true)
        XCTAssertEqual(verified[1_700], false, "a manual start must not join the unverified call")
        XCTAssertEqual(verified[1_830], true)
    }

    /// The same evening's manual Start from the menu bar: while the first call
    /// is unverified, the recording must neither join its session (whose later
    /// end would stop it) nor be labeled with its room.
    func testManualStartDoesNotJoinAnUnverifiedCall() async throws {
        let replay = try replay("meet-room-change-after-unrecognized-end")
        let app = AppState()
        for second in stride(from: 0.0, through: 1_700, by: 2) {
            await replay.clock.advance(to: second)
            await app.detector.tickForTesting()
            guard second == 100 else { continue }
            let verified = try XCTUnwrap(app.recordingContext(for: app.detector.activeApp))
            XCTAssertEqual(verified.detectedApp?.meetingURL?.absoluteString, "https://meet.google.com/bcd-fghj-klm")
            if app.settings.autoRecordMode != .manual {
                XCTAssertEqual(verified.detectorSessionID, app.detector.activeSessionID)
            }
        }
        let context = try XCTUnwrap(app.recordingContext(for: app.detector.activeApp))
        XCTAssertNotNil(app.detector.activeSessionID, "the first call is still bound")
        XCTAssertNil(context.detectorSessionID)
        XCTAssertNil(context.detectedApp?.meetingURL)
        XCTAssertEqual(context.detectedApp?.bundleID, "com.google.Chrome", "the browser's audio is still captured")
    }

    /// Back-to-back events on one Meet link: the call never ends, so the next
    /// event must split the recording, as it does for a native app. An event
    /// in another room means the current call is running over and must not.
    func testNextEventInTheSameRoomSplitsTheCall() async throws {
        for (nextRoom, splits) in [("bcd-fghj-klm", true), ("npq-rstv-wxz", false)] {
            let replay = try replay("meet-same-room-back-to-back")
            let detector = MeetingDetector()
            detector.calendar = ReplayCalendar(candidates: [
                meeting("first", from: -77, to: 1_723, room: "bcd-fghj-klm", replay: replay),
                meeting("second", from: 1_723, to: 5_323, room: nextRoom, replay: replay),
            ])
            detector.calendarEnabled = true
            var sessions: [UUID?] = []
            var switched: [(at: TimeInterval, context: MeetingDetectionContext)] = []
            detector.onMeetingStarted = { sessions.append($0.detectorSessionID) }
            detector.onMeetingSwitched = { switched.append((replay.clock.elapsed, $0)) }
            detector.onMeetingEnded = { _ in XCTFail("the call never ends") }
            for second in stride(from: 0.0, through: 1_800, by: 2) {
                await replay.clock.advance(to: second)
                await detector.tickForTesting()
            }
            XCTAssertEqual(sessions.count, 1, nextRoom)
            guard splits else {
                XCTAssertTrue(switched.isEmpty, "an event in another room does not split the call")
                continue
            }
            XCTAssertEqual(switched.count, 1)
            XCTAssertEqual(switched.first?.context.reason, "calendar-handoff")
            XCTAssertEqual(switched.first?.context.calendarEvent?.externalID, "second")
            XCTAssertEqual(switched.first?.context.detectorSessionID, sessions.first ?? nil)
            XCTAssertGreaterThanOrEqual(switched.first?.at ?? 0, 1_723)
            XCTAssertLessThan(switched.first?.at ?? .infinity, 1_727)
            CaptureEnvironment.reset()
        }
    }

    private func meeting(_ id: String, from start: TimeInterval, to end: TimeInterval, room: String,
                         replay: ReplayCaptureEnvironment) -> CalendarMeetingCandidate {
        let origin = replay.clock.now().addingTimeInterval(-replay.clock.elapsed)
        return CalendarMeetingCandidate(
            provider: "eventkit", externalID: id, title: id,
            startDate: origin.addingTimeInterval(start), endDate: origin.addingTimeInterval(end),
            meetingURL: URL(string: "https://meet.google.com/\(room)?authuser=1"), sourceCalendarTitle: nil)
    }

    private final class ReplayCalendar: CalendarEventProviding {
        let authorizationStatus = CalendarAuthorizationStatus.fullAccess
        let candidates: [CalendarMeetingCandidate]
        init(candidates: [CalendarMeetingCandidate]) { self.candidates = candidates }
        func requestAccess(_ completion: @escaping (Bool) -> Void) { completion(true) }
        func meetingCandidates(now: Date) -> [CalendarMeetingCandidate] { candidates }
    }

    /// Teams (#49/#56): a launch sound must not start a meeting; sustained call
    /// audio must, after the native-audio confirmation window.
    func testTeamsLaunchBlipDoesNotStartAMeetingButTheCallDoes() async throws {
        let replay = try replay("teams-launch-blip-then-call")
        let detector = MeetingDetector()
        var started: [TimeInterval] = []
        detector.onMeetingStarted = { _ in started.append(replay.clock.elapsed) }
        for second in stride(from: 0.0, through: 200, by: 2) {
            await replay.clock.advance(to: second)
            await detector.tickForTesting()
        }
        XCTAssertEqual(started.count, 1)
        XCTAssertGreaterThanOrEqual(started.first ?? 0,
                                    60 + MeetingDetector.nativeAudioMinimumConfirmationDuration - 2)
    }

    private let teams = MeetingDetector.DetectedApp(name: "Teams", bundleID: "com.microsoft.teams2", pid: 700)

    /// #179: new Teams plays a scheduled meeting only through modulehost, whose
    /// stream is open even while Teams is idle, so nothing counted as a source
    /// and a manual recording stayed microphone-only. It must hold modulehost.
    func testManualRecordingHoldsTheTeamsCallOnModuleHost() throws {
        _ = try replay("teams-call-only-on-modulehost")
        XCTAssertNil(MeetingDetector.captureCandidateApp(), "modulehost is not evidence of a call")
        let unbound = Meeting.CaptureIntent(systemAudioRequested: true)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .held(teams))
        XCTAssertEqual(MeetingDetector.currentCaptureTargetProcess(for: teams)?.id, 720, "the tap goes on modulehost")
    }

    /// The case 2fde15d guards: Teams sits idle while the Meet call being
    /// recorded cannot be read yet. Teams is only held, the call replaces it
    /// once readable, and a recording bound to the call never holds Teams.
    func testAHeldTeamsStreamGivesWayToTheMeetCall() async throws {
        let replay = try replay("teams-idle-while-meet-call-unreadable")
        let room = try XCTUnwrap(URL(string: "https://meet.google.com/bcd-fghj-klm"))
        let unbound = Meeting.CaptureIntent(systemAudioRequested: true)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .held(teams))
        XCTAssertNil(RecordingSystemAudioSource.find(for: .init(systemAudioRequested: true, meetingURL: room)))

        await replay.clock.advance(to: 40)
        let call = MeetingDetector.DetectedApp(name: "Google Chrome", bundleID: "com.google.Chrome",
                                               pid: 801, meetingURL: room)
        XCTAssertEqual(RecordingSystemAudioSource.find(for: unbound), .verified(call))
    }

    /// Every scripted browser trace must replay to at least one text capture.
    func testScriptedBrowserTracesReplayToACapture() async throws {
        let folder = try XCTUnwrap(Bundle(for: Self.self).url(
            forResource: "capture-traces", withExtension: nil, subdirectory: "Fixtures"))
        let scripted = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("scripted-") }
        guard !scripted.isEmpty else { throw XCTSkip("no scripted traces recorded yet") }
        for url in scripted {
            let replay = ReplayCaptureEnvironment(trace: try CaptureTrace.load(from: url), start: Date())
            CaptureEnvironment.install(replay.environment)
            let store = ActivityStore(databaseURL: root.appendingPathComponent("\(UUID()).sqlite"))
            var settings = AppSettings()
            settings.trackingEnabled = true
            settings.screenContextCaptureMode = .accessibleText
            let service = ScreenshotService(store: store, storage: StorageManager(),
                                            sampler: ActivitySampler(store: store),
                                            now: { replay.clock.now() }, settings: { settings })
            for second in stride(from: 5.0, through: replay.trace.events.last?.t ?? 5, by: 5) {
                await replay.clock.advance(to: second)
                await service.captureIfAppropriate(trigger: .manual)
            }
            XCTAssertFalse(store.screenshots(in: nil, includingMissingFiles: true).isEmpty, url.lastPathComponent)
        }
    }
}
