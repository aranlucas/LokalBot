import SwiftUI

struct AgentCommands: Commands {
    @ObservedObject var app: AppState
    private var active: Bool { app.navSection == .agent }
    var body: some Commands {
        CommandMenu(app.settings.appLanguage.localized("Agent")) {
            Button(app.settings.appLanguage.localized("New Task")) { app.agentSessions.addSession() }.keyboardShortcut("n", modifiers: .command)
                .disabled(!active)
            Button(app.settings.appLanguage.localized("Search Tasks")) { app.agentSessions.searchRequest += 1 }.keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!active)
            Divider()
            Button(app.settings.appLanguage.localized("Previous Task")) { app.agentSessions.selectNeighbor(-1) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(!active)
            Button(app.settings.appLanguage.localized("Next Task")) { app.agentSessions.selectNeighbor(1) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(!active)
            Button(app.settings.appLanguage.localized("Toggle Results")) { app.agentSessions.resultsRequest += 1 }.keyboardShortcut("b", modifiers: [.command, .option])
                .disabled(!active)
            Button(app.settings.appLanguage.localized("Focus Composer")) { app.agentSessions.composerFocusRequest += 1 }.keyboardShortcut("l", modifiers: .command)
                .disabled(!active)
            Divider()
            Button(app.settings.appLanguage.localized("Increase Text Size")) { app.agentSessions.textSize = min(24, app.agentSessions.textSize + 1) }.keyboardShortcut("+", modifiers: .command)
                .disabled(!active)
            Button(app.settings.appLanguage.localized("Decrease Text Size")) { app.agentSessions.textSize = max(12, app.agentSessions.textSize - 1) }.keyboardShortcut("-", modifiers: .command)
                .disabled(!active)
            Button(app.settings.appLanguage.localized("Reset Text Size")) { app.agentSessions.textSize = 15 }.keyboardShortcut("0", modifiers: .command)
                .disabled(!active)
        }
    }
}
