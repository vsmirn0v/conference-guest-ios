import AppKit
import SwiftUI

struct AssistantOutcomesView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var data: AssistantDataStore
    @ObservedObject private var library: MeetingLibraryController
    @State private var selectedSessionID: UUID?
    @State private var pendingSend: (outcome: UUID, meeting: UUID)?
    @State private var query = ""
    @State private var collapsedDays: Set<Day> = []
    @State private var calendar = Calendar.current
    @State private var rename: Rename?
    @State private var exportRequest: ExportRequest?
    @State private var obsidianMessage: String?
    @Environment(\.locale) private var locale

    private struct Day: Hashable {
        let date: Date?
    }

    private struct Rename: Identifiable {
        let id: UUID
        var title: String
    }

    private struct ExportRequest: Identifiable {
        let id = UUID()
        var sessionID: UUID?
    }

    init(attention: AttentionCoordinator) {
        self.attention = attention
        _data = ObservedObject(wrappedValue: attention.store.assistant)
        _library = ObservedObject(wrappedValue: attention.store.meetingLibrary)
    }

    private var search: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var groups: [(key: Day, value: [MeetingLibraryCard])] {
        let cards = library.cards.filter { card in
            search.isEmpty || card.title.localizedStandardContains(search) ||
                card.notePreview?.localizedStandardContains(search) == true ||
                data.outcomes.first(where: { $0.id == card.outcomeID })?.summary.localizedStandardContains(search) == true
        }
        return Dictionary(grouping: cards) { card in
            Day(date: card.effectiveDate.map { calendar.startOfDay(for: $0.date) })
        }
        .mapValues { cards in
            cards.sorted { left, right in
                let lhs = left.effectiveDate?.date ?? .distantPast
                let rhs = right.effectiveDate?.date ?? .distantPast
                return lhs == rhs ? left.sessionID.uuidString < right.sessionID.uuidString : lhs > rhs
            }
        }
        .sorted { ($0.key.date ?? .distantPast) > ($1.key.date ?? .distantPast) }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField(L("Search meetings"), text: $query)
                    .textFieldStyle(.roundedBorder).padding(10)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(groups, id: \.key) { day, cards in
                            DisclosureGroup(isExpanded: Binding(get: { !search.isEmpty || !collapsedDays.contains(day) },
                                set: { expanded in
                                    guard search.isEmpty else { return }
                                    if expanded { collapsedDays.remove(day) } else { collapsedDays.insert(day) }
                                })) {
                                ForEach(cards) { card in
                                    Button { select(card) } label: { cardRow(card) }
                                        .buttonStyle(.plain).accessibilityIdentifier("assistant.meeting-card")
                                }
                            } label: {
                                HStack {
                                    Text(day.date?.formatted(.dateTime.day().month(.wide).year().locale(locale)) ?? L("Date unknown"))
                                    Spacer()
                                    Text(cards.count.formatted()).foregroundStyle(.secondary)
                                }.font(.subheadline.weight(.semibold))
                            }.padding(.vertical, 4)
                        }
                    }.padding(8)
                }
                if groups.isEmpty {
                    Text(search.isEmpty ? L("Meeting notes and outcomes appear here.") : L("No matching meetings"))
                        .font(.callout).foregroundStyle(.secondary).padding()
                }
                Divider()
                Button(L("Export Markdown…")) { exportRequest = ExportRequest() }
                    .disabled(library.cards.isEmpty)
                    .padding(10)
            }.frame(width: 270).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let card = library.cards.first(where: { $0.sessionID == selectedSessionID }) {
                selectedMeeting(card).id(card.sessionID)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L("Choose a meeting")).font(.title3)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            }
        }
        .onAppear {
            if let requested = attention.requestedOutcomeSessionID {
                selectedSessionID = requested
                attention.requestedOutcomeSessionID = nil
            }
            else if selectedSessionID == nil { select(groups.first?.value.first) }
        }
        .onChange(of: attention.requestedOutcomeSessionID) { id in
            if let id {
                selectedSessionID = id
                query = ""
                attention.requestedOutcomeSessionID = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            calendar = Calendar.current
        }
        .onDisappear { data.flushOutcomeEdits() }
        .sheet(item: $rename) { value in
            RenameMeetingSheet(library: library, sessionID: value.id, currentTitle: value.title)
        }
        .sheet(item: $exportRequest) { value in
            MeetingManualExportView(attention: attention, singleSessionID: value.sessionID)
        }
        .alert(L("Save in Obsidian"), isPresented: Binding(get: { obsidianMessage != nil },
            set: { shown in if !shown { obsidianMessage = nil } })) {
            Button(L("OK"), role: .cancel) { obsidianMessage = nil }
        } message: {
            Text(obsidianMessage ?? "")
        }
    }

    private func select(_ card: MeetingLibraryCard?) { selectedSessionID = card?.sessionID }

    private func selectedMeeting(_ card: MeetingLibraryCard) -> some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(card.title).font(.title2.bold()).lineLimit(2)
                    if let date = card.effectiveDate {
                        Text(date.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        if date.fromEnd {
                            Text(L("By end time")).font(.caption).foregroundStyle(.secondary)
                                .accessibilityIdentifier("assistant.date-end-fallback")
                        }
                    } else {
                        Text(L("Date unknown")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button { rename = Rename(id: card.sessionID, title: card.title) } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless).help(L("Rename meeting"))
                .accessibilityLabel(L("Rename meeting"))
                Spacer(minLength: 4)
                exportButtons(sessionID: card.sessionID)
            }.padding(16)
            Divider()
            GeometryReader { geometry in
                let wide = geometry.size.width >= 820
                let layout = wide ? AnyLayout(HStackLayout(alignment: .top, spacing: 0)) :
                    AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
                ScrollView {
                    layout {
                        meetingNotes(card)
                            .frame(minWidth: wide ? 340 : nil, maxWidth: .infinity)
                            .frame(height: wide ? max(250, geometry.size.height) : 330)
                        Rectangle().fill(Color(nsColor: .separatorColor))
                            .frame(width: wide ? 1 : nil, height: wide ? geometry.size.height : 1)
                        if wide {
                            ScrollView { outcomeContent(card) }
                                .frame(minWidth: 410, maxWidth: .infinity, maxHeight: .infinity)
                                .frame(height: geometry.size.height)
                        } else {
                            outcomeContent(card)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func meetingNotes(_ card: MeetingLibraryCard) -> some View {
        MeetingNotesView(sessionID: card.sessionID, notes: attention.store.notes, title: L("My notes"),
            ended: false, openWindow: {
                let main = NSApp.keyWindow
                attention.store.notes.windows.open(sessionID: card.sessionID, title: card.title,
                    date: card.effectiveDate?.date, showInMain: { [weak main] in
                        attention.requestedOutcomeSessionID = card.sessionID
                        if main?.isMiniaturized == true { main?.deminiaturize(nil) }
                        main?.makeKeyAndOrderFront(nil)
                    })
            })
    }

    @ViewBuilder private func outcomeContent(_ card: MeetingLibraryCard) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let id = card.outcomeID, let error = data.outcomeWriteErrors[id] {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Outcome changes could not be saved. %@", error)).font(.callout).foregroundStyle(.red)
                    HStack {
                        Button(L("Retry")) { attention.store.retryOutcomeEdits(id) }
                        Button(L("Discard unsaved changes"), role: .destructive) {
                            attention.store.discardOutcomeEdits(id)
                        }
                    }
                }.padding(16)
            }
            if card.outcomeState == .failed || card.outcomeState == .pending || attention.outcomeError[card.sessionID] != nil {
                generationDetail(card)
            } else if let outcome = data.outcomes.first(where: { $0.id == card.outcomeID }) {
                detail(outcome)
            } else {
                Text(card.state == .active || card.state == .reconnecting ? L("Meeting in progress") : L("Outcome unavailable"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
            AssistantOutcomeHistoryView(store: library.store, sessionID: card.sessionID, updatedAt: card.updatedAt)
            ParticipationOutcomeActivity(sessionID: card.sessionID, root: attention.store.root)
        }
    }

    @ViewBuilder private func cardRow(_ card: MeetingLibraryCard) -> some View {
        let isSelected = selectedSessionID == card.sessionID
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(card.title).fontWeight(.semibold).lineLimit(1)
                if card.hasNotes {
                    Image(systemName: "note.text").font(.caption).foregroundStyle(.secondary)
                        .help(L("Has notes"))
                }
                Spacer()
            }
            HStack(spacing: 6) {
                if let date = card.effectiveDate {
                    Text(date.date.formatted(date: .omitted, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                        .help(date.fromEnd ? L("By end time") : L("Start time"))
                    if date.fromEnd {
                        Text(L("By end time")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                switch card.outcomeState {
                case .pending:
                    Text("·").foregroundStyle(.secondary)
                    Text(L("Preparing outcome…")).font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text("·").foregroundStyle(.secondary)
                    Text(L("Outcome failed")).font(.caption).foregroundStyle(.red)
                case .ready:
                    Text(L("Outcome ready")).font(.caption).foregroundStyle(.secondary)
                case .draft, .notStarted:
                    Text(card.state == .active || card.state == .reconnecting ? L("Meeting in progress") : L("Outcome unavailable"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let outcome = data.outcomes.first(where: { $0.id == card.outcomeID }) {
                    Text("·").foregroundStyle(.secondary)
                    Text(outcome.summary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                } else if let status = attention.outcomeStatus[card.sessionID] {
                    Text("·").foregroundStyle(.secondary)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.accentColor.opacity(0.13) : .clear,
                in: RoundedRectangle(cornerRadius: 7))
    }

    private func generationDetail(_ card: MeetingLibraryCard) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let error = attention.outcomeError[card.sessionID] {
                Text(error).foregroundStyle(.red)
            } else if card.outcomeState == .failed {
                let failure = card.outcomeErrorCode.flatMap(MeetingOutcomeFailure.init(rawValue:))
                Text(failure?.localizedDescription ?? L("The outcome could not be generated."))
                    .foregroundStyle(.red)
            } else {
                Text(L("Preparing outcome…")).foregroundStyle(.secondary)
            }
            if card.outcomeState == .failed {
                if card.hasOutcomeInput, let id = card.outcomeID {
                    Button(L("Retry outcome")) { attention.retryOutcome(for: card.sessionID, outcomeID: id) }
                        .accessibilityIdentifier("assistant.retry-outcome")
                        .disabled(attention.outcomeStatus[card.sessionID] != nil)
                } else {
                    Text(L("The original meeting input is unavailable for retry.")).foregroundStyle(.secondary)
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportButtons(sessionID: UUID) -> some View {
        HStack {
            Button(L("Export Markdown…")) { exportRequest = ExportRequest(sessionID: sessionID) }
            Button(L("Save in Obsidian")) {
                Task { @MainActor in
                    guard await attention.store.notes.flush(sessionID: sessionID) else {
                        obsidianMessage = L("The local note could not be saved. Export Markdown to recover the draft.")
                        return
                    }
                    await attention.store.waitForOutcomeWrites()
                    do {
                        try await library.saveInObsidian(sessionID)
                        obsidianMessage = L("The saved meeting was queued for Obsidian.")
                    } catch { obsidianMessage = error.localizedDescription }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ outcome: MeetingOutcome) -> some View {
        let binding = Binding(get: { data.outcomes.first { $0.id == outcome.id } ?? outcome },
            set: { data.updateOutcome($0) })
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                Button(L("Copy as text")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(outcome.shareText, forType: .string)
                }
                Button(L("Send to meeting chat")) {
                    if let target = attention.outcomeChatTarget(outcome) {
                        pendingSend = (outcome.id, target.sessionID)
                    }
                }
                .disabled(attention.outcomeChatTarget(outcome) == nil)
            }
            if pendingSend?.outcome == outcome.id, let meetingID = pendingSend?.meeting,
               let target = attention.meetings().first(where: { $0.sessionID == meetingID && !$0.isClosed }) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Send this outcome to the chat of “%@”?", target.title)).font(.headline)
                    if target.sessionID != outcome.meetingID {
                        Text(L("This is the meeting open now. The outcome is from an earlier occurrence."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(outcome.summary).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                    HStack {
                        Button(L("Confirm")) {
                            pendingSend = nil
                            _ = attention.sendOutcome(outcome, to: meetingID)
                        }.buttonStyle(.borderedProminent).accessibilityIdentifier("assistant.outcome.confirm")
                        Button(L("Cancel"), role: .cancel) { pendingSend = nil }
                    }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            }
            if let error = attention.outcomeError[outcome.id] ?? outcome.meetingID.flatMap({ attention.outcomeError[$0] }) {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            GroupBox(L("Summary")) {
                TextField(L("Summary"), text: binding.summary, axis: .vertical).lineLimit(3...8)
                    .textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
            }
            editableLines(L("Decisions"), values: binding.decisions)
            GroupBox(L("Tasks")) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(outcome.tasks.filter(data.isTaskOperational)) { task in
                        let taskBinding = Binding<MeetingOutcomeTask>(
                            get: { binding.wrappedValue.tasks.first { $0.id == task.id } ?? task },
                            set: { updated in
                                var copy = binding.wrappedValue
                                guard let idx = copy.tasks.firstIndex(where: { $0.id == task.id }) else { return }
                                copy.tasks[idx] = updated
                                binding.wrappedValue = copy
                            }
                        )
                        HStack(alignment: .top, spacing: 8) {
                            Toggle(L("Task completed"), isOn: Binding(get: { taskBinding.wrappedValue.done }, set: { done in
                                var current = taskBinding.wrappedValue
                                current.setDone(done)
                                taskBinding.wrappedValue = current
                            })).labelsHidden()
                            VStack(alignment: .leading, spacing: 4) {
                                TextField(L("Task"), text: taskBinding.text, axis: .vertical).textFieldStyle(.plain)
                                HStack {
                                    TextField(L("Owner"), text: Binding(get: { taskBinding.wrappedValue.owner }, set: { owner in
                                        var current = taskBinding.wrappedValue
                                        guard current.owner != owner else { return }
                                        current.owner = owner
                                        current.assigneeID = nil
                                        current.reminderAt = nil
                                        taskBinding.wrappedValue = current
                                    })).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                    if let due = task.dateForDisplay(calendar: calendar) {
                                        Text(L("Due %@", due.formatted(date: .abbreviated, time: task.dueDay == nil ? .shortened : .omitted)))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Button(task.reminderAt == nil ? L("Remind me") : L("Reminder set")) { attention.remind(task, in: outcome) }
                                .disabled(task.reminderAt != nil || task.done || !data.taskProfile.owns(task))
                            Button { var copy = binding.wrappedValue; copy.tasks.removeAll { $0.id == task.id }; data.updateOutcome(copy) } label: {
                                Image(systemName: "trash")
                            }.buttonStyle(.borderless).help(L("Delete task"))
                        }
                    }
                    Button(L("Add task")) { var copy = binding.wrappedValue; copy.tasks.append(.init(text: L("New task"))); data.updateOutcome(copy) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if !outcome.taskReviewCandidates.isEmpty {
                GroupBox(L("Review suggested tasks")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(outcome.taskReviewCandidates) { candidate in
                            HStack {
                                Text(candidate.text)
                                Spacer()
                                if !outcome.tasks.isEmpty {
                                    Menu(L("Match existing task")) {
                                        ForEach(outcome.tasks) { existing in
                                            Button(existing.text) {
                                                attention.reviewTaskCandidate(candidate, in: outcome, accept: false, matchedTaskID: existing.id)
                                            }
                                        }
                                    }
                                }
                                Button(L("Add")) { attention.reviewTaskCandidate(candidate, in: outcome, accept: true) }
                                Button(L("Dismiss")) { attention.reviewTaskCandidate(candidate, in: outcome, accept: false) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            editableLines(L("Open questions"), values: binding.openQuestions)
            if outcome.seriesID != nil || outcome.invitation != nil {
                GroupBox(L("Series history")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(data.seriesOutcomes(invitation: outcome.invitation, series: outcome.seriesID)) { item in
                            Button { select(library.cards.first { $0.outcomeID == item.id }) } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.knownEndedAt?.formatted(date: .abbreviated, time: .shortened) ?? L("Date unknown")).font(.caption.weight(.semibold))
                                    Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func editableLines(_ title: String, values: Binding<[String]>) -> some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(values.wrappedValue.enumerated()), id: \.offset) { index, current in
                    let lineBinding = Binding<String>(
                        get: { values.wrappedValue.indices.contains(index) ? values.wrappedValue[index] : current },
                        set: { newValue in
                            guard values.wrappedValue.indices.contains(index) else { return }
                            values.wrappedValue[index] = newValue
                        }
                    )
                    HStack(alignment: .top) {
                        TextField(title, text: lineBinding, axis: .vertical).textFieldStyle(.plain)
                        Button {
                            guard values.wrappedValue.indices.contains(index) else { return }
                            values.wrappedValue.remove(at: index)
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(L("Delete line"))
                    }
                }
                Button(L("Add line")) { values.wrappedValue.append("") }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct AssistantOutcomeHistoryView: View {
    let store: MeetingLibraryStore
    let sessionID: UUID
    let updatedAt: Date
    @State private var history: [MeetingOutcomeVersion] = []

    var body: some View {
        VStack(alignment: .leading) {
            if !history.isEmpty {
                DisclosureGroup(L("Previous outcome versions")) {
                    ForEach(history) { version in
                        VStack(alignment: .leading, spacing: 5) {
                            if let date = version.savedAt {
                                Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            }
                            Text(version.outcome.shareText).textSelection(.enabled)
                        }.padding(.vertical, 5)
                    }
                }.padding(20)
            }
        }
        .task(id: updatedAt) {
            let versions = try? await store.outcomeVersions(sessionID: sessionID)
            if !Task.isCancelled { history = (versions ?? []).filter { !$0.isCurrent } }
        }
    }
}

private struct RenameMeetingSheet: View {
    let library: MeetingLibraryController
    let sessionID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var error: String?
    @State private var saving = false

    init(library: MeetingLibraryController, sessionID: UUID, currentTitle: String) {
        self.library = library
        self.sessionID = sessionID
        _title = State(initialValue: currentTitle)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Rename meeting")).font(.headline)
            TextField(L("Meeting title"), text: $title).textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button(L("Cancel"), role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save"), action: save).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 360).disabled(saving).interactiveDismissDisabled(saving)
    }

    private func save() {
        guard !saving else { return }
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { error = L("Enter a meeting title."); return }
        saving = true
        Task {
            defer { saving = false }
            do {
                try await library.renameSession(sessionID, title: value)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// "Last time" on the home screen. Observes assistant data on its own.
struct AssistantLastOutcome: View {
    @ObservedObject var assistant: AssistantDataStore
    var invitation: URL?
    var series: String?
    var before: Date

    var body: some View {
        if let outcome = assistant.latestOutcome(invitation: invitation, series: series, before: before) {
            LastTimeView(outcome: outcome, visibleTasks: outcome.tasks.filter(assistant.isTaskOperational))
        }
    }
}

struct LastTimeView: View {
    let outcome: MeetingOutcome
    let visibleTasks: [MeetingOutcomeTask]
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Last time: %@", outcome.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            let pending = visibleTasks.filter { !$0.done }
            if !pending.isEmpty {
                Text(L("Open tasks: %ld of %ld", pending.count, visibleTasks.count)).font(.caption2).foregroundStyle(.orange)
            }
        }.accessibilityElement(children: .combine)
    }
}
