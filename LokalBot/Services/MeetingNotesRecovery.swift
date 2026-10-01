import Foundation

extension MeetingNotesGenerator {
    struct Recovery: Codable {
        var nextPage = 0
        var scanComplete = false
        var records: [MeetingNotesEvidence.Record] = []
        var pending: [MeetingNotesEvidence.Rejection] = []
        var repairTokenFloor: Int?
        var terminalFailure: String?
        var noProgressAttempts: Int?
    }

    struct PartJob {
        var evidence: MeetingNotesEvidence
        var units: [MeetingNotesEvidence.Unit]
        var engine: TextEngine
        var template: NoteTemplate
        var language: SummaryLanguage
        var context: [String]
        var contextTokens: Int
        var meetingID: UUID
        var number: Int
        var remainingParts: Int
        var budget: MeetingGenerationBudget
    }

    /// At most three extraction pages and two repair calls per part in this
    /// attempt, plus two for records queued behind a task whose owner the
    /// repairs could not bind. Every call also consumes the shared job
    /// allowance. A restart resumes the ledger and pending repairs, including
    /// legacy checkpoints.
    static func generatePart(_ initial: Part, job: PartJob, save: (Part) throws -> Void) async throws {
        var part = initial
        var recovery = part.recovery ?? legacyRecovery(part, transcript: job.evidence.transcript)
        // Older checkpoints retained source-less rejections forever. Start one
        // fresh scan, preserving accepted evidence, instead of an impossible repair.
        let knownSources = Set(job.units.map(\.source))
        if recovery.pending.contains(where: { $0.sources.isEmpty }) {
            recovery.pending.removeAll { $0.sources.isEmpty }
            recovery.scanComplete = false
            recovery.nextPage = 0
            recovery.noProgressAttempts = nil
            // Pre-recovery builds persisted this source-less state as a
            // terminal provider failure. Clear that marker before the guard
            // below so the fresh scan can actually run.
            recovery.terminalFailure = nil
        }
        if let failure = recovery.terminalFailure { throw TextEngineError.badResponse(failure) }
        let minimum = job.engine.minimumStructuredOutputTokens
        func checkpoint() throws {
            part.recovery = recovery
            try save(part)
        }
        func accept(_ value: MeetingNotesEvidence.Validated) {
            part.claims = distinctClaims(part.claims + value.claims)
            let pendingIDs = Set(recovery.pending.compactMap(\.actionID))
            var held = part.outcomes.actionItems.filter { pendingIDs.contains($0.id) }
            var previous = part.outcomes
            previous.actionItems.removeAll { pendingIDs.contains($0.id) }
            let newPendingIDs = Set(value.rejected.compactMap(\.actionID))
            var incoming = value.outcomes
            incoming.actionItems.removeAll { newPendingIDs.contains($0.id) }
            func sameTask(_ lhs: MeetingOutcomes.ActionItem, _ rhs: MeetingOutcomes.ActionItem) -> Bool {
                OutcomeTextSimilarity.normalized(lhs.text) == OutcomeTextSimilarity.normalized(rhs.text)
                    && !Set(lhs.citations.map(\.segmentID)).isDisjoint(with: rhs.citations.map(\.segmentID))
            }
            // Keep pending IDs stable across extraction pages. Merging their
            // citations/text first would strand the repair's replacement ID.
            for action in incoming.actionItems {
                let replaced = Set(held.filter { sameTask($0, action) }.map(\.id))
                held.removeAll { replaced.contains($0.id) }
                recovery.pending.removeAll { $0.actionID.map { replaced.contains($0) } == true }
            }
            for rejection in value.rejected {
                guard let actionID = rejection.actionID,
                      let action = value.outcomes.actionItems.first(where: { $0.id == actionID }),
                      !held.contains(where: { sameTask($0, action) }) else { continue }
                held.append(action)
                recovery.pending.append(rejection)
            }
            part.outcomes = MeetingOutcomesGenerator.merge([previous, incoming])
            part.outcomes.actionItems += held
            var seen = Set(recovery.records.map(\.key))
            recovery.records += value.records.filter { seen.insert($0.key).inserted }
        }

        var extractionRecoveryRetryUsed = false
        var extractionRecoveryRetryPending = false
        for _ in 0..<3 where !recovery.scanComplete {
            try Task.checkCancellation()
            let allowance = try await job.budget.allowance(remainingParts: job.remainingParts, minimum: minimum)
            let maximumNotes = min(12, max(3, allowance / 200))
            let maximumActions = min(10, max(2, allowance / 350))
            let stage = recovery.nextPage == 0 ? "extract-\(job.number)" : "continue-\(job.number)-\(recovery.nextPage)"
            var userPrompt = prompt(units: job.units, roster: job.evidence.roster)
                + (recovery.nextPage == 0 ? "" : try continuation(recovery.records))
            if extractionRecoveryRetryPending {
                userPrompt += "\nThe previous extraction did not pass all source-link checks. Re-read only these supplied evidence rows. "
                    + "Return the exact top-level keys notes, actions, and has_more. Every note and action must "
                    + "copy one source ID from these rows and include all required fields. Omit an optional record "
                    + "rather than guessing or emitting a source-less object. If no grounded record remains, return "
                    + "empty arrays with has_more=false."
                extractionRecoveryRetryPending = false
            }
            let system = systemPrompt(template: job.template, language: job.language)
            try await requireInputRoom(system: system, prompt: userPrompt, context: job.context, tokens: allowance, job: job)
            let raw = try await request(engine: job.engine, system: system, prompt: userPrompt, context: job.context,
                schema: MeetingNotesEvidence.schema(units: job.units, speakers: Array(job.evidence.speakers.keys),
                    template: job.template, maximumNotes: maximumNotes, maximumActions: maximumActions),
                tokens: allowance, stage: stage, contextTokens: job.contextTokens, budget: job.budget)
            let started = ProcessInfo.processInfo.systemUptime
            var validated = job.evidence.validate(raw.content, units: job.units, template: job.template,
                meetingID: job.meetingID, maximumNotes: maximumNotes, maximumActions: maximumActions)
            let previousCount = recovery.records.count
            accept(validated)
            // An empty final page may finish a previously populated scan, but
            // empty output cannot certify a substantial untouched transcript.
            if part.claims.isEmpty && part.outcomes.isEmpty,
               job.units.reduce(0, { $0 + $1.text.split(whereSeparator: \.isWhitespace).count }) > 500 {
                validated.complete = false
            }
            // A malformed optional record may have no usable source at all
            // (for example an action omitted `source`). It cannot be repaired
            // without evidence, but it must not poison otherwise valid notes
            // or turn a provider-shape error into an evidence-ID failure. Keep
            // the rejection in validation telemetry and only queue source-bound
            // records for targeted repair.
            for rejection in validated.rejected
                where rejection.actionID == nil && !rejection.sources.isEmpty && !recovery.pending.contains(rejection) {
                recovery.pending.append(rejection)
            }
            // Some OpenAI-compatible providers occasionally return an
            // incomplete envelope or a source-less optional action even though
            // the request itself succeeded. One bounded, explicit re-read can
            // recover a useful summary; without it the no-progress guard would
            // turn a provider shape glitch into a failed meeting.
            let hasSourceLessShapeError = validated.rejected.contains {
                $0.sources.isEmpty && ["invalid_action", "invalid_note"].contains($0.reason)
            }
            if !extractionRecoveryRetryUsed,
               !raw.truncated,
               recovery.pending.isEmpty,
               !validated.complete,
               hasSourceLessShapeError {
                extractionRecoveryRetryUsed = true
                extractionRecoveryRetryPending = true
            }
            recovery.scanComplete = validated.complete && !raw.truncated
            recovery.nextPage += 1
            await recordValidation(validated, stage: stage, truncated: raw.truncated, budget: job.budget)
            try checkpoint()
            await job.budget.recordPhase("validation", seconds: ProcessInfo.processInfo.systemUptime - started)
            if validated.rejected.contains(where: {
                !$0.sources.isEmpty && knownSources.isDisjoint(with: $0.sources)
            }) {
                recovery.terminalFailure = "The summary provider returned missing or invalid evidence IDs. Source-linked partial notes were saved. Choose a different summary model or provider before retrying."
                try checkpoint()
                throw TextEngineError.badResponse(recovery.terminalFailure!)
            }
            // A provider repeating a full page must not spend the entire job
            // cycling. Keep its accepted facts and resume explicitly later.
            if recovery.records.count == previousCount && !recovery.scanComplete {
                if extractionRecoveryRetryPending {
                    try checkpoint()
                    continue
                }
                if !raw.truncated && recovery.pending.isEmpty {
                    recovery.noProgressAttempts = (recovery.noProgressAttempts ?? 0) + 1
                    if recovery.noProgressAttempts! >= 2 {
                        recovery.terminalFailure = "The summary provider made no further source-linked progress. Partial notes were saved. Choose a different summary model or provider before retrying."
                        try checkpoint()
                        throw TextEngineError.badResponse(recovery.terminalFailure!)
                    }
                }
                try checkpoint()
                break
            }
            recovery.noProgressAttempts = nil
        }

        let terminalReasons: Set<String> = ["unsupported_commitment", "conversation_management", "status_not_task", "empty_outcome"]
        recovery.pending.removeAll { terminalReasons.contains($0.reason) }
        queueMissingCommitments(part, job: job, recovery: &recovery)
        try checkpoint()

        // Ownership repairs run first. A task whose latest repair answered in
        // full but still could not bind it to one undertaking stays visible
        // as owner-unclear, like a wrong-owner claim: the same evidence fails
        // every retry, so holding the part open would fail the meeting each
        // time. Records queued behind ownership repairs then get their own
        // two repairs. The user's own commitments stay strict: a part missing
        // one stays open.
        let ownershipReasons: Set<String> = ["missing_ownership_evidence", "ambiguous_ownership_evidence", "ownership_quote_not_found"]
        for phase in 0..<2 {
            var answeredOwnership = Set<String>()
            var repairedOwnership = false
            var previousRepairTokens = 0
            for attempt in 0..<2 where !recovery.pending.isEmpty {
                let repairable = repairBatch(recovery.pending, units: job.units)
                guard !repairable.isEmpty else { break } // Never repair an invented source using unrelated evidence.
                let repairUnits = repairEvidence(repairable, units: job.units)
                let noteLimit = repairable.filter { $0.kind == "notes" }.count
                let actionLimit = repairable.filter { $0.kind == "actions" }.count
                let desired = min(4_096, max(minimum, recovery.repairTokenFloor ?? 0, attempt == 0
                    ? min(2_048, 512 + noteLimit * 128 + actionLimit * 384) : previousRepairTokens * 2))
                let repairTokens = try await job.budget.allowance(remainingParts: job.remainingParts, desired: desired, minimum: minimum)
                if attempt > 0, recovery.repairTokenFloor != nil, repairTokens <= previousRepairTokens { break }
                let userPrompt = try repairPrompt(repairable, units: repairUnits, roster: job.evidence.roster,
                    noteLimit: noteLimit, actionLimit: actionLimit)
                    + (attempt == 0 || repairable.first?.actionID != nil ? ""
                        : try continuation(recovery.records.filter { record in repairUnits.contains { $0.source == record.source } }))
                let system = PromptTemplates.meetingNotesRepairSystem(language: job.language)
                try await requireInputRoom(system: system, prompt: userPrompt, context: [], tokens: repairTokens, job: job)
                let stage = attempt == 0 ? "repair-\(job.number)" : "continue-repair-\(job.number)"
                let raw = try await request(engine: job.engine, system: system, prompt: userPrompt, context: [],
                    schema: MeetingNotesEvidence.schema(units: repairUnits, speakers: Array(job.evidence.speakers.keys),
                        template: job.template, maximumNotes: noteLimit, maximumActions: actionLimit,
                        actionTexts: repairable.allSatisfy { $0.actionID != nil } ? repairable.compactMap(\.text) : nil),
                    tokens: repairTokens, stage: stage, contextTokens: job.contextTokens, budget: job.budget)
                let started = ProcessInfo.processInfo.systemUptime
                let fixed = job.evidence.validate(raw.content, units: repairUnits, template: job.template,
                    meetingID: job.meetingID, maximumNotes: noteLimit, maximumActions: actionLimit)
                await recordValidation(fixed, stage: stage, truncated: raw.truncated, budget: job.budget)
                let repairSources = Set(repairUnits.map(\.source))
                if fixed.rejected.contains(where: { repairSources.isDisjoint(with: $0.sources) }) {
                    recovery.terminalFailure = "The summary provider returned missing or invalid evidence IDs during repair. Source-linked partial notes were saved. Choose a different summary model or provider before retrying."
                    try checkpoint()
                    throw TextEngineError.badResponse(recovery.terminalFailure!)
                }
                let ownershipRepair = repairable.first?.actionID != nil
                if ownershipRepair {
                    repairedOwnership = true
                    acceptOwnershipRepairs(fixed, requested: repairable, job: job, complete: fixed.complete && !raw.truncated,
                                           part: &part, recovery: &recovery)
                    // Ownership repairs keep each task's text fixed, so the text
                    // identifies the task across replacement IDs.
                    let texts = repairable.compactMap { $0.text.map(OutcomeTextSimilarity.normalized) }
                    if fixed.complete && !raw.truncated { answeredOwnership.formUnion(texts) } else { answeredOwnership.subtract(texts) }
                } else {
                    accept(fixed)
                }
                if fixed.complete && !raw.truncated {
                    // Unsupported records may be omitted after a complete repair;
                    // independently validated facts never depend on their survival.
                    if !ownershipRepair {
                        recovery.pending.removeAll { repairable.contains($0) }
                    }
                    recovery.repairTokenFloor = nil
                } else if raw.truncated {
                    recovery.repairTokenFloor = min(4_096, repairTokens * 2)
                }
                queueMissingCommitments(part, job: job, recovery: &recovery)
                previousRepairTokens = repairTokens
                try checkpoint()
                await job.budget.recordPhase("validation", seconds: ProcessInfo.processInfo.systemUptime - started)
                if raw.truncated && repairTokens >= 4_096 { break }
                if !fixed.complete && !raw.truncated && fixed.hasMore != true { break }
            }
            if missingCommitments(part, job: job).isEmpty {
                recovery.pending.removeAll { rejection in
                    guard let actionID = rejection.actionID, let text = rejection.text, ownershipReasons.contains(rejection.reason),
                          answeredOwnership.contains(OutcomeTextSimilarity.normalized(text)) else { return false }
                    return part.outcomes.actionItems.contains { $0.id == actionID && $0.ownershipIsUnclear }
                }
            }
            guard phase == 0, repairedOwnership, !recovery.pending.isEmpty,
                  !recovery.pending.contains(where: { $0.actionID != nil }) else { break }
            try checkpoint()
        }
        part.complete = recovery.scanComplete && recovery.pending.isEmpty && missingCommitments(part, job: job).isEmpty
        try checkpoint()
    }

