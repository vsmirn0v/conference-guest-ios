import ConferenceCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSAssistantSettingsView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator
    @ObservedObject private var voiceStore = IOSVoiceStore.shared
    @ObservedObject private var voxStore = IOSVoxCPM2Store.shared

    @State private var apiKeyDraft = ""
    @State private var choosingModel = false
    @State private var pickingArchiveFolder = false
    @State private var pickingExportBundleFolder = false
    @State private var pickingImportBundleFolder = false
    @State private var archiveFeedback: String?

    var body: some View {
        Form {
            Section {
                Picker(L("Default mode in active meeting"), selection: $assistant.defaultForegroundMode) {
                    ForEach(IOSMeetingAssistantMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Picker(L("Default mode in background meetings"), selection: $assistant.defaultBackgroundMode) {
                    ForEach(IOSMeetingAssistantMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Picker(L("When meeting sound is off"), selection: $assistant.defaultSilencedMode) {
                    ForEach(IOSMeetingAssistantMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                Picker(L("Participation reply channel"), selection: $assistant.participationConfig.defaultOutput) {
                    ForEach(IOSParticipationOutput.allCases) { channel in
                        Label(channel.title, systemImage: channel.symbol).tag(channel)
                    }
                }
                Toggle(L("Ask before sending replies"), isOn: $assistant.participationConfig.askBeforeSending)
                TextField(L("Default participation goal (optional)"), text: $assistant.participationConfig.goal, axis: .vertical)
                    .lineLimit(1...3)
            } header: {
                Text(L("Live Meeting Assistant"))
            } footer: {
                Text(L("Modes can be changed per meeting from the call header or active meetings list. Participation automatically pauses whenever your microphone is unmuted."))
            }

            Section {
                Toggle(L("Hands-free “Rock” wake word"), isOn: $voiceStore.wakeWordEnabled)
                    .accessibilityIdentifier("assistant.wakeWord")
                Picker(L("Assistant reply voice"), selection: $voiceStore.assistantAuditionVoice) {
                    Section(L("Neural presets (VoxCPM2)")) {
                        ForEach(AssistantVoxVoicePreset.allCases) { preset in
                            Text(preset.localizedTitle).tag(AssistantAuditionVoiceSelection.voxPreset(preset))
                        }
                    }
                    Section(L("Personal & Cloned")) {
                        if voxStore.isDeviceSupported {
                            Text(L("My cloned voice")).tag(AssistantAuditionVoiceSelection.clonedVoice)
                        }
                        Text(L("Personal Voice")).tag(AssistantAuditionVoiceSelection.personalVoice)
                    }
                    Section(L("iPhone system voices")) {
                        Text(L("System voice (automatic)")).tag(AssistantAuditionVoiceSelection.systemVoice(identifier: ""))
                    }
                }
                Toggle(L("Speak voice-triggered replies aloud"), isOn: $voiceStore.autoAuditionVoiceReplies)
                Toggle(L("Speak typed replies aloud"), isOn: $voiceStore.autoAuditionTypedReplies)
            } header: {
                Text(L("Voice Commands & Audition"))
            } footer: {
                Text(L("Always ready while you are in the app or muted in a call, and paused when your meeting microphone is unmuted."))
            }

            Section {
                Toggle(L("Generate summaries automatically after meetings"), isOn: $workspace.outcomeConfig.autoGenerateOnLeave)
                Picker(L("Summary provider"), selection: Binding(
                    get: { workspace.outcomeConfig.providerKind },
                    set: { kind in
                        var configuration = workspace.outcomeConfig
                        guard configuration.providerKind != kind else { return }
                        configuration.providerKind = kind
                        configuration.model = kind.defaultModel
                        configuration.contextTokens = nil
                        workspace.outcomeConfig = configuration
                        apiKeyDraft = workspace.readAPIKey(for: kind)
                    }
                )) {
                    ForEach(PortableOutcomeProviderKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }

                if workspace.outcomeConfig.providerKind == .custom {
                    TextField(L("Base URL (OpenAI-compatible /v1)"), text: $workspace.outcomeConfig.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if workspace.outcomeConfig.providerKind.needsKey {
                    if let endpoint = workspace.outcomeConfig.endpoint, let host = endpoint.host {
                        let recipient = endpoint.port.map { "\(host):\($0)" } ?? host
                        Toggle(L("Allow meeting data sharing with %@", recipient), isOn: Binding(
                            get: { workspace.remoteAISharingAllowed },
                            set: { workspace.setRemoteAIConsent($0) }
                        ))
                        .accessibilityIdentifier("assistant.remoteDataConsent")
                        Text(L("For summaries and live assistance, this device can send meeting titles, participant names, transcripts, chat, notes and assistant instructions to %@. This includes automatic summaries when enabled.", recipient))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Button {
                        choosingModel = true
                    } label: {
                        Label(L("Choose provider model…"), systemImage: "list.bullet")
                    }
                    .disabled(workspace.outcomeConfig.modelCatalogEndpoint == nil || apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    TextField(L("Model"), text: Binding(
                        get: { workspace.outcomeConfig.model },
                        set: { model in
                            var configuration = workspace.outcomeConfig
                            guard configuration.model != model else { return }
                            configuration.model = model
                            configuration.contextTokens = nil
                            workspace.outcomeConfig = configuration
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("API Key (stored in Keychain)"), text: Binding(
                        get: { apiKeyDraft },
                        set: { key in
                            apiKeyDraft = key
                            workspace.saveAPIKey(key, for: workspace.outcomeConfig.providerKind)
                        }
                    ))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            } header: {
                Text(L("Meeting Summaries & Tasks"))
            } footer: {
                Text(L("When “Mac via iCloud” is selected, iPhone waits briefly for your Mac to produce and export the summary when Mac was in the call; otherwise iPhone generates it automatically."))
            }

            Section(L("Same-Room Back-to-Back Meetings")) {
                Picker(
                    L("Default behavior"),
                    selection: Binding(
                        get: { workspace.defaultTransitionMode },
                        set: { mode in Task { await workspace.saveDefaultTransitionMode(mode) } }
                    )
                ) {
                    ForEach(IOSSameRoomTransitionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
            }

            Section {
                Toggle(
                    L("Sync meetings, notes, tasks & settings"),
                    isOn: Binding(get: { sync.syncWorkspace }, set: { sync.setSyncWorkspace($0) })
                )
                .disabled(!sync.enabled)

                Toggle(
                    L("Share calendar schedule"),
                    isOn: Binding(get: { sync.shareCalendar }, set: { sync.setShareCalendar($0) })
                )
                .disabled(!sync.enabled)

                Picker(
                    L("Raw transcript iCloud retention"),
                    selection: Binding(get: { sync.transcriptRetention }, set: { sync.setTranscriptRetention($0) })
                ) {
                    ForEach(TranscriptSyncRetention.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }
                .disabled(!sync.enabled || !sync.syncWorkspace)
            } header: {
                Text(L("iCloud Workspace Sync"))
            } footer: {
                Text(L("Older transcripts expire only from iCloud sync storage; full copies remain on this device and in your transcript backup folder."))
            }

            Section {
                HStack {
                    Text(L("Backup folder"))
                    Spacer()
                    Text(sync.archiveFolderName ?? L("App storage"))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Button(L("Choose Backup Folder…")) {
                    pickingArchiveFolder = true
                }
                if sync.archiveFolderName != nil {
                    Button(L("Use Default App Storage")) {
                        sync.updateTranscriptArchiveFolder(url: nil)
                    }
                }

                HStack {
                    Text(L("Archived sessions"))
                    Spacer()
                    Text("\(workspace.archiveStats.archivedCount) · \(ByteCountFormatter.string(fromByteCount: workspace.archiveStats.totalBytes, countStyle: .file))")
                        .foregroundStyle(.secondary)
                }

                Button(L("Export Transcript Archive…")) {
                    pickingExportBundleFolder = true
                }
                Button(L("Import Transcript Archive…")) {
                    pickingImportBundleFolder = true
                }

                if let archiveFeedback {
                    Text(archiveFeedback)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Transcript Backup & Archive"))
            }

            Section {
                Button {
                    Task { await workspace.synchronizeNow() }
                } label: {
                    HStack {
                        Text(L("Sync Workspace Now"))
                        Spacer()
                        if workspace.isSyncing { ProgressView() }
                    }
                }
                .disabled(!sync.enabled || workspace.isSyncing)

                if let synced = workspace.lastSyncedAt {
                    HStack {
                        Text(L("Last synced"))
                        Spacer()
                        Text(synced.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = workspace.syncError {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .navigationTitle(L("Assistant & Sync"))
        .sheet(isPresented: $choosingModel) {
            let configuration = workspace.outcomeConfig
            IOSSummaryModelPicker(configuration: configuration, key: workspace.readAPIKey(for: configuration.providerKind)) { model in
                var current = workspace.outcomeConfig
                guard current.providerKind == configuration.providerKind,
                      current.modelCatalogEndpoint == configuration.modelCatalogEndpoint else { return }
                current.model = model.id
                current.contextTokens = model.contextLength
                workspace.outcomeConfig = current
            }
        }
        .onAppear {
            apiKeyDraft = workspace.readAPIKey(for: workspace.outcomeConfig.providerKind)
            Task { await workspace.refreshArchiveStats() }
        }
        .fileImporter(isPresented: $pickingArchiveFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                sync.updateTranscriptArchiveFolder(url: url)
                Task {
                    try? await Task.sleep(for: .milliseconds(250))
                    await workspace.refreshArchiveStats()
                }
            }
        }
        .fileImporter(isPresented: $pickingExportBundleFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let count = try await workspace.exportArchiveBundle(to: url)
                        archiveFeedback = L("Exported %ld meeting transcripts.", count)
                    } catch {
                        archiveFeedback = error.localizedDescription
                    }
                }
            }
        }
        .fileImporter(isPresented: $pickingImportBundleFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                let accessed = url.startAccessingSecurityScopedResource()
                Task {
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    do {
                        let count = try await workspace.importArchiveBundle(from: url)
                        archiveFeedback = L("Imported %ld archived transcripts.", count)
                    } catch {
                        archiveFeedback = error.localizedDescription
                    }
                }
            }
        }
    }
}

private struct IOSSummaryModelPicker: View {
    let configuration: PortableOutcomeConfiguration
    let key: String
    let onSelect: (ProviderModelInfo) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var models: [ProviderModelInfo] = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    @State private var loadAttempt = 0

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView(L("Loading models…"))
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error).multilineTextAlignment(.center)
                        Button(L("Try again")) { loadAttempt += 1 }
                    }
                    .padding()
                } else {
                    let shown = ProviderModelCatalog.filter(models, query: search)
                    List(shown) { model in
                        Button {
                            onSelect(model)
                            dismiss()
                        } label: {
                            modelRow(model)
                        }
                        .buttonStyle(.plain)
                    }
                    .overlay {
                        if shown.isEmpty { Text(L("No models match.")).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle(configuration.providerKind.title)
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: L("Search models"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
            }
            .task(id: loadAttempt) {
                loading = true
                error = nil
                defer { loading = false }
                do {
                    models = try await ProviderModelCatalog.fetch(configuration: configuration, key: key)
                } catch where !Task.isCancelled {
                    self.error = error.localizedDescription
                } catch {}
            }
        }
    }

    private func modelRow(_ model: ProviderModelInfo) -> some View {
        let selected = model.id == configuration.resolvedModel
        var details: [String] = []
        if model.name != nil { details.append(model.id) }
        if let length = model.contextLength { details.append(L("%ld K context", length / 1000)) }
        if let price = model.promptPrice {
            details.append(price == 0 ? L("free") : L("$%.2f per million input tokens", price))
        }
        if model.structuredOutput == false { details.append(L("no structured output")) }
        return HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.name ?? model.id)
                if !details.isEmpty {
                    Text(details.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if selected { Image(systemName: "checkmark").foregroundStyle(Color.accentColor) }
        }
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
