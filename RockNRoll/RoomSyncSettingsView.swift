import SwiftUI

struct RoomSyncSettingsView: View {
    @ObservedObject var sync: RoomSyncCoordinator
    @State private var confirmDelete = false
    @State private var confirmFresh = false
    var body: some View {
        Section {
            Toggle("Sync with iCloud", isOn: Binding(get: { sync.enabled }, set: { sync.setEnabled($0) }))
                .disabled(sync.busy)
            if sync.enabled {
                Toggle("Include recent jams", isOn: Binding(get: { sync.includeRecent }, set: { sync.setIncludeRecent($0) }))
                Button("Sync now") { sync.requestSync(immediate: true) }.disabled(sync.busy)
            }
            HStack {
                if sync.busy { ProgressView() }
                Text(sync.status).font(.footnote).foregroundStyle(.secondary)
            }
            if let warning = sync.storageWarning {
                Text(warning).font(.footnote).foregroundStyle(.orange)
                Button("Retry saving sync changes") { sync.requestSync(immediate: true) }
            }
            if let choice = sync.nameChoice {
                Text("Your devices have different saved names. Choose the name to use for future joins.")
                    .font(.subheadline)
                Button("Use this device’s name: \(choice.local)") { sync.chooseName(useCloud: false) }
                Button("Use iCloud name: \(choice.cloud.isEmpty ? "No saved name" : choice.cloud)") { sync.chooseName(useCloud: true) }
            }
            if sync.needsFreshAccount {
                Button("Start fresh for this Apple Account", role: .destructive) { confirmFresh = true }
            }
            Button("Delete synced data…", role: .destructive) { confirmDelete = true }
                .disabled(sync.busy || !sync.canDeleteSyncedData)
        } header: {
            Text("Across your devices")
        } footer: {
            Text("Sync uses the same iCloud Apple Account on your devices. Names and saved invitations, including invitation passwords, stay in your private iCloud storage. Audio, video, chat and transcripts are not synced. Turning sync off keeps this device’s data.")
        }
        .confirmationDialog("Delete your name and saved jams from iCloud?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete from iCloud", role: .destructive) { Task { await sync.deleteSyncedData() } }
        } message: {
            Text("Other devices will pause sync when they next connect. This device’s local name and rooms remain.")
        }
        .confirmationDialog("Start fresh with the current Apple Account?", isPresented: $confirmFresh, titleVisibility: .visible) {
            Button("Start fresh", role: .destructive) { sync.startFreshForCurrentAccount() }
        } message: {
            Text("The local name and room list will be cleared before syncing. Data in your previous Apple Account stays there.")
        }
    }
}
