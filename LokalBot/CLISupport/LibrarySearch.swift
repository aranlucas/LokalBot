import Foundation

enum LibraryInputPolicy {
    static let maximumMeetingCount = 1_000
    static let maximumSearchHits = 500
    static let maximumQueryCharacters = 4_096
    static let maximumQuestionCharacters = 16_384
}

/// Shared word search over on-disk meeting artifacts, so the CLI and MCP
/// expose one behavior without needing the app's index. A meeting matches
/// when it contains every query word, in any order and ignoring case and
/// accents; when none does, meetings with the most words follow. Hits with
/// the exact phrase lead, ties keep meeting recency, and a quoted query
/// matches only its exact phrase.
enum LibrarySearch {
    static let defaultLimit = 50
    /// One long meeting full of a common word must not fill every slot.
    static let maximumTranscriptHitsPerMeeting = 5

    private struct Candidate {
        var hit: SessionFormatter.SearchHit
        var meeting: Int
        var kind: Int
        var position: Int
        var matched: [String]
        var exact: Bool
    }

    static func hits(
        query: String,
        limit: Int = defaultLimit,
        meetings: [Meeting]? = nil,
        transcriptHitsPerMeeting: Int? = maximumTranscriptHitsPerMeeting
    ) throws -> [SessionFormatter.SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let quoted = trimmed.count > 2 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
        let phrase = folded(quoted ? String(trimmed.dropFirst().dropLast()) : trimmed)
        guard !phrase.isEmpty else { return [] }
        let terms = quoted ? [phrase] : searchTerms(phrase)
        let all = try meetings ?? SessionLookup.loadAllMeetings()

        var candidates: [Candidate] = []
        var coverage: [Int: Set<String>] = [:]
        func consider(_ text: String, meeting index: Int, kind: Int, position: Int,
                      hit: (String) -> SessionFormatter.SearchHit?) {
            let haystack = folded(text)
            let matched = terms.filter { haystack.contains($0) }
            guard let first = matched.first else { return }
            let exact = haystack.contains(phrase)
            guard let value = (exact ? hit(phrase) : nil) ?? hit(first) else { return }
            coverage[index, default: []].formUnion(matched)
            candidates.append(Candidate(hit: value, meeting: index, kind: kind, position: position,
                                        matched: matched, exact: exact))
        }

        for (index, meeting) in all.enumerated() {
            let short = SessionLookup.shortID(meeting.id)
            consider(meeting.title, meeting: index, kind: 0, position: 0) { _ in
                .init(meeting_id: short, meeting_title: meeting.title, match_kind: "title",
                      snippet: meeting.title, timestamp: nil)
            }
            if let summary = SessionLookup.summaryMarkdown(for: meeting) {
                consider(summary, meeting: index, kind: 1, position: 0) { needle in
                    snippet(in: summary, around: needle).map {
                        .init(meeting_id: short, meeting_title: meeting.title, match_kind: "summary",
                              snippet: $0, timestamp: nil)
                    }
                }
            }
            if let transcript = SessionLookup.transcript(for: meeting) {
                for (position, segment) in transcript.segments.enumerated() {
                    consider(segment.text, meeting: index, kind: 2, position: position) { _ in
                        .init(meeting_id: short, meeting_title: meeting.title, match_kind: "transcript",
                              snippet: segment.text, timestamp: Transcript.stamp(segment.start))
                    }
                }
            }
        }

        // A word found in few meetings says more than one found in most, so
        // "what did we decide about pricing" ranks by "pricing", not "we".
        var meetingsWithTerm: [String: Int] = [:]
        for words in coverage.values { for word in words { meetingsWithTerm[word, default: 0] += 1 } }
        let total = Double(max(1, all.count))
        func weight(_ words: [String]) -> Double {
            var sum = 0.0
            for word in words {
                let meetingsWithWord = Double(max(1, meetingsWithTerm[word] ?? 1))
                sum += log(1 + total / meetingsWithWord)
            }
            return sum
        }
        var meetingWeights: [Int: Double] = [:]
        for (meeting, words) in coverage { meetingWeights[meeting] = weight(Array(words)) }

        // Every word somewhere in the meeting wins; when no meeting has them
        // all, partial matches follow so a near miss is still found.
        let complete = Set(coverage.filter { $0.value.count == terms.count }.keys)
        var ranked: [(candidate: Candidate, score: Double)] = []
        for candidate in candidates where complete.isEmpty || complete.contains(candidate.meeting) {
            ranked.append((candidate, weight(candidate.matched)))
        }
        ranked.sort { lhs, rhs in
            if lhs.candidate.exact != rhs.candidate.exact { return lhs.candidate.exact }
            let left = meetingWeights[lhs.candidate.meeting] ?? 0
            let right = meetingWeights[rhs.candidate.meeting] ?? 0
            if left != right { return left > right }
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.candidate.meeting != rhs.candidate.meeting { return lhs.candidate.meeting < rhs.candidate.meeting }
            if lhs.candidate.kind != rhs.candidate.kind { return lhs.candidate.kind < rhs.candidate.kind }
            return lhs.candidate.position < rhs.candidate.position
        }

        var transcriptHits: [Int: Int] = [:]
        var hits: [SessionFormatter.SearchHit] = []
        for (candidate, _) in ranked where hits.count < limit {
            if candidate.kind == 2, let transcriptHitsPerMeeting {
                let count = transcriptHits[candidate.meeting, default: 0]
                guard count < transcriptHitsPerMeeting else { continue }
                transcriptHits[candidate.meeting] = count + 1
            }
            hits.append(candidate.hit)
        }
        return hits
    }

    /// Case- and accent-insensitive form used only for matching, never for
    /// display: "izvestaj" finds "izveštaj" and "CAFE" finds "café".
    static func folded(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Distinct words in query order. A run of CJK characters stays one word
    /// and still matches inside an unspaced sentence.
    static func searchTerms(_ foldedQuery: String) -> [String] {
        var seen = Set<String>()
        let words = foldedQuery.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        // A single Latin letter ("t" from "don't") matches nearly everything;
        // keep one only when it is the whole query.
        let meaningful = words.filter { $0.count > 1 || $0.unicodeScalars.contains { !$0.isASCII } }
        return meaningful.isEmpty ? words : meaningful
    }

    static func snippet(in haystack: String, around needle: String) -> String? {
        guard let range = haystack.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) else { return nil }
        let start = haystack.index(
            range.lowerBound,
            offsetBy: -40,
            limitedBy: haystack.startIndex) ?? haystack.startIndex
        let end = haystack.index(
            range.upperBound,
            offsetBy: 40,
            limitedBy: haystack.endIndex) ?? haystack.endIndex
        var snippet = String(haystack[start..<end])
        if start != haystack.startIndex { snippet = "…" + snippet }
        if end != haystack.endIndex { snippet += "…" }
        return snippet
    }
}
