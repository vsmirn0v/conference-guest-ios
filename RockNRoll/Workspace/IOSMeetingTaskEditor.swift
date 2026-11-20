import SwiftUI

struct IOSMeetingTaskEditor: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    let task: IOSMeetingTaskItem
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var owner: String
    @State private var saving = false
    @State private var confirmingDelete = false
    @State private var error: String?

    init(workspace: IOSWorkspaceCoordinator, task: IOSMeetingTaskItem) {
        self.workspace = workspace
        self.task = task
        _text = State(initialValue: task.text)
        _owner = State(initialValue: task.owner)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Task")) {
                    TextField(L("What needs to be done?"), text: $text, axis: .vertical)
                    TextField(L("Owner"), text: $owner)
                }
                Section {
                    Button(L("Delete task"), role: .destructive) { confirmingDelete = true }
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .disabled(saving)
            .navigationTitle(L("Task"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        saving = true
                        error = nil
                        Task {
                            guard let latest = workspace.tasks.first(where: { $0.id == task.id }) else {
                                dismiss()
                                return
                            }
                            let updated = latest.applyingEdits(from: task, text: text, owner: owner)
                            if await workspace.updateTask(updated) {
                                dismiss()
                            } else {
                                error = workspace.syncError ?? L("Sync changes are not saved on this device yet. Retry before closing the app.")
                                saving = false
                            }
                        }
                    }
                    .disabled(saving || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog(L("Delete task"), isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button(L("Delete task"), role: .destructive) {
                    saving = true
                    error = nil
                    Task {
                        if await workspace.deleteTask(task.id) {
                            dismiss()
                        } else {
                            error = workspace.syncError ?? L("Sync changes are not saved on this device yet. Retry before closing the app.")
                            saving = false
                        }
                    }
                }
            }
        }
    }
}
