import SwiftUI

struct ObsidianSettingsView: View {
    @ObservedObject var coordinator: ObsidianExportCoordinator
    @State private var confirmHeld = false
    @State private var configureLayout = false

    var body: some View {
        Form {
            Section {
                Toggle(L("Export meetings to Obsidian"), isOn: Binding(
                    get: { coordinator.isEnabled }, set: coordinator.setEnabled))
                Toggle(L("Save to vault after the meeting"), isOn: Binding(
                    get: { coordinator.saveAfterMeeting }, set: coordinator.setSaveAfterMeeting))
                Text(L("The first completed outcome includes notes saved before it becomes available."))
                    .font(.caption).foregroundStyle(.secondary)
                Toggle(L("Automatically sync changes"), isOn: Binding(
                    get: { coordinator.syncChanges }, set: coordinator.setSyncChanges))
                Text(L("Changes to outcomes, notes and tasks are sent from Rock’N’Roll to Obsidian."))
                    .font(.caption).foregroundStyle(.secondary)

                let destination = coordinator.destination
                LabeledContent(L("Mode"), value: (destination?.mode ?? .separateFiles).title)
                Button(L("Format and placement…")) { configureLayout = true }
                LabeledContent(L("Vault"), value: coordinator.vaultName ?? L("Choose a vault"))
                Button(coordinator.vaultName == nil ? L("Choose Vault…") : L("Choose or reauthorize vault…")) {
                    coordinator.chooseVault()
                }
                if coordinator.waitingForVault && (coordinator.isEnabled || coordinator.pendingCount > 0) {
                    Text(L("Waiting for vault access")).foregroundStyle(.secondary)
                }
                if coordinator.pendingCount > 0 {
                    LabeledContent(L("Waiting to export"), value: coordinator.pendingCount.formatted())
                    Button(L("Retry access")) { coordinator.retryAccess() }
                }
                if coordinator.heldCount > 0 {
                    LabeledContent(L("Paused exports"), value: coordinator.heldCount.formatted())
                    Text(L("Previously queued exports stay paused until you send them explicitly."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Send accumulated exports…")) { confirmHeld = true }
                }
                if coordinator.partialCount > 0 {
                    LabeledContent(L("Partially exported"), value: coordinator.partialCount.formatted())
                        .foregroundStyle(.orange)
                }
                if coordinator.conflictCount > 0 {
                    LabeledContent(L("Needs your decision"), value: coordinator.conflictCount.formatted())
                        .foregroundStyle(.red)
                    ObsidianConflictsSection(coordinator: coordinator)
                }
                if let error = coordinator.lastError { Text(error).foregroundStyle(.red) }
                if let success = coordinator.lastSuccess {
                    LabeledContent(L("Last export"), value: L("Revision %@ · %@",
                        success.revision.formatted(), success.date.formatted(date: .abbreviated, time: .shortened)))
                }
            } header: {
                Text(L("Obsidian"))
            } footer: {
                Text(L("The main switch pauses all automatic exports. Manual Markdown export works without Obsidian."))
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $configureLayout) { ObsidianLayoutSettingsView(coordinator: coordinator) }
        .sheet(isPresented: $confirmHeld) { ObsidianHeldExportsView(coordinator: coordinator) }
        .onAppear { coordinator.load(); coordinator.startStatusLoop() }
        .onDisappear { coordinator.stopStatusLoop() }
    }
}

private struct ObsidianHeldExportsView: View {
    @ObservedObject var coordinator: ObsidianExportCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var meetings: [(id: UUID, title: String, date: MeetingEffectiveDate?, snapshots: [ObsidianExportSnapshot])] = []
    @State private var destination: ObsidianDestinationRecord?
    @State private var selected: Set<UUID> = []
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Send accumulated exports")).font(.headline)
            Text(L("Choose meetings to send to the current vault.")).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red) }
            List(meetings, id: \.id) { meeting in
                VStack(alignment: .leading) {
                    Toggle(isOn: Binding(get: { selected.contains(meeting.id) }, set: { checked in
                        if checked { selected.insert(meeting.id) } else { selected.remove(meeting.id) }
                    })) {
                        VStack(alignment: .leading) {
                            Text(meeting.title)
                            if let date = meeting.date {
                                Text(date.date.formatted(date: .abbreviated, time: .shortened) + (date.fromEnd ? " · " + L("By end time") : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { Text(L("Date unknown")).font(.caption).foregroundStyle(.secondary) }
                        }
                    }
                    DisclosureGroup(L("Preview")) {
                        ForEach(Array(meeting.snapshots.enumerated()), id: \.offset) { _, snapshot in
                            Text(MeetingMarkdownTemplate.managedContent(session: snapshot.session, note: snapshot.note,
                                outcome: snapshot.outcome, outcomeState: snapshot.outcomeState,
                                sections: destination?.layout.sections ?? .all))
                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                    }
                }
            }.frame(minWidth: 400, minHeight: 200)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Send exports")) {
                    guard let destination else { return }
                    sending = true
                    Task {
                        let previews = Dictionary(uniqueKeysWithValues: meetings.filter { selected.contains($0.id) }.map { ($0.id, $0.snapshots) })
                        do { try await coordinator.sendHeld(sessionIDs: selected, destination: destination, snapshots: previews); dismiss() }
                        catch {
                            if let exportError = error as? ObsidianExportError,
                               exportError == .destinationChanged || exportError == .staleRevision {
                                self.error = L("Export settings or queued content changed. Close and reopen this list to review the latest exports.")
                            } else { self.error = error.localizedDescription }
                            sending = false
                        }
                    }
                }.disabled(selected.isEmpty || sending || destination == nil)
            }
        }.padding(20)
        .task {
            do {
                let preview = try await coordinator.heldMeetings()
                destination = preview.0
                meetings = preview.1
                selected = Set(meetings.map(\.id))
            } catch { self.error = error.localizedDescription }
        }
    }
}
