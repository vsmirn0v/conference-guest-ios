import AppKit
import SwiftUI

struct AssistantOutcomesView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var data: AssistantDataStore
    @State private var selectedID: UUID?

    init(attention: AttentionCoordinator) {
        self.attention = attention
        _data = ObservedObject(wrappedValue: attention.store.assistant)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(data.outcomes) { outcome in
                            Button { selectedID = outcome.id } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(outcome.meetingTitle).fontWeight(.semibold).lineLimit(1)
                                    Text(outcome.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    Text(outcome.endedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                                }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(selectedID == outcome.id ? Color.accentColor.opacity(0.13) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            }.buttonStyle(.plain).accessibilityIdentifier("assistant.outcome")
                        }
                    }.padding(8)
                }
                if data.loaded && data.outcomes.isEmpty {
                    Text(L("Outcomes appear after you leave a transcribed meeting.")).font(.callout)
                        .foregroundStyle(.secondary).padding()
                }
            }.frame(width: 330).background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if let id = selectedID, let outcome = data.outcomes.first(where: { $0.id == id }) {
                detail(outcome)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.bubble").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L("Choose a meeting outcome")).font(.title3)
                    Text(L("Summaries, decisions, tasks and open questions stay editable on this Mac."))
                        .foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            }
        }
        .onAppear { if selectedID == nil { selectedID = data.outcomes.first?.id } }
        .onChange(of: data.outcomes.map(\.id)) { ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = ids.first }
            else if self.selectedID == nil { self.selectedID = ids.first }
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
                    Button(L("Send to meeting chat")) { _ = attention.sendOutcome(outcome) }
                        .disabled(!attention.meetings().contains { !$0.isClosed && $0.invitation == outcome.invitation && $0.chat.canSend })
                }
                if let error = attention.outcomeStatus[outcome.id] { Text(error).font(.caption).foregroundStyle(.red) }
                GroupBox(L("Summary")) {
                    TextField(L("Summary"), text: binding.summary, axis: .vertical).lineLimit(3...8)
                        .textFieldStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
                }
                editableLines(L("Decisions"), values: binding.decisions)
                GroupBox(L("Tasks")) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(outcome.tasks) { task in
                            if let index = outcome.tasks.firstIndex(where: { $0.id == task.id }) {
                                HStack(alignment: .top, spacing: 8) {
                                    Toggle("", isOn: binding.tasks[index].done).labelsHidden()
                                    VStack(alignment: .leading, spacing: 4) {
                                        TextField(L("Task"), text: binding.tasks[index].text, axis: .vertical).textFieldStyle(.plain)
                                        HStack {
                                            TextField(L("Owner"), text: binding.tasks[index].owner).textFieldStyle(.roundedBorder).frame(maxWidth: 160)
                                            if let due = task.dueAt { Text(L("Due %@", due.formatted(date: .abbreviated, time: .shortened))).font(.caption).foregroundStyle(.secondary) }
                                        }
                                    }
                                    Button(task.reminderAt == nil ? L("Remind me") : L("Reminder set")) { attention.remind(task, in: outcome) }
                                        .disabled(task.reminderAt != nil)
                                    Button { var copy = outcome; copy.tasks.removeAll { $0.id == task.id }; data.updateOutcome(copy) } label: {
                                        Image(systemName: "trash")
                                    }.buttonStyle(.borderless).help(L("Delete task"))
                                }
                            }
                        }
                        Button(L("Add task")) { var copy = outcome; copy.tasks.append(.init(text: L("New task"))); data.updateOutcome(copy) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                editableLines(L("Open questions"), values: binding.openQuestions)
                if outcome.seriesID != nil || outcome.invitation != nil {
                    GroupBox(L("Series history")) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(data.seriesOutcomes(invitation: outcome.invitation, series: outcome.seriesID)) { item in
                                Button { selectedID = item.id } label: {
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
                ForEach(values.wrappedValue.indices, id: \.self) { index in
                    HStack(alignment: .top) {
                        TextField(title, text: values[index], axis: .vertical).textFieldStyle(.plain)
                        Button { values.wrappedValue.remove(at: index) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help(L("Delete line"))
                    }
                }
                Button(L("Add line")) { values.wrappedValue.append("") }
            }.frame(maxWidth: .infinity, alignment: .leading)
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
