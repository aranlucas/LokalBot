import XCTest
@testable import LokalBot

final class CodingAgentSessionTests: XCTestCase {
    private var root: URL!
    private var calendar: Calendar!
    private var day: Date!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodingAgentSessionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        day = try utc("2026-09-29T12:00:00Z")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Claude Code

    func testClaudeReaderKeepsRequestsRepliesEditsAndActionsButNeverToolOutput() throws {
        try writeClaudeSession("S1", lines: claudeWorkday, created: "2026-09-29T08:00:00Z")

        let bursts = scan().bursts

        XCTAssertEqual(bursts.count, 2, "an idle gap over ten minutes starts a new burst")
        let first = try XCTUnwrap(bursts.first)
        XCTAssertEqual(first.agent, .claudeCode)
        XCTAssertEqual(first.title, "Fix digest freshness")
        XCTAssertEqual(first.project, "LokalBot")
        XCTAssertEqual(first.branch, "claude/fix-badge")
        XCTAssertEqual(first.prompts, ["Fix the stale digest badge. Use [REDACTED_TOKEN]"])
        XCTAssertEqual(first.finalReply, "Opened the PR and pushed.")
        XCTAssertEqual(first.changedFiles, ["LokalBot/Views/DayDigestCard.swift"])
        XCTAssertEqual(first.actions, [
            .commit(message: "Keep the digest badge fresh"),
            .pushed,
            .openedPullRequest(title: "Keep the digest badge fresh"),
        ])
        XCTAssertEqual(first.pullRequests, ["https://github.com/stevyhacker/LokalBot/pull/118"])
        XCTAssertEqual(first.start, try utc("2026-09-29T09:00:00Z"))
        XCTAssertEqual(first.end, try utc("2026-09-29T09:20:00Z"))
        XCTAssertEqual(first.activeDuration, 15 * 60, "the ten-minute wait counts as five")
        XCTAssertEqual(first.toolCallCount, 3)

        let second = try XCTUnwrap(bursts.last)
        XCTAssertEqual(second.prompts, ["/code-review high", "Ran in terminal: git push"])
        XCTAssertEqual(second.actions, [.pushed])
        XCTAssertTrue(second.pullRequests.isEmpty, "a link re-emitted while idle joins no burst")

        let evidence = bursts.map { $0.evidenceText(calendar: calendar) }.joined(separator: "\n")
        for leaked in [
            "FILE CONTENTS", "private plan", "SECRET OUTPUT", "ignore me", "ghp_",
            "meta stuff", "sidechain.swift", "yesterday's request", "Caveat", "/fast",
        ] {
            XCTAssertFalse(evidence.contains(leaked), "leaked \(leaked)")
        }
    }

    func testClaudeForkCreditsCopiedHistoryToTheOriginalSession() throws {
        let original = [
            claudeUser(uuid: "u10", at: "2026-09-29T08:00:00Z", text: "Original request"),
            claudeAssistantText(uuid: "a10", at: "2026-09-29T08:01:00Z", text: "Original reply"),
        ]
        try writeClaudeSession("ORIGINAL", lines: original, created: "2026-09-28T08:00:00Z")
        try writeClaudeSession(
            "FORK",
            lines: original + [
                #"{"type":"custom-title","customTitle":"Original (fork)","sessionId":"FORK"}"#,
                claudeUser(uuid: "u11", at: "2026-09-29T08:30:00Z", text: "Fork-only request"),
            ],
            created: "2026-09-29T08:20:00Z")

        let bursts = scan().bursts

        XCTAssertEqual(bursts.map(\.sessionID), ["ORIGINAL", "FORK"])
        XCTAssertEqual(bursts.first?.prompts, ["Original request"])
        XCTAssertEqual(bursts.last?.prompts, ["Fork-only request"])
        XCTAssertEqual(bursts.last?.title, "Original (fork)")
    }

