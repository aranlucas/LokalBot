import Foundation

/// Shared model context policy and cleanup of pre-unified checkpoints.
enum MeetingSummaryGenerator {
    static let builtInContextTokens = MainLLMRuntimePolicy.contextTokens
    static let conservativeExternalContextTokens = 16_384

    /// The smallest context window OpenRouter advertised across every endpoint
    /// of these models on 1 October 2026 (`/api/v1/models/<id>/endpoints`).
    /// Exact ids only: variants such as `:free` route to other endpoints.
    /// The window is a guard, not a part size. Parts still target the planner's
    /// 6,000 estimated tokens, which UTF-8 bytes bound far below these windows
    /// even for punctuation-heavy or non-Latin text, so a larger window only
    /// stops continuations, repairs and expanded retries from being refused.
    static let verifiedOpenRouterContextTokens: [String: Int] = [
        "z-ai/glm-5.3": 262_144,
        "z-ai/glm-5.3-flash": 262_144,
        "qwen/qwen3.8-flash": 1_000_000,
    ]

    static func contextTokenLimit(for backend: AppSettings.SummarizerBackend) -> Int {
        backend == .builtIn ? builtInContextTokens : conservativeExternalContextTokens
    }

    static func contextTokenLimit(for config: AppSettings) -> Int {
        // Unknown/custom servers and models retain 16K.
        if config.summarizerBackend == .openAICompatible,
           let url = URL(string: config.openAIBaseURL),
           ChatCompletionDialect.inferred(from: url) == .openRouter,
           let verified = verifiedOpenRouterContextTokens[config.openAIModel.lowercased()] {
            return verified
        }
        return contextTokenLimit(for: config.summarizerBackend)
    }

    static func removeCheckpoint(in folder: URL) {
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("summary.parts.partial.json"))
        MeetingNotesGenerator.removeCheckpoint(in: folder)
    }
}
