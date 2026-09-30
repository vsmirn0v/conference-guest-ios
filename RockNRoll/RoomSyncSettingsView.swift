import SwiftUI

struct RoomSyncSettingsView: View {
    @ObservedObject var sync: RoomSyncCoordinator
    @ObservedObject var continuation: MeetingContinuationCoordinator
    @State private var confirmDelete = false
    @State private var confirmFresh = false
    var body: some View {
        Section {
            Toggle(L("Sync with iCloud"), isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                .disabled(sync.busy)
            if sync.enabled {
                Toggle(L("Show active jams on my devices"), isOn: Binding(get: { continuation.enabled }, set: { continuation.setEnabled($0) }))
                Toggle(L("Include recent jams"), isOn: Binding(get: { sync.includeRecent }, set: { sync.setIncludeRecent($0) }))
                Button(L("Sync now")) { sync.requestSync(immediate: true) }.disabled(sync.busy)
            }
            HStack {
                if sync.busy { ProgressView() }
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
            }
            if let warning = sync.storageWarning {
                Text(warning).font(.footnote).foregroundStyle(.orange)
                Button(L("Retry saving sync changes")) { sync.requestSync(immediate: true) }
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
            Text(L("Sync uses the same iCloud Apple Account on your devices. Names and saved invitations, including invitation passwords, stay in your private iCloud storage. Optional active-jam sharing lets another device continue your current jam and includes its name, invitation and device type. Audio, video, chat and transcripts are not synced. Turning sync off keeps this device’s data."))
        }
        .confirmationDialog(L("Delete your name and saved jams from iCloud?"), isPresented: $confirmDelete, titleVisibility: .visible) {
            Button(L("Delete from iCloud"), role: .destructive) { Task { await sync.deleteSyncedData() } }
        } message: {
            Text(L("Other devices will pause sync when they next connect. This device’s local name and rooms remain."))
        }
        .confirmationDialog(L("Start fresh with the current Apple Account?"), isPresented: $confirmFresh, titleVisibility: .visible) {
            Button(L("Start fresh"), role: .destructive) { sync.startFreshForCurrentAccount() }
        } message: {
            Text(L("The local name and room list will be cleared before syncing. Data in your previous Apple Account stays there."))
        }
    }
}
