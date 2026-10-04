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
