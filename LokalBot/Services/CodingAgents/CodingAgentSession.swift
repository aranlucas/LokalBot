import Foundation

/// A coding agent whose local session transcripts LokalBot can read as
/// work evidence. Transcripts are the agent's own files; LokalBot reads an
/// explicit allowlist of transcript paths and never the agent's credentials.
enum CodingAgentKind: String, CaseIterable, Codable, Sendable {
    case claudeCode = "claude-code"
    case codex

    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        }
    }
}

/// An outcome parsed from a command the agent ran. These are recorded
/// actions, unlike the agent's own report, which is only a claim.
enum CodingAgentAction: Hashable, Codable, Sendable {
    case commit(message: String)
    case openedPullRequest(title: String)
    /// `nil` when the command merged the current branch's PR.
    case mergedPullRequest(number: Int?)
    case release(tag: String)
    case pushed
    case ranTests

    var summary: String {
        switch self {
        case .commit(let message): "commit: \(message)"
        case .openedPullRequest(let title): "opened PR: \(title)"
        case .mergedPullRequest(let number): number.map { "merged PR #\($0)" } ?? "merged PR"
        case .release(let tag): "release: \(tag)"
        case .pushed: "pushed"
        case .ranTests: "ran tests"
        }
    }
}

/// One timestamped fact from a transcript. Tool output, file contents,
/// reasoning, and injected system or developer text never become events.
struct CodingAgentEvent: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case prompt(String)
        case reply(String)
        case toolCall
        case fileChange(String)
        case action(CodingAgentAction)
        /// A PR the agent associated with the session. Claude Code re-emits
        /// these links every turn, so they annotate work but never start,
        /// extend, or keep alive a burst on their own.
        case pullRequest(String)
        /// Timestamp-only evidence that the agent was working, such as a
        /// tool result whose content is deliberately not read.
        case activity
    }

    var at: Date
    var kind: Kind
    /// The source record's hashed id, for dropping copies a fork or resumed
    /// session carries. Hashes are per process and never persisted.
    var recordKey: Int?

    var isAnnotation: Bool {
        if case .pullRequest = kind { return true }
        return false
    }
}

/// One parsed session, with events already clipped to the requested day.
struct CodingAgentTranscript: Equatable, Sendable {
    var agent: CodingAgentKind
    var sessionID: String
    var title: String?
    var workingDirectory: String?
    var branch: String?
    /// The session read LokalBot's own library through its CLI or MCP.
    /// Its replies may restate library content, so they are withheld to
    /// keep the digest from consuming its own output.
    var consultedLokalBot = false
    var events: [CodingAgentEvent]
}

/// A contiguous run of agent work inside one session. A new burst starts
/// after the same idle gap the day digest uses to split segments, so a
/// session left open all day never merges the whole day into one item.
struct CodingAgentBurst: Equatable, Codable, Sendable {
    var agent: CodingAgentKind
    var sessionID: String
    var title: String
    var project: String
    var branch: String?
    var start: Date
    var end: Date
    var activeDuration: TimeInterval
    var prompts: [String]
    var promptCount: Int
    var finalReply: String?
    var changedFiles: [String]
    var changedFileCount: Int
    var actions: [CodingAgentAction]
    var pullRequests: [String]
    var toolCallCount: Int

    /// Stable within a day: bursts are keyed by session and first event.
    var id: String { "\(agent.rawValue):\(sessionID):\(Int(start.timeIntervalSince1970))" }

    /// A burst idle for the full inactivity gap can never grow again: any
    /// later event starts a new burst. Only settled bursts become evidence,
    /// so a saved digest's inputs cannot change underneath it.
    func isSettled(at now: Date) -> Bool {
        now.timeIntervalSince(end) >= CodingAgentBurstBuilder.inactivityGap
    }

