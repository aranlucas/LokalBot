import Foundation
@testable import LokalBot

/// Fixed, synthetic inputs sent to real models by the recorder. Nothing here
/// comes from a real library; changing it invalidates committed recordings.
enum SyntheticModelPrompts {
    static let askQuestion = "What did we decide about the caching layer, and who owns the next step?"

    static func digestEvidence(calendar: Calendar) -> DayDigestEvidence {
        func time(_ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 8, day: 4, hour: hour, minute: minute))!
        }
        let blocks = [
            ActivityBlock(id: 1, app: "Xcode", title: "EvictionPolicy.swift", start: time(9), end: time(10, 30)),
            ActivityBlock(id: 2, app: "Google Chrome", title: "Pull request #42 - caching layer",
                          start: time(10, 30), end: time(11, 15)),
            ActivityBlock(id: 3, app: "Terminal", title: "load harness", start: time(14), end: time(15, 30)),
        ]
        let contexts = [
            DayScreenContext(snapshotID: 11, capturedAt: time(9, 20), app: "Xcode", windowTitle: "EvictionPolicy.swift",
                             text: "func evict(olderThan cutoff: Date) — LRU eviction for the Redis cache; tests: 12 passed"),
            DayScreenContext(snapshotID: 12, capturedAt: time(10, 45), app: "Google Chrome",
                             windowTitle: "Pull request #42 - caching layer",
                             text: "Review: approve after benchmarking failover latency. Merge blocked on cluster mode decision."),
            DayScreenContext(snapshotID: 13, capturedAt: time(14, 40), app: "Terminal", windowTitle: "load harness",
                             text: "failover p95 1.8s → 0.9s after connection pool change; benchmark complete"),
        ]
        return DayDigestEvidence.build(day: time(12), blocks: blocks, screenContexts: contexts,
                                       meetings: [], calendar: calendar)
    }

    static func standupTranscript() -> Transcript {
        let lines: [(TimeInterval, TimeInterval, String, String)] = [
            (0, 12, "me", "Let's lock the caching layer. I propose Redis for the pub-sub support."),
            (12, 26, "them", "Agreed on Redis. Open question: do we need cluster mode from day one?"),
            (26, 38, "me", "I'll draft the eviction-policy doc by Thursday."),
            (38, 52, "them", "Please benchmark failover latency before we commit to a cluster."),
            (52, 66, "me", "Fair. I'll borrow the load harness from the search team for that."),
        ]
        return Transcript(segments: lines.map {
            Transcript.Segment(start: $0.0, end: $0.1, speaker: $0.2, text: $0.3)
        }, engine: "synthetic")
    }
}
