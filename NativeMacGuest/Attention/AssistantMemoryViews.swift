import AppKit
import SwiftUI

/// Local People / Meetings / You memory, plus changes that need explicit review.
struct AssistantMemorySettings: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var data: AssistantDataStore
    @State private var editing: AssistantMemoryItem?
    @State private var editingSuggestion: AssistantSuggestion?
    @State private var adding = false
    @State private var confirmingDelete = false
    @State private var notice: String?

    init(attention: AttentionCoordinator) {
        self.attention = attention
        _data = ObservedObject(wrappedValue: attention.store.assistant)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Memory")).font(.title2.bold()).nativeSettingAnchor("settings.memory")
                    Text(L("Visible, editable facts on this Mac. Only the 3–5 most relevant excerpts are included in a model request."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                NativeSettingsButton(title: L("Add memory"), id: "settings.memory-add") { adding = true }
            }
            if let warning = data.loadWarning {
                HStack(alignment: .firstTextBaseline) {
                    Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Button(L("Dismiss")) { data.dismissLoadWarning() }.controlSize(.small)
                }
            }
            if let warning = data.saveWarning { Label(warning, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.secondary) }

            GroupBox(L("This week I noticed")) {
                VStack(alignment: .leading, spacing: 10) {
                    if data.suggestions.isEmpty {
                        Text(L("No suggested changes. The assistant does not add these memories or defaults without you."))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(data.suggestions) { suggestion in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(suggestion.text).font(.callout)
                            Text(suggestion.proposedText).foregroundStyle(.secondary).lineLimit(3)
                            HStack {
                                Button(L("Keep")) { attention.keepSuggestion(suggestion.id) }
                                Button(L("Edit")) { editingSuggestion = suggestion }
                                Button(L("Drop")) { data.dropSuggestion(suggestion.id) }.foregroundStyle(.red)
                            }.controlSize(.small)
                        }
                        if suggestion.id != data.suggestions.last?.id { Divider() }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }

            ForEach(AssistantMemoryKind.allCases, id: \.self) { kind in
                GroupBox(kind.title) {
                    VStack(alignment: .leading, spacing: 8) {
                        let items = data.memories.filter { $0.kind == kind }
                        if items.isEmpty { Text(L("Nothing saved here.")).foregroundStyle(.secondary) }
                        ForEach(items) { item in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.text).lineLimit(3).textSelection(.enabled)
                                    Text(L("Updated %@", item.updatedAt.formatted(date: .abbreviated, time: .shortened)))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button(L("Edit")) { editing = item }.controlSize(.small)
                                Button { data.deleteMemory(item.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help(L("Delete memory"))
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            GroupBox(L("Retention and privacy")) {
                VStack(alignment: .leading, spacing: 10) {
                    NativeSettingsPopup(
                        title: L("Keep local memory for"),
                        selection: $data.retentionDays,
                        choices: [30, 90, 365],
                        titleForChoice: { days in
                            switch days {
                            case 30: L("30 days")
                            case 90: L("90 days")
                            case 365: L("1 year")
                            default: String(days)
                            }
                        },
                        id: "settings.memory-retention"
                    )
                    .frame(maxWidth: 360)
                    Text(L("Deleting memory also removes outcomes and pending suggestions on this Mac. Decision journals and meeting instructions are managed separately."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack {
                        NativeSettingsButton(title: L("Export memory…"), id: "settings.memory-export") {
                            export()
                        }
                        NativeSettingsButton(
                            title: L("Delete all assistant memory…"),
                            role: .destructive,
                            id: "settings.memory-delete"
                        ) {
                            confirmingDelete = true
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $editing) { item in
            AssistantMemoryEditor(item: item) { data.updateMemory($0) }
        }
        .sheet(item: $editingSuggestion) { suggestion in
            AssistantSuggestionEditor(suggestion: suggestion) { text in
                attention.keepSuggestion(suggestion.id, editedText: text)
            }
        }
        .sheet(isPresented: $adding) {
            AssistantMemoryEditor(item: nil) { item in
                data.remember(item.text, kind: item.kind, invitation: item.invitation, series: item.seriesID, people: item.people)
            }
        }
        .confirmationDialog(L("Delete all assistant memory?"), isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button(L("Delete all"), role: .destructive) { data.deleteAll() }
            Button(L("Cancel"), role: .cancel) {}
        } message: { Text(L("This removes local outcomes, memories and pending suggestions. It cannot be undone.")) }
    }

    private func export() {
        do {
            let data = try data.exportData()
            let panel = NSSavePanel(); panel.nameFieldStringValue = "RockNRoll-assistant-memory.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try data.write(to: url, options: .atomic)
            notice = L("Memory exported without API keys or decision journals.")
        } catch { notice = error.localizedDescription }
    }
}

private struct AssistantMemoryEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var item: AssistantMemoryItem
    let save: (AssistantMemoryItem) -> Void

    init(item: AssistantMemoryItem?, save: @escaping (AssistantMemoryItem) -> Void) {
        let now = Date()
        _item = State(initialValue: item ?? .init(kind: .you, text: "", createdAt: now, updatedAt: now))
        self.save = save
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edit memory")).font(.title3.bold())
            LabeledContent(L("Store")) {
                NativeSegmentedControl(
                    label: L("Store"),
                    selection: $item.kind,
                    options: AssistantMemoryKind.allCases.map { .init(value: $0, title: $0.title) }
                )
            }
            TextField(L("Memory"), text: $item.text, axis: .vertical).lineLimit(4...10)
            HStack {
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Save")) { save(item); dismiss() }.keyboardShortcut(.defaultAction).disabled(item.text.trimmed.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}

private struct AssistantSuggestionEditor: View {
    @Environment(\.dismiss) private var dismiss
    let suggestion: AssistantSuggestion
    @State private var text: String
    let keep: (String) -> Void

    init(suggestion: AssistantSuggestion, keep: @escaping (String) -> Void) {
        self.suggestion = suggestion; _text = State(initialValue: suggestion.proposedText); self.keep = keep
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("Edit suggested change")).font(.title3.bold())
            Text(suggestion.text).foregroundStyle(.secondary)
            TextField(L("Suggested change"), text: $text, axis: .vertical).lineLimit(3...8)
            HStack {
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Keep")) { keep(text); dismiss() }.keyboardShortcut(.defaultAction).disabled(text.trimmed.isEmpty)
            }
        }.padding(20).frame(width: 480)
    }
}
