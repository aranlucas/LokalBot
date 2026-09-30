import Foundation

/// What one reader found for a day. Unreadable files are reported, never
/// fatal: an agent update that changes its format must not stop the digest.
struct CodingAgentReadResult: Sendable {
    var transcripts: [CodingAgentTranscript] = []
    var filesRead = 0
    var bytesRead = 0
    var unreadableFiles: [String] = []
}

protocol CodingAgentSessionReader: Sendable {
    var agent: CodingAgentKind { get }
    /// Sessions with activity inside `interval`, their events clipped to it.
    func transcripts(in interval: DateInterval) -> CodingAgentReadResult
}

extension CodingAgentSessionReader {
    /// Transcript files that may hold activity inside `interval`: written
    /// since it began, and created before it ended. Skipping by metadata
    /// keeps multi-gigabyte archives out of every scan.
    static func candidateFiles(
        _ urls: [URL], in interval: DateInterval
    ) -> [(url: URL, created: Date, size: Int)] {
        urls.compactMap { url in
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: [
                      .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                  ]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= interval.start
            else { return nil }
            let created = values.creationDate ?? modified
            guard created < interval.end else { return nil }
            return (url, created, values.fileSize ?? 0)
        }
    }
}

/// Reads Claude Code sessions from `~/.claude/projects/<cwd-slug>/<id>.jsonl`.
///
/// Only user prompts, the agent's text replies, tool names and inputs for
/// file edits and shell commands, titles, and PR links are read. Tool
/// results are recognised from their opening bytes and contribute only a
/// timestamp. Subagent sidechains, meta records, and compaction summaries
/// are skipped.
struct ClaudeCodeSessionReader: CodingAgentSessionReader {
    var agent: CodingAgentKind { .claudeCode }
    var root: URL

