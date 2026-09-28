import SwiftUI

/// Four deliberate steps. Capture preferences remain a draft until Review;
/// permissions and model downloads happen only through their named actions.
struct OnboardingView: View {
    enum Mode { case welcome, permissions }
    enum Step: Int, CaseIterable {
        case capture, permissions, models, review
        var title: String {
            switch self {
            case .capture: "Choose what to remember"
            case .permissions: "Enable the access you need"
            case .models: "Prepare your workflows"
            case .review: "Review and start"
            }
        }
    }
    var mode: Mode = .welcome
    @EnvironmentObject private var app: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var permissions = PermissionManager.shared
    @State private var step: Step = .capture
    @State private var draft = CaptureSetupDraft(settings: AppSettings())
    @State private var initialGrants: [AppPermission: Bool] = [:]
    @State private var includeAutocomplete = false

    private var relevantPermissions: [AppPermission] {
        if mode == .permissions { return AppPermission.allCases }
        var result: [AppPermission] = [.microphone]
        if draft.dayMemory { result.append(.accessibility) }
        if draft.dayMemory && draft.contextMode.capturesPixels { result.append(.screenRecording) }
        return result
    }
    private var newlyGrantedRestartPermission: Bool {
        [.accessibility, .inputMonitoring, .screenRecording].contains {
            initialGrants[$0] != true && permissions.granted[$0] == true
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: 16) {
                Image(systemName: stepIcon)
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(LBTokens.Palette.accentText)
                    .frame(width: 64, height: 64)
                    .lbGroupedSurface()
                if mode == .welcome {
                    HStack(spacing: 8) {
                        ForEach(Step.allCases, id: \.rawValue) { item in
                            Circle().fill(item == step ? LBTokens.Palette.accentText : Color.secondary.opacity(0.25))
                                .frame(width: 6, height: 6)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Setup progress")
                    .accessibilityValue("Step \(step.rawValue + 1) of 4")
                    .accessibilityIdentifier("onboarding.progress")
                }
                Text(step.title).font(.largeTitle.bold()).multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28).padding(.top, 24).padding(.bottom, 8)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch step {
                    case .capture: captureChoices
                    case .permissions: permissionChoices
                    case .models: modelChoices
                    case .review: review
                    }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                if mode == .welcome {
                    Text("Step \(step.rawValue + 1) of 4").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if mode == .welcome, step != .capture {
                    Button("Back") { step = Step(rawValue: step.rawValue - 1) ?? .capture }
                }
                if mode == .permissions {
                    Button("Done") { dismiss() }.primaryActionButton()
                } else if step == .review {
                    Button("Apply Choices and Start") {
                        app.settings = draft.applying(to: app.settings)
                        UserDefaults.standard.set(true, forKey: AppState.onboardingShownKey)
                        dismiss()
                    }.primaryActionButton().accessibilityIdentifier("onboarding.finish")
                } else {
                    Button(step == .permissions ? "Continue with Current Access" : "Continue") {
                        step = Step(rawValue: step.rawValue + 1) ?? .review
                    }.primaryActionButton().keyboardShortcut(.defaultAction)
                }
            }.padding(24)
        }
        .frame(width: 650, height: 640)
        .toggleStyle(LBAccentSwitchStyle())
        .onAppear {
            draft = CaptureSetupDraft(settings: app.settings)
            permissions.refresh()
            initialGrants = permissions.granted
            permissions.startPolling()
            if mode == .permissions { step = .permissions }
        }
        .onDisappear { permissions.stopPolling(); PermissionGuidanceController.shared.dismiss() }
    }

    private var stepIcon: String {
        switch step {
        case .capture: "brain.head.profile"
        case .permissions: "hand.raised"
        case .models: "cpu"
        case .review: "checkmark.circle"
        }
    }

    private var captureChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Keep meeting evidence and a useful memory of your day. You can change each choice later in Settings.")
                .font(.body).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Picker("Detected Meetings", selection: $draft.meetingMode) {
                    ForEach(AppSettings.AutoRecordMode.allCases) { Text($0.rawValue).tag($0) }
                }.accessibilityIdentifier("onboarding.meetingMode")
                Text("Ask via notification waits for you to start recording. Manual mode keeps Record now available.")
                    .workspaceTextRole(.supporting)
            }.workspacePanel()
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Remember app and window activity", isOn: $draft.dayMemory)
                Picker("Day-Memory Detail", selection: $draft.contextMode) {
                    ForEach(AppSettings.ScreenContextCaptureMode.allCases) { Text($0.rawValue).tag($0) }
                }.disabled(!draft.dayMemory)
                Text(draft.contextMode.detail).workspaceTextRole(.trust)
                Text("Text and images build on app activity. Images are encrypted on disk; captured text remains searchable under your retention policy.")
                    .workspaceTextRole(.supporting)
            }.workspacePanel()
            Label("These choices are applied on the final Review step.", systemImage: "checklist")
                .workspaceTextRole(.supporting)
        }
    }

    private var permissionChoices: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Grant only what you need now. You can finish setup with missing permissions and enable the corresponding feature later.")
                .workspaceTextRole(.trust)
            ForEach(relevantPermissions, id: \.self) { permission in
                PermissionRow(permission: permission, prominentRationale: true)
                    .workspacePanel()
            }
            if newlyGrantedRestartPermission {
                Text("A newly granted permission may require a relaunch. Finish setup first; relaunch from Settings if the feature remains unavailable.")
                    .workspaceTextRole(.supporting)
            }
            Text("Autocomplete and global dictation shortcuts can be enabled later from Write.")
                .workspaceTextRole(.supporting)
        }
    }

    private var modelChoices: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Meeting processing needs a Transcribe model and a Think model. Downloads can be deferred; captured meetings wait for their selected models.")
                .workspaceTextRole(.trust)
            modelRow("Speech recognition", model: app.settings.transcriptionModelDisplayName, role: .transcribe)
            modelRow("Summaries and Ask", model: app.settings.thinkModelDisplayName, role: .think)
            InferenceDisclosure(settings: app.settings,
                                localText: "The configured Think model processes selected context on this Mac.",
                                remoteText: "Selected transcript and work context is sent to the approved model server.")
            Toggle("Also prepare Autocomplete (optional)", isOn: $includeAutocomplete)
                .accessibilityLabel("Also prepare Autocomplete (optional)")
            if includeAutocomplete { modelRow("Autocomplete", model: app.settings.cotypingBuiltInModelID, role: .autocomplete) }
            Button("Prepare Selected Models") {
                app.modelRoles.startCoreModelDownloads(includeAutocomplete: includeAutocomplete)
            }.buttonStyle(.bordered).accessibilityIdentifier("onboarding.downloadModels")
            Text("Downloads use the model provider. They do not send your meeting content. Existing downloaded models are kept.")
                .workspaceTextRole(.supporting)
        }
    }

    private func modelRow(_ title: String, model: String, role: ModelRole) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Font.body.weight(.semibold))
                Text(model).font(Font.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Text(app.modelRoles.snapshot[role].label).font(.callout.weight(.semibold))
        }.workspacePanel()
    }

    private var review: some View {
        VStack(alignment: .leading, spacing: 18) {
            LabeledContent("Meeting recording", value: draft.meetingMode.rawValue)
            LabeledContent("Day memory", value: draft.dayMemory ? draft.contextMode.rawValue : "Off")
            LabeledContent("Think model", value: InferencePresentation(settings: app.settings).label)
            LabeledContent("Meeting models", value: app.modelRoles.snapshot.meetingReady ? "Ready to use · not a test result" : "Preparation can continue later")
            let missing = relevantPermissions.filter { permissions.granted[$0] != true }
            if !missing.isEmpty {
                Text("Still unavailable: " + missing.map(\.title).joined(separator: ", ") + ". Features needing this access stay unavailable until you grant it.")
                    .workspaceTextRole(.supporting)
            }
            Text("You can browse, search and edit your existing local library immediately. Setup does not delete any content or change existing remote-server approvals.")
                .workspaceTextRole(.trust)
        }
    }
}