    func testCacheReparsesOnlyChangedFilesAndStillDropsANewForksCopies() throws {
        let original = [
            claudeUser(uuid: "u10", at: "2026-09-29T08:00:00Z", text: "Original request"),
            claudeAssistantText(uuid: "a10", at: "2026-09-29T08:01:00Z", text: "Original reply"),
        ]
        try writeClaudeSession("ORIGINAL", lines: original, created: "2026-09-28T08:00:00Z")
        let reader = ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))
        let cache = CodingAgentParseCache()

        let first = reader.transcripts(in: dayInterval, cache: cache)
        let unchanged = reader.transcripts(in: dayInterval, cache: cache)
        XCTAssertEqual(first.filesRead, 1)
        XCTAssertEqual(unchanged.filesRead, 0, "an unchanged file is reused, not parsed")
        XCTAssertEqual(unchanged.transcripts, first.transcripts)

        // The fork arrives after the original was cached; its copied
        // history must still be credited to the original.
        try writeClaudeSession(
            "FORK",
            lines: original + [claudeUser(uuid: "u11", at: "2026-09-29T08:30:00Z", text: "Fork-only request")],
            created: "2026-09-29T08:20:00Z")
        let withFork = reader.transcripts(in: dayInterval, cache: cache)

        XCTAssertEqual(withFork.filesRead, 1, "only the new file is parsed")
        let bursts = withFork.transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }
        XCTAssertEqual(bursts.map(\.prompts), [["Original request"], ["Fork-only request"]])
    }

    func testCompactingActivityNeverChangesABurst() throws {
        let start = try utc("2026-09-29T09:00:00Z")
        var events = [CodingAgentEvent(at: start, kind: .prompt("Build it"))]
        // Tool results every 20 s for four minutes, a 7-minute wait, more
        // results, then an idle gap long enough to start a new burst.
        for second in stride(from: 20, through: 240, by: 20) {
            events.append(CodingAgentEvent(at: start.addingTimeInterval(TimeInterval(second)), kind: .activity))
        }
        events.append(CodingAgentEvent(at: start.addingTimeInterval(660), kind: .activity))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(680), kind: .reply("Built.")))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(690), kind: .pullRequest("https://github.com/o/r/pull/1")))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(2_000), kind: .activity))
        events.append(CodingAgentEvent(at: start.addingTimeInterval(2_010), kind: .fileChange("A.swift")))
        let transcript = CodingAgentTranscript(agent: .codex, sessionID: "T", events: events)
        var compacted = transcript
        compacted.events = CodingAgentBurstBuilder.compactingActivity(events)

        XCTAssertLessThan(compacted.events.count, events.count)
        XCTAssertEqual(CodingAgentBurstBuilder.bursts(from: compacted), CodingAgentBurstBuilder.bursts(from: transcript))
    }

    func testSessionThatReadTheLokalBotLibraryWithholdsReplies() throws {
        try writeClaudeSession("S2", lines: [
            claudeUser(uuid: "u1", at: "2026-09-29T10:00:00Z", text: "What did I promise Ana?"),
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"mcp__lokalbot__search_meetings","input":{"query":"Ana"}}]},"uuid":"a1","timestamp":"2026-09-29T10:00:10.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S2"}"#,
            claudeAssistantText(uuid: "a2", at: "2026-09-29T10:01:00Z", text: "You promised Ana the budget by Friday."),
        ], created: "2026-09-29T09:00:00Z")

        let burst = try XCTUnwrap(scan().bursts.first)

        XCTAssertEqual(burst.prompts, ["What did I promise Ana?"])
        XCTAssertNil(burst.finalReply, "a reply may restate library content")
    }

    // MARK: - Codex

    func testCodexReaderFindsResumedRolloutAndSkipsSubagentsAndStaleFiles() throws {
        let codex = root.appendingPathComponent("codex", isDirectory: true)
        try write(
            codexResumedRollout,
            to: codex.appendingPathComponent("sessions/2026/09/03/rollout-2026-09-03T10-00-00-T1.jsonl"),
            created: "2026-09-03T10:00:00Z", modified: "2026-09-29T18:00:00Z")
        try write(
            [
                #"{"timestamp":"2026-09-29T14:10:00.000Z","type":"session_meta","payload":{"id":"G1","cwd":"/Users/me/Code/Mojo","source":{"subagent":{"other":"guardian"}}}}"#,
                #"{"timestamp":"2026-09-29T14:10:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Review this approval"}]}}"#,
            ],
            to: codex.appendingPathComponent("sessions/2026/09/29/rollout-2026-09-29T14-10-00-G1.jsonl"),
            created: "2026-09-29T14:10:00Z", modified: "2026-09-29T14:11:00Z")
        try write(
            [#"{"timestamp":"2026-09-20T09:00:00.000Z","type":"session_meta","payload":{"id":"OLD","cwd":"/tmp","source":"cli"}}"#],
            to: codex.appendingPathComponent("sessions/2026/09/20/rollout-2026-09-20T09-00-00-OLD.jsonl"),
            created: "2026-09-20T09:00:00Z", modified: "2026-09-20T09:30:00Z")
        try write(
            [
                #"{"id":"T1","thread_name":"Update app branding","updated_at":"2026-09-03T10:00:00Z"}"#,
                #"{"id":"T1","thread_name":"Update Mojo branding","updated_at":"2026-09-29T14:00:00Z"}"#,
            ],
            to: codex.appendingPathComponent("session_index.jsonl"),
            created: "2026-09-03T10:00:00Z", modified: "2026-09-29T14:00:00Z")

        let result = CodexSessionReader(root: codex).transcripts(in: dayInterval)
        let bursts = result.transcripts.flatMap { CodingAgentBurstBuilder.bursts(from: $0) }

        XCTAssertEqual(result.filesRead, 2, "a rollout untouched since before the day is never opened")
        XCTAssertEqual(bursts.count, 1, "the guardian subagent is not the person's session")
        let burst = try XCTUnwrap(bursts.first)
        XCTAssertEqual(burst.agent, .codex)
        XCTAssertEqual(burst.sessionID, "T1")
        XCTAssertEqual(burst.title, "Update Mojo branding")
        XCTAssertEqual(burst.project, "Mojo")
        XCTAssertEqual(burst.branch, "stevyhacker/mojo-branding")
        XCTAssertEqual(burst.prompts, ["Apply Mojo branding across the app"])
        XCTAssertEqual(
            burst.changedFiles, ["Sources/Theme.swift", "Sources/Logo.swift", "Sources/Colors.swift"])
        XCTAssertEqual(burst.actions, [
            .commit(message: "feat: apply Mojo branding across the app"),
            .pushed,
            .openedPullRequest(title: "feat: apply Mojo branding across the app"),
        ])
        XCTAssertEqual(burst.finalReply, "Opened localhostinc/app PR #186 with the branding.")
        XCTAssertEqual(burst.toolCallCount, 2)

        let evidence = burst.evidenceText(calendar: calendar)
        for leaked in [
            "old request", "developer instructions", "AGENTS.md", "environment_context",
            "Open tabs", "NEVER KEPT", "hidden reasoning",
        ] {
            XCTAssertFalse(evidence.contains(leaked), "leaked \(leaked)")
        }
    }

    // MARK: - Scanner and bursts

    func testScannerDropsSessionsInsideExcludedFolders() throws {
        try writeClaudeSession("S1", lines: claudeWorkday, created: "2026-09-29T08:00:00Z")
        let scanner = CodingAgentSessionScanner(
            readers: [ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))],
            excludedFolders: ["/Users/me/Code/"])

        let result = scanner.scan(day: day, calendar: calendar)

        XCTAssertTrue(result.bursts.isEmpty)
        XCTAssertEqual(result.excludedSessions, 1)
        XCTAssertFalse(scanner.isExcluded("/Users/me/CodeReview"), "a sibling folder is not inside it")
    }

    func testBurstWithoutRequestsContinuesEarlierWorkAndPingsAloneAreDropped() throws {
        let transcript = CodingAgentTranscript(
            agent: .codex, sessionID: "T9", workingDirectory: "/Users/me/Code/App",
            events: [
                CodingAgentEvent(at: try utc("2026-09-29T08:00:00Z"), kind: .activity),
                CodingAgentEvent(at: try utc("2026-09-29T09:00:00Z"), kind: .fileChange("App.swift")),
                CodingAgentEvent(at: try utc("2026-09-29T09:01:00Z"), kind: .activity),
            ])

        let bursts = CodingAgentBurstBuilder.bursts(from: transcript)

        XCTAssertEqual(bursts.count, 1)
        XCTAssertEqual(bursts.first?.title, "Untitled session")
        XCTAssertTrue(bursts.first?.evidenceText(calendar: calendar)
            .contains("Requests: continued work from an earlier request") == true)
    }

    func testEvidenceTextLeadsWithWorkAndLabelsTheReportAsAClaim() throws {
        let burst = CodingAgentBurst(
            agent: .claudeCode, sessionID: "1ac1dcdf-d832", title: "README improvements",
            project: "LokalBot", branch: "master",
            start: try utc("2026-09-29T06:50:00Z"), end: try utc("2026-09-29T07:00:00Z"),
            activeDuration: 540, prompts: ["a", "b", "c", "d", "e"], promptCount: 7,
            finalReply: "Opened PR #107.", changedFiles: ["README.md"], changedFileCount: 3,
            actions: [.mergedPullRequest(number: 110), .mergedPullRequest(number: nil)],
            pullRequests: ["https://github.com/stevyhacker/LokalBot/pull/107"], toolCallCount: 20)

        XCTAssertEqual(burst.evidenceText(calendar: calendar), """
            WORK SOURCE: AGENT SESSION [agent:claude-code:1ac1dcdf]
            Agent: Claude Code
            Session: README improvements
            Project: LokalBot (branch master)
            Requests:
            - a
            - b
            - c
            - d
            - (+3 more)
            Changed files (3): README.md, +2 more
            Recorded actions: merged PR #110; merged PR
            Pull requests: https://github.com/stevyhacker/LokalBot/pull/107
            Agent's final report (a claim; corroborate with actions): Opened PR #107.
            LOW-PRIORITY TRACE METADATA — do not summarize directly:
            06:50–07:00; active=9m; tool_calls=20
            """)
    }

    // MARK: - Text rules

    func testPromptKeepsOnlyWhatThePersonWrote() {
        XCTAssertEqual(
            CodingAgentText.prompt("<system-reminder>ctx</system-reminder>\nShip it"), "Ship it")
        XCTAssertEqual(
            CodingAgentText.prompt("# Context from my IDE setup:\n## Active file: a.swift\n## My request for Codex:\nRename it"),
            "Rename it")
        XCTAssertEqual(
            CodingAgentText.prompt("Summarize <pasted_content id=\"1\">long log</pasted_content id=\"1\"> please"),
            "Summarize [pasted text] please")
        XCTAssertEqual(
            CodingAgentText.prompt("<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>high</command-args>"),
            "/code-review high")
        XCTAssertNil(CodingAgentText.prompt("<command-name>/fast</command-name>\n<command-args>on</command-args>"))
        XCTAssertEqual(
            CodingAgentText.prompt("<scheduled-task name=\"disk-check\" file=\"/x/SKILL.md\">\nAutomated run…"),
            "Scheduled task: disk-check")
        XCTAssertEqual(
            CodingAgentText.prompt("<heartbeat>\n  <automation_id>daily-update</automation_id>\n</heartbeat>"),
            "Scheduled automation: daily-update")
        XCTAssertEqual(
            CodingAgentText.prompt("<bash-input>ls -la</bash-input><bash-stdout>secret.txt</bash-stdout><bash-stderr></bash-stderr>"),
            "Ran in terminal: ls -la")
        XCTAssertEqual(
            CodingAgentText.prompt("<launch-selected-element><text>page</text></launch-selected-element>\nMake this bigger"),
            "Make this bigger")
        XCTAssertEqual(CodingAgentText.prompt("Style the <div> and <span> tags"), "Style the <div> and <span> tags")
        XCTAssertNil(CodingAgentText.prompt("<environment_context>\n  <cwd>/x</cwd>\n</environment_context>"))
        XCTAssertNil(CodingAgentText.prompt("<turn_aborted>"))
        XCTAssertNil(CodingAgentText.prompt("Caveat: The messages below were generated by the user"))
        XCTAssertEqual(
            CodingAgentText.prompt("deploy with password: hunter2hunter2"), "deploy with password: [REDACTED]")
    }

    func testActionsAreParsedFromTheCommandsTheAgentRan() {
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: """
                git add -A && git commit -m "$(cat <<'EOF'
                Keep the digest badge fresh

                Longer body.
                EOF
                )" && git push -u origin HEAD
                """),
            [.commit(message: "Keep the digest badge fresh"), .pushed])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: #"git -C repo commit -am "Fix \"quoted\" title""#),
            [.commit(message: #"Fix "quoted" title"#)])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: "gh pr create --draft -t 'Add films' --body x"),
            [.openedPullRequest(title: "Add films")])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: "gh pr merge 110 --squash; gh pr merge https://github.com/o/r/pull/7; gh pr merge --auto"),
            [.mergedPullRequest(number: 110), .mergedPullRequest(number: 7), .mergedPullRequest(number: nil)])
        XCTAssertEqual(CodingAgentText.actions(inCommand: "gh release create v0.9.2 dist/x.dmg"), [.release(tag: "v0.9.2")])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: "xcodebuild -scheme LokalBot -destination 'platform=macOS' test"),
            [.ranTests])
        XCTAssertEqual(
            CodingAgentText.actions(inCommand: #"["/bin/zsh","-lc","npm run test && git push"]"#),
            [.pushed, .ranTests])
        XCTAssertEqual(CodingAgentText.actions(inCommand: "git status && git log --oneline"), [])
        XCTAssertTrue(CodingAgentText.readsLokalBot(command: "lokalbot search 'budget'"))
        XCTAssertTrue(CodingAgentText.readsLokalBot(command: "/Applications/LokalBot.app/Contents/Helpers/lokalbot-cli list"))
        XCTAssertFalse(CodingAgentText.readsLokalBot(command: "cd ~/Code/LokalBot && swift build"))
    }

    func testChangedFilesAreNamedRelativeToTheProject() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(
            CodingAgentText.displayPath("/Users/me/Code/App/Sources/A.swift", workingDirectory: "/Users/me/Code/App"),
            "Sources/A.swift")
        XCTAssertEqual(
            CodingAgentText.displayPath(
                "/Users/me/Code/App/.claude/worktrees/fix-badge/Sources/A.swift", workingDirectory: "/Users/me/Code/App"),
            "Sources/A.swift")
        XCTAssertEqual(
            CodingAgentText.displayPath("/Users/me/.codex/worktrees/f2bb/Colony/web/page.tsx", workingDirectory: nil),
            "web/page.tsx")
        XCTAssertEqual(
            CodingAgentText.displayPath(
                "/private/tmp/claude-501/-Users-me-Code-App/1ac1dcdf-d832-4204-904b-f3e4e9a6f33c/scratchpad/x/team.html",
                workingDirectory: "/Users/me/Code/App"),
            "scratchpad/x/team.html")
        XCTAssertEqual(
            CodingAgentText.displayPath(home + "/Notes/plan.md", workingDirectory: "/Users/me/Code/App"),
            "~/Notes/plan.md")
        XCTAssertEqual(
            CodingAgentBurstBuilder.projectName(for: "/Users/me/Code/LokalBot/.claude/worktrees/agent-session-evidence"),
            "LokalBot")
        XCTAssertEqual(CodingAgentBurstBuilder.projectName(for: nil), "Unknown project")
    }

    func testTimestampsParseBothAgentsFormats() throws {
        let reference = try utc("2026-09-29T14:46:12Z")
        XCTAssertEqual(CodingAgentTimestamp.date("2026-09-29T14:46:12Z"), reference)
        XCTAssertEqual(
            try XCTUnwrap(CodingAgentTimestamp.date("2026-09-29T14:46:12.824Z")).timeIntervalSince(reference),
            0.824, accuracy: 0.0001)
        XCTAssertEqual(
            try XCTUnwrap(CodingAgentTimestamp.date("2026-09-29T20:02:50.291977Z")).timeIntervalSince1970,
            try utc("2026-09-29T20:02:50Z").timeIntervalSince1970 + 0.291977, accuracy: 0.0001)
        XCTAssertEqual(CodingAgentTimestamp.date("2026-09-29T16:46:12+02:00"), reference)
        XCTAssertEqual(CodingAgentTimestamp.date("2024-02-29T00:00:00Z"), try utc("2024-02-29T00:00:00Z"))
        XCTAssertNil(CodingAgentTimestamp.date("yesterday"))
    }

    func testHeadlessAgentSessionsFlag() throws {
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--agent-sessions"]), .agentSessions(dayKey: nil))
        XCTAssertEqual(
            HeadlessCommand.parse(["LokalBot", "--agent-sessions", "2026-09-29"]),
            .agentSessions(dayKey: "2026-09-29"))
        XCTAssertEqual(HeadlessCommand.parse(["LokalBot", "--agent", "hi"]), .agent(prompt: "hi"))
        XCTAssertEqual(CodingAgentSessionsCLI.run(dayKey: "2026-02-30"), 2)

        let empty = CodingAgentDayScan(
            interval: dayInterval, bursts: [], sessionCount: 0, filesRead: 3, bytesRead: 2_500_000,
            unreadableFiles: ["/x/broken.jsonl"], excludedSessions: 1)
        XCTAssertEqual(
            CodingAgentSessionsCLI.render(empty, day: day, elapsed: 0.42, calendar: calendar),
            """
            Unreadable transcript: /x/broken.jsonl

            LokalBot --agent-sessions: 2026-09-29 — 0 sessions, 0 bursts, 0 evidence chars from 3 files (2 MB) in 0.4s; 1 excluded
            """)
    }

    // MARK: - Fixtures

    private var dayInterval: DateInterval {
        DateInterval(start: calendar.startOfDay(for: day), duration: 86_400)
    }

    private func scan() -> CodingAgentDayScan {
        CodingAgentSessionScanner(readers: [ClaudeCodeSessionReader(root: root.appendingPathComponent("claude"))])
            .scan(day: day, calendar: calendar)
    }

    private var claudeWorkday: [String] {
        [
            #"{"type":"custom-title","customTitle":"Fix digest freshness","sessionId":"S1"}"#,
            claudeUser(uuid: "u0", at: "2026-09-28T23:59:00Z", text: "yesterday's request"),
            claudeUser(
                uuid: "u1", at: "2026-09-29T09:00:00Z",
                text: "<system-reminder>ignore me</system-reminder>Fix the stale digest badge. Use ghp_abcdefghijklmnopqrstuvwx1234"),
            #"{"parentUuid":"u1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"private plan"},{"type":"text","text":"Fixing the badge now."},"#
                + #"{"type":"tool_use","id":"t1","name":"Edit","input":{"file_path":"/Users/me/Code/LokalBot/LokalBot/Views/DayDigestCard.swift","old_string":"a","new_string":"b"}}]},"#
                + #""uuid":"a1","timestamp":"2026-09-29T09:01:00.000Z","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S1"}"#,
            #"{"parentUuid":"a1","isSidechain":false,"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"FILE CONTENTS SHOULD NEVER APPEAR"}]},"uuid":"r1","timestamp":"2026-09-29T09:02:00.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S1"}"#,
            #"{"parentUuid":"r1","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","#
                + #""input":{"command":"git add -A && git commit -m \"$(cat <<'EOF'\nKeep the digest badge fresh\n\nBody\nEOF\n)\" && git push","description":"Commit"}}]},"#
                + #""uuid":"a2","timestamp":"2026-09-29T09:05:00.000Z","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S1"}"#,
            #"{"parentUuid":"a2","isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"gh pr create --draft --title \"Keep the digest badge fresh\" --body \"x\""}}]},"uuid":"a3","timestamp":"2026-09-29T09:10:00.000Z","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S1"}"#,
            claudeAssistantText(uuid: "a4", at: "2026-09-29T09:20:00Z", text: "Opened the PR and pushed."),
            #"{"type":"pr-link","sessionId":"S1","prNumber":118,"prUrl":"https://github.com/stevyhacker/LokalBot/pull/118","prRepository":"stevyhacker/LokalBot","timestamp":"2026-09-29T09:20:30.000Z"}"#,
            claudeUser(
                uuid: "u2", at: "2026-09-29T11:00:00Z",
                text: "<command-message>code-review</command-message>\n<command-name>/code-review</command-name>\n<command-args>high</command-args>"),
            claudeAssistantText(uuid: "a5", at: "2026-09-29T11:01:00Z", text: "No findings."),
            claudeUser(uuid: "u3", at: "2026-09-29T11:05:00Z", text: "<command-name>/fast</command-name>\n<command-args>on</command-args>"),
            #"{"parentUuid":"u3","isSidechain":false,"isMeta":true,"type":"user","message":{"role":"user","content":"meta stuff"},"uuid":"m1","timestamp":"2026-09-29T11:06:00.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S1"}"#,
            #"{"parentUuid":"m1","isSidechain":true,"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Write","input":{"file_path":"/Users/me/Code/LokalBot/sidechain.swift","content":"x"}}]},"uuid":"s1","timestamp":"2026-09-29T11:07:00.000Z","cwd":"/Users/me/Code/LokalBot","sessionId":"S1"}"#,
            claudeUser(uuid: "u4", at: "2026-09-29T11:08:00Z", text: "Caveat: The messages below were generated by the user while running local commands."),
            claudeUser(
                uuid: "u5", at: "2026-09-29T11:10:00Z",
                text: "<bash-input>git push</bash-input><bash-stdout>Everything up-to-date SECRET OUTPUT</bash-stdout><bash-stderr></bash-stderr>"),
            #"{"type":"pr-link","sessionId":"S1","prNumber":118,"prUrl":"https://github.com/stevyhacker/LokalBot/pull/119","prRepository":"stevyhacker/LokalBot","timestamp":"2026-09-29T13:00:00.000Z"}"#,
            "{not json",
            #"{"type":"some-future-record","payload":{"x":1}}"#,
        ]
    }

    private var codexResumedRollout: [String] {
        [
            #"{"timestamp":"2026-09-03T10:00:00.000Z","type":"session_meta","payload":{"id":"T1","timestamp":"2026-09-03T10:00:00.000Z","cwd":"/Users/me/Code/Mojo","originator":"Codex Desktop","source":"vscode","git":{"branch":"stevyhacker/mojo-branding","commit_hash":"abc"}}}"#,
            #"{"timestamp":"2026-09-03T10:00:05.000Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"old request from September 3"}]}}"#,
            #"{"timestamp":"2026-09-29T14:00:00.000Z","type":"response_item","payload":{"type":"message","role":"developer","content":[{"type":"input_text","text":"developer instructions"}]}}"#,
            ##"{"timestamp":"2026-09-29T14:00:01.000Z","type":"response_item","payload":{"type":"message","role":"user","content":["##
                + ##"{"type":"input_text","text":"# AGENTS.md instructions for /Users/me/Code/Mojo\n\n<INSTRUCTIONS>rules</INSTRUCTIONS>"},"##
                + ##"{"type":"input_text","text":"<environment_context>\n  <cwd>/Users/me/Code/Mojo</cwd>\n</environment_context>"},"##
                + ##"{"type":"input_text","text":"# Context from my IDE setup:\n\n## Open tabs:\n- a.swift\n\n## My request:\nApply Mojo branding across the app"}]}}"##,
            #"{"timestamp":"2026-09-29T14:00:02.000Z","type":"response_item","payload":{"type":"reasoning","summary":[],"content":null,"encrypted_content":"hidden reasoning"}}"#,
            #"{"timestamp":"2026-09-29T14:02:00.000Z","type":"response_item","payload":{"type":"custom_tool_call","status":"completed","call_id":"c1","name":"apply_patch","input":"*** Begin Patch\n*** Update File: /Users/me/Code/Mojo/Sources/Theme.swift\n@@\n-old\n+new\n*** Add File: /Users/me/Code/Mojo/Sources/Logo.swift\n+new\n*** End Patch"}}"#,
            #"{"timestamp":"2026-09-29T14:02:01.000Z","type":"response_item","payload":{"type":"custom_tool_call_output","call_id":"c1","output":"PATCH OUTPUT NEVER KEPT"}}"#,
            #"{"timestamp":"2026-09-29T14:03:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"T1","turn_id":"x","item":{"type":"Reasoning","id":"r","summary_text":["hidden reasoning"]}}}"#,
            #"{"timestamp":"2026-09-29T14:05:00.000Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"git commit -am 'feat: apply Mojo branding across the app' && git push -u origin HEAD\"}","call_id":"f1"}}"#,
            #"{"timestamp":"2026-09-29T14:05:02.000Z","type":"response_item","payload":{"type":"function_call_output","call_id":"f1","output":"COMMAND OUTPUT NEVER KEPT"}}"#,
            #"{"timestamp":"2026-09-29T14:06:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"T1","turn_id":"x","item":{"type":"CommandExecution","id":"e1","command":"[\"/bin/zsh\",\"-lc\",\"gh pr create --title \\\"feat: apply Mojo branding across the app\\\" --body x\"]","aggregated_output":"OUTPUT NEVER KEPT","exit_code":0}}}"#,
            #"{"timestamp":"2026-09-29T14:07:00.000Z","type":"event_msg","payload":{"type":"item_completed","thread_id":"T1","turn_id":"x","item":{"type":"FileChange","id":"fc1","changes":{"/Users/me/Code/Mojo/Sources/Colors.swift":{"type":"update","unified_diff":"DIFF NEVER KEPT"}},"status":"completed"}}}"#,
            #"{"timestamp":"2026-09-29T14:08:00.000Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Opened localhostinc/app PR #186 with the branding."}]}}"#,
        ]
    }

    /// A user record in Claude Code's key order, which the tool-result
    /// fast path depends on.
    private func claudeUser(uuid: String, at timestamp: String, text: String) -> String {
        let prefix = #"{"parentUuid":null,"isSidechain":false,"type":"user","message":{"role":"user","content":"#
        return prefix + json(text) + "}," + claudeTrailer(uuid: uuid, at: timestamp)
    }

    private func claudeAssistantText(uuid: String, at timestamp: String, text: String) -> String {
        let prefix = #"{"parentUuid":null,"isSidechain":false,"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"#
        return prefix + json(text) + "}]}," + claudeTrailer(uuid: uuid, at: timestamp)
    }

    private func claudeTrailer(uuid: String, at timestamp: String) -> String {
        let millis = timestamp.replacingOccurrences(of: "Z", with: ".000Z")
        return #""uuid":"# + json(uuid) + #","timestamp":"# + json(millis)
            + #","cwd":"/Users/me/Code/LokalBot","gitBranch":"claude/fix-badge","sessionId":"S"}"#
    }

    /// `value` as a quoted JSON string.
    private func json(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[\"\"]".utf8)
        return String((String(data: data, encoding: .utf8) ?? "[\"\"]").dropFirst().dropLast())
    }

    private func writeClaudeSession(_ id: String, lines: [String], created: String) throws {
        try write(
            lines,
            to: root.appendingPathComponent("claude/-Users-me-Code-LokalBot/\(id).jsonl"),
            created: created, modified: "2026-09-29T20:00:00Z")
    }

    private func write(_ lines: [String], to url: URL, created: String, modified: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.creationDate: try utc(created), .modificationDate: try utc(modified)],
            ofItemAtPath: url.path)
    }

    private func utc(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value), value)
    }
}
