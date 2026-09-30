import XCTest
@testable import LokalBot

/// How coding-agent sessions reach the digest model: as segment evidence,
/// with reserved room, once per session, ahead of the same work on screen.
final class CodingAgentDigestModelTests: XCTestCase {
    private var calendar: Calendar!
    private var day: Date!

    override func setUpWithError() throws {
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        day = try date("2026-09-29T00:00:00Z")
    }

    func testSegmentsCarryAgentSessionsAsWorkEvidence() throws {
        let evidence = build(bursts: [try burst(
            "A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z",
            actions: [.commit(message: "Keep the digest badge fresh"), .pushed])])

        let segments = evidence.summarySegments()

        XCTAssertEqual(segments.count, 1)
        let text = try XCTUnwrap(segments.first?.evidence)
        XCTAssertTrue(text.contains("WORK SOURCE: AGENT SESSION"), text)
        XCTAssertTrue(text.contains("Session: Fix digest freshness"), text)
        XCTAssertTrue(text.contains("Recorded actions: commit: Keep the digest badge fresh; pushed"), text)
        XCTAssertTrue(text.contains("Claude Code — Fix digest freshness"), "the inventory names the session")
    }

    func testACrowdedSegmentKeepsRoomForSessionsThatRecordedOutcomes() throws {
        // One busy stretch with forty screen activities and seven parallel
        // sessions, followed by seven short, separate stretches, so the busy
        // one stays a single segment with more events than detail slots.
        let morning: Date = day.addingTimeInterval(9 * 3_600)
        var blocks: [ActivityBlock] = []
        for minute in 0..<40 {
            let start: Date = morning.addingTimeInterval(TimeInterval(minute) * 60)
            blocks.append(ActivityBlock(
                id: Int64(minute), app: "Safari", title: "Docs \(minute)",
                start: start, end: start.addingTimeInterval(60)))
        }
        for hour in 11...17 {
            let start: Date = day.addingTimeInterval(TimeInterval(hour) * 3_600)
            blocks.append(ActivityBlock(
                id: Int64(100 + hour), app: "Notes", title: "Note \(hour)",
                start: start, end: start.addingTimeInterval(60)))
        }
        var bursts: [CodingAgentBurst] = []
        for index in 1...7 {
            bursts.append(try burst(
                "S\(index)", start: "2026-09-29T09:05:00Z", end: "2026-09-29T09:30:00Z",
                title: "Session \(index)", actions: [.commit(message: "Change \(index)")]))
        }

        let segments = build(blocks: blocks, bursts: bursts).summarySegments()

        XCTAssertEqual(segments.count, 8)
        let busy = try XCTUnwrap(segments.first?.evidence)
        XCTAssertEqual(busy.components(separatedBy: "WORK SOURCE: AGENT SESSION").count - 1, 6)
        XCTAssertEqual(busy.components(separatedBy: "WORK SOURCE: ACTIVITY").count - 1, 6,
                       "screen activity keeps the other half of the detail budget")
    }

    func testASessionsBurstsInOneSegmentAppearOnceWithAllTheirActions() throws {
        // Seven separate later stretches keep the session to one segment; a
        // quiet day would otherwise be spread across several.
        let later: [ActivityBlock] = (11...17).map { hour in
            let start: Date = day.addingTimeInterval(TimeInterval(hour) * 3_600)
            return ActivityBlock(id: Int64(hour), app: "Notes", title: "Note \(hour)",
                                 start: start, end: start.addingTimeInterval(60))
        }
        let evidence = build(blocks: later, bursts: [
            try burst("A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:10:00Z",
                      prompts: ["Fix the badge"], actions: [.commit(message: "Fix the badge")]),
            try burst("A", start: "2026-09-29T09:15:00Z", end: "2026-09-29T09:25:00Z",
                      prompts: ["Open the PR"], actions: [.openedPullRequest(title: "Fix the badge")]),
        ])

        let text = try XCTUnwrap(evidence.summarySegments().first?.evidence)

        XCTAssertEqual(text.components(separatedBy: "WORK SOURCE: AGENT SESSION").count - 1, 1)
        XCTAssertTrue(text.contains("- Fix the badge\n- Open the PR"), text)
        XCTAssertTrue(text.contains("Recorded actions: commit: Fix the badge; opened PR: Fix the badge"), text)
        XCTAssertTrue(text.contains("active=20m"), "both bursts' active time counts once each")
    }

