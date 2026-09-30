#if LOKALBOT_TEST_HOOKS
import Foundation

/// Switches that exist only in Debug builds (`LOKALBOT_TEST_HOOKS`). Each
/// replaces one external dependency with a recorded fake for CI and the UI
/// background host; release builds never compile this file's effects.
enum TestHooks {
    private static func value(_ key: String) -> String? {
        let value = ProcessInfo.processInfo.environment[key]
        return value?.isEmpty == false ? value : nil
    }

    /// Directory of golden transcripts: `<slug>/<track>.json`.
    static var goldenTranscriptsDirectory: URL? {
        value("LOKALBOT_TEST_GOLDEN_TRANSCRIPTS").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    static var backgroundHostEnabled: Bool { value("LOKALBOT_UI_TEST_BACKGROUND") == "1" }
    static var backgroundTracePath: String? { value("LOKALBOT_UI_TEST_TRACE") }
    static var backgroundAudioDirectory: URL? {
        value("LOKALBOT_UI_TEST_AUDIO").map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}

/// Returns the golden transcript for a meeting track instead of running ASR.
struct GoldenTranscriptionEngine: TranscriptionEngine {
    let directory: URL
    var displayName: String { "Golden transcript" }
    var supportsStreaming: Bool { false }

    func prepare(progress: ModelPreparationProgressHandler?) async throws {}

    func transcribe(audio: URL, language: String?) async throws -> Transcript {
        let folderName = audio.deletingLastPathComponent().lastPathComponent
        let slug = folderName.replacingOccurrences(of: #"^\d{2}-"#, with: "", options: .regularExpression)
        let track = audio.deletingPathExtension().lastPathComponent
        let url = directory.appendingPathComponent(slug).appendingPathComponent("\(track).json")
        return try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: url))
    }
}
#endif