    /// Ownership repairs keep each existing task's text fixed so
    /// a different promise from the same neighborhood cannot replace it. The
    /// unresolved task remains visible on failure, and replacement is atomic.
    private static func acceptOwnershipRepairs(
        _ fixed: MeetingNotesEvidence.Validated,
        requested: [MeetingNotesEvidence.Rejection], job: PartJob, complete: Bool,
        part: inout Part, recovery: inout Recovery
    ) {
        for request in requested {
            guard let actionID = request.actionID, let text = request.text,
                  let index = recovery.pending.firstIndex(of: request) else { continue }
            func matches(_ value: String?) -> Bool { value.map(OutcomeTextSimilarity.normalized) == OutcomeTextSimilarity.normalized(text) }
            let allowed = Set(repairEvidence([request], units: job.units).compactMap { job.evidence.transcript.summaryCitationSources[$0.source] })
            let actions = fixed.outcomes.actionItems.filter { matches($0.text) && $0.citations.allSatisfy { allowed.contains($0.segmentID) } }
            guard actions.count == 1, let action = actions.first else {
                // A grounded repair can discover that the alleged task was
                // negated, completed, or just conversation management.
                let terminal = fixed.rejected.contains { rejection in
                    matches(rejection.text) && !rejection.sources.isEmpty
                        && rejection.sources.allSatisfy { job.evidence.transcript.summaryCitationSources[$0].map { allowed.contains($0) } == true }
                        && ["unsupported_commitment", "conversation_management", "status_not_task"].contains(rejection.reason)
                }
                if complete && terminal {
                    part.outcomes.actionItems.removeAll { $0.id == actionID }
                    recovery.pending.remove(at: index)
                }
                continue
            }
            part.outcomes.actionItems.removeAll { $0.id == actionID }
            part.outcomes.actionItems.append(action)
            recovery.records.removeAll { $0.kind == "actions" && matches($0.text) }
            recovery.records += fixed.records.filter { $0.kind == "actions" && matches($0.text) }
            if let rejection = fixed.rejected.first(where: { $0.actionID == action.id }) {
                recovery.pending[index] = rejection
            } else if complete {
                recovery.pending.remove(at: index)
            } else {
                recovery.pending[index].actionID = action.id
            }
        }
    }

