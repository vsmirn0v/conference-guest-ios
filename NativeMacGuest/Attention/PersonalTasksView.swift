import ConferenceCore
import SwiftUI

struct PersonalTasksView: View {
    let attention: AttentionCoordinator
    let openOutcome: (UUID, UUID?) -> Void
    @ObservedObject private var assistant: AssistantDataStore
    @ObservedObject private var library: MeetingLibraryController
    @ObservedObject private var taskSync: WorkspaceTaskSyncController
    @AppStorage("native.assistant.personalTaskFilter") private var filter = PersonalTaskFilter.open
    @AppStorage("native.assistant.tasksAssignedToMeOnly") private var assignedToMeOnly = true
    @AppStorage("native.assistant.taskGrouping") private var grouping = PersonalTaskGrouping.list
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @Environment(\.openURL) private var openURL
    @State private var rows: [PersonalTaskRow] = []
    @State private var searchText = ""
    @State private var selectedAssignee: PersonalTaskAssigneeFilter = .all
    @State private var busy: Set<UUID> = []
    @State private var showAliases = false
    @State private var showArchive = false
    @State private var showSyncSettings = false
    @State private var isSelecting = false
    @State private var selectedTaskIDs: Set<UUID> = []
    @State private var editingDetailRow: PersonalTaskRow?
    @State private var schedulingDiscussionRow: PersonalTaskRow?
    @State private var aliases = ""
    @State private var error: String?
    @State private var undo: PersonalTaskRow?

    init(attention: AttentionCoordinator, openOutcome: @escaping (UUID, UUID?) -> Void) {
        self.attention = attention
        self.openOutcome = openOutcome
        _assistant = ObservedObject(wrappedValue: attention.store.assistant)
        _library = ObservedObject(wrappedValue: attention.store.meetingLibrary)
        _taskSync = ObservedObject(wrappedValue: attention.taskSync)
    }

    private struct HistoryInputs: Equatable {
        let profile: PersonalTaskProfile
        let archive: [UUID: Date]
        let outcomes: [MeetingOutcome]
        let cards: [MeetingLibraryCard]
        let assignedToMeOnly: Bool
    }

