import SwiftUI

/// Integrations settings: vault selection, enable/disable, pending/conflict counts
/// and retry. Mode A (separate meeting files) is the only mode this build exposes.
struct ObsidianSettingsView: View {
    @ObservedObject var coordinator: ObsidianExportCoordinator

    var body: some View {
        Form {
            Section {
                Toggle(L("Export meetings to Obsidian"), isOn: Binding(
                    get: { coordinator.isEnabled },
                    set: { enabled in
                        if enabled, !coordinator.isEnabled { coordinator.enable() }
                        else if !enabled, coordinator.isEnabled { coordinator.disable() }
                    }))
                if coordinator.isEnabled {
                    LabeledContent(L("Mode"), value: L("Separate file per meeting"))
                    LabeledContent(L("Vault"), value: coordinator.vaultName ?? L("Selected"))
                    if coordinator.pendingCount > 0 {
                        LabeledContent(L("Waiting to export"), value: String(coordinator.pendingCount))
                    }
                    if coordinator.conflictCount > 0 {
                        LabeledContent(L("Needs your decision"), value: String(coordinator.conflictCount))
                            .foregroundColor(.red)
                    }
                    if let error = coordinator.lastError {
                        Text(error).foregroundColor(.red)
                    }
                    HStack {
                        Button(L("Check Access Again…")) { coordinator.reauthorize() }
                        Button(L("Retry Export")) { coordinator.retryAll() }
                            .disabled(coordinator.pendingCount == 0 && coordinator.conflictCount == 0)
                    }
                } else {
                    Text(L("Notes and outcomes stay on this Mac unless you export them. Manual Markdown export works without Obsidian."))
                        .font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text(L("Obsidian"))
            } footer: {
                Text(L("Export is one-way: Obsidian files are never read back, and deleting a meeting here never deletes vault files. Recovery backups are kept in the app container."))
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .onAppear { coordinator.load(); coordinator.startStatusLoop() }
        .onDisappear { coordinator.stopStatusLoop() }
    }
}
