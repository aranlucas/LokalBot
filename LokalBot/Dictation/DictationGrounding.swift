import Foundation

/// Dictation has its own grants. Reuse the current-source lookup without
/// enabling Autocomplete or inheriting its permissions or writing history.
enum DictationGrounding {
    /// Context can complete an explicit writing instruction. A direct sentence
    /// must not acquire claims from nearby messages, even in Compose mode.
    /// Unknown/ambiguous phrasing conservatively gets ordinary cleanup.
    static func requestsContext(_ speech: String) -> Bool {
        var text = LibrarySearch.folded(speech).trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixes = ["please ", "can you ", "could you ", "would you ", "i want you to ", "i'd like you to ",
                        "molim te ", "molim vas ", "mozes li ", "mozete li ", "bitte ", "por favor ", "s'il te plait "]
        for _ in 0..<3 {
            guard let prefix = prefixes.first(where: text.hasPrefix) else { break }
            text.removeFirst(prefix.count)
        }
        let command = text.split(whereSeparator: { !$0.isLetter }).first.map(String.init) ?? ""
        return ["reply", "respond", "answer", "draft", "write", "compose", "rewrite", "rephrase", "edit", "polish",
                "summarize", "summarise", "translate", "odgovori", "napisi", "sastavi", "prevedi", "preformulisi",
                "ecris", "redige", "reponds", "reformule", "traduis", "schreibe", "verfasse", "antworte",
                "ubersetze", "escribe", "redacta", "responde", "traduce", "напиши", "ответь", "переведи"].contains(command)
    }

    static func memorySettings(_ settings: AppSettings) -> AppSettings {
        var selected = settings
        selected.cotypingUseMeetingMemory = settings.dictationIntent == .compose && settings.dictationUseMeetingMemory
        selected.cotypingUseScreenMemory = settings.dictationIntent == .compose && settings.dictationUseScreenMemory
        selected.cotypingUseAppContext = settings.dictationUseScreenContext || settings.dictationUseVisibleContext
        return selected
    }

    static func visiblePolicy(_ settings: AppSettings) -> CotypingVisibleContext.Policy {
        .init(enabled: settings.dictationIntent == .compose && settings.dictationUseVisibleContext,
              excludedApps: settings.excludedAppList, excludedDomains: settings.excludedScreenDomainList)
    }

    static func field(speech: String, screen: DictationScreenContext?,
                      visible: CotypingVisibleContext.Snapshot?) -> CotypingField {
        // This query is a spoken writing request, not typed shell/code input.
        var field = CotypingField(appName: "Dictation", processID: 0, role: "AXTextArea",
                                  precedingText: speech, trailingText: "", selectionLength: 0,
                                  caretRect: .zero, isSecure: false, caretIsExact: true,
                                  windowTitle: visible?.target.windowTitle ?? screen?.windowTitle)
        field.visibleContext = visible
        return field
    }

    static func permissionsMatch(_ frozen: AppSettings, _ current: AppSettings) -> Bool {
        frozen.dictationIntent == current.dictationIntent
            && frozen.dictationUseScreenContext == current.dictationUseScreenContext
            && frozen.dictationUseVisibleContext == current.dictationUseVisibleContext
            && frozen.dictationUseMeetingMemory == current.dictationUseMeetingMemory
            && frozen.dictationUseScreenMemory == current.dictationUseScreenMemory
            && frozen.dreamingEnabled == current.dreamingEnabled
            && frozen.excludedApps == current.excludedApps
            && frozen.excludedScreenDomains == current.excludedScreenDomains
            && frozen.approvedRemoteInferenceOrigins == current.approvedRemoteInferenceOrigins
            && destinationMatches(frozen.dictationCompositionTextEngineSettings,
                                  current.dictationCompositionTextEngineSettings)
    }

    private static func destinationMatches(_ frozen: AppSettings, _ current: AppSettings) -> Bool {
        frozen.summarizerBackend == current.summarizerBackend
            && frozen.builtInModelID == current.builtInModelID
            && frozen.openAIBaseURL == current.openAIBaseURL
            && frozen.ollamaBaseURL == current.ollamaBaseURL
            && !InferencePresentation(settings: current).isBlocked
    }
}
