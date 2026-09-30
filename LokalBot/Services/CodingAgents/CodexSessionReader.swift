import Foundation

/// Reads Codex rollouts from `~/.codex/sessions/YYYY/MM/DD/*.jsonl` and
/// `~/.codex/archived_sessions/`.
///
/// A rollout stays in the folder of the day it started even when it is
/// resumed weeks later, so files are selected by modification date rather
/// than by folder. Subagent threads, including approval reviewers, are
/// skipped: their parent session reports the work. Titles come from
/// `session_index.jsonl`; credentials and the internal SQLite state are
/// never opened.
struct CodexSessionReader: CodingAgentSessionReader {
    var agent: CodingAgentKind { .codex }
    var root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex", isDirectory: true)) {
        self.root = root
    }

    /// Opening bytes of records that never carry evidence beyond their time.
    private static let timestampOnlyMarkers = [
        #""type":"function_call_output""#, #""type":"custom_tool_call_output""#,
        #""type":"reasoning""#, #""type":"token_count""#, #""type":"token_usage_record""#,
        #""item":{"type":"Reasoning""#, #""item":{"type":"AgentMessage""#,
        #""item":{"type":"UserMessage""#, #""item":{"type":"ImageView""#,
    ]

    func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
        var result = CodingAgentReadResult()
        let files = ["sessions", "archived_sessions"].flatMap { folder -> [URL] in
            let enumerator = FileManager.default.enumerator(
                at: root.appendingPathComponent(folder, isDirectory: true),
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles])
            return (enumerator?.allObjects as? [URL]) ?? []
        }
        let candidates = Self.candidateFiles(files, in: interval).sorted { $0.url.path < $1.url.path }
        for candidate in candidates {
            do {
                let lines = try CodingAgentJSONLines(contentsOf: candidate.url)
                result.filesRead += 1
                result.bytesRead += candidate.size
                if let transcript = parse(lines, interval: interval) {
                    result.transcripts.append(transcript)
                }
            } catch {
                result.unreadableFiles.append(candidate.url.path)
            }
        }
        if !result.transcripts.isEmpty {
            let titles = threadTitles()
            for index in result.transcripts.indices {
                result.transcripts[index].title = titles[result.transcripts[index].sessionID]
                    .flatMap(CodingAgentText.title)
            }
        }
        return result
    }

    func parse(_ lines: CodingAgentJSONLines, interval: DateInterval) -> CodingAgentTranscript? {
        var transcript = CodingAgentTranscript(agent: .codex, sessionID: "", events: [])
        var isSubagent = false
        lines.forEach { line in
            guard !isSubagent else { return }
            if Self.timestampOnlyMarkers.contains(where: { line.prefix(400, contains: $0) }) {
                if let at = CodingAgentTimestamp.date(line.stringValue(forKey: "timestamp")),
                   interval.contains(at) {
                    transcript.events.append(CodingAgentEvent(at: at, kind: .activity))
                }
                return
            }
            guard let record = line.object(),
                  let payload = record["payload"] as? [String: Any] else { return }
            if record["type"] as? String == "session_meta" {
                // A subagent's `source` is an object such as
                // {"subagent":{"other":"guardian"}}; people start "vscode"/"cli".
                if let source = payload["source"] as? [String: Any], source["subagent"] != nil {
                    isSubagent = true
                    return
                }
                transcript.sessionID = payload["id"] as? String ?? transcript.sessionID
                transcript.workingDirectory = payload["cwd"] as? String
                if let git = payload["git"] as? [String: Any],
                   let branch = git["branch"] as? String, !branch.isEmpty, branch != "HEAD" {
                    transcript.branch = branch
                }
                return
            }
            inspectForLokalBotAccess(record, payload: payload, transcript: &transcript)
            guard let at = CodingAgentTimestamp.date(record["timestamp"] as? String),
                  interval.contains(at) else { return }
            let before = transcript.events.count
            switch record["type"] as? String {
            case "response_item":
                appendResponseItem(payload, at: at, to: &transcript)
            case "event_msg":
                if payload["type"] as? String == "item_completed",
                   let item = payload["item"] as? [String: Any] {
                    appendCompletedItem(item, at: at, to: &transcript)
                }
            default:
                break
            }
            if transcript.events.count == before {
                transcript.events.append(CodingAgentEvent(at: at, kind: .activity))
            }
        }
        guard !isSubagent, !transcript.sessionID.isEmpty,
              transcript.events.contains(where: { !$0.isAnnotation }) else { return nil }
        return transcript
    }

    private func appendResponseItem(
        _ payload: [String: Any], at: Date, to transcript: inout CodingAgentTranscript
    ) {
        switch payload["type"] as? String {
        case "message":
            let role = payload["role"] as? String
            guard role == "user" || role == "assistant",
                  let content = payload["content"] as? [[String: Any]] else { return }
            // Codex sends injected instructions and context as separate
            // items of the same user message; each is judged on its own.
            let texts = content.compactMap { item -> String? in
                guard ["input_text", "output_text"].contains(item["type"] as? String ?? "") else {
                    return nil
                }
                return item["text"] as? String
            }
            if role == "user" {
                let prompts = texts.compactMap(CodingAgentText.prompt)
                if !prompts.isEmpty {
                    let joined = CodingAgentText.truncated(
                        prompts.joined(separator: " "), maxCharacters: CodingAgentText.promptCharacters)
                    transcript.events.append(CodingAgentEvent(at: at, kind: .prompt(joined)))
                }
            } else if let reply = CodingAgentText.reply(texts.joined(separator: "\n")) {
                transcript.events.append(CodingAgentEvent(at: at, kind: .reply(reply)))
            }
        case "function_call", "custom_tool_call":
            transcript.events.append(CodingAgentEvent(at: at, kind: .toolCall))
            let body = (payload["arguments"] ?? payload["input"]) as? String ?? ""
            for path in patchedFiles(in: body) {
                transcript.events.append(CodingAgentEvent(
                    at: at,
                    kind: .fileChange(CodingAgentText.displayPath(
                        path, workingDirectory: transcript.workingDirectory))))
            }
            if let command = shellCommand(inArguments: body) {
                for action in CodingAgentText.actions(inCommand: command) {
                    transcript.events.append(CodingAgentEvent(at: at, kind: .action(action)))
                }
            }
            for url in CodingAgentText.pullRequestURLs(in: body) {
                transcript.events.append(CodingAgentEvent(at: at, kind: .pullRequest(url)))
            }
        default:
            break
        }
    }

    private func appendCompletedItem(
        _ item: [String: Any], at: Date, to transcript: inout CodingAgentTranscript
    ) {
        switch item["type"] as? String {
        case "CommandExecution":
            // Only the command; `aggregated_output` and friends are never read.
            guard let command = item["command"] as? String else { return }
            for action in CodingAgentText.actions(inCommand: command) {
                transcript.events.append(CodingAgentEvent(at: at, kind: .action(action)))
            }
            for url in CodingAgentText.pullRequestURLs(in: command) {
                transcript.events.append(CodingAgentEvent(at: at, kind: .pullRequest(url)))
            }
        case "FileChange":
            // `changes` maps each path to its diff; only the keys are used.
            guard let changes = item["changes"] as? [String: Any] else { return }
            for path in changes.keys.sorted() {
                transcript.events.append(CodingAgentEvent(
                    at: at,
                    kind: .fileChange(CodingAgentText.displayPath(
                        path, workingDirectory: transcript.workingDirectory))))
            }
        default:
            break
        }
    }

    /// `apply_patch` names each file on a header line.
    private func patchedFiles(in body: String) -> [String] {
        guard body.contains("*** ") else { return [] }
        return body.components(separatedBy: "\n").compactMap { line in
            for header in ["*** Update File: ", "*** Add File: "] where line.hasPrefix(header) {
                return String(line.dropFirst(header.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    /// Shell tools pass JSON arguments with `cmd` (string) or `command`
    /// (string or argv).
    private func shellCommand(inArguments body: String) -> String? {
        guard body.hasPrefix("{"), let data = body.data(using: .utf8),
              let arguments = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        if let command = (arguments["cmd"] ?? arguments["command"]) as? String { return command }
        return (arguments["command"] as? [String])?.last
    }

    private func inspectForLokalBotAccess(
        _ record: [String: Any], payload: [String: Any], transcript: inout CodingAgentTranscript
    ) {
        guard !transcript.consultedLokalBot else { return }
        let item = payload["item"] as? [String: Any]
        let server = item?["server"] as? String ?? ""
        let name = payload["name"] as? String ?? ""
        let command = (item?["command"] as? String)
            ?? shellCommand(inArguments: (payload["arguments"] ?? payload["input"]) as? String ?? "")
            ?? ""
        if CodingAgentText.readsLokalBot(toolName: server)
            || CodingAgentText.readsLokalBot(toolName: name)
            || CodingAgentText.readsLokalBot(command: CodingAgentText.unwrappedShellCommand(command)) {
            transcript.consultedLokalBot = true
        }
    }

    /// Thread names by id; later lines are renames and win.
    private func threadTitles() -> [String: String] {
        let url = root.appendingPathComponent("session_index.jsonl")
        guard let lines = try? CodingAgentJSONLines(contentsOf: url) else { return [:] }
        var titles: [String: String] = [:]
        lines.forEach { line in
            guard let record = line.object(), let id = record["id"] as? String,
                  let name = record["thread_name"] as? String, !name.isEmpty else { return }
            titles[id] = name
        }
        return titles
    }
}
