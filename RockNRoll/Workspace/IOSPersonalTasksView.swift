import ConferenceCore
import SwiftUI

enum IOSTaskFilter: String, CaseIterable, Identifiable {
    case open
    case done
    case archived
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .open: return L("Open")
        case .done: return L("Done")
        case .archived: return L("Archived")
        case .all: return L("All")
        }
    }
}

struct IOSPersonalTasksView: View {
    @ObservedObject var workspace: IOSWorkspaceCoordinator
    var onOpenSession: (UUID) -> Void

    @AppStorage("ios.workspace.taskFilter") private var filter: IOSTaskFilter = .open
    @AppStorage("ios.workspace.tasksAssignedToMeOnly") private var myTasksOnly = true
    @State private var showingProfileEditor = false
    @State private var editingReminderTask: IOSMeetingTaskItem?
    @State private var reminderDateDraft = Date().addingTimeInterval(3600)

    @State private var profileNameDraft = ""
    @State private var profileAliasesDraft = ""

    private var ownedTasks: [IOSMeetingTaskItem] {
        guard workspace.taskProfile.isConfigured else { return [] }
        return workspace.tasks.filter { workspace.taskProfile.owns($0) }
    }

    private var filteredTasks: [IOSMeetingTaskItem] {
        let base = myTasksOnly ? ownedTasks : workspace.tasks
        switch filter {
        case .open:
            return base.filter { !$0.done && workspace.taskArchiveDates[$0.id] == nil }
        case .done:
            return base.filter(\.done)
        case .archived:
            return base.filter { !$0.done && workspace.taskArchiveDates[$0.id] != nil }
        case .all:
            return base
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                Picker(L("Task Filter"), selection: $filter) {
                    ForEach(IOSTaskFilter.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack {
                    Toggle(L("Assigned to me"), isOn: $myTasksOnly)
                        .font(.subheadline)
                    Spacer()
                    Button(L("Profile")) {
                        loadProfileDrafts()
                        showingProfileEditor = true
                    }
                    .font(.subheadline)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)

            if myTasksOnly && !workspace.taskProfile.isConfigured {
                ContentUnavailableView {
                    Label(L("Set the names used to assign tasks to you."), systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text(L("Only tasks assigned to names you confirm appear here."))
                } actions: {
                    Button(L("Set up your task profile")) {
                        loadProfileDrafts()
                        showingProfileEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                    Button(L("Show all tasks")) {
                        myTasksOnly = false
                    }
                    .buttonStyle(.bordered)
                }
            } else if filteredTasks.isEmpty {
                if myTasksOnly && !workspace.tasks.isEmpty {
                    if !ownedTasks.isEmpty && filter != .all {
                        ContentUnavailableView {
                            Label(L("No tasks match this filter."), systemImage: "line.3.horizontal.decrease.circle")
                        } actions: {
                            Button(L("Show all")) { filter = .all }
                                .buttonStyle(.borderedProminent)
                            Button(L("Show all tasks")) { myTasksOnly = false }
                                .buttonStyle(.bordered)
                        }
                    } else {
                        ContentUnavailableView {
                            Label(L("No active tasks assigned to your confirmed names."), systemImage: "checklist")
                        } description: {
                            Text(L("Tasks extracted from meetings on iPhone and Mac appear here."))
                        } actions: {
                            Button(L("Show all tasks")) { myTasksOnly = false }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                } else if !myTasksOnly && !workspace.tasks.isEmpty && filter != .all {
                    ContentUnavailableView {
                        Label(L("No tasks match this filter."), systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button(L("Show all")) { filter = .all }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    ContentUnavailableView(
                        L("No Tasks"),
                        systemImage: "checklist",
                        description: Text(L("Tasks extracted from meetings on iPhone and Mac appear here."))
                    )
                }
            } else {
                List {
                    ForEach(filteredTasks) { task in
                        taskRow(task)
                    }
                }
                .listStyle(.insetGrouped)
            }
        }
        .sheet(isPresented: $showingProfileEditor) {
            NavigationStack {
                Form {
                    Section(L("Your Identity for Task Matching")) {
                        TextField(L("Your name"), text: $profileNameDraft)
                        TextField(L("Other names or aliases (comma separated)"), text: $profileAliasesDraft)
                    }
                    Section {
                        Text(L("Rock'N'Roll syncs your task profile via iCloud and highlights action items owned by you on both Mac and iPhone."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .navigationTitle(L("Task Profile"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Cancel")) { showingProfileEditor = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Save")) {
                            let aliases = IOSTaskProfile.confirmedAliases(profileAliasesDraft)
                            let updated = IOSTaskProfile(
                                profileID: workspace.taskProfile.profileID.isEmpty ? "default" : workspace.taskProfile.profileID,
                                assigneeID: profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? nil : profileNameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
                                aliases: aliases
                            )
                            showingProfileEditor = false
                            Task { await workspace.saveTaskProfile(updated) }
                        }
                    }
                }
            }
        }
        .sheet(item: $editingReminderTask) { task in
            NavigationStack {
                Form {
                    DatePicker(L("Remind me at"), selection: $reminderDateDraft, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    if task.reminderAt != nil {
                        Button(L("Clear Reminder"), role: .destructive) {
                            var cleared = task
                            cleared.reminderAt = nil
                            cleared.updatedAt = Date()
                            editingReminderTask = nil
                            Task { await workspace.updateTask(cleared) }
                        }
                    }
                }
                .navigationTitle(L("Task Reminder"))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(L("Cancel")) { editingReminderTask = nil }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(L("Save")) {
                            var updated = task
                            updated.reminderAt = reminderDateDraft
                            updated.updatedAt = Date()
                            editingReminderTask = nil
                            Task { await workspace.updateTask(updated) }
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: IOSMeetingTaskItem) -> some View {
        let sessionTitle = workspace.sessions.first(where: { $0.id == task.sessionID })?.title ?? L("Meeting")
        let isArchived = workspace.taskArchiveDates[task.id] != nil
        let isOwned = workspace.taskProfile.owns(task)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                Task { await workspace.toggleTaskDone(task.id) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.done ? .green : .secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 4) {
                Text(task.text)
                    .font(.body)
                    .strikethrough(task.done)
                    .foregroundStyle(task.done ? .secondary : .primary)

                HStack(spacing: 8) {
                    if !task.owner.isEmpty {
                        Text(task.owner)
                            .font(.caption.weight(!myTasksOnly && isOwned ? .semibold : .medium))
                            .foregroundStyle(!myTasksOnly && isOwned ? Color.accentColor : Color.secondary)
                    }
                    if let dueDay = task.dueDay, !dueDay.isEmpty {
                        Label(dueDay, systemImage: "calendar")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let reminderAt = task.reminderAt, !task.done {
                        Label(reminderAt.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                Button {
                    onOpenSession(task.sessionID)
                } label: {
                    Text(sessionTitle)
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .swipeActions(edge: .trailing) {
            Button(isArchived ? L("Restore") : L("Archive")) {
                Task { await workspace.setTaskArchived(task.id, archived: !isArchived) }
            }
            .tint(.indigo)
            Button(L("Remind")) {
                reminderDateDraft = task.reminderAt ?? Date().addingTimeInterval(3600)
                editingReminderTask = task
            }
            .tint(.orange)
        }
    }

    private func loadProfileDrafts() {
        profileNameDraft = workspace.taskProfile.assigneeID ?? ""
        profileAliasesDraft = workspace.taskProfile.aliases.joined(separator: ", ")
    }
}
