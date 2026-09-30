import Foundation

/// Coding-agent work for one local day, ready to join the day's evidence.
struct CodingAgentDayScan: Sendable {
    var interval: DateInterval
    var bursts: [CodingAgentBurst]
    var sessionCount: Int
    var filesRead: Int
    var bytesRead: Int
    var unreadableFiles: [String]
    var excludedSessions: Int

    var evidenceCharacters: Int { bursts.reduce(0) { $0 + $1.evidenceText().count } }
}

/// Collects bursts from every enabled agent for a day and applies the
/// person's project-folder exclusions before anything leaves the reader.
struct CodingAgentSessionScanner: Sendable {
    var readers: [any CodingAgentSessionReader]
    /// Sessions whose working directory is inside one of these folders are
    /// dropped, for repositories whose work must never enter the library.
    var excludedFolders: [String] = []

    static func standard(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        agents: Set<CodingAgentKind> = Set(CodingAgentKind.allCases),
        excludedFolders: [String] = []
    ) -> CodingAgentSessionScanner {
        let readers: [any CodingAgentSessionReader] = CodingAgentKind.allCases
            .filter(agents.contains)
            .map { agent in
                switch agent {
                case .claudeCode:
                    ClaudeCodeSessionReader(
                        root: home.appendingPathComponent(".claude/projects", isDirectory: true))
                case .codex:
                    CodexSessionReader(root: home.appendingPathComponent(".codex", isDirectory: true))
                }
            }
        return CodingAgentSessionScanner(readers: readers, excludedFolders: excludedFolders)
    }

    func scan(day: Date, calendar: Calendar = .current) -> CodingAgentDayScan {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let interval = DateInterval(start: start, end: end)
        var scan = CodingAgentDayScan(
            interval: interval, bursts: [], sessionCount: 0, filesRead: 0, bytesRead: 0,
            unreadableFiles: [], excludedSessions: 0)
        for reader in readers {
            let result = reader.transcripts(in: interval)
            scan.filesRead += result.filesRead
            scan.bytesRead += result.bytesRead
            scan.unreadableFiles += result.unreadableFiles
            for transcript in result.transcripts {
                guard !isExcluded(transcript.workingDirectory) else {
                    scan.excludedSessions += 1
                    continue
                }
                let bursts = CodingAgentBurstBuilder.bursts(from: transcript)
                guard !bursts.isEmpty else { continue }
                scan.sessionCount += 1
                scan.bursts += bursts
            }
        }
        scan.bursts.sort { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            return lhs.id < rhs.id
        }
        return scan
    }

    func isExcluded(_ workingDirectory: String?) -> Bool {
        guard let workingDirectory else { return false }
        let path = (workingDirectory as NSString).standardizingPath
        return excludedFolders.contains { rule in
            let folder = ((rule.trimmingCharacters(in: .whitespacesAndNewlines) as NSString)
                .expandingTildeInPath as NSString).standardizingPath
            guard !folder.isEmpty, folder != "/" else { return false }
            return path == folder || path.hasPrefix(folder + "/")
        }
    }
}
