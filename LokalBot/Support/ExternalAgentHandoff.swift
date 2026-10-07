import AppKit

/// Starts a new conversation in another assistant app with a meeting's notes
/// already in its composer. Both apps only prefill the composer: nothing
/// leaves this Mac until the user presses Send there.
enum ExternalAgentHandoff: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"

    /// Claude cuts `q` at about 14,000 characters. Codex documents no limit;
    /// it gets the same budget so both apps open with the same notes.
    static let promptCharacterLimit = 12_000

    /// Targets with an installed app, looked up once: workspace menus
    /// rebuild their items on every playback update.
    static let installed: [ExternalAgentHandoff] = allCases.filter { target in
        URL(string: "\(target.scheme)://").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) != nil
    }

    private var scheme: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        }
    }

    /// `claude://claude.ai/new?q=` and `codex://new?prompt=`, as each app
    /// documents them.
    func url(prompt: String) -> URL? {
        let (base, key) = switch self {
        case .claude: ("claude://claude.ai/new", "q")
        case .codex: ("codex://new", "prompt")
        }
        return URL(string: "\(base)?\(key)=\(Self.encodeQueryValue(prompt))")
    }

    @MainActor func open(prompt: String) -> Bool {
        guard let url = url(prompt: prompt) else { return false }
        return NSWorkspace.shared.open(url)
    }

    /// URLComponents leaves `+`, `&`, and `=` bare, which URLSearchParams
    /// parsing in both apps would turn into a space or a new parameter.
    static func encodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedCharacters) ?? ""
    }

    private static let unreservedCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func prompt(for meeting: Meeting, limit: Int = promptCharacterLimit) -> String {
        prompt(meetingID: SessionLookup.shortID(meeting.id), limit: limit) { transcriptCharacters in
            SessionFormatter.getMarkdown(meeting, options: .init(
                includeSummary: true,
                includeTranscript: transcriptCharacters != nil,
                includeMetadata: true,
                transcriptCharacters: transcriptCharacters))
        }
    }

    /// `notes(nil)` renders the notes without a transcript and `notes(n)`
    /// adds up to n characters of it. The transcript gets whatever room the
    /// notes leave, and its window ends with a pointer that an agent with
    /// LokalBot's MCP tools can follow using the meeting ID.
    static func prompt(meetingID: String, limit: Int, notes: (Int?) -> String) -> String {
        let intro = "Here are my notes from a meeting recorded in LokalBot (meeting ID \(meetingID)).\n\n"
        let withoutTranscript = notes(nil)
        // Leave room for the transcript heading and its "continues" pointer.
        let room = limit - intro.count - withoutTranscript.count - 200
        let body = room >= 1_000 ? notes(room) : withoutTranscript
        let text = intro + body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        let cut = "\n\n[Cut short to fit.]"
        return String(text.prefix(limit - cut.count)) + cut
    }
}
