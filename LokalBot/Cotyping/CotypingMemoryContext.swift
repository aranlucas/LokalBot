import Foundation

/// Small, relevant facts from explicitly enabled saved sources. This is a
/// retrieval policy, not a second language-model call or a persistent profile.
enum CotypingMemoryContext {
    struct Policy: Equatable, Sendable {
        var meetings: Bool
        var screenDerived: Bool
        var workMemory: Bool = true

        init(meetings: Bool, screenDerived: Bool, workMemory: Bool = true) {
            self.meetings = meetings
            self.screenDerived = screenDerived
            self.workMemory = workMemory
        }

        init(settings: AppSettings) {
            meetings = settings.cotypingUseMeetingMemory
            screenDerived = settings.cotypingUseScreenMemory
            workMemory = settings.dreamingEnabled
        }

        var enabled: Bool { meetings || (screenDerived && workMemory) }

        func permits(_ item: Item) -> Bool {
            (!item.requiresMeetings || meetings) && (!item.requiresScreenMemory || screenDerived)
                && (!item.isWorkMemory || workMemory)
                && (item.requiresMeetings || item.requiresScreenMemory)
        }
    }

    struct Item: Codable, Equatable, Sendable {
        var id: String
        var title: String
        var text: String
        var updatedAt: Date
        var requiresMeetings: Bool
        var requiresScreenMemory: Bool = false
        var isWorkMemory: Bool = false
    }

    struct Selection: Equatable, Sendable {
        var items: [Item] = []
        var text: String? {
            items.isEmpty ? nil : items.map(\.text).joined(separator: "\n")
        }
        var sourceTitles: [String] { Array(Set(items.map(\.title))).sorted() }
    }

    static let maxItems = 2
    static let maxItemCharacters = 180
    static let maxAge: TimeInterval = 90 * 24 * 60 * 60
    // Generic writing/meeting language must not pull an unrelated private fact
    // into a draft merely because both contain "project", "owner" or "today".
    private static let genericTerms: Set<String> = [
        "please", "thanks", "thank", "hello", "dear", "hi", "team", "notes", "note", "meeting", "meetings",
        "project", "update", "status", "owner", "deadline", "decision", "decisions", "action", "next", "today",
        "tomorrow", "yesterday", "week", "month", "year", "send", "write", "writing", "message", "email",
        "review", "follow", "following", "need", "want", "just", "quick", "new", "work", "working", "plan",
        "planning", "discuss", "discussed", "subject", "topic", "draft", "check", "regarding", "due", "name",
    ]

    static func terms(_ text: String) -> Set<String> {
        Set(LibrarySearch.searchTerms(LibrarySearch.folded(text)).filter {
            $0.count >= 3 && !SearchIndex.stopWords.contains($0) && !genericTerms.contains($0)
        })
    }

    static func query(for field: CotypingField, includeTitle: Bool, includeVisibleContext: Bool = true) -> String {
        guard !field.isSecure, field.selectionLength == 0,
              ![CotypingSurfaceClass.codeEditor, .terminal].contains(
                CotypingSurfaceClassifier.classify(bundleID: field.bundleID,
                                                   isIntegratedTerminal: field.isIntegratedTerminal)) else { return "" }
        let prefix = String(field.precedingText.suffix(500))
        // Only the already-authorized, spatially selected live excerpts can add
        // search terms. This connects a short reply to a project named above it.
        let visible = includeVisibleContext ? (field.visibleContext?.text.map { " " + $0 } ?? "") : ""
        let text = prefix + (includeTitle ? " " + (field.windowTitle ?? "") : "") + visible
        guard ScreenContextPrivacy.redact(text).count == 0 else { return "" }
        return terms(text).sorted().prefix(12).joined(separator: " ")
    }

    static func select(items: [Item], for field: CotypingField, includeTitle: Bool,
                       policy: Policy, now: Date = Date(), allowBodyMatch: Bool = true) -> Selection {
        select(items: items, query: query(for: field, includeTitle: includeTitle),
               contentQuery: allowBodyMatch ? query(for: field, includeTitle: includeTitle, includeVisibleContext: false) : "",
               policy: policy, now: now)
    }

    static func select(items: [Item], query: String, contentQuery: String? = nil,
                       policy: Policy, now: Date = Date()) -> Selection {
        let queryTerms = terms(query)
        // Visible conversation can identify a saved topic by its title, but its
        // incidental vocabulary must not qualify another project's body text.
        // Keep body-overlap retrieval available for the user's own draft/title.
        let contentTerms = terms(contentQuery ?? query)
        guard policy.enabled, !queryTerms.isEmpty else { return Selection() }
        var ranked: [(Item, Int, Bool)] = []
        for item in items where policy.permits(item) {
            guard now.timeIntervalSince(item.updatedAt) >= -60,
                  now.timeIntervalSince(item.updatedAt) <= maxAge,
                  let text = sanitized(item.text), let title = sanitized(item.title) else { continue }
            let titleMatches = terms(title).intersection(queryTerms).count
            let contentMatches = terms(text).intersection(contentTerms).count
            guard titleMatches > 0 || contentMatches >= 2 else { continue }
            // Prefer short facts; keep the prompt budget independent of source size.
            var selected = item
            selected.text = PromptContextSanitizer.sanitize(text, maxCharacters: maxItemCharacters)
            selected.title = String(title.prefix(80))
            ranked.append((selected, titleMatches * 3 + contentMatches, titleMatches > 0))
        }
        // If a named topic is recognized, generic sentence overlap in another
        // project's facts must not add a second, conflicting name or deadline.
        if ranked.contains(where: { $0.2 }) { ranked.removeAll { !$0.2 } }
        ranked.sort {
            if $0.1 != $1.1 { return $0.1 > $1.1 }
            if $0.0.updatedAt != $1.0.updatedAt { return $0.0.updatedAt > $1.0.updatedAt }
            return $0.0.id < $1.0.id
        }
        // An older version of the same named topic must not contradict the
        // current one. Multiple snippets from the current source remain useful.
        let newest = Dictionary(grouping: ranked.map(\.0), by: { LibrarySearch.folded($0.title) })
            .mapValues { $0.map(\.updatedAt).max() ?? Date.distantPast }
        var seen = Set<String>()
        return Selection(items: ranked.compactMap { item, _, _ in
            guard item.updatedAt == newest[LibrarySearch.folded(item.title)] else { return nil }
            return seen.insert(LibrarySearch.folded(item.text)).inserted ? item : nil
        }.prefix(maxItems).map { $0 })
    }

    static func sanitized(_ text: String) -> String? {
        guard !text.isEmpty, ScreenContextPrivacy.redact(text).count == 0 else { return nil }
        let lower = text.lowercased()
        guard !["<|", "[inst]", "[system]", "ignore previous", "ignore all previous", "system prompt",
                "assistant:", "system:", "developer:", "previously accepted completion:"].contains(where: lower.contains)
        else { return nil }
        let cleaned = PromptContextSanitizer.sanitize(text)
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return cleaned.isEmpty ? nil : cleaned
    }
}