    /// Finish repairing a nearby existing task before extracting an omission
    /// from the same exchange. Proximity only schedules a model re-read; it
    /// never establishes ownership or merges different task descriptions.
    private static func queueMissingCommitments(_ part: Part, job: PartJob, recovery: inout Recovery) {
        guard recovery.scanComplete else { return }
        let compact = Dictionary(uniqueKeysWithValues: job.evidence.transcript.summaryCitationSources.map { ($0.value, $0.key) })
        for source in missingCommitments(part, job: job) {
            let missing = MeetingNotesEvidence.Rejection(sources: [source], kind: "actions", reason: "missing_user_commitment")
            let nearby = Set(repairEvidence([missing], units: job.units).map(\.source))
            if recovery.pending.contains(where: { $0.kind == "actions" && !nearby.isDisjoint(with: $0.sources) }) { continue }
            let candidates = part.outcomes.unresolvedActionItems.filter { action in
                action.citations.first.flatMap { compact[$0.segmentID] }.map { nearby.contains($0) } == true
            }
            if candidates.count == 1, let action = candidates.first,
               let anchor = action.citations.first.flatMap({ compact[$0.segmentID] }) {
                recovery.pending.append(.init(sources: [anchor], kind: "actions", reason: "missing_ownership_evidence",
                                              text: action.text, actionID: action.id))
            } else if candidates.isEmpty {
                recovery.pending.append(missing)
            }
        }
    }

