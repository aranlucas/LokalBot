import Foundation

/// The newest saved-memory lookup for one field. A keystroke never waits for
/// a lookup: it takes the newest finished one, and a new lookup runs only when
/// the field or the finished words before the caret change what could match.
struct CotypingMemoryLookup {
    struct Ticket: Equatable {
        let anchor: String
        let query: CotypingMemoryContext.Query
    }

    private(set) var snapshot = CotypingMemoryContextProvider.Snapshot.empty
    private var anchor: String?
    private var requested: CotypingMemoryContext.Query?
    var task: Task<Void, Never>?

    func needsLookup(anchor: String, query: CotypingMemoryContext.Query) -> Bool {
        anchor != self.anchor || query != requested
    }

    /// Starts a lookup, replacing one still running. A different field
    /// forgets the previous field's facts at once.
    mutating func begin(anchor: String, query: CotypingMemoryContext.Query) -> Ticket {
        task?.cancel()
        task = nil
        if anchor != self.anchor { snapshot = .empty }
        self.anchor = anchor
        requested = query
        return Ticket(anchor: anchor, query: query)
    }

    /// Keeps a finished lookup only if it is still the one asked for last.
    mutating func finish(_ ticket: Ticket, with result: CotypingMemoryContextProvider.Snapshot) {
        guard ticket.anchor == anchor, ticket.query == requested else { return }
        snapshot = result
        task = nil
    }

    mutating func reset() {
        task?.cancel()
        self = CotypingMemoryLookup()
    }

    /// The text before the caret without a word still being typed, so a
    /// half-typed word neither starts a lookup nor changes the facts mid-word.
    static func finishedWords(of text: String) -> String {
        guard let last = text.last, last.isLetter || last.isNumber else { return text }
        return String(text[..<(text.lastIndex { !($0.isLetter || $0.isNumber) }.map(text.index(after:)) ?? text.startIndex)])
    }
}