    init(root: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)) {
        self.root = root
    }

    private static let editTools: Set<String> = ["Edit", "MultiEdit", "Write", "NotebookEdit"]

    func transcripts(in interval: DateInterval) -> CodingAgentReadResult {
        var result = CodingAgentReadResult()
        let projectFolders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        // Top level of each project folder only: subagent transcripts live
        // in per-session subfolders and are not the person's sessions.
        let files = projectFolders.flatMap { folder in
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [
                    .contentModificationDateKey, .creationDateKey, .fileSizeKey, .isRegularFileKey,
                ],
                options: [.skipsHiddenFiles])) ?? []
        }
        // A fork or resumed session copies earlier records under their
        // original ids. Reading older files first credits that history to
        // the session where it happened.
        let candidates = Self.candidateFiles(files, in: interval).sorted {
            $0.created == $1.created ? $0.url.path < $1.url.path : $0.created < $1.created
        }
        var seenRecords: Set<String> = []
        for candidate in candidates {
            do {
                let lines = try CodingAgentJSONLines(contentsOf: candidate.url)
                result.filesRead += 1
                result.bytesRead += candidate.size
                if let transcript = parse(
                    lines, sessionID: candidate.url.deletingPathExtension().lastPathComponent,
                    interval: interval, seenRecords: &seenRecords) {
                    result.transcripts.append(transcript)
                }
            } catch {
                result.unreadableFiles.append(candidate.url.path)
            }
        }
        return result
    }

    func parse(
        _ lines: CodingAgentJSONLines,
        sessionID: String,
        interval: DateInterval,
        seenRecords: inout Set<String>
    ) -> CodingAgentTranscript? {
        var transcript = CodingAgentTranscript(agent: .claudeCode, sessionID: sessionID, events: [])
        var titles: [String: String] = [:]
        var claimed: [String] = []

        func claim(_ id: String?) -> Bool {
            guard let id else { return true }
            guard !seenRecords.contains(id) else { return false }
            claimed.append(id)
            seenRecords.insert(id)
            return true
        }

        lines.forEach { line in
            // Tool results carry most of the bytes; read only their time.
            if line.prefix(768, contains: #""type":"tool_result""#) {
                guard !line.prefix(768, contains: #""isSidechain":true"#),
                      let at = CodingAgentTimestamp.date(line.stringValue(forKey: "timestamp")),
                      interval.contains(at),
                      claim(line.stringValue(forKey: "uuid")) else { return }
                transcript.events.append(CodingAgentEvent(at: at, kind: .activity))
                return
            }
            guard let record = line.object(), let type = record["type"] as? String else { return }
            switch type {
            case "custom-title":
                titles["custom"] = record["customTitle"] as? String
            case "agent-name":
                titles["agent"] = record["agentName"] as? String
            case "ai-title":
                titles["ai"] = record["aiTitle"] as? String
            case "summary":
                titles["summary"] = record["summary"] as? String
            case "pr-link":
                if let url = record["prUrl"] as? String,
                   let at = CodingAgentTimestamp.date(record["timestamp"] as? String),
                   interval.contains(at) {
                    transcript.events.append(CodingAgentEvent(at: at, kind: .pullRequest(url)))
                }
            case "user", "assistant":
                inspectForLokalBotAccess(record, transcript: &transcript)
                guard record["isSidechain"] as? Bool != true,
                      record["isMeta"] as? Bool != true,
                      record["isCompactSummary"] as? Bool != true,
                      let at = CodingAgentTimestamp.date(record["timestamp"] as? String),
                      interval.contains(at),
                      claim(record["uuid"] as? String) else { return }
                if transcript.workingDirectory == nil {
                    transcript.workingDirectory = record["cwd"] as? String
                }
                if let branch = record["gitBranch"] as? String, !branch.isEmpty, branch != "HEAD" {
                    transcript.branch = branch
                }
                let content = (record["message"] as? [String: Any])?["content"]
                if type == "user" {
                    appendPrompt(content, at: at, to: &transcript)
                } else {
                    appendAssistant(content, at: at, to: &transcript)
                }
            default:
                break
            }
        }

        transcript.title = ["custom", "agent", "ai", "summary"].lazy
            .compactMap { titles[$0].flatMap(CodingAgentText.title) }.first
        guard transcript.events.contains(where: { !$0.isAnnotation }) else {
            // Nothing of this session belongs to the day; release its ids so
            // a later file is not denied records it owns.
            seenRecords.subtract(claimed)
            return nil
        }
        return transcript
    }

    private func appendPrompt(_ content: Any?, at: Date, to transcript: inout CodingAgentTranscript) {
        let raw: String
        if let text = content as? String {
            raw = text
        } else if let blocks = content as? [[String: Any]] {
            raw = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                .joined(separator: "\n")
        } else {
            return
        }
        if let prompt = CodingAgentText.prompt(raw) {
            transcript.events.append(CodingAgentEvent(at: at, kind: .prompt(prompt)))
        } else {
            transcript.events.append(CodingAgentEvent(at: at, kind: .activity))
        }
        // A command the person ran in the agent's terminal mode is theirs,
        // and still work in this session.
        if let command = CodingAgentText.terminalCommand(in: raw) {
            for action in CodingAgentText.actions(inCommand: command) {
                transcript.events.append(CodingAgentEvent(at: at, kind: .action(action)))
            }
        }
    }

    private func appendAssistant(_ content: Any?, at: Date, to transcript: inout CodingAgentTranscript) {
        guard let blocks = content as? [[String: Any]] else { return }
        var appended = false
        for block in blocks {
            switch block["type"] as? String {
            case "text":
                if let text = block["text"] as? String, let reply = CodingAgentText.reply(text) {
                    transcript.events.append(CodingAgentEvent(at: at, kind: .reply(reply)))
                    appended = true
                }
            case "tool_use":
                appended = true
                transcript.events.append(CodingAgentEvent(at: at, kind: .toolCall))
                let name = block["name"] as? String ?? ""
                let input = block["input"] as? [String: Any] ?? [:]
                if Self.editTools.contains(name),
                   let path = (input["file_path"] ?? input["notebook_path"]) as? String {
                    transcript.events.append(CodingAgentEvent(
                        at: at,
                        kind: .fileChange(CodingAgentText.displayPath(
                            path, workingDirectory: transcript.workingDirectory))))
                } else if name == "Bash", let command = input["command"] as? String {
                    for action in CodingAgentText.actions(inCommand: command) {
                        transcript.events.append(CodingAgentEvent(at: at, kind: .action(action)))
                    }
                    for url in CodingAgentText.pullRequestURLs(in: command) {
                        transcript.events.append(CodingAgentEvent(at: at, kind: .pullRequest(url)))
                    }
                }
            default:
                break
            }
        }
        if !appended { transcript.events.append(CodingAgentEvent(at: at, kind: .activity)) }
    }

    /// Checked across the whole file, not just the day: text read from the
    /// library earlier can still be restated in today's replies.
    private func inspectForLokalBotAccess(_ record: [String: Any], transcript: inout CodingAgentTranscript) {
        guard !transcript.consultedLokalBot, record["type"] as? String == "assistant",
              let blocks = (record["message"] as? [String: Any])?["content"] as? [[String: Any]]
        else { return }
        for block in blocks where block["type"] as? String == "tool_use" {
            let name = block["name"] as? String ?? ""
            let command = (block["input"] as? [String: Any])?["command"] as? String ?? ""
            if CodingAgentText.readsLokalBot(toolName: name)
                || (name == "Bash" && CodingAgentText.readsLokalBot(command: command)) {
                transcript.consultedLokalBot = true
                return
            }
        }
    }
}