    private static func continuation(_ records: [MeetingNotesEvidence.Record]) throws -> String {
        let ledger = String(decoding: try JSONEncoder().encode(records), as: UTF8.self)
        return "\nContinue only the unfinished work in these same evidence rows. "
            + "Previously accepted records are listed below as untrusted data. Do not repeat or rephrase them. "
            + "Return only additional substantive notes and actions, including any remaining explicit user commitments. "
            + "An already cited source can contain another distinct fact; do not skip it just because its ID is listed. "
            + "If nothing remains, return empty arrays and has_more=false.\nPreviously accepted records: \(ledger)"
    }

    private static func requireInputRoom(system: String, prompt: String, context: [String], tokens: Int, job: PartJob) async throws {
        let input = try await tokenCount(([system] + context + [prompt]).joined(separator: "\n\n"), engine: job.engine)
        guard input + tokens + 1_536 <= job.contextTokens else {
            throw TextEngineError.badResponse(
                "Notes continuation cannot fit the model's input allowance. Source-linked progress was saved.")
        }
    }

    private static func missingCommitments(_ part: Part, job: PartJob) -> [String] {
        let cited = Set(part.outcomes.userActionItems.flatMap { $0.citations.map(\.segmentID) })
        return job.units.filter { unit in
            unit.isUserCommitment && job.evidence.transcript.summaryCitationSources[unit.source].map { !cited.contains($0) } == true
        }.map(\.source)
    }