    /// Every field the digest can read, in a fixed order, for evidence
    /// signatures that change exactly when the burst's content does.
    var signatureFields: [String] {
        [
            id, agent.rawValue, sessionID, title, project, branch ?? "",
            String(start.timeIntervalSince1970), String(end.timeIntervalSince1970),
            String(activeDuration), prompts.joined(separator: "\u{1e}"), String(promptCount),
            finalReply ?? "", changedFiles.joined(separator: "\u{1e}"), String(changedFileCount),
            actions.map(\.summary).joined(separator: "\u{1e}"),
            pullRequests.joined(separator: "\u{1e}"), String(toolCallCount),
        ]
    }

    /// Model-facing evidence in the same shape as the digest's other work
    /// sources: substantive content first, trace metadata last and labeled.
    func evidenceText(calendar: Calendar = .current, maxPrompts: Int = 4) -> String {
        var lines = [
            "WORK SOURCE: AGENT SESSION [agent:\(agent.rawValue):\(sessionID.prefix(8))]",
            "Agent: \(agent.displayName)",
            "Session: \(title)",
            "Project: \(project)" + (branch.map { " (branch \($0))" } ?? ""),
        ]
        if prompts.isEmpty {
            lines.append("Requests: continued work from an earlier request")
        } else {
            lines.append("Requests:")
            lines += prompts.prefix(maxPrompts).map { "- \($0)" }
            let remaining = promptCount - min(maxPrompts, prompts.count)
            if remaining > 0 { lines.append("- (+\(remaining) more)") }
        }
        if !changedFiles.isEmpty {
            let hidden = changedFileCount - changedFiles.count
            lines.append(
                "Changed files (\(changedFileCount)): " + changedFiles.joined(separator: ", ")
                    + (hidden > 0 ? ", +\(hidden) more" : ""))
        }
        if !actions.isEmpty {
            lines.append("Recorded actions: " + actions.map(\.summary).joined(separator: "; "))
        }
        if !pullRequests.isEmpty {
            lines.append("Pull requests: " + pullRequests.joined(separator: ", "))
        }
        if let finalReply {
            lines.append("Agent's final report (a claim; corroborate with actions): \(finalReply)")
        }
        lines.append(
            "LOW-PRIORITY TRACE METADATA — do not summarize directly:\n"
                + "\(Self.time(start, calendar))–\(Self.time(end, calendar)); "
                + "active=\(Int((activeDuration / 60).rounded()))m; tool_calls=\(toolCallCount)")
        return lines.joined(separator: "\n")
    }

    private static func time(_ date: Date, _ calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}

enum CodingAgentBurstBuilder {
    /// Matches `DayDigestEvidence.summarySegments(inactivityGap:)`.
    static let inactivityGap: TimeInterval = 10 * 60
    /// Longer gaps between events count as waiting, not active work.
    static let activeGapCap: TimeInterval = 5 * 60
    static let storedPrompts = 6
    static let storedFiles = 16

    static func bursts(
        from transcript: CodingAgentTranscript,
        inactivityGap: TimeInterval = inactivityGap
    ) -> [CodingAgentBurst] {
        let ordered = transcript.events.enumerated().sorted { lhs, rhs in
            lhs.element.at == rhs.element.at ? lhs.offset < rhs.offset : lhs.element.at < rhs.element.at
        }.map(\.element)
        var groups: [[CodingAgentEvent]] = []
        for event in ordered where !event.isAnnotation {
            if let last = groups.last?.last, event.at.timeIntervalSince(last.at) <= inactivityGap {
                groups[groups.count - 1].append(event)
            } else {
                groups.append([event])
            }
        }
        // Annotations join the burst that was active when they were written;
        // a link re-emitted while nothing else happened is dropped.
        for annotation in ordered where annotation.isAnnotation {
            guard let index = groups.lastIndex(where: { group in
                guard let first = group.first, let last = group.last else { return false }
                return annotation.at >= first.at
                    && annotation.at.timeIntervalSince(last.at) <= inactivityGap
            }) else { continue }
            groups[index].append(annotation)
        }

        let title = transcript.title.flatMap(Self.nonEmpty)
            ?? firstPrompt(in: ordered).map { CodingAgentText.truncated($0, maxCharacters: 80) }
            ?? "Untitled session"
        let project = projectName(for: transcript.workingDirectory)
        return groups.compactMap { group in
            burst(
                group, transcript: transcript, title: title, project: project)
        }
    }

