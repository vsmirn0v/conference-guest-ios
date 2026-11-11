import SwiftUI

struct PersonalTasksView: View {
    let attention: AttentionCoordinator
    let openOutcome: (UUID) -> Void
    @ObservedObject private var assistant: AssistantDataStore
    @ObservedObject private var library: MeetingLibraryController
    @AppStorage("native.assistant.personalTaskFilter") private var filter = PersonalTaskFilter.open
    @Environment(\.calendar) private var calendar
    @Environment(\.timeZone) private var timeZone
    @State private var rows: [PersonalTaskRow] = []
    @State private var busy: Set<UUID> = []
    @State private var showAliases = false
    @State private var showArchive = false
    @State private var aliases = ""
    @State private var error: String?
    @State private var undo: PersonalTaskRow?

    init(attention: AttentionCoordinator, openOutcome: @escaping (UUID) -> Void) {
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
    }

    private var displayCalendar: Calendar {
        var value = calendar
        value.timeZone = timeZone
        return value
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(L("Filter"), selection: $filter) {
                    Text(L("All")).tag(PersonalTaskFilter.all)
                    Text(L("Open")).tag(PersonalTaskFilter.open)
                    Text(L("Completed")).tag(PersonalTaskFilter.completed)
                }.pickerStyle(.segmented).labelsHidden()
                Spacer(minLength: 12)
                Menu {
                    Button(L("My names in tasks…"), action: editAliases)
                    Button(L("Manage archive…")) { showArchive = true }
                } label: {
                    Image(systemName: "ellipsis.circle").accessibilityLabel(L("Task options"))
                }.menuStyle(.borderlessButton).fixedSize()
            }.padding(12)
            Divider()
            if !assistant.taskProfile.isConfigured {
                VStack(spacing: 10) {
                    Text(L("Set the names used to assign tasks to you.")).foregroundStyle(.secondary)
                    Button(L("My names in tasks…"), action: editAliases)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                let filtered = PersonalTaskQuery.rows(rows, filter: filter, calendar: displayCalendar)
                List {
                    ForEach(filtered) { row in taskRow(row, archived: false) }
                }.overlay {
                    if filtered.isEmpty {
                        Text(L("No tasks in this view.")).foregroundStyle(.secondary)
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
        .task(id: HistoryInputs(profile: assistant.taskProfile, archive: assistant.taskArchiveDates,
                                outcomes: assistant.outcomes, cards: library.cards)) {
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

    private func taskRow(_ row: PersonalTaskRow, archived: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if archived {
                Image(systemName: row.task.done ? "checkmark.square" : "square")
                    .accessibilityLabel(row.task.done ? L("Completed") : L("Open"))
            } else {
                Toggle(row.task.text, isOn: Binding(get: { row.task.done }, set: { done in
                    mutate(row) { try await attention.setTaskDone(row, done: done) }
                })).labelsHidden().disabled(busy.contains(row.id))
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(row.task.text).strikethrough(row.task.done)
                if let due = row.task.dateForDisplay(calendar: displayCalendar) {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let overdue = !row.task.done && (row.task.deadline(calendar: displayCalendar) ?? .distantFuture) <= context.date
                        let date = due.formatted(date: .abbreviated, time: row.task.dueDay == nil ? .shortened : .omitted)
                        Text(overdue ? L("Overdue · %@", date) : L("Due %@", date))
                            .foregroundStyle(overdue ? Color.red : Color.secondary)
                    }.font(.caption)
                }
                Button {
                    showArchive = false
                    openOutcome(row.sessionID)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                        if let date = row.meetingDate {
                            Text(date.formatted(date: .abbreviated, time: .omitted))
                        }
                    }.font(.caption)
                }.buttonStyle(.link)
            }
            Spacer()
            Button(archived ? L("Restore") : L("Archive")) { archive(row, value: !archived) }
                .buttonStyle(.borderless).disabled(busy.contains(row.id))
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
            let updated = try await library.store.taskHistory(profile: assistant.taskProfile)
            if !Task.isCancelled { rows = updated }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
