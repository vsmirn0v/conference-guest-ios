import ConferenceCore
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct RoomSyncSettingsView: View {
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @State private var confirmDelete = false
    @State private var confirmFresh = false
    @State private var pickingArchiveFolder = false

    var body: some View {
        Section {
            syncSwitch(
                L("Sync with iCloud"),
                isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }),
                id: "settings.sync",
                fallbackFor: sync.enabled ? [] : [
                    "settings.handoff",
                    "settings.sync-recent",
                    "settings.sync-workspace",
                    "settings.sync-calendar",
                    "settings.sync-transcripts",
                    "settings.sync-now"
                ]
            )
            .disabled(sync.busy)
            if sync.enabled {
                syncSwitch(
                    L("Show active jams on my devices"),
                    isOn: Binding(get: { continuation.enabled }, set: { continuation.setEnabled($0) }),
                    id: "settings.handoff"
                )
                syncSwitch(
                    L("Include recent jams"),
                    isOn: Binding(get: { sync.includeRecent }, set: { sync.setIncludeRecent($0) }),
                    id: "settings.sync-recent"
                )
                syncSwitch(
                    L("Sync meeting history, summaries, notes & tasks"),
                    isOn: Binding(get: { sync.syncWorkspace }, set: { sync.setSyncWorkspace($0) }),
                    id: "settings.sync-workspace"
                )
                syncSwitch(
                    L("Share calendar schedule"),
                    isOn: Binding(get: { sync.shareCalendar }, set: { sync.setShareCalendar($0) }),
                    id: "settings.sync-calendar"
                )
                transcriptRetentionControl
                syncNowButton.disabled(sync.busy)
            }
            archiveFolderControls
            HStack {
                if sync.busy { ProgressView() }
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
            }
            if let warning = sync.storageWarning {
                Text(warning).font(.footnote).foregroundStyle(.orange)
                Button(L("Retry saving sync changes")) { sync.retryLocalSave() }
            }
            if let choice = sync.nameChoice {
                Text(L("Your devices have different saved names. Choose the name to use for future joins."))
                    .font(.subheadline)
                Button(L("Use this device’s name: %@", choice.local)) { sync.chooseName(useCloud: false) }
                Button(L("Use iCloud name: %@", choice.cloud.isEmpty ? L("No saved name") : choice.cloud)) { sync.chooseName(useCloud: true) }
            }
            if sync.needsFreshAccount {
                Button(L("Start fresh for this Apple Account"), role: .destructive) { confirmFresh = true }
            }
            Button(L("Delete synced data…"), role: .destructive) { confirmDelete = true }
                .disabled(sync.busy || !sync.canDeleteSyncedData)
        } header: {
            Text(L("Across your devices"))
        } footer: {
            Text(L("Sync uses the same iCloud Apple Account on your devices. Saved invitations, meeting history, summaries, notes, tasks, optional calendar schedule and recent raw transcripts stay in your private iCloud storage. Older transcripts stay on this device or in your backup folder."))
        }
        .confirmationDialog(L("Delete your name and saved jams from iCloud?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete from iCloud"), role: .destructive) { Task { await sync.deleteSyncedData() } }
        } message: {
            Text(L("Other devices will pause sync when they next connect. This device’s local name, rooms and meeting library remain."))
        }
        .confirmationDialog(L("Start fresh with the current Apple Account?"), isPresented: $confirmFresh, titleVisibility: .visible) {
            Button(L("Start fresh"), role: .destructive) { sync.startFreshForCurrentAccount() }
        } message: {
            Text(L("The local name and room list will be cleared before syncing. Data in your previous Apple Account stays there."))
        }
        #if !os(macOS)
        .fileImporter(isPresented: $pickingArchiveFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                sync.updateTranscriptArchiveFolder(url: url)
            }
        }
        #endif
    }

    @ViewBuilder private var transcriptRetentionControl: some View {
        let binding = Binding(
            get: { sync.transcriptRetention },
            set: { sync.setTranscriptRetention($0) }
        )
        #if os(macOS)
        NativeSettingsPopup(
            title: L("Raw transcript sync"),
            selection: binding,
            choices: TranscriptSyncRetention.allCases,
            titleForChoice: \.title,
            id: "settings.sync-transcripts"
        )
        #else
        Picker(L("Raw transcript sync"), selection: binding) {
            ForEach(TranscriptSyncRetention.allCases, id: \.self) { choice in
                Text(choice.title).tag(choice)
            }
        }
        .accessibilityIdentifier("settings.sync-transcripts")
        #endif
    }

    @ViewBuilder private var archiveFolderControls: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Transcript backup folder"))
                Text(sync.archiveFolderName ?? L("On this device"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            #if os(macOS)
            NativeSettingsButton(title: L("Choose…"), id: "settings.transcript-archive") {
                chooseMacArchiveFolder()
            }
            #else
            Button(L("Choose…")) { pickingArchiveFolder = true }
                .accessibilityIdentifier("settings.transcript-archive")
            #endif
        }
        if sync.archiveFolderName != nil {
            Button(L("Use device storage only"), role: .destructive) {
                sync.updateTranscriptArchiveFolder(url: nil)
            }
        }
    }

    #if os(macOS)
    private func chooseMacArchiveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("Choose Backup Folder")
        if panel.runModal() == .OK, let url = panel.url {
            sync.updateTranscriptArchiveFolder(url: url)
        }
    }
    #endif

    @ViewBuilder private func syncSwitch(_ title: String, isOn: Binding<Bool>, id: String, fallbackFor: Set<String> = []) -> some View {
        #if os(macOS)
        NativeSettingsSwitch(title: title, isOn: isOn, id: id, fallbackFor: fallbackFor)
        #else
        Toggle(title, isOn: isOn)
        #endif
    }

    @ViewBuilder private var syncNowButton: some View {
        #if os(macOS)
        NativeSettingsButton(title: L("Sync now"), id: "settings.sync-now") { sync.requestSync(immediate: true) }
        #else
        Button(L("Sync now")) { sync.requestSync(immediate: true) }
        #endif
    }
}