    func testScreenTextFromAgentAppsYieldsToTheSessionItShows() throws {
        let blocks = [
            ActivityBlock(id: 1, app: "Claude", title: "Claude",
                          start: try date("2026-09-29T09:00:00Z"), end: try date("2026-09-29T09:30:00Z")),
            ActivityBlock(id: 2, app: "Xcode", title: "LokalBot",
                          start: try date("2026-09-29T10:30:00Z"), end: try date("2026-09-29T11:30:00Z")),
            ActivityBlock(id: 3, app: "Claude", title: "Claude",
                          start: try date("2026-09-29T13:00:00Z"), end: try date("2026-09-29T14:00:00Z")),
        ]
        var contexts: [DayScreenContext] = []
        for (prefix, start, block) in [("CLAUDE-DURING", "09:00", 1), ("XCODE", "10:30", 2), ("CLAUDE-AFTER", "13:00", 3)] {
            let base = try date("2026-09-29T\(start):00Z")
            contexts += (0..<5).map { index in
                DayScreenContext(
                    snapshotID: Int64(block * 10 + index), capturedAt: base.addingTimeInterval(TimeInterval(index * 300 + 60)),
                    app: blocks[block - 1].app, windowTitle: blocks[block - 1].title,
                    text: "\(prefix)-\(index) distinct captured text for sample \(index)")
            }
        }
        contexts.append(DayScreenContext(
            snapshotID: 99, capturedAt: try date("2026-09-29T09:40:00Z"), app: "Terminal",
            windowTitle: "zsh", text: "TERMINAL-STANDALONE transcript on screen"))
        let evidence = build(
            blocks: blocks, contexts: contexts,
            bursts: [try burst("A", start: "2026-09-29T09:10:00Z", end: "2026-09-29T09:50:00Z")])

        let text = evidence.summarySegments().map(\.evidence).joined(separator: "\n")

        XCTAssertEqual(text.components(separatedBy: "CLAUDE-DURING-").count - 1, 1,
                       "an agent app's screen text during a session keeps one sample")
        XCTAssertTrue(text.contains("A coding-agent session covers this interval"), text)
        XCTAssertGreaterThan(text.components(separatedBy: "XCODE-").count - 1, 1)
        XCTAssertGreaterThan(text.components(separatedBy: "CLAUDE-AFTER-").count - 1, 1,
                             "the same app outside any session is ordinary evidence")
        XCTAssertFalse(text.contains("TERMINAL-STANDALONE"))
        XCTAssertTrue(evidence.renderDocument(summary: "", calendar: calendar).contains("TERMINAL-STANDALONE"),
                      "the lossless journal still keeps it")
    }

    func testFocusPromptExplainsHowToReadAgentSessions() {
        let prompt = PromptTemplates.dayDigestFocusSystem
        XCTAssertTrue(prompt.contains("AGENT SESSION evidence"))
        XCTAssertTrue(prompt.contains("recorded actions"))
        XCTAssertTrue(prompt.contains("the agent's claim"))
    }

    func testTheModelReceivesAgentEvidenceAndItsTaskReachesTheDigest() async throws {
        let recorder = PromptRecorder()
        let evidence = build(bursts: [try burst(
            "A", start: "2026-09-29T09:00:00Z", end: "2026-09-29T09:20:00Z",
            actions: [.openedPullRequest(title: "Keep the digest badge fresh")])])

        let result = try await DayDigestOverviewGenerator.generateResult(
            evidence: evidence, engine: RecordingEngine(recorder: recorder),
            customPrompt: "", calendar: calendar, sleep: { _ in })

        let prompts = await recorder.focusPrompts
        XCTAssertEqual(prompts.count, 1)
        XCTAssertTrue(prompts.first?.contains("opened PR: Keep the digest badge fresh") == true)
        XCTAssertTrue(result.summary.contains("Keep the digest badge fresh"), result.summary)
        XCTAssertEqual(result.quality, .complete)
    }

    // MARK: - Fixtures

    private actor PromptRecorder {
        private(set) var focusPrompts: [String] = []
        func record(_ prompt: String) { focusPrompts.append(prompt) }
    }

    private struct RecordingEngine: TextEngine {
        let recorder: PromptRecorder
        var displayName: String { "recording-test" }

        func generate(system: String, prompt: String, context: [String]) async throws -> String { "unused" }

        func generate(system: String, prompt: String, context: [String],
                      schema: [String: Any], options: TextGenerationOptions) async throws -> String {
            if system == PromptTemplates.dayDigestFocusSystem {
                await recorder.record(prompt)
                return """
                    {"substantive":true,"task":"Keep the digest badge fresh","work_done":"Opened a pull request that keeps the digest badge fresh.","status":"in_progress","outcome":"A pull request is open.","next_step":"","source_ids":[]}
                    """
            }
            return """
                {"tasks":[{"title":"Keep the digest badge fresh","status":"in_progress","summary":"Opened a pull request that keeps the digest badge fresh.","next_step":"","block_indices":[0]}],"decisions":[],"blockers":[]}
                """
        }
    }

    private func build(
        blocks: [ActivityBlock] = [], contexts: [DayScreenContext] = [], bursts: [CodingAgentBurst]
    ) -> DayDigestEvidence {
        DayDigestEvidence.build(
            day: day, blocks: blocks, screenContexts: contexts, meetings: [],
            codingAgentBursts: bursts, calendar: calendar)
    }

    private func burst(
        _ session: String,
        start: String,
        end: String,
        title: String = "Fix digest freshness",
        prompts: [String] = ["Fix the stale digest badge"],
        actions: [CodingAgentAction] = []
    ) throws -> CodingAgentBurst {
        let startDate = try date(start)
        let endDate = try date(end)
        return CodingAgentBurst(
            agent: .claudeCode, sessionID: session, title: title, project: "LokalBot",
            branch: "claude/fix-badge", start: startDate, end: endDate,
            activeDuration: endDate.timeIntervalSince(startDate),
            prompts: prompts, promptCount: prompts.count, finalReply: "Done.",
            changedFiles: ["LokalBot/Views/DayDigestCard.swift"], changedFileCount: 1,
            actions: actions, pullRequests: [], toolCallCount: 3)
    }

    private func date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
    }
}
