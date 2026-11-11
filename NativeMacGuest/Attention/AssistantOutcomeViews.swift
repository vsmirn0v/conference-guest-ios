import AppKit
import SwiftUI

struct AssistantOutcomesView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var data: AssistantDataStore
    @ObservedObject private var library: MeetingLibraryController
    @State private var selectedSessionID: UUID?
    @State private var pendingSend: (outcome: UUID, meeting: UUID)?
    @State private var selectedNote: UUID?
    @State private var noteText: String?

    init(attention: AttentionCoordinator) {
        self.attention = attention
        _data = ObservedObject(wrappedValue: attention.store.assistant)
        _library = ObservedObject(wrappedValue: attention.store.meetingLibrary)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(library.cards) { card in
                            Button { select(card) } label: {
                                cardRow(card)
                            }.buttonStyle(.plain).accessibilityIdentifier("assistant.meeting-card")
                        }
                        // Generations in flight that have no persisted card yet.
                        ForEach(Array(attention.outcomeStatus.keys.sorted { $0.uuidString < $1.uuidString }), id: \.self) { id in
                            if !library.cards.contains(where: { $0.sessionID == id }),
                               let status = attention.outcomeStatus[id] {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(8)
                }
                if library.cards.isEmpty {
                    Text(L("Meeting notes and outcomes appear here. Nothing leaves this Mac unless you export it.")).font(.callout)
                        .foregroundStyle(.secondary).padding()
                }
            }.frame(width: 330).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            VStack(spacing: 0) {
                if let sessionID = selectedSessionID,
                   let card = library.cards.first(where: { $0.sessionID == sessionID }),
                   card.outcomeState == .failed || card.outcomeState == .pending || attention.outcomeError[sessionID] != nil {
                    generationDetail(card)
                } else if let sessionID = selectedSessionID,
                          let outcomeID = library.cards.first(where: { $0.sessionID == sessionID })?.outcomeID,
                          let outcome = data.outcomes.first(where: { $0.id == outcomeID }) {
                    detail(outcome)
                } else if let sessionID = selectedNote {
                    noteDetail(sessionID)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.bubble").font(.largeTitle).foregroundStyle(.secondary)
                        Text(L("Choose a meeting")).font(.title3)
                        Text(L("Notes, summaries, decisions, tasks and open questions stay on this Mac."))
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
                }
                if let sessionID = selectedSessionID {
                    ParticipationOutcomeActivity(sessionID: sessionID, root: attention.store.root)
                }
            }
        }
        .onAppear { if selectedSessionID == nil { select(library.cards.first) } }
        .onDisappear { data.flushOutcomeEdits() }
    }

    private func select(_ card: MeetingLibraryCard?) {
        selectedNote = nil
        selectedSessionID = card?.sessionID
        noteText = nil
        guard let card else { return }
        if card.hasNotes {
            selectedNote = card.sessionID
            Task { @MainActor in
                noteText = await library.note(sessionID: card.sessionID)?.markdown
            }
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
                Text(card.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                switch card.outcomeState {
                case .pending:
                    Text("·").foregroundStyle(.secondary)
                    Text(L("Preparing outcome…")).font(.caption).foregroundStyle(.secondary)
                case .failed:
                    Text("·").foregroundStyle(.secondary)
                    Text(L("Outcome failed")).font(.caption).foregroundStyle(.red)
                case .ready, .draft, .notStarted: EmptyView()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(card.title).font(.title2).bold()
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
                if card.hasNotes, let noteText {
                    Divider()
                    Text(noteText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                }
                exportButtons(sessionID: card.sessionID)
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder private func noteDetail(_ sessionID: UUID) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let card = library.cards.first(where: { $0.sessionID == sessionID }) {
                    Text(card.title).font(.title2.bold())
                    Text(card.startedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                }
                if let noteText, !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(noteText).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L("No saved notes for this meeting.")).foregroundStyle(.secondary)
                }
                exportButtons(sessionID: sessionID)
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
    }

    @ViewBuilder private func exportButtons(sessionID: UUID) -> some View {
        let exporter = MeetingManualExportController(
            library: library, notes: attention.store.notes)
        HStack {
            Button(L("Export Markdown…")) {
                Task {
                    let items = await exporter.makeItems(sessionIDs: [sessionID])
                    if let item = items.first { await exporter.exportSingle(item: item) }
                }
            }
        }
    }

    @ViewBuilder private func detail(_ outcome: MeetingOutcome) -> some View {
        let binding = Binding(get: { data.outcomes.first { $0.id == outcome.id } ?? outcome },
            set: { data.updateOutcome($0) })
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(outcome.meetingTitle).font(.title2.bold())
                        Text(outcome.endedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Copy as text")) {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(outcome.shareText, forType: .string)
                    }
                    Button(L("Export Markdown…")) {
                        let exporter = MeetingManualExportController(
                            library: library, notes: attention.store.notes)
                        Task {
                            if let meetingID = outcome.meetingID ?? library.cards.first(where: { $0.outcomeID == outcome.id })?.sessionID {
                                let items = await exporter.makeItems(sessionIDs: [meetingID])
                                if let item = items.first { await exporter.exportSingle(item: item) }
                            }
                        }
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
                        ForEach(outcome.tasks) { task in
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
                                Toggle("", isOn: taskBinding.done).labelsHidden()
                                VStack(alignment: .leading, spacing: 4) {
                                    TextField(L("Task"), text: taskBinding.text, axis: .vertical).textFieldStyle(.plain)
                                    HStack {
                                        TextField(L("Owner"), text: taskBinding.owner).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                        if let due = task.dueAt { Text(L("Due %@", due.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                Button(task.reminderAt == nil ? L("Remind me") : L("Reminder set")) { attention.remind(task, in: outcome) }
                                    .disabled(task.reminderAt != nil)
                                Button { var copy = binding.wrappedValue; copy.tasks.removeAll { $0.id == task.id }; data.updateOutcome(copy) } label: {
                                    Image(systemName: "trash")
                                }.buttonStyle(.borderless).help(L("Delete task"))
                            }
                        }
                        Button(L("Add task")) { var copy = binding.wrappedValue; copy.tasks.append(.init(text: L("New task"))); data.updateOutcome(copy) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                editableLines(L("Open questions"), values: binding.openQuestions)
                if outcome.seriesID != nil || outcome.invitation != nil {
                    GroupBox(L("Series history")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(data.seriesOutcomes(invitation: outcome.invitation, series: outcome.seriesID)) { item in
                                Button { select(library.cards.first { $0.outcomeID == item.id }) } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(item.endedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption.weight(.semibold))
                                        Text(item.summary).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }.padding(24).frame(maxWidth: 760, alignment: .leading)
        }
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

/// "Last time" on the home screen. Observes assistant data on its own.
struct AssistantLastOutcome: View {
    @ObservedObject var assistant: AssistantDataStore
    var invitation: URL?
    var series: String?
    var before: Date

    var body: some View {
        if let outcome = assistant.latestOutcome(invitation: invitation, series: series, before: before) {
            LastTimeView(outcome: outcome)
        }
    }
}

struct LastTimeView: View {
    let outcome: MeetingOutcome
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L("Last time: %@", outcome.summary)).font(.caption).foregroundStyle(.secondary).lineLimit(3)
            let pending = outcome.tasks.filter { !$0.done }
            if !pending.isEmpty {
                Text(L("Open tasks: %ld of %ld", pending.count, outcome.tasks.count)).font(.caption2).foregroundStyle(.orange)
            }
        }.accessibilityElement(children: .combine)
    }
}
