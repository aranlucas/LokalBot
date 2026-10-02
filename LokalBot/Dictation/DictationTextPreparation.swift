import Foundation

/// The intent boundary is shared by production and hermetic runtime tests.
/// Transcribe cannot construct a language model or request screen context.
enum DictationTextPreparation {
    struct Result {
        let text: String
        let compositionModel: String?
        var sourceTitles: [String] = []
        var contextIsCurrent: @MainActor () -> Bool = { true }
    }

    /// No thinking turn, a low temperature for faithful cleanup, and an output
    /// ceiling well above a long dictated message.
    static let composeOptions = TextGenerationOptions(maxTokens: 4_096, reasoningBudgetTokens: 0, temperature: 0.2)

    @MainActor
    static func prepare(
        speech: String,
        settings: AppSettings,
        screenContext: () async -> DictationScreenContext?,
        visibleContext: () async -> CotypingVisibleContext.Snapshot? = { nil },
        memoryContext: (CotypingField, AppSettings) async -> CotypingMemoryContextProvider.Snapshot = { _, _ in .empty },
        currentSettings: @escaping () -> AppSettings? = { nil },
        validateVisibleContext: (CotypingVisibleContext.Snapshot) async -> Bool = { _ in false },
        validateScreenContext: (DictationScreenContext) async -> Bool = { _ in false },
        makeEngine: (AppSettings) async throws -> TextEngine
    ) async throws -> Result {
        try Task.checkCancellation()
        guard settings.dictationIntent == .compose else {
            return Result(text: speech, compositionModel: nil)
        }
        func permissionsCurrent() -> Bool {
            DictationGrounding.permissionsMatch(settings, currentSettings() ?? settings)
        }
        guard permissionsCurrent() else { throw DictationComposeError.contextChanged }
        let usesContext = DictationGrounding.requestsContext(speech)
        let context = usesContext && settings.dictationUseScreenContext ? await screenContext() : nil
        try Task.checkCancellation()
        guard permissionsCurrent() else { throw DictationComposeError.contextChanged }
        let visible = usesContext && settings.dictationUseVisibleContext ? await visibleContext() : nil
        try Task.checkCancellation()
        guard permissionsCurrent() else { throw DictationComposeError.contextChanged }
        let selectedSettings = DictationGrounding.memorySettings(settings)
        let memory = usesContext && CotypingMemoryContext.Policy(settings: selectedSettings).enabled
            ? await memoryContext(DictationGrounding.field(speech: speech, screen: context, visible: visible), selectedSettings)
            : .empty
        let isCurrent = {
            permissionsCurrent() && memory.isCurrent(settings: DictationGrounding.memorySettings(currentSettings() ?? settings))
        }
        func validate() async throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw DictationComposeError.contextChanged }
            if let visible, !(await validateVisibleContext(visible)) { throw DictationComposeError.contextChanged }
            if let context, !(await validateScreenContext(context)) { throw DictationComposeError.contextChanged }
            try Task.checkCancellation()
            guard isCurrent() else { throw DictationComposeError.contextChanged }
        }
        try await validate()
        let engine = try await makeEngine(settings)
        try await validate()
        let prompt = DictationComposePrompt.userPrompt(
            spokenText: speech, context: context,
            profile: DictationComposeProfile(personalization: settings.cotypingPersonalization),
            visibleContext: visible?.text, memoryContext: memory.selection.text)
        // Someone is waiting to insert this text. Without options the built-in
        // server would allow an 8K-token thinking turn before any visible text.
        let output = try await engine.generate(system: DictationComposePrompt.system, prompt: prompt, context: [],
                                               options: Self.composeOptions)
        try await validate()
        let text = DictationComposePrompt.normalizedOutput(output)
        guard !text.isEmpty else { throw DictationComposeError.emptyOutput }
        return Result(text: text, compositionModel: engine.displayName,
                      sourceTitles: memory.selection.sourceTitles, contextIsCurrent: isCurrent)
    }
}
