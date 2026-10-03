import Foundation

/// Explicit, headless replay of synthetic writing. References/scoring stay in the
/// caller: the model receives only the already-typed text and permitted context.
/// Uses production request construction, token healing, decoding and normalization.
enum CotypingQualityReplay {
    struct Input: Decodable {
        var cases: [Case]
        var maxWords: Int?
        var maxTokens: Int?
        var maxPrefixCharacters: Int?
        var maxPrefixWords: Int?
        var temperature: Double?
        var repeatPenalty: Double?
        var appContext: Bool?
        var userName: String?
        var styleNote: String?
        var languageHint: String?
        var extendedContext: String?
        var memoryItems: [CotypingMemoryContext.Item]?
        var useMeetingMemory: Bool?
        var useScreenMemory: Bool?
        var memoryNow: Date?
        var useVisibleContext: Bool?
    }

    struct Case: Decodable {
        var id: String
        var prefix: String
        var trailing: String?
        var appName: String?
        var bundleID: String?
        var windowTitle: String?
        var placeholder: String?
        var wordPrefixIsValidWord: Bool?
        /// Explicit experiment control, recorded in output. Omit for product replay.
        var promptOverride: String?
        var visibleContext: CotypingVisibleContextReplay.Fixture?
    }

    struct Observation: Encodable {
        var id: String
        var prompt: String
        var text: String
        var suppression: String?
        var latencyMs: Double
        var error: String?
        var usedPromptOverride: Bool
        var memoryIDs: [String] = []
        var visibleIDs: [String] = []
        var visibleTextReadIDs: [String] = []
    }

    @MainActor
    static func run(input: URL, model: URL) async -> Int32 {
        let engine = LocalLlamaCotypingEngine(runtime: LlamaCotypingRuntime(), modelPath: model.path)
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let fixture = try decoder.decode(Input.self, from: Data(contentsOf: input))
            guard !fixture.cases.isEmpty,
                  Set(fixture.cases.map(\.id)).count == fixture.cases.count else {
                throw ReplayError.invalidCases
            }
            let config = try configuration(for: fixture)
            let personalization = CotypingPersonalization(
                userName: fixture.userName, styleNote: fixture.styleNote,
                languageHint: fixture.languageHint, isMultiLine: false,
                appContextEnabled: fixture.appContext ?? true,
                extendedContext: fixture.extendedContext)
            // Loading/Metal priming is outside warm prediction latency.
            try await engine.prewarm()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            var failed = false
            for (index, item) in fixture.cases.enumerated() {
                let observation = await replay(item, generation: UInt64(index), config: config,
                                               personalization: personalization, engine: engine, fixture: fixture)
                failed = failed || observation.error != nil
                let line = try encoder.encode(observation) + Data([10])
                try FileHandle.standardOutput.write(contentsOf: line)
            }
            await engine.unload()
            return failed ? 1 : 0
        } catch {
            try? FileHandle.standardError.write(contentsOf: Data("Cotyping replay: \(error)\n".utf8))
            await engine.unload()
            return 1
        }
    }

    static func configuration(for input: Input) throws -> CotypingConfiguration {
        var config = CotypingConfiguration.standard
        let settings = AppSettings()
        config.maxResponseWords = input.maxWords ?? settings.cotypingMaxWords
        config.maxResponseTokens = input.maxTokens ?? settings.cotypingMaxResponseTokens
        config.maxPrefixCharacters = input.maxPrefixCharacters ?? config.maxPrefixCharacters
        config.maxPrefixWords = input.maxPrefixWords ?? config.maxPrefixWords
        config.temperature = input.temperature ?? config.temperature
        config.repeatPenalty = input.repeatPenalty ?? config.repeatPenalty
        guard (1...30).contains(config.maxResponseWords), (1...120).contains(config.maxResponseTokens),
              (1...14000).contains(config.maxPrefixCharacters), (1...2400).contains(config.maxPrefixWords),
              config.temperature.isFinite, (0...2).contains(config.temperature),
              config.repeatPenalty.isFinite, (0.5...2).contains(config.repeatPenalty) else {
            throw ReplayError.invalidConfiguration
        }
        return config
    }

    @MainActor
    private static func replay(
        _ item: Case, generation: UInt64, config: CotypingConfiguration,
        personalization: CotypingPersonalization, engine: LocalLlamaCotypingEngine, fixture: Input
    ) async -> Observation {
        var field = CotypingField(
            appName: item.appName ?? "Notes", bundleID: item.bundleID ?? "com.apple.Notes",
            processID: 0, role: "AXTextArea", precedingText: item.prefix,
            trailingText: item.trailing ?? "", selectionLength: 0,
            caretRect: .zero, isSecure: false, caretIsExact: true,
            windowTitle: item.windowTitle, fieldPlaceholder: item.placeholder)
        let visibleSource = item.visibleContext.map(CotypingVisibleContextReplay.init)
        let visible = visibleSource?.capture(enabled: fixture.useVisibleContext ?? false)
        field.visibleContext = visible
        let memory = CotypingMemoryContext.select(
            items: fixture.memoryItems ?? [], for: field, includeTitle: personalization.appContextEnabled,
            policy: .init(meetings: fixture.useMeetingMemory ?? false, screenDerived: fixture.useScreenMemory ?? false),
            now: fixture.memoryNow ?? Date())
        guard let built = CotypingRequestBuilder.build(
            field: field, config: config, personalization: personalization, generation: generation,
            memoryContext: memory.text,
            visibleContext: visible?.text,
            wordPrefixIsValidWord: item.wordPrefixIsValidWord ?? true) else {
            return Observation(id: item.id, prompt: "", text: "", suppression: "pre-generation-gate",
                               latencyMs: 0, usedPromptOverride: false)
        }
        let request = overridingPrompt(item.promptOverride, in: built)
        let start = ContinuousClock.now
        do {
            let result = try await engine.generate(request)
            return Observation(id: item.id, prompt: request.prompt, text: result.text,
                               suppression: result.suppression?.rawValue,
                               latencyMs: milliseconds(since: start), usedPromptOverride: item.promptOverride != nil,
                               memoryIDs: memory.items.map(\.id),
                               visibleIDs: visible?.excerpts.map(\.id) ?? [],
                               visibleTextReadIDs: visibleSource?.textReadIDs ?? [])
        } catch {
            return Observation(id: item.id, prompt: request.prompt, text: "",
                               latencyMs: milliseconds(since: start), error: String(describing: error),
                               usedPromptOverride: item.promptOverride != nil)
        }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Double {
        let elapsed = start.duration(to: .now).components
        return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
    }

    private static func overridingPrompt(_ prompt: String?, in request: CotypingRequest) -> CotypingRequest {
        guard let prompt else { return request }
        return CotypingRequest(
            prompt: prompt, prefixText: request.prefixText, trailingText: request.trailingText,
            isMultiLine: request.isMultiLine, maxTokens: request.maxTokens, maxWords: request.maxWords,
            temperature: request.temperature, topP: request.topP, topK: request.topK, minP: request.minP,
            repeatPenalty: request.repeatPenalty, seed: request.seed, generation: request.generation,
            forceWordContinuation: request.forceWordContinuation, wordPrefixAtCaret: request.wordPrefixAtCaret,
            wordPrefixIsValidWord: request.wordPrefixIsValidWord, conditioningPreface: request.conditioningPreface)
    }

    enum ReplayError: Error { case invalidCases, invalidConfiguration }
}