    private static func burst(
        _ events: [CodingAgentEvent],
        transcript: CodingAgentTranscript,
        title: String,
        project: String
    ) -> CodingAgentBurst? {
        var prompts: [String] = [], promptCount = 0
        var reply: String?
        var files: [String] = [], seenFiles: Set<String> = []
        var actions: [CodingAgentAction] = []
        var pullRequests: [String] = []
        var toolCalls = 0
        for event in events {
            switch event.kind {
            case .prompt(let text):
                promptCount += 1
                if prompts.count < storedPrompts { prompts.append(text) }
            case .reply(let text):
                reply = text
            case .toolCall:
                toolCalls += 1
            case .fileChange(let path):
                if seenFiles.insert(path).inserted { files.append(path) }
            case .action(let action):
                if !actions.contains(action) { actions.append(action) }
            case .pullRequest(let url):
                if !pullRequests.contains(url) { pullRequests.append(url) }
            case .activity:
                break
            }
        }
        if transcript.consultedLokalBot { reply = nil }
        guard promptCount > 0 || reply != nil || !files.isEmpty || !actions.isEmpty else {
            return nil
        }
        let times = events.filter { !$0.isAnnotation }.map(\.at)
        guard let start = times.first, let end = times.last else { return nil }
        let active = zip(times, times.dropFirst()).reduce(0) { total, pair in
            total + min(pair.1.timeIntervalSince(pair.0), activeGapCap)
        }
        return CodingAgentBurst(
            agent: transcript.agent,
            sessionID: transcript.sessionID,
            title: title,
            project: project,
            branch: transcript.branch,
            start: start,
            end: end,
            activeDuration: active,
            prompts: prompts,
            promptCount: promptCount,
            finalReply: reply,
            changedFiles: Array(files.prefix(storedFiles)),
            changedFileCount: files.count,
            actions: actions,
            pullRequests: pullRequests,
            toolCallCount: toolCalls)
    }

    /// Drops timestamp-only events that change neither a burst boundary nor
    /// its active time. A ping is redundant when the events either side of it
    /// are within `activeGapCap` of each other: the gaps it splits count in
    /// full either way. Busy sessions log thousands of tool results, so this
    /// keeps cached transcripts small without changing any burst.
    static func compactingActivity(_ events: [CodingAgentEvent]) -> [CodingAgentEvent] {
        let annotations = events.filter(\.isAnnotation)
        let ordered = events.enumerated()
            .filter { !$0.element.isAnnotation }
            .sorted { lhs, rhs in
                lhs.element.at == rhs.element.at ? lhs.offset < rhs.offset : lhs.element.at < rhs.element.at
            }
            .map(\.element)
        guard ordered.count > 2 else { return ordered + annotations }
        var kept = [ordered[0]]
        for index in 1..<(ordered.count - 1) {
            let event = ordered[index]
            if case .activity = event.kind, let previous = kept.last,
               ordered[index + 1].at.timeIntervalSince(previous.at) <= activeGapCap {
                continue
            }
            kept.append(event)
        }
        kept.append(ordered[ordered.count - 1])
        return kept + annotations
    }

    /// The repository name, not the checkout folder: agent worktrees live
    /// under `<repo>/.claude/worktrees/<name>`.
    static func projectName(for workingDirectory: String?) -> String {
        guard let workingDirectory, !workingDirectory.isEmpty else { return "Unknown project" }
        let components = URL(fileURLWithPath: workingDirectory).standardizedFileURL.pathComponents
        if let marker = components.lastIndex(of: ".claude"), marker > 1,
           components.indices.contains(marker + 1), components[marker + 1] == "worktrees" {
            return components[marker - 1]
        }
        return components.last.flatMap(nonEmpty) ?? "Unknown project"
    }

    private static func firstPrompt(in events: [CodingAgentEvent]) -> String? {
        for event in events {
            if case .prompt(let text) = event.kind { return text }
        }
        return nil
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