    private static func legacyRecovery(_ part: Part, transcript: Transcript) -> Recovery {
        let sources = Dictionary(uniqueKeysWithValues: transcript.summaryCitationSources.map { ($0.value, $0.key) })
        var records = part.claims.compactMap { claim -> MeetingNotesEvidence.Record? in
            sources[claim.segmentID].map { .init(kind: "notes", source: $0, text: claim.text) }
        }
        records += part.outcomes.actionItems.compactMap { action in
            action.citations.first.flatMap { sources[$0.segmentID] }.map { .init(kind: "actions", source: $0, text: action.text) }
        }
        return Recovery(nextPage: records.isEmpty ? 0 : 1, records: records)
    }

    private static func repairBatch(_ rejected: [MeetingNotesEvidence.Rejection], units: [MeetingNotesEvidence.Unit]) -> [MeetingNotesEvidence.Rejection] {
        let sources = Set(units.map(\.source))
        let known = rejected.filter { !sources.isDisjoint(with: $0.sources) }
        let ownership = known.filter { $0.actionID != nil }
        if !ownership.isEmpty { return Array(ownership.prefix(10)) }
        return Array(known.filter { $0.kind == "notes" }.prefix(12)) + Array(known.filter { $0.kind == "actions" }.prefix(10))
    }

