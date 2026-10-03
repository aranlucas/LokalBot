import Foundation

/// How autocomplete behaved while typing in one kind of app. Counts and
/// timings only: no text, app name or window title is kept.
struct CotypingLiveMeasure: Codable, Equatable, Sendable {
    /// Suggestions that became visible after a keystroke.
    var shown = 0
    /// Rolling window of the time from the last keystroke to a visible
    /// suggestion, newest last. Unlike generation latency this includes the
    /// wait for the app to publish the keystroke, the pause before
    /// suggesting, context lookup and validation.
    var visibleLatenciesMs: [Int] = []
    /// Accept keypresses that inserted text.
    var accepts = 0
    /// Accepts after which the field held the inserted text.
    var insertionsConfirmed = 0
    /// Accepts after which the field held something else.
    var insertionsMismatched = 0
    /// Accepts whose result the app never published in time to check.
    var insertionsUnconfirmed = 0
    /// Accepts followed at once by a deletion or an undo.
    var acceptsCorrected = 0

    static let maxLatencies = 50

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func count(_ key: CodingKeys) throws -> Int {
            try container.decodeIfPresent(Int.self, forKey: key) ?? 0
        }
        shown = try count(.shown)
        visibleLatenciesMs = try container.decodeIfPresent([Int].self, forKey: .visibleLatenciesMs) ?? []
        accepts = try count(.accepts)
        insertionsConfirmed = try count(.insertionsConfirmed)
        insertionsMismatched = try count(.insertionsMismatched)
        insertionsUnconfirmed = try count(.insertionsUnconfirmed)
        acceptsCorrected = try count(.acceptsCorrected)
    }

    var isEmpty: Bool { self == CotypingLiveMeasure() }
    var medianVisibleMs: Int? { Self.percentile(visibleLatenciesMs, 0.5) }
    var p95VisibleMs: Int? { Self.percentile(visibleLatenciesMs, 0.95) }
    /// Insertions with a known outcome; unconfirmed ones say nothing either way.
    var insertionsChecked: Int { insertionsConfirmed + insertionsMismatched }

    mutating func recordShown(latencyMs: Int) {
        shown += 1
        visibleLatenciesMs.append(max(0, latencyMs))
        if visibleLatenciesMs.count > Self.maxLatencies {
            visibleLatenciesMs.removeFirst(visibleLatenciesMs.count - Self.maxLatencies)
        }
    }

    mutating func record(_ outcome: CotypingInsertionCheck.Outcome) {
        switch outcome {
        case .confirmed: insertionsConfirmed += 1
        case .mismatched: insertionsMismatched += 1
        case .unconfirmed: insertionsUnconfirmed += 1
        case .pending: break
        }
    }

    mutating func merge(_ other: CotypingLiveMeasure) {
        shown += other.shown
        visibleLatenciesMs += other.visibleLatenciesMs
        accepts += other.accepts
        insertionsConfirmed += other.insertionsConfirmed
        insertionsMismatched += other.insertionsMismatched
        insertionsUnconfirmed += other.insertionsUnconfirmed
        acceptsCorrected += other.acceptsCorrected
    }

    /// Nearest-rank percentile, matching `CotypingStats`.
    static func percentile(_ samples: [Int], _ p: Double) -> Int? {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let index = max(0, min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}

/// Whether an accepted suggestion really arrived in the host field. The accept
/// tap only posts the keystrokes; this compares what the app publishes
/// afterwards with what was sent.
struct CotypingInsertionCheck: Equatable, Sendable {
    enum Outcome: Equatable, Sendable {
        /// The app has not published the change yet.
        case pending
        /// The field holds the text before the caret followed by the insertion.
        case confirmed
        /// The field changed, but not to the inserted text.
        case mismatched
        /// The field never published a change, or focus left before it did.
        case unconfirmed
    }

    static let timeoutMilliseconds = 1_500
    private static let tailLength = 48

    /// The end of the text before the caret when the first accept was sent.
    let tail: String
    private(set) var inserted: String
    /// Accepts this check stands for. A second accept sent before the app
    /// published the first is checked together with it.
    private(set) var count = 1
    let surface: String
    let processID: pid_t
    let role: String
    private(set) var startedUptimeNanoseconds: UInt64

    init(field: CotypingField, inserted: String, surface: String, startedUptimeNanoseconds: UInt64) {
        tail = Self.normalized(String(field.precedingText.suffix(Self.tailLength)))
        self.inserted = Self.normalized(inserted)
        self.surface = surface
        processID = field.processID
        role = field.role
        self.startedUptimeNanoseconds = startedUptimeNanoseconds
    }

    /// Adds an accept that was sent while this one was still unpublished.
    mutating func extend(byInserting text: String, at uptimeNanoseconds: UInt64) {
        inserted += Self.normalized(text)
        count += 1
        startedUptimeNanoseconds = uptimeNanoseconds
    }

    /// `live` is the focused field now, or nil when nothing editable has focus.
    func outcome(live: CotypingField?, elapsedMilliseconds: Int) -> Outcome {
        let timedOut = elapsedMilliseconds >= Self.timeoutMilliseconds
        guard let live, live.processID == processID, live.role == role else {
            return timedOut ? .unconfirmed : .pending
        }
        let text = Self.normalized(live.precedingText)
        // Typing may already have continued past the insertion.
        let window = String(text.suffix(tail.count + inserted.count + 64))
        if window.contains(tail + inserted) { return .confirmed }
        // The insertion arrived and was edited before it could be read back.
        // Between two accepts checked together, a partial text only means the
        // second has not been published yet.
        if count == 1, !tail.isEmpty, let before = window.range(of: tail, options: .backwards) {
            let after = window[before.upperBound...]
            if after.count * 2 >= inserted.count, inserted.hasPrefix(after) { return .confirmed }
        }
        guard timedOut else { return .pending }
        // Unchanged text means the app published nothing; anything else means
        // the insertion landed wrongly.
        return text.hasSuffix(tail) ? .unconfirmed : .mismatched
    }

    /// Browsers publish a trailing space as a non-breaking space. That is not
    /// a visible difference, so it is not counted as one.
    private static func normalized(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ")
    }
}

extension CotypingSurfaceClass {
    /// Name used in the typing measurements.
    var measureTitle: String {
        switch self {
        case .other: "Native apps"
        case .browser: "Browsers"
        case .chat: "Chat"
        case .email: "Email"
        case .codeEditor: "Code editors"
        case .terminal: "Terminals"
        }
    }

    /// Order in which surfaces are listed.
    static let measured: [CotypingSurfaceClass] = [.other, .browser, .chat, .email, .codeEditor, .terminal]
}

extension CotypingStats {
    /// All surfaces together.
    var liveTotal: CotypingLiveMeasure {
        var total = CotypingLiveMeasure()
        for measure in live.values { total.merge(measure) }
        return total
    }

    /// The recorded surfaces in display order.
    var liveRows: [(title: String, measure: CotypingLiveMeasure)] {
        var rows: [(title: String, measure: CotypingLiveMeasure)] = []
        for surface in CotypingSurfaceClass.measured {
            if let measure = live[surface.rawValue], !measure.isEmpty {
                rows.append((surface.measureTitle, measure))
            }
        }
        return rows
    }

    /// A plain-text table for comparing runs, for example the same typing
    /// with two models. Holds counts and timings only.
    func report(model: String) -> String {
        var lines = ["Autocomplete typing measurements (\(model))"]
        let generation = medianLatencyMs.map { " · generation median \($0) ms, p95 \(p95LatencyMs ?? $0) ms" } ?? ""
        lines.append("Suggested \(generations) · accepted \(accepts)\(generation)")
        lines.append("")
        lines.append("| Surface | Shown | Keystroke to visible (median / p95) | Accepted | Insertions confirmed / wrong / unconfirmed | Corrected right after |")
        lines.append("| --- | ---: | ---: | ---: | ---: | ---: |")
        var rows = liveRows
        if rows.count > 1 { rows.append(("All", liveTotal)) }
        for row in rows {
            let measure = row.measure
            let timing = measure.medianVisibleMs.map { "\($0) / \(measure.p95VisibleMs ?? $0) ms" } ?? "n/a"
            let insertions = "\(measure.insertionsConfirmed) / \(measure.insertionsMismatched) / \(measure.insertionsUnconfirmed)"
            lines.append("| \(row.title) | \(measure.shown) | \(timing) | \(measure.accepts) | \(insertions) | \(measure.acceptsCorrected) |")
        }
        if rows.isEmpty { lines.append("| No typing measured yet | 0 | n/a | 0 | 0 / 0 / 0 | 0 |") }
        return lines.joined(separator: "\n")
    }
}
