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

    @ObservedObject private var taskSync: WorkspaceTaskSyncController
    @AppStorage("ios.workspace.taskFilter") private var filter: IOSTaskFilter = .open
    @AppStorage("ios.workspace.tasksAssignedToMeOnly") private var myTasksOnly = true
    @AppStorage("ios.workspace.taskGrouping") private var grouping: IOSTaskGrouping = .list
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.openURL) private var openURL
    @State private var searchText = ""
    @State private var selectedAssignee: IOSTaskAssigneeFilter = .all
    @State private var editingTask: IOSMeetingTaskItem?
    @State private var busy: Set<UUID> = []
    @State private var undoTaskID: UUID?
    @State private var showingProfileEditor = false
    @State private var showingSyncSettings = false
    @State private var isSelecting = false
    @State private var selectedTaskIDs: Set<UUID> = []
    @State private var schedulingDiscussionTask: IOSMeetingTaskItem?
    @State private var editingReminderTask: IOSMeetingTaskItem?
    @State private var reminderDateDraft = Date().addingTimeInterval(3600)
    @State private var reminderRepeatDraft: TaskReminderRepeatRule = .none

    @State private var profileNameDraft = ""
    @State private var profileAliasesDraft = ""

    init(workspace: IOSWorkspaceCoordinator, onOpenSession: @escaping (UUID) -> Void) {
        self.workspace = workspace
        self.onOpenSession = onOpenSession
        _taskSync = ObservedObject(wrappedValue: workspace.taskSync)
    }

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
                        Button(L("Sync Tasks…")) { Task { await taskSync.runSync() } }
                        Button(L("Import from Jira / Reminders…")) {
                            Task { await taskSync.runSync(directionOverride: .importOnly) }
                        }
                        Menu(L("Role Mode")) {
                            ForEach(TaskSyncRoleMode.allCases) { mode in
                                Button {
                                    Task {
                                        await taskSync.setRoleMode(mode)
                                        if mode == .managerLead {
                                            myTasksOnly = false
                                        } else if mode == .personalOwner && workspace.taskProfile.isConfigured {
                                            myTasksOnly = true
                                        }
                                    }
                                } label: {
                                    HStack {
                                        Text(mode.localizedTitle)
                                        if taskSync.preferences.roleMode == mode {
                                            Image(systemName: "checkmark")
                                        }
                                    }
                                }
                            }
                        }
                        Button(isSelecting ? L("Exit Selection") : L("Select Tasks…")) {
                            isSelecting.toggle()
                            if !isSelecting { selectedTaskIDs.removeAll() }
                        }
                        Divider()
                        Button(L("Task Sync & Contacts…")) { showingSyncSettings = true }
                    } label: {
                        if taskSync.isBusy {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                        }
                    }
                    .accessibilityLabel(L("External Task Sync"))
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
                if isSelecting {
                    HStack {
                        Text(L("%ld selected", selectedTaskIDs.count))
                            .font(.caption.weight(.medium))
                        Button(L("Select All")) {
                            selectedTaskIDs.formUnion(filteredTasks.map(\.id))
                        }
                        .font(.caption)
                        Spacer()
                        Button(L("Sync (%ld)", selectedTaskIDs.count)) {
                            let picked = selectedTaskIDs
                            isSelecting = false
                            selectedTaskIDs.removeAll()
                            Task { await taskSync.runSync(explicitTaskIDs: picked) }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(selectedTaskIDs.isEmpty || taskSync.isBusy)
                        Button(L("Done")) {
                            isSelecting = false
                            selectedTaskIDs.removeAll()
                        }
                        .font(.caption)
                    }
                }
                if !taskSync.pendingMacHandovers.isEmpty {
                    Label(
                        L("%ld Jira action(s) queued for your Mac via iCloud", taskSync.pendingMacHandovers.count),
                        systemImage: "laptopcomputer.and.iphone"
                    )
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let status = taskSync.statusMessage {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let syncErr = taskSync.errorMessage {
                    Text(syncErr)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
        .sheet(item: $editingTask) { task in
            IOSMeetingTaskEditor(workspace: workspace, task: task) { sid in
                onOpenSession(sid)
            }
        }
        .sheet(isPresented: $showingSyncSettings) {
            TaskSyncSettingsSheet(controller: taskSync)
        }
        .sheet(item: $taskSync.pendingPacket) { packet in
            TaskSyncPacketReviewSheet(controller: taskSync, packet: packet)
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
                    Section(L("Quick Presets")) {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Button(L("+1 hour")) {
                                    reminderDateDraft = Date().addingTimeInterval(3600)
                                    reminderRepeatDraft = .none
                                }
                                Button(L("Tomorrow 09:00")) {
                                    reminderDateDraft = TaskReminderRule.tomorrowMorning().customDate ?? Date().addingTimeInterval(86_400)
                                    reminderRepeatDraft = .none
                                }
                                Button(L("Next Mon 09:00")) {
                                    reminderDateDraft = TaskReminderRule.nextMondayMorning().customDate ?? Date().addingTimeInterval(7 * 86_400)
                                    reminderRepeatDraft = .none
                                }
                                Button(L("Daily 09:00")) {
                                    let rule = TaskReminderRule.dailyFollowUp()
                                    reminderDateDraft = rule.customDate ?? Date().addingTimeInterval(86_400)
                                    reminderRepeatDraft = .daily
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                    Section(L("Reminder Schedule")) {
                        DatePicker(L("Remind me at"), selection: $reminderDateDraft, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        Picker(L("Repeat Rule"), selection: $reminderRepeatDraft) {
                            ForEach(TaskReminderRepeatRule.allCases) { rule in
                                Text(rule.localizedTitle).tag(rule)
                            }
                        }
                    }
                    if task.reminderAt != nil || task.extended.reminderRule != nil {
                        Button(L("Clear Reminder"), role: .destructive) {
                            editingReminderTask = nil
                            updateReminder(task.id, date: nil, repeatRule: nil)
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
                            updateReminder(task.id, date: reminderDateDraft, repeatRule: reminderRepeatDraft)
                        }
                    }
                }
            }
        }
        .sheet(item: $schedulingDiscussionTask) { task in
            let session = workspace.sessions.first { $0.id == task.sessionID }
            let record = WorkspaceTaskRecord(
                id: task.id,
                sessionID: task.sessionID,
                outcomeID: task.outcomeID,
                meetingTitle: session?.title ?? L("Meeting"),
                meetingDate: session?.startedAt,
                text: task.text,
                owner: task.owner,
                assigneeID: task.assigneeID,
                dueDay: task.dueDay,
                dueAt: task.dueAt,
                reminderAt: task.reminderAt,
                done: task.done,
                completedAt: task.completedAt,
                archivedAt: workspace.taskArchiveDates[task.id],
                updatedAt: task.updatedAt,
                isOwnedByCurrentUser: workspace.taskProfile.owns(task),
                extended: task.extended
            )
            TaskDiscussionMeetingSheet(task: record, syncController: taskSync) { linked, addPreReminder in
                var discussions = task.extended.scheduledDiscussions
                if !discussions.contains(where: {
                    $0.id == linked.id ||
                        (linked.calendarEventIdentifier != nil && $0.calendarEventIdentifier == linked.calendarEventIdentifier)
                }) {
                    discussions.append(linked)
                    discussions.sort { $0.startAt < $1.startAt }
                }
                var updatedRule = task.extended.reminderRule
                var nextAlert = task.reminderAt
                if addPreReminder {
                    let rule = TaskReminderRule(
                        isEnabled: true,
                        triggerMode: .beforeLinkedMeeting,
                        offsetMinutesBefore: 15,
                        repeatRule: task.extended.reminderRule?.repeatRule ?? .none,
                        escalateWhenBlockedOrOverdue: task.extended.reminderRule?.escalateWhenBlockedOrOverdue ?? false
                    )
                    updatedRule = rule
                    nextAlert = rule.nextFireDate(
                        after: Date(),
                        dueDay: task.dueDay,
                        dueAt: task.dueAt,
                        status: task.extended.workflowStatus,
                        done: task.done,
                        scheduledDiscussions: discussions
                    )
                }
                let payload = TaskDetailEditPayload(
                    text: task.text,
                    owner: task.owner,
                    status: task.done ? .done : task.extended.workflowStatus,
                    priority: task.extended.priority,
                    issueKind: task.extended.issueKind,
                    parentEpicKey: task.extended.parentEpicKey,
                    dueDay: task.dueDay,
                    reminderAt: nextAlert,
                    reminderRule: updatedRule,
                    scheduledDiscussions: discussions,
                    contextNotes: task.extended.contextNotes
                )
                _ = await workspace.updateTaskExtendedDetails(taskID: task.id, payload: payload)
            }
        }
    }

    private func taskRow(_ task: IOSMeetingTaskItem, showMeeting: Bool = true) -> some View {
        let sessionTitle = workspace.sessions.first(where: { $0.id == task.sessionID })?.title ?? L("Meeting")
        let isArchived = archiveDates[task.id] != nil
        let isOwned = workspace.taskProfile.owns(task)

        return HStack(alignment: .top, spacing: 12) {
            if isSelecting {
                Button {
                    if selectedTaskIDs.contains(task.id) { selectedTaskIDs.remove(task.id) }
                    else { selectedTaskIDs.insert(task.id) }
                } label: {
                    Image(systemName: selectedTaskIDs.contains(task.id) ? "checkmark.square.fill" : "square")
                        .font(.title3)
                        .foregroundStyle(selectedTaskIDs.contains(task.id) ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
            }
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
                    if task.extended.issueKind != .task {
                        Text(task.extended.issueKind.localizedTitle.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(task.extended.issueKind == .epic ? Color.purple.opacity(0.18) : Color.secondary.opacity(0.16), in: Capsule())
                            .foregroundStyle(task.extended.issueKind == .epic ? Color.purple : Color.secondary)
                    }
                    if task.extended.workflowStatus != .todo && !task.done {
                        Text(task.extended.workflowStatus.localizedTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor(task.extended.workflowStatus).opacity(0.16), in: Capsule())
                            .foregroundStyle(statusColor(task.extended.workflowStatus))
                    }
                    if let epicKey = task.extended.parentEpicKey, !epicKey.isEmpty {
                        Text("↳ \(epicKey)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.purple)
                    }
                    if !task.owner.isEmpty {
                        Text(task.owner)
                            .font(.caption.weight(!myTasksOnly && isOwned ? .semibold : .medium))
                            .foregroundStyle(!myTasksOnly && isOwned ? Color.accentColor : Color.secondary)
                    } else if !myTasksOnly {
                        Label(L("Unassigned"), systemImage: "person.slash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(task.extended.externalBindings) { binding in
                        let label = binding.externalKey ?? binding.provider.localizedTitle
                        if let urlStr = binding.externalURL, let url = URL(string: urlStr) {
                            Button(label) { openURL(url) }
                                .font(.caption2.monospaced())
                                .buttonStyle(.borderless)
                        } else {
                            Text(label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if task.extended.contextHistory.count > 1 {
                        Text(L("%ld meetings", task.extended.contextHistory.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                let notesSnippet = task.extended.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notesSnippet.isEmpty {
                    Text(notesSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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
                    let repeatIcon = (task.extended.reminderRule?.repeatRule ?? .none) != .none ? "repeat" : "bell.fill"
                    Label(reminderAt.formatted(date: .abbreviated, time: .shortened), systemImage: repeatIcon)
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let rule = task.extended.reminderRule, rule.isEnabled, !task.done {
                    Label(rule.summaryLabel(calendar: displayCalendar), systemImage: "bell.badge")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if let nextMeeting = task.extended.scheduledDiscussions.first(where: { $0.endAt > Date() }) {
                    Label("\(nextMeeting.startAt.formatted(date: .abbreviated, time: .shortened)) · \(nextMeeting.title)", systemImage: "calendar.badge.clock")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                        .lineLimit(1)
                }
                if showMeeting && task.sessionID != TaskExtendedMetadata.externalImportsSessionID {
                    Button {
                        onOpenSession(task.sessionID)
                    } label: {
                        Text(sessionTitle)
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.plain)
                } else if showMeeting && !sessionTitle.isEmpty {
                    Text(sessionTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { editingTask = task }
        .contextMenu {
            Button(L("Details & Reminder Rules…")) { editingTask = task }
            Button(L("Schedule Discussion…")) { schedulingDiscussionTask = task }
            Menu(L("Status")) {
                ForEach(TaskWorkflowStatus.allCases) { st in
                    Button(st.localizedTitle) {
                        mutate(task.id) {
                            let payload = TaskDetailEditPayload(
                                text: task.text,
                                owner: task.owner,
                                status: st,
                                priority: task.extended.priority,
                                issueKind: task.extended.issueKind,
                                parentEpicKey: task.extended.parentEpicKey,
                                dueDay: task.dueDay,
                                reminderAt: st.isTerminalDone ? nil : task.reminderAt,
                                reminderRule: task.extended.reminderRule,
                                scheduledDiscussions: task.extended.scheduledDiscussions,
                                contextNotes: task.extended.contextNotes
                            )
                            _ = await workspace.updateTaskExtendedDetails(taskID: task.id, payload: payload)
                        }
                    }
                }
            }
            if taskSync.preferences.anyProviderEnabled {
                Button(L("Sync Task…")) {
                    Task { await taskSync.runSync(explicitTaskIDs: [task.id]) }
                }
            }
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
            if (isOwned || task.extended.reminderRule?.isEnabled == true) && !task.done && !isArchived {
                Button(L("Remind")) {
                    reminderDateDraft = max(task.reminderAt ?? Date().addingTimeInterval(3600), Date())
                    reminderRepeatDraft = task.extended.reminderRule?.repeatRule ?? .none
                    editingReminderTask = task
                }
                .tint(.orange)
            }
        }
    }

    private func statusColor(_ status: TaskWorkflowStatus) -> Color {
        switch status {
        case .blocked: return .red
        case .inProgress: return .blue
        case .inReview: return .purple
        case .done: return .green
        case .cancelled, .todo: return .secondary
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

    private func updateReminder(_ id: UUID, date: Date?, repeatRule: TaskReminderRepeatRule? = nil) {
        mutate(id) {
            guard var latest = workspace.tasks.first(where: { $0.id == id }),
                  !latest.done,
                  (workspace.taskProfile.owns(latest) || latest.extended.reminderRule?.isEnabled == true),
                  archiveDates[id] == nil else { return }
            if let date {
                let comps = displayCalendar.dateComponents([.hour, .minute], from: date)
                let rule = TaskReminderRule(
                    isEnabled: true,
                    triggerMode: .atSpecificTime,
                    customDate: date,
                    hourOfDay: comps.hour ?? 9,
                    minuteOfHour: comps.minute ?? 0,
                    repeatRule: repeatRule ?? latest.extended.reminderRule?.repeatRule ?? .none,
                    escalateWhenBlockedOrOverdue: latest.extended.reminderRule?.escalateWhenBlockedOrOverdue ?? false
                )
                latest.extended.reminderRule = rule
                latest.reminderAt = date
            } else {
                latest.extended.reminderRule = nil
                latest.reminderAt = nil
            }
            latest.updatedAt = Date()
            _ = await workspace.updateTask(latest)
        }
    }

    private func loadProfileDrafts() {
        profileNameDraft = workspace.taskProfile.aliases.first ?? ""
        profileAliasesDraft = workspace.taskProfile.aliases.dropFirst().joined(separator: ", ")
    }
}