    private static func repairEvidence(_ rejected: [MeetingNotesEvidence.Rejection], units: [MeetingNotesEvidence.Unit]) -> [MeetingNotesEvidence.Unit] {
        let sources = Set(rejected.flatMap(\.sources))
        let actionSources = Set(rejected.filter { $0.kind == "actions" }.flatMap(\.sources))
        let indices = Set(units.indices.filter { sources.contains(units[$0].source) }.flatMap { index in
            let radius = actionSources.contains(units[index].source) ? 8 : 2
            return max(0, index - radius)...min(units.count - 1, index + radius)
        })
        return units.indices.filter { indices.contains($0) }.map { units[$0] }
    }

    private static func repairPrompt(_ rejected: [MeetingNotesEvidence.Rejection], units: [MeetingNotesEvidence.Unit],
                                     roster: String, noteLimit: Int, actionLimit: Int) throws -> String {
        let sources = Set(units.map(\.source))
        let feedback = rejected.map { rejection -> [String: String] in
            var value = ["kind": rejection.kind, "reason": rejection.reason,
                         "sources": rejection.sources.filter { sources.contains($0) }.joined(separator: ", ")]
            if let text = rejection.text { value["text"] = String(text.prefix(280)) }
            return value
        }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: feedback), as: UTF8.self)
        return "This is a targeted repair. Repair at most \(noteLimit) notes and \(actionLimit) actions from the rejected sources. "
            + "Return empty arrays for unrequested kinds. Do not add a TL;DR or unrelated facts from neighboring context. "
            + "Previously accepted source-linked records are retained. Omit unsupported records. "
            + "For missing_user_commitment, extract the user's undertaking and its nearest relevant task context. "
            + "For distant_action_context, cite only sources within eight segments of the primary source. "
            + "For missing_ownership_evidence, ambiguous_ownership_evidence, or ownership_quote_not_found, "
            + "repair only the action in feedback.text and copy that task text unchanged. Select a verbatim quote "
            + "for that task and its actual source; never substitute another person's task from the neighborhood. "
            + "has_more refers only to these requested repairs.\nValidation feedback: \(json)\n"
            + prompt(units: units, roster: roster)
    }
}
