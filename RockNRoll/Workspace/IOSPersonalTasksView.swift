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
    @AppStorage("ios.workspace.taskGrouping") private var grouping: IOSTaskGrouping = .list
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var searchText = ""
    @State private var selectedAssignee: IOSTaskAssigneeFilter = .all
    @State private var editingTask: IOSMeetingTaskItem?
    @State private var busy: Set<UUID> = []
    @State private var undoTaskID: UUID?
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
        IOSPersonalTasksQuery.tasks(myTasksOnly ? ownedTasks : workspace.tasks, sessions: workspace.sessions,
                                    archiveDates: archiveDates, filter: filter, calendar: displayCalendar,
                                    search: searchText, assignee: myTasksOnly ? .all : selectedAssignee)
    }

    private var displayCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }

    private var archiveDates: [UUID: Date] {
        let ownedIDs = Set(ownedTasks.map(\.id))
        return workspace.taskArchiveDates.filter { ownedIDs.contains($0.key) }
    }

    private var assigneeOptions: (people: [IOSTaskAssigneeOption], hasUnassigned: Bool) {
        IOSPersonalTasksQuery.assignees(in: workspace.tasks.filter {
            filter == .archived ? archiveDates[$0.id] != nil : archiveDates[$0.id] == nil
        })
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
                    Menu {
                        Picker(L("Group by"), selection: $grouping) {
                            Label(L("Flat list"), systemImage: "list.bullet").tag(IOSTaskGrouping.list)
                            Label(L("Group by meeting"), systemImage: "rectangle.3.group").tag(IOSTaskGrouping.byMeeting)
                        }
                    } label: {
                        Image(systemName: grouping == .list ? "list.bullet" : "rectangle.3.group")
                    }
                    .accessibilityLabel(L("Group by"))
                }

                if !(myTasksOnly && !workspace.taskProfile.isConfigured) {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("Search tasks…"), text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button { searchText = "" } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel(L("Clear filters"))
                        }
                    }
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    if !myTasksOnly {
                        let options = assigneeOptions
                        Picker(L("Assignee"), selection: $selectedAssignee) {
                            Text(L("All assignees")).tag(IOSTaskAssigneeFilter.all)
                            if options.hasUnassigned { Text(L("Unassigned")).tag(IOSTaskAssigneeFilter.unassigned) }
                            ForEach(options.people) { person in
                                Text(person.name).tag(IOSTaskAssigneeFilter.person(person.key))
                            }
                        }
                        .pickerStyle(.menu)
                    }
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
                if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedAssignee != .all {
                    ContentUnavailableView {
                        Label(L("No tasks match this filter."), systemImage: "line.3.horizontal.decrease.circle")
                    } actions: {
                        Button(L("Clear filters")) { searchText = ""; selectedAssignee = .all }
                            .buttonStyle(.borderedProminent)
                    }
                } else if myTasksOnly && !workspace.tasks.isEmpty {
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
                    if grouping == .byMeeting {
                        ForEach(IOSPersonalTasksQuery.groupedByMeeting(filteredTasks, sessions: workspace.sessions)) { group in
                            Section {
                                ForEach(group.tasks) { task in taskRow(task, showMeeting: false) }
                            } header: {
                                Button { onOpenSession(group.sessionID) } label: {
                                    HStack {
                                        VStack(alignment: .leading) {
                                            Text(group.title.isEmpty ? L("Meeting") : group.title)
                                            if let date = group.date { Text(date.formatted(date: .abbreviated, time: .omitted)) }
                                        }
                                        Spacer()
                                        Text("\(group.tasks.count)")
                                    }
                                }
                                .textCase(nil)
                            }
                        }
                    } else {
                        ForEach(filteredTasks) { task in taskRow(task) }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.interactively)
            }
            if let undoTaskID {
                HStack {
                    Text(L("Task archived"))
                    Spacer()
                    Button(L("Undo")) { archive(undoTaskID, archived: false) }
                        .disabled(busy.contains(undoTaskID))
                }
                .padding()
            }
        }
        .onChange(of: myTasksOnly) { _, onlyMine in
            if onlyMine { selectedAssignee = .all }
        }
        .onChange(of: workspace.tasks) { _, _ in sanitizeAssignee() }
        .onChange(of: filter) { _, _ in sanitizeAssignee() }
        .onChange(of: workspace.taskArchiveDates) { _, _ in sanitizeAssignee() }
        .onChange(of: workspace.taskProfile) { _, _ in sanitizeAssignee() }
        .task(id: undoTaskID) {
            guard undoTaskID != nil else { return }
            do {
                try await Task.sleep(for: .seconds(8))
                undoTaskID = nil
            } catch { }
        }
        .sheet(item: $editingTask) { task in IOSMeetingTaskEditor(workspace: workspace, task: task) }
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
                            let updated = workspace.taskProfile.editingConfirmedNames(name: profileNameDraft,
                                                                                     aliases: profileAliasesDraft)
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
                            editingReminderTask = nil
                            updateReminder(task.id, date: nil)
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
                            editingReminderTask = nil
                            updateReminder(task.id, date: reminderDateDraft)
                        }
                    }
                }
            }
        }
    }

    private func taskRow(_ task: IOSMeetingTaskItem, showMeeting: Bool = true) -> some View {
        let sessionTitle = workspace.sessions.first(where: { $0.id == task.sessionID })?.title ?? L("Meeting")
        let isArchived = archiveDates[task.id] != nil
        let isOwned = workspace.taskProfile.owns(task)

        return HStack(alignment: .top, spacing: 12) {
            Button {
                mutate(task.id) { await workspace.toggleTaskDone(task.id) }
            } label: {
                Image(systemName: task.done ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(task.done ? .green : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isArchived || busy.contains(task.id))
            .accessibilityLabel(L("Task completed"))
            .accessibilityValue(task.done ? L("Done") : L("Open"))

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
                    } else if !myTasksOnly {
                        Label(L("Unassigned"), systemImage: "person.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let due = task.dateForDisplay(calendar: displayCalendar) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let overdue = !task.done && (task.deadline(calendar: displayCalendar) ?? .distantFuture) <= context.date
                        let date = due.formatted(date: .abbreviated, time: task.hasDayDeadline(calendar: displayCalendar) ? .omitted : .shortened)
                        Text(overdue ? L("Overdue · %@", date) : L("Due %@", date))
                            .foregroundStyle(overdue ? Color.red : Color.secondary)
                    }.font(.caption)
                }
                if let reminderAt = task.reminderAt, !task.done {
                    Label(reminderAt.formatted(date: .abbreviated, time: .shortened), systemImage: "bell.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if showMeeting {
                    Button {
                        onOpenSession(task.sessionID)
                    } label: {
                        Text(sessionTitle)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("Edit")) { editingTask = task }
            if isArchived || isOwned {
                Button(isArchived ? L("Restore") : L("Archive")) { archive(task.id, archived: !isArchived) }
            }
        }
        .swipeActions(edge: .leading) {
            Button(L("Edit")) { editingTask = task }.tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            if isArchived || isOwned {
                Button(isArchived ? L("Restore") : L("Archive")) {
                    archive(task.id, archived: !isArchived)
                }
                .tint(.indigo)
                .disabled(busy.contains(task.id))
            }
            if isOwned && !task.done && !isArchived {
                Button(L("Remind")) {
                    reminderDateDraft = max(task.reminderAt ?? Date().addingTimeInterval(3600), Date())
                    editingReminderTask = task
                }
                .tint(.orange)
            }
        }
    }

    private func sanitizeAssignee() {
        let options = assigneeOptions
        switch selectedAssignee {
        case .all: break
        case .unassigned: if !options.hasUnassigned { selectedAssignee = .all }
        case .person(let key): if !options.people.contains(where: { $0.key == key }) { selectedAssignee = .all }
        }
    }

    private func mutate(_ id: UUID, operation: @escaping @MainActor () async -> Void) {
        guard busy.insert(id).inserted else { return }
        Task { @MainActor in
            defer { busy.remove(id) }
            await operation()
        }
    }

    private func archive(_ id: UUID, archived: Bool) {
        mutate(id) {
            await workspace.setTaskArchived(id, archived: archived)
            if (workspace.taskArchiveDates[id] != nil) == archived { undoTaskID = archived ? id : nil }
        }
    }

    private func updateReminder(_ id: UUID, date: Date?) {
        mutate(id) {
            guard var latest = workspace.tasks.first(where: { $0.id == id }),
                  !latest.done, workspace.taskProfile.owns(latest), archiveDates[id] == nil else { return }
            latest.reminderAt = date
            latest.updatedAt = Date()
            _ = await workspace.updateTask(latest)
        }
    }

    private func loadProfileDrafts() {
        profileNameDraft = workspace.taskProfile.aliases.first ?? ""
        profileAliasesDraft = workspace.taskProfile.aliases.dropFirst().joined(separator: ", ")
    }
}
