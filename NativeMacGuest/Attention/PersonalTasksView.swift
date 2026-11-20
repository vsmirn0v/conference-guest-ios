import SwiftUI

struct PersonalTasksView: View {
    let attention: AttentionCoordinator
    let openOutcome: (UUID, UUID?) -> Void
    @ObservedObject private var assistant: AssistantDataStore
    @ObservedObject private var library: MeetingLibraryController
    @AppStorage("native.assistant.personalTaskFilter") private var filter = PersonalTaskFilter.open
    @AppStorage("native.assistant.tasksAssignedToMeOnly") private var assignedToMeOnly = true
    @AppStorage("native.assistant.taskGrouping") private var grouping = PersonalTaskGrouping.list
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var rows: [PersonalTaskRow] = []
    @State private var searchText = ""
    @State private var selectedAssignee: PersonalTaskAssigneeFilter = .all
    @State private var busy: Set<UUID> = []
    @State private var showAliases = false
    @State private var showArchive = false
    @State private var aliases = ""
    @State private var error: String?
    @State private var undo: PersonalTaskRow?

    init(attention: AttentionCoordinator, openOutcome: @escaping (UUID, UUID?) -> Void) {
        self.attention = attention
        self.openOutcome = openOutcome
        _assistant = ObservedObject(wrappedValue: attention.store.assistant)
        _library = ObservedObject(wrappedValue: attention.store.meetingLibrary)
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
                    Picker(L("Filter"), selection: $filter) {
                        Text(L("All")).tag(PersonalTaskFilter.all)
                        Text(L("Open")).tag(PersonalTaskFilter.open)
                        Text(L("Completed")).tag(PersonalTaskFilter.completed)
                    }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
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
                        Button(L("My names in tasks…"), action: editAliases)
                        Button(L("Manage archive…")) { showArchive = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel(L("Task options"))
                    }.menuStyle(.borderlessButton).fixedSize()
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
                HStack(spacing: 10) {
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
                }
                if showMeetingLink {
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
                }
            }
            Spacer()
            if archived || owned {
                Button(archived ? L("Restore") : L("Archive")) { archive(row, value: !archived) }
                    .buttonStyle(.borderless).disabled(busy.contains(row.id))
            }
        }.padding(.vertical, 5)
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
