import Foundation

/// The intent boundary is shared by production and hermetic runtime tests.
/// Transcribe cannot construct a language model or request screen context.
enum DictationTextPreparation {
    struct Result {
        let text: String
        let compositionModel: String?
    }

    /// No thinking turn, a low temperature for faithful cleanup, and an output
    /// ceiling well above a long dictated message.
    static let composeOptions = TextGenerationOptions(maxTokens: 4_096, reasoningBudgetTokens: 0, temperature: 0.2)

    @MainActor
    static func prepare(
        speech: String,
        settings: AppSettings,
        screenContext: () async -> DictationScreenContext?,
        makeEngine: (AppSettings) async throws -> TextEngine
    ) async throws -> Result {
        try Task.checkCancellation()
        guard settings.dictationIntent == .compose else {
            return Result(text: speech, compositionModel: nil)
        }
        let context = settings.dictationUseScreenContext ? await screenContext() : nil
        try Task.checkCancellation()
        let engine = try await makeEngine(settings)
        let prompt = DictationComposePrompt.userPrompt(
            spokenText: speech, context: context,
            profile: DictationComposeProfile(personalization: settings.cotypingPersonalization))
        // Someone is waiting to insert this text. Without options the built-in
        // server would allow an 8K-token thinking turn before any visible text.
        let output = try await engine.generate(system: DictationComposePrompt.system, prompt: prompt, context: [],
                                               options: Self.composeOptions)
        try Task.checkCancellation()
        let text = DictationComposePrompt.normalizedOutput(output)
        guard !text.isEmpty else { throw DictationComposeError.emptyOutput }
        return Result(text: text, compositionModel: engine.displayName)
    }
}