    private var displayCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }

    private var assigneeOptions: (people: [PersonalTaskAssigneeOption], hasUnassigned: Bool) {
        PersonalTaskQuery.assignees(in: rows)
    }

    private var effectiveAssignee: PersonalTaskAssigneeFilter {
        assignedToMeOnly ? .all : selectedAssignee
    }

    private var hasSecondaryFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || effectiveAssignee != .all
    }

    var body: some View {
        let options = assigneeOptions
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    NativeSegmentedControl(
                        label: L("Filter"),
                        selection: $filter,
                        options: [
                            .init(value: .all, title: L("All")),
                            .init(value: .open, title: L("Open")),
                            .init(value: .completed, title: L("Completed")),
                        ]
                    )
                    Spacer(minLength: 8)
                    Toggle(L("Assigned to me"), isOn: $assignedToMeOnly)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Picker(L("Group by"), selection: $grouping) {
                        Image(systemName: "list.bullet")
                            .accessibilityLabel(L("Flat list"))
                            .help(L("Flat list"))
                            .tag(PersonalTaskGrouping.list)
                        Image(systemName: "rectangle.3.group")
                            .accessibilityLabel(L("Group by meeting"))
                            .help(L("Group by meeting"))
                            .tag(PersonalTaskGrouping.byMeeting)
                    }.pickerStyle(.segmented).labelsHidden().fixedSize()
                    Menu {
                        Button(L("Sync Tasks…")) { Task { await taskSync.runSync() } }
                        Button(L("Import from Jira / Reminders…")) {
                            Task { await taskSync.runSync(directionOverride: .importOnly) }
                        }
                        if !taskSync.pendingMacHandovers.isEmpty {
                            Button(L("Process %ld iPhone Handover(s) Now", taskSync.pendingMacHandovers.count)) {
                                Task { await attention.handleRemoteJiraHandovers() }
                            }
                        }
                        Menu(L("Role Mode")) {
                            ForEach(TaskSyncRoleMode.allCases) { mode in
                                Button {
                                    Task {
                                        await taskSync.setRoleMode(mode)
                                        if mode == .managerLead {
                                            assignedToMeOnly = false
                                        } else if mode == .personalOwner && assistant.taskProfile.isConfigured {
                                            assignedToMeOnly = true
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
                        Button(isSelecting ? L("Exit Selection") : L("Select Tasks to Sync…")) {
                            isSelecting.toggle()
                            if !isSelecting { selectedTaskIDs.removeAll() }
                        }
                        Divider()
                        Button(L("Task Sync & Contacts Settings…")) { showSyncSettings = true }
                    } label: {
                        if taskSync.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .accessibilityLabel(L("External Task Sync"))
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        Button(L("My names in tasks…"), action: editAliases)
                        Button(L("Manage archive…")) { showArchive = true }
                        Divider()
                        Button(L("Task Sync & Contacts Settings…")) { showSyncSettings = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel(L("Task options"))
                    }.menuStyle(.borderlessButton).fixedSize()
                }
                if isSelecting {
                    let visibleFiltered = PersonalTaskQuery.rows(
                        rows,
                        filter: filter,
                        calendar: displayCalendar,
                        search: searchText,
                        assignee: effectiveAssignee
                    )
                    HStack(spacing: 8) {
                        Text(L("%ld selected", selectedTaskIDs.count))
                            .font(.caption.weight(.medium))
                        Button(L("Select Visible")) {
                            selectedTaskIDs.formUnion(visibleFiltered.map(\.id))
                        }
                        .font(.caption)
                        Spacer()
                        Button(L("Sync Selected…")) {
                            let chosen = selectedTaskIDs
                            isSelecting = false
                            selectedTaskIDs.removeAll()
                            Task { await taskSync.runSync(explicitTaskIDs: chosen) }
                        }
                        .font(.caption.weight(.semibold))
                        .disabled(selectedTaskIDs.isEmpty || taskSync.isBusy)
                        Button(L("Done")) {
                            isSelecting = false
                            selectedTaskIDs.removeAll()
                        }
                        .font(.caption)
                    }
                    .padding(.top, 2)
                }
                if !(assignedToMeOnly && !assistant.taskProfile.isConfigured) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)
                            TextField(L("Search tasks…"), text: $searchText)
                                .textFieldStyle(.plain)
                            if !searchText.isEmpty {
                                Button {
                                    searchText = ""
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(L("Clear filters"))
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))

                        if !assignedToMeOnly && (!options.people.isEmpty || options.hasUnassigned) {
                            Picker(L("Assignee"), selection: $selectedAssignee) {
                                Text(L("All assignees")).tag(PersonalTaskAssigneeFilter.all)
                                if options.hasUnassigned {
                                    Text(L("Unassigned")).tag(PersonalTaskAssigneeFilter.unassigned)
                                }
                                ForEach(options.people) { option in
                                    Text(MeetingOutcomePrompt.displayText(option.displayName)).tag(PersonalTaskAssigneeFilter.person(option.key))
                                }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 190)
                        }
                    }
                }
            }.padding(12)
            Divider()
            if assignedToMeOnly && !assistant.taskProfile.isConfigured {
                VStack(spacing: 10) {
                    Text(L("Set the names used to assign tasks to you.")).foregroundStyle(.secondary)
                    Text(L("Only tasks assigned to names you confirm appear here."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(L("My names in tasks…"), action: editAliases)
                        Button(L("Show all tasks")) { assignedToMeOnly = false }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                let filtered = PersonalTaskQuery.rows(
                    rows,
                    filter: filter,
                    calendar: displayCalendar,
                    search: searchText,
                    assignee: effectiveAssignee
                )
                Group {
                    if grouping == .byMeeting {
                        let groups = PersonalTaskQuery.groupedByMeeting(filtered)
                        List {
                            ForEach(groups) { group in
                                Section {
                                    ForEach(group.rows) { row in
                                        taskRow(row, archived: false, showMeetingLink: false)
                                    }
                                } header: {
                                    meetingGroupHeader(group)
                                }
                            }
                        }
                    } else {
                        List {
                            ForEach(filtered) { row in taskRow(row, archived: false, showMeetingLink: true) }
                        }
                    }
                }.overlay {
                    if filtered.isEmpty {
                        VStack(spacing: 8) {
                            if PersonalTaskQuery.rows(rows, filter: .all, calendar: displayCalendar).isEmpty {
                                if assignedToMeOnly {
                                    Text(L("No active tasks assigned to your confirmed names."))
                                    if rows.contains(where: { $0.archivedAt != nil }) {
                                        Text(L("Archived tasks are available in Task options.")).font(.caption)
                                    }
                                    Button(L("Show all tasks")) { assignedToMeOnly = false }
                                } else {
                                    Text(L("No tasks yet."))
                                    Text(L("Tasks extracted from meetings appear here.")).font(.caption)
                                }
                            } else {
                                Text(L("No tasks match this filter."))
                                if hasSecondaryFilters {
                                    Button(L("Clear filters")) { clearSecondaryFilters() }
                                } else {
                                    Button(L("Show all")) { filter = .all }
                                }
                            }
                        }.foregroundStyle(.secondary)
                    }
                }
            }
            if let undo {
                HStack {
                    Text(L("Task archived"))
                    Spacer()
                    Button(L("Undo")) { archive(undo, value: false) }
                }.padding(12)
            }
            if let syncStatus = taskSync.statusMessage {
                Text(syncStatus).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 4)
            }
            if let syncError = taskSync.errorMessage {
                Text(syncError).font(.caption).foregroundStyle(.red).padding(.horizontal, 12).padding(.bottom, 4)
            }
            if let error { Text(error).foregroundStyle(.red).padding(8) }
        }
        .onChange(of: assignedToMeOnly) { onlyMine in
            if onlyMine { selectedAssignee = .all }
        }
        .onChange(of: rows) { updated in
            sanitizeAssigneeSelection(in: updated)
        }
        .task(id: HistoryInputs(profile: assistant.taskProfile, archive: assistant.taskArchiveDates,
                                outcomes: assistant.outcomes, cards: library.cards, assignedToMeOnly: assignedToMeOnly)) {
            await attention.store.waitForMeetingLibrary()
            await reload()
        }
        .task(id: undo?.id) {
            guard undo != nil else { return }
            do {
                try await Task.sleep(for: .seconds(8))
                undo = nil
            } catch { }
        }
        .sheet(isPresented: $showAliases) { aliasesSheet }
        .sheet(isPresented: $showArchive) { archiveSheet }
        .sheet(isPresented: $showSyncSettings) {
            TaskSyncSettingsSheet(controller: taskSync)
        }
        .sheet(item: $taskSync.pendingPacket) { packet in
            TaskSyncPacketReviewSheet(controller: taskSync, packet: packet)
        }
        .sheet(item: $editingDetailRow) { row in
            TaskDetailAndContextSheet(
                task: workspaceRecord(for: row),
                syncController: taskSync,
                knownEpics: knownEpicOptions,
                onSave: { payload in
                    let ok = await attention.setTaskExtendedDetails(row: row, payload: payload)
                    if ok { await reload() }
                    return ok
                },
                onDelete: nil,
                onOpenMeeting: { sid in openOutcome(sid, row.id) }
            )
        }
        .sheet(item: $schedulingDiscussionRow) { row in
            TaskDiscussionMeetingSheet(task: workspaceRecord(for: row), syncController: taskSync) { linked, addPreReminder in
                var discussions = row.task.extended.scheduledDiscussions
                if !discussions.contains(where: {
                    $0.id == linked.id ||
                        (linked.calendarEventIdentifier != nil && $0.calendarEventIdentifier == linked.calendarEventIdentifier)
                }) {
                    discussions.append(linked)
                    discussions.sort { $0.startAt < $1.startAt }
                }
                var updatedRule = row.task.extended.reminderRule
                var nextAlert = row.task.reminderAt
                if addPreReminder {
                    let rule = TaskReminderRule(
                        isEnabled: true,
                        triggerMode: .beforeLinkedMeeting,
                        offsetMinutesBefore: 15,
                        repeatRule: row.task.extended.reminderRule?.repeatRule ?? .none,
                        escalateWhenBlockedOrOverdue: row.task.extended.reminderRule?.escalateWhenBlockedOrOverdue ?? false
                    )
                    updatedRule = rule
                    nextAlert = rule.nextFireDate(
                        after: Date(),
                        dueDay: row.task.dueDay,
                        dueAt: row.task.dueAt,
                        status: row.task.done ? .done : row.task.extended.workflowStatus,
                        done: row.task.done,
                        scheduledDiscussions: discussions
                    )
                }
                let payload = TaskDetailEditPayload(
                    text: row.task.text,
                    owner: row.task.owner,
                    status: row.task.done ? .done : row.task.extended.workflowStatus,
                    priority: row.task.extended.priority,
                    issueKind: row.task.extended.issueKind,
                    parentEpicKey: row.task.extended.parentEpicKey,
                    dueDay: row.task.dueDay,
                    reminderAt: nextAlert,
                    reminderRule: updatedRule,
                    scheduledDiscussions: discussions,
                    contextNotes: row.task.extended.contextNotes
                )
                if await attention.setTaskExtendedDetails(row: row, payload: payload) {
                    await reload()
                }
            }
        }
    }

    private var knownEpicOptions: [(key: String, title: String)] {
        rows.compactMap { row in
            guard row.task.extended.issueKind == .epic else { return nil }
            let key = row.task.extended.binding(for: .jira)?.externalKey
                ?? CrossMeetingTaskReconciler.extractIssueKeys(from: row.task.text).first
            guard let key, !key.isEmpty else { return nil }
            return (key: key, title: MeetingOutcomePrompt.displayText(row.task.text))
        }
    }

    private func editAliases() {
        aliases = assistant.taskProfile.aliases.joined(separator: "\n")
        error = nil
        showAliases = true
    }

    private var aliasesSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("My names in tasks")).font(.headline)
            Text(L("Enter each full name or confirmed alias on a separate line."))
                .foregroundStyle(.secondary)
            TextEditor(text: $aliases).font(.body).frame(height: 140)
                .accessibilityLabel(L("Task owner names"))
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { showAliases = false }
                Button(L("Save")) {
                    var profile = assistant.taskProfile
                    profile.aliases = PersonalTaskProfile.confirmedAliases(aliases)
                    Task { @MainActor in
                        do {
                            try await library.store.saveTaskProfile(profile)
                            attention.store.markTaskProfileManuallyEdited()
                            assistant.taskProfile = profile
                            await attention.reconcileTaskReminderCancellations()
                            showAliases = false
                        } catch { self.error = error.localizedDescription }
                    }
                }.keyboardShortcut(.defaultAction).disabled(assistant.taskProfile.id.isEmpty)
            }
        }.padding(20).frame(width: 440)
    }

    private var archiveSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Manage archive")).font(.headline)
            List {
                ForEach(PersonalTaskQuery.rows(rows, filter: .all, calendar: displayCalendar, archive: true)) {
                    taskRow($0, archived: true)
                }
            }
            HStack {
                if let error { Text(error).foregroundStyle(.red) }
                Spacer()
                Button(L("Close")) { showArchive = false }
            }
        }.padding(20).frame(minWidth: 540, minHeight: 320)
    }

    private func clearSecondaryFilters() {
        searchText = ""
        selectedAssignee = .all
        let remaining = PersonalTaskQuery.rows(rows, filter: filter, calendar: displayCalendar)
        if remaining.isEmpty && !PersonalTaskQuery.rows(rows, filter: .all, calendar: displayCalendar).isEmpty {
            filter = .all
        }
    }

    private func sanitizeAssigneeSelection(in updatedRows: [PersonalTaskRow]) {
        let options = PersonalTaskQuery.assignees(in: updatedRows)
        switch selectedAssignee {
        case .all:
            break
        case .unassigned:
            if !options.hasUnassigned { selectedAssignee = .all }
        case .person(let key):
            if !options.people.contains(where: { $0.key == key }) { selectedAssignee = .all }
        }
    }

    private func meetingGroupHeader(_ group: PersonalTaskMeetingGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                openOutcome(group.sessionID, nil)
            } label: {
                Text(group.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? L("Meeting") : group.title)
                    .font(.subheadline.weight(.semibold))
            }.buttonStyle(.link)
            if let date = group.meetingDate {
                Text(date.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(group.rows.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func taskRow(_ row: PersonalTaskRow, archived: Bool, showMeetingLink: Bool = true) -> some View {
        let owned = assistant.taskProfile.owns(row.task)
        let ownerText = MeetingOutcomePrompt.displayText(row.task.owner).trimmingCharacters(in: .whitespacesAndNewlines)
        let taskText = MeetingOutcomePrompt.displayText(row.task.text)

        return HStack(alignment: .top, spacing: 12) {
            if isSelecting && !archived {
                Button {
                    if selectedTaskIDs.contains(row.id) { selectedTaskIDs.remove(row.id) }
                    else { selectedTaskIDs.insert(row.id) }
                } label: {
                    Image(systemName: selectedTaskIDs.contains(row.id) ? "checkmark.square.fill" : "square")
                        .foregroundStyle(selectedTaskIDs.contains(row.id) ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.plain)
            }
            if archived {
                Image(systemName: row.task.done ? "checkmark.square" : "square")
                    .accessibilityLabel(row.task.done ? L("Completed") : L("Open"))
            } else {
                Toggle(taskText, isOn: Binding(get: { row.task.done }, set: { done in
                    mutate(row) { try await attention.setTaskDone(row, done: done) }
                })).labelsHidden().disabled(busy.contains(row.id))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(taskText).strikethrough(row.task.done)
                HStack(spacing: 8) {
                    if row.task.extended.issueKind != .task {
                        Text(row.task.extended.issueKind.localizedTitle.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(row.task.extended.issueKind == .epic ? Color.purple.opacity(0.18) : Color.secondary.opacity(0.16), in: Capsule())
                            .foregroundStyle(row.task.extended.issueKind == .epic ? Color.purple : Color.secondary)
                    }
                    if row.task.extended.workflowStatus != .todo && !row.task.done {
                        Text(row.task.extended.workflowStatus.localizedTitle)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(statusColor(row.task.extended.workflowStatus).opacity(0.16), in: Capsule())
                            .foregroundStyle(statusColor(row.task.extended.workflowStatus))
                    }
                    if let epicKey = row.task.extended.parentEpicKey, !epicKey.isEmpty {
                        Text("↳ \(epicKey)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.purple)
                    }
                    if !ownerText.isEmpty {
                        Label(ownerText, systemImage: "person")
                            .font(.caption.weight(owned ? .medium : .regular))
                            .foregroundStyle(owned ? Color.accentColor : Color.secondary)
                    } else if !assignedToMeOnly {
                        Label(L("Unassigned"), systemImage: "person.slash")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if let due = row.task.dateForDisplay(calendar: displayCalendar) {
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            let overdue = !row.task.done && (row.task.deadline(calendar: displayCalendar) ?? .distantFuture) <= context.date
                            let date = due.formatted(date: .abbreviated, time: row.task.dueDay == nil ? .shortened : .omitted)
                            Text(overdue ? L("Overdue · %@", date) : L("Due %@", date))
                                .foregroundStyle(overdue ? Color.red : Color.secondary)
                        }.font(.caption)
                    }
                    if let reminderAt = row.task.reminderAt, !row.task.done {
                        let repeatIcon = (row.task.extended.reminderRule?.repeatRule ?? .none) != .none ? "repeat" : "bell.fill"
                        Label(reminderAt.formatted(date: .abbreviated, time: .shortened), systemImage: repeatIcon)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if let rule = row.task.extended.reminderRule, rule.isEnabled, !row.task.done {
                        Label(rule.summaryLabel(calendar: displayCalendar), systemImage: "bell.badge")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let nextMeeting = row.task.extended.scheduledDiscussions.first(where: { $0.endAt > Date() }) {
                        Label(nextMeeting.startAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar.badge.clock")
                            .font(.caption2)
                            .foregroundStyle(Color.accentColor)
                    }
                    ForEach(row.task.extended.externalBindings) { binding in
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
                    if row.task.extended.contextHistory.count > 1 {
                        Text(L("%ld meetings", row.task.extended.contextHistory.count))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                let notesSnippet = row.task.extended.contextNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                if !notesSnippet.isEmpty {
                    Text(notesSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if showMeetingLink && row.sessionID != TaskExtendedMetadata.externalImportsSessionID {
                    Button {
                        showArchive = false
                        openOutcome(row.sessionID, row.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            if let date = row.meetingDate {
                                Text(date.formatted(date: .abbreviated, time: .omitted))
                            }
                        }.font(.caption)
                    }.buttonStyle(.link)
                } else if showMeetingLink && !row.title.isEmpty {
                    Text(row.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if !archived {
                Button { editingDetailRow = row } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("Details & Context"))
            }
            if archived || owned {
                Button(archived ? L("Restore") : L("Archive")) { archive(row, value: !archived) }
                    .buttonStyle(.borderless).disabled(busy.contains(row.id))
            }
        }
        .padding(.vertical, 5)
        .contextMenu {
            Button(L("Details & Reminder Rules…")) { editingDetailRow = row }
            Button(L("Schedule Discussion Meeting…")) { schedulingDiscussionRow = row }
            Menu(L("Reminder Presets")) {
                Button(L("+1 hour")) { applyReminderPreset(row, rule: .inOneHour()) }
                Button(L("Tomorrow 09:00")) { applyReminderPreset(row, rule: .tomorrowMorning()) }
                Button(L("Next Mon 09:00")) { applyReminderPreset(row, rule: .nextMondayMorning()) }
                Button(L("Daily 09:00")) { applyReminderPreset(row, rule: .dailyFollowUp()) }
                if row.task.reminderAt != nil || row.task.extended.reminderRule != nil {
                    Divider()
                    Button(L("Clear Reminder"), role: .destructive) { applyReminderPreset(row, rule: nil) }
                }
            }
            Menu(L("Status")) {
                ForEach(TaskWorkflowStatus.allCases) { st in
                    Button(st.localizedTitle) {
                        mutate(row) {
                            let payload = TaskDetailEditPayload(
                                text: row.task.text,
                                owner: row.task.owner,
                                status: st,
                                priority: row.task.extended.priority,
                                issueKind: row.task.extended.issueKind,
                                parentEpicKey: row.task.extended.parentEpicKey,
                                dueDay: row.task.dueDay,
                                reminderAt: st.isTerminalDone ? nil : row.task.reminderAt,
                                reminderRule: row.task.extended.reminderRule,
                                scheduledDiscussions: row.task.extended.scheduledDiscussions,
                                contextNotes: row.task.extended.contextNotes
                            )
                            _ = await attention.setTaskExtendedDetails(row: row, payload: payload)
                        }
                    }
                }
            }
            if taskSync.preferences.anyProviderEnabled {
                Button(L("Sync Task…")) {
                    Task { await taskSync.runSync(explicitTaskIDs: [row.id]) }
                }
            }
        }
    }

    private func applyReminderPreset(_ row: PersonalTaskRow, rule: TaskReminderRule?) {
        mutate(row) {
            let nextAt = rule?.nextFireDate(
                after: Date(),
                dueDay: row.task.dueDay,
                dueAt: row.task.dueAt,
                status: row.task.done ? .done : row.task.extended.workflowStatus,
                done: row.task.done,
                scheduledDiscussions: row.task.extended.scheduledDiscussions
            )
            let payload = TaskDetailEditPayload(
                text: row.task.text,
                owner: row.task.owner,
                status: row.task.done ? .done : row.task.extended.workflowStatus,
                priority: row.task.extended.priority,
                issueKind: row.task.extended.issueKind,
                parentEpicKey: row.task.extended.parentEpicKey,
                dueDay: row.task.dueDay,
                reminderAt: nextAt,
                reminderRule: rule,
                scheduledDiscussions: row.task.extended.scheduledDiscussions,
                contextNotes: row.task.extended.contextNotes
            )
            _ = await attention.setTaskExtendedDetails(row: row, payload: payload)
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

    private func workspaceRecord(for row: PersonalTaskRow) -> WorkspaceTaskRecord {
        WorkspaceTaskRecord(
            id: row.id,
            sessionID: row.sessionID,
            outcomeID: row.outcomeID,
            meetingTitle: row.title,
            meetingDate: row.meetingDate,
            text: row.task.text,
            owner: row.task.owner,
            assigneeID: row.task.assigneeID,
            dueDay: row.task.dueDay,
            dueAt: row.task.dueAt,
            reminderAt: row.task.reminderAt,
            done: row.task.done,
            completedAt: row.task.completedAt,
            archivedAt: row.archivedAt,
            isOwnedByCurrentUser: assistant.taskProfile.owns(row.task),
            extended: row.task.extended
        )
    }

    private func archive(_ row: PersonalTaskRow, value: Bool) {
        mutate(row) {
            try await attention.setTaskArchived(row, archived: value)
            undo = value ? row : nil
        }
    }

    private func mutate(_ row: PersonalTaskRow, operation: @escaping @MainActor () async throws -> Void) {
        guard busy.insert(row.id).inserted else { return }
        error = nil
        Task { @MainActor in
            defer { busy.remove(row.id) }
            do { try await operation() }
            catch { self.error = error.localizedDescription }
            await reload()
        }
    }

    private func reload() async {
        do {
            let updated = try await library.store.taskHistory(profile: assistant.taskProfile, includeAll: !assignedToMeOnly)
            if !Task.isCancelled { rows = updated }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
