import ConferenceCore
import SwiftUI
import UniformTypeIdentifiers

struct IOSAssistantSettingsView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var assistant: IOSAssistantCoordinator

    @State private var apiKeyDraft = ""
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
                Toggle(L("Generate summaries automatically after meetings"), isOn: $workspace.outcomeConfig.autoGenerateOnLeave)
                Picker(L("Summary provider"), selection: $workspace.outcomeConfig.providerKind) {
                    ForEach(PortableOutcomeProviderKind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .onChange(of: workspace.outcomeConfig.providerKind) { _, newKind in
                    apiKeyDraft = workspace.readAPIKey(for: newKind)
                    if workspace.outcomeConfig.model.isEmpty && !newKind.defaultModel.isEmpty {
                        workspace.outcomeConfig.model = newKind.defaultModel
                    }
                }

                if workspace.outcomeConfig.providerKind == .custom {
                    TextField(L("Base URL (OpenAI-compatible /v1)"), text: $workspace.outcomeConfig.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                if workspace.outcomeConfig.providerKind.needsKey {
                    TextField(L("Model"), text: $workspace.outcomeConfig.model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField(L("API Key (stored in Keychain)"), text: $apiKeyDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: apiKeyDraft) { _, newValue in
                            workspace.saveAPIKey(newValue, for: workspace.outcomeConfig.providerKind)
                        }
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
