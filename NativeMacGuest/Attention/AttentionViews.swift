import AppKit
import ConferenceCore
import SwiftUI

extension AttentionLevel {
    var title: String { switch self { case .now: L("Now"); case .soon: L("Soon"); case .no: L("Quiet") } }
    var color: Color { switch self { case .now: .red; case .soon: .orange; case .no: .secondary } }
}

/// Cards for meetings that need you, over the main window's content.
struct AttentionCardStack: View {
    @ObservedObject var attention: AttentionCoordinator
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(attention.cards) { card in AttentionCardView(attention: attention, card: card) }
        }
        .padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .animation(.easeOut(duration: 0.2), value: attention.cards.map(\.id))
    }
}

struct AttentionCardView: View {
    @ObservedObject var attention: AttentionCoordinator
    let card: AttentionCoordinator.Card
    @State private var declining = false
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(card.verdict.level.title.uppercased()).font(.caption2.weight(.bold)).foregroundStyle(.white)
                    .padding(.horizontal, 6).padding(.vertical, 2).background(card.verdict.level.color, in: RoundedRectangle(cornerRadius: 4))
                Text(L("“%@” needs you", card.meetingTitle)).font(.headline).lineLimit(1)
                Spacer(minLength: 4)
                Text(card.createdAt, style: .time).font(.caption).foregroundStyle(.secondary)
            }
            Text(card.verdict.reason).fixedSize(horizontal: false, vertical: true)
            ForEach(card.evidence.prefix(2), id: \.id) { line in
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 2)
                    (Text(line.speaker).fontWeight(.semibold) + Text(" — " + line.text)).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                }.fixedSize(horizontal: false, vertical: true)
            }
            if !card.channels.isEmpty && !declining { AttentionReplyView(attention: attention, card: card) }
            if declining {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("Why not?")).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        ForEach([PresetExample.DeclineReason.notUrgent, .wrongMeeting, .alreadyKnown], id: \.self) { reason in
                            Button(reason.title) { attention.decline(card, reason: reason) }.controlSize(.small)
                        }
                    }
                    HStack(spacing: 6) {
                        TextField(L("Other reason"), text: $note).textFieldStyle(.roundedBorder).controlSize(.small)
                            .onSubmit { attention.decline(card, reason: .other, note: note) }
                        Button(L("Save")) { attention.decline(card, reason: .other, note: note) }.controlSize(.small).disabled(note.trimmed.isEmpty)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    Button(L("Open meeting")) { attention.open(card) }.buttonStyle(.borderedProminent)
                        .keyboardShortcut(card.draft == nil ? .defaultAction : nil)
                    Button(L("Why")) { attention.inspecting = card }
                    Spacer(minLength: 4)
                    if card.verdict.level == .soon { Button(L("Dismiss")) { attention.dismiss(card) }.buttonStyle(.borderless) }
                    Button(L("Decline")) { declining = true }.buttonStyle(.borderless).foregroundStyle(.red)
                }
            }
        }
        .padding(12).frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(card.verdict.level.color).frame(width: 4).padding(.vertical, 10) }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain).accessibilityIdentifier("attention.card")
    }
}

/// A drafted chat reply and reaction on a card. Nothing is sent until you press
/// Send or a reaction; you can edit the text first.
struct AttentionReplyView: View {
    @ObservedObject var attention: AttentionCoordinator
    let card: AttentionCoordinator.Card
    @State private var text = ""
    @State private var edited = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.drafting {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(L("Drafting a reply…")).font(.caption).foregroundStyle(.secondary)
                }
            } else if let draft = card.draft {
                if card.channels.chat {
                    TextField(L("Reply in the meeting chat"), text: $text, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("attention.reply")
                        .onChange(of: text) { value in edited = value != draft.chat }
                }
                HStack(spacing: 6) {
                    if card.channels.chat {
                        Button(L("Send")) { attention.sendReply(card, text: text) }
                            .buttonStyle(.borderedProminent).disabled(text.trimmed.isEmpty)
                            .keyboardShortcut(.return, modifiers: .command).help(L("Send this message to the meeting chat (⌘↩)"))
                    }
                    if let reaction = draft.reaction {
                        Button(reaction.emoji) { attention.sendReaction(card, reaction) }.help(L("Send this reaction"))
                    }
                    if card.channels.reactions.count > 1 { reactionMenu }
                    Spacer(minLength: 4)
                    Button(L("Redraft")) { edited = false; attention.draftReply(card.id) }.buttonStyle(.borderless).controlSize(.small)
                }
            } else {
                HStack(spacing: 6) {
                    Button(card.channels.chat ? L("Draft a reply") : L("Suggest a reaction")) { attention.draftReply(card.id) }.controlSize(.small)
                    if card.channels.reactions.count > 1 { reactionMenu }
                }
            }
            if let error = card.draftError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { text = card.draft?.chat ?? "" }
        .onChange(of: card.draft) { draft in if !edited { text = draft?.chat ?? "" } }
    }

    private var reactionMenu: some View {
        Menu {
            ForEach(card.channels.reactions, id: \.self) { reaction in
                Button(reaction.emoji) { attention.sendReaction(card, reaction) }
            }
        } label: { Image(systemName: "face.smiling") }
            .menuStyle(.borderlessButton).fixedSize().help(L("Send a reaction"))
    }
}

extension PresetExample.DeclineReason {
    var title: String {
        switch self { case .notUrgent: L("Not urgent"); case .wrongMeeting: L("Not for me"); case .alreadyKnown: L("I already know"); case .other: L("Other") }
    }
}

/// The sidebar row's badge: the latest card for a meeting.
struct AttentionBadge: View {
    @ObservedObject var attention: AttentionCoordinator
    let meetingID: UUID
    var body: some View {
        if let card = attention.card(for: meetingID) {
            Text(card.verdict.level.title).font(.caption2.weight(.bold)).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1).background(card.verdict.level.color, in: Capsule())
                .help(card.verdict.reason).accessibilityLabel(L("Needs you: %@", card.verdict.reason))
        } else if attention.judging == meetingID {
            ProgressView().controlSize(.mini).help(L("Checking whether this meeting needs you"))
        }
    }
}

/// What the judge saw and why it decided as it did.
struct AttentionInspector: View {
    @ObservedObject var attention: AttentionCoordinator
    let card: AttentionCoordinator.Card
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Why “%@” was judged “%@”", card.meetingTitle, card.verdict.level.title)).font(.title3.weight(.semibold))
                Text(L("%@ · %@ · probability %.2f, threshold %.2f · %.1f s", card.provider, card.model,
                       card.verdict.probability, card.threshold, card.latency)).font(.caption).foregroundStyle(.secondary)
            }
            GroupBox(L("Reason")) { Text(card.verdict.reason).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            GroupBox(L("What the judge read")) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(card.window.lines, id: \.id) { line in lineRow(line, cited: card.verdict.evidence.contains(line.id)) }
                        if card.window.lines.isEmpty { Text(L("Nothing was said.")).foregroundStyle(.secondary) }
                    }
                }.frame(minHeight: 120, maxHeight: 260)
            }
            if let preset = card.presetID.flatMap(attention.store.preset(id:)) {
                GroupBox(L("Instructions used")) {
                    VStack(alignment: .leading, spacing: 4) {
                        if !preset.matters.trimmed.isEmpty { Text(L("Matters: %@", preset.matters)) }
                        if !preset.never.trimmed.isEmpty { Text(L("Never: %@", preset.never)) }
                        Text(L("%ld approved and %ld declined examples", preset.examples.filter { $0.decision == .approved }.count,
                               preset.examples.filter { $0.decision == .declined }.count)).foregroundStyle(.secondary)
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text(L("This meeting has no instructions yet. The judge used only your profile.")).font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button(L("Edit instructions")) {
                    attention.inspecting = nil
                    attention.editingPreset = .init(invitation: card.invitation, seriesID: card.seriesID, title: card.meetingTitle)
                }
                Button(L("Copy for support")) { copyForSupport() }
                Spacer()
                if attention.cards.contains(where: { $0.id == card.id }) {
                    Button(L("This was wrong"), role: .destructive) { attention.decline(card, reason: .other, note: L("Marked wrong in the inspector")); dismiss() }
                }
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 560)
    }

    private func lineRow(_ line: AttentionWindow.Line, cited: Bool) -> some View {
        let speaker: String = line.speaker + (line.isYou ? " (" + L("you") + ")" : "")
        let source: String = line.source == .chat ? " [" + L("chat") + "]" : ""
        let reference = Text(line.ref + "  ").foregroundColor(.secondary)
        let name = Text(speaker).fontWeight(.semibold)
        let body = Text(source + ": " + line.text)
        return (reference + name + body)
            .font(.callout).padding(.horizontal, 4).padding(.vertical, 2)
            .background(cited ? Color.orange.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
    }

    /// The window, verdict and settings as JSON. The API key is never included.
    private func copyForSupport() {
        struct Report: Encodable { let meeting: String; let provider: String; let model: String; let latency: Double
            let threshold: Double; let verdict: AttentionVerdict; let window: AttentionWindow }
        let report = Report(meeting: card.meetingTitle, provider: card.provider, model: card.model, latency: card.latency,
                            threshold: card.threshold, verdict: card.verdict, window: card.window)
        let encoder = JSONEncoder.attention; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Instructions for one room, optionally shared with its calendar series.
struct MeetingPresetEditor: View {
    @ObservedObject var store: AttentionStore
    let target: AttentionCoordinator.PresetTarget
    @Environment(\.dismiss) private var dismiss
    @State private var preset: MeetingPreset
    @State private var people: String
    @State private var appliesToSeries: Bool

    init(store: AttentionStore, target: AttentionCoordinator.PresetTarget) {
        self.store = store; self.target = target
        let existing = store.preset(room: target.invitation, latest: target.latest, series: target.seriesID)
            ?? MeetingPreset(title: target.title, bindings: [.room(target.invitation.absoluteString)])
        _preset = State(initialValue: existing)
        _people = State(initialValue: existing.people.joined(separator: ", "))
        _appliesToSeries = State(initialValue: target.seriesID.map { existing.bindings.contains(.calendarSeries($0)) } ?? false)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Instructions for “%@”", target.title)).font(.title3.weight(.semibold))
                Text(L("The judge reads these with the meeting's last three minutes. They stay on this Mac and are sent only to your judge provider.")).font(.caption).foregroundStyle(.secondary)
            }.padding([.horizontal, .top], 20)
            Form {
                Section {
                    field(L("What this meeting is about"), text: $preset.about, prompt: L("Weekly infrastructure sync. Anna leads."))
                    field(L("What matters to me"), text: $preset.matters, prompt: L("DNS cut-over, certificates, decisions that need my sign-off."))
                    TextField(L("People to listen for"), text: $people, prompt: Text(L("Names separated by commas")))
                    field(L("Never"), text: $preset.never, prompt: L("Budget questions are not mine."))
                    Picker(L("Urgency"), selection: $preset.urgency) {
                        Text(L("Quiet")).tag(AttentionUrgency.quiet); Text(L("Normal")).tag(AttentionUrgency.normal); Text(L("Eager")).tag(AttentionUrgency.eager)
                    }.pickerStyle(.segmented)
                    Text(L("Threshold %.2f. Your approvals lower it and declines raise it.", preset.threshold)).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Draft chat replies and reactions for this meeting"),
                           isOn: Binding(get: { preset.repliesAllowed }, set: { preset.suggestReplies = $0 }))
                    if target.seriesID != nil { Toggle(L("Use for every meeting in this calendar series"), isOn: $appliesToSeries) }
                }
                Section(L("Learned from you")) {
                    if preset.examples.isEmpty {
                        Text(L("Approve or decline cards and they appear here.")).foregroundStyle(.secondary)
                    }
                    ForEach(preset.examples.reversed()) { example in
                        HStack(alignment: .top) {
                            Image(systemName: example.decision == .approved ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(example.decision == .approved ? Color.green : Color.red)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(example.excerpt).lineLimit(2)
                                Text([example.at.formatted(date: .abbreviated, time: .shortened), example.declineReason?.title, example.note]
                                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button { preset.examples.removeAll { $0.id == example.id } } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help(L("Forget this example"))
                        }
                    }
                }
            }.formStyle(.grouped)
            HStack {
                if store.preset(id: preset.id) != nil {
                    Button(L("Delete instructions"), role: .destructive) { store.delete(preset.id); dismiss() }
                }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Save")) { save(); dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(width: 560, height: 640)
    }

    private func field(_ title: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text, prompt: Text(prompt), axis: .vertical).lineLimit(2...5)
        }
    }
    private func save() {
        var value = preset
        value.people = people.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        value.title = target.title
        var bindings = value.bindings.filter { if case .calendarSeries = $0 { false } else { true } }
        if !bindings.contains(.room(target.invitation.absoluteString)) { bindings.append(.room(target.invitation.absoluteString)) }
        if appliesToSeries, let series = target.seriesID { bindings.append(.calendarSeries(series)) }
        else { bindings += value.bindings.filter { if case .calendarSeries(let id) = $0 { id != target.seriesID } else { false } } }
        value.bindings = bindings
        store.save(value)
    }
}

/// The provider's model list, searchable. Models that list structured output come first.
struct AttentionModelPicker: View {
    @ObservedObject var store: AttentionStore
    /// The model shown as chosen and what a pick does; by default it becomes the judge's model.
    var chosen: String? = nil
    var onSelect: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var models: [AttentionModelInfo] = []
    @State private var query = ""
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Models at %@", store.provider.host)).font(.title3.weight(.semibold))
            TextField(L("Search models"), text: $query).textFieldStyle(.roundedBorder).accessibilityIdentifier("attention.models.search")
            Group {
                if loading {
                    ProgressView(L("Loading models…")).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 10) {
                        Text(error).foregroundStyle(.red).multilineTextAlignment(.center)
                        Button(L("Try again")) { Task { await load() } }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let shown = AttentionModelCatalog.filter(models, query: query)
                    List(shown) { model in
                        Button {
                            if let onSelect { onSelect(model.id) } else { store.provider.model = model.id }
                            dismiss()
                        } label: { row(model) }.buttonStyle(.plain)
                    }.overlay { if shown.isEmpty { Text(L("No models match.")).foregroundStyle(.secondary) } }
                }
            }.frame(minHeight: 360)
            HStack {
                if !loading, error == nil { Text(L("%ld models", models.count)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }.padding(20).frame(width: 560, height: 520)
            .task { await load() }
    }

    private func row(_ model: AttentionModelInfo) -> some View {
        let chosen = model.id == (self.chosen ?? store.provider.model)
        var details: [String] = []
        if let context = model.contextLength { details.append(L("%ld K context", context / 1000)) }
        if let price = model.promptPrice { details.append(price == 0 ? L("free") : L("$%.2f per million input tokens", price)) }
        if model.structuredOutput == false { details.append(L("no structured output")) }
        return HStack(alignment: .top) {
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle").foregroundStyle(chosen ? Color.accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name ?? model.id).fontWeight(chosen ? .semibold : .regular)
                Text(([model.name == nil ? nil : model.id] + details).compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }.contentShape(Rectangle()).padding(.vertical, 2)
            .opacity(model.structuredOutput == false ? 0.6 : 1)
    }

    private func load() async {
        loading = true; error = nil
        do { models = try await AttentionModelCatalog.fetch(store.provider, key: store.apiKey()) }
        catch { self.error = error.localizedDescription }
        loading = false
    }
}

/// Settings → Intelligence: the judge, your profile and what leaves this Mac.
struct NativeDesktopIntelligenceSettings: View {
    @ObservedObject var store: AttentionStore
    @ObservedObject var attention: AttentionCoordinator
    @State private var key = ""
    @State private var aliases = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var choosingModel = false
    @State private var comparing = false

    var body: some View {
        Form {
            Section {
                Toggle(L("Tell me when a meeting needs me"), isOn: $store.enabled).accessibilityIdentifier("attention.enabled")
                Text(L("While you are in several meetings, a judge model reads the last three minutes of each meeting you are not looking at and shows a card when one needs you. It needs a transcript: turn on Transcription, or use the meeting's own.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Pause on battery power"), isOn: $store.pauseOnBattery)
                if let error = attention.lastError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Section(L("About you")) {
                TextField(L("Your name"), text: $store.profile.name, prompt: Text(L("As people say it in meetings")))
                TextField(L("Other names"), text: $aliases, prompt: Text(L("Nicknames, separated by commas")))
                    .onSubmit(saveAliases).onChange(of: aliases) { _ in saveAliases() }
                TextField(L("Your role"), text: $store.profile.role, prompt: Text(L("For example: infrastructure lead, owns DNS and certificates")))
            }
            Section(L("Judge")) {
                Picker(L("Provider"), selection: Binding(get: { store.provider.kind }, set: { kind in
                    if kind != store.provider.kind { store.provider = AttentionProvider.defaults[kind] ?? store.provider }
                })) { ForEach(AttentionProvider.Kind.allCases, id: \.self) { Text(AttentionProvider.defaults[$0]?.title ?? $0.rawValue).tag($0) } }
                TextField(L("Address"), text: $store.provider.baseURL)
                if store.provider.endpoint == nil { Text(L("Enter an http or https address.")).font(.caption).foregroundStyle(.red) }
                HStack {
                    TextField(L("Model"), text: $store.provider.model)
                    Button(L("Choose…")) { choosingModel = true }.disabled(store.provider.endpoint == nil)
                        .help(L("Pick from the models this provider offers"))
                }
                if store.provider.needsKey {
                    HStack {
                        SecureField(store.hasKey ? L("Saved in the keychain") : L("API key"), text: $key).accessibilityIdentifier("attention.key")
                        Button(L("Save")) { store.setAPIKey(key); key = "" }.disabled(key.trimmed.isEmpty)
                        if store.hasKey { Button(L("Remove")) { store.setAPIKey("") } }
                    }
                    Text(L("The key is stored in this Mac's keychain and sent only to the address above.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(L("Compare models…")) { comparing = true }
                        .disabled(store.provider.endpoint == nil || store.provider.needsKey && !store.hasKey)
                        .help(L("Run your saved decisions through another model and see how it agrees with your choices"))
                    Button(testing ? L("Testing…") : L("Test")) { runTest() }.disabled(testing || !store.ready && !(store.provider.endpoint != nil && (!store.provider.needsKey || store.hasKey)))
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(testFailed ? Color.red : .secondary).lineLimit(3) }
                }
            }
            Section(L("Replies")) {
                Toggle(L("Draft chat replies and reactions on cards"), isOn: $store.draftReplies).accessibilityIdentifier("attention.replies")
                Text(L("When a meeting that needs you accepts chat or reactions, the card offers a short reply written by the same model. Nothing is sent until you press Send or a reaction, and you can edit the text first.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L("How you write"), text: Binding(get: { store.profile.replyStyle ?? "" },
                                                           set: { store.profile.replyStyle = $0.trimmed.isEmpty ? nil : $0 }),
                          prompt: Text(L("For example: brief and informal, no emoji")))
                    .disabled(!store.draftReplies)
            }
            Section(L("What leaves this Mac")) {
                Label(L("For each meeting you are not looking at: its last three minutes of text and chat, its instructions and your profile go to %@, at most six times a minute.", store.provider.host), systemImage: "arrow.up.forward")
                if store.draftReplies {
                    Label(L("Drafting a reply sends the same text and the judge's reason once more. What you send goes to the meeting, as if you typed it."), systemImage: "text.bubble")
                }
                Label(L("Audio never leaves this Mac."), systemImage: "lock")
                Label(L("Decisions are kept on this Mac for 30 days so you can see why a card appeared."), systemImage: "clock")
            }.font(.callout)
            Section(L("Meeting instructions")) {
                if store.presets.isEmpty { Text(L("Add instructions from a meeting's or favorite's menu.")).foregroundStyle(.secondary) }
                ForEach(store.presets) { preset in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(preset.title)
                            Text(L("%ld examples · threshold %.2f", preset.examples.count, preset.threshold)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Edit")) {
                            if case .room(let room)? = preset.bindings.first(where: { if case .room = $0 { true } else { false } }), let url = URL(string: room) {
                                attention.editingPreset = .init(invitation: url, seriesID: preset.bindings.compactMap { if case .calendarSeries(let id) = $0 { id } else { nil } }.first, title: preset.title)
                            }
                        }
                        Button(L("Delete"), role: .destructive) { store.delete(preset.id) }.buttonStyle(.borderless)
                    }
                }
                if let warning = store.persistenceWarning { Text(warning).font(.caption).foregroundStyle(.red) }
            }
        }.formStyle(.grouped)
            .onAppear { aliases = store.profile.aliases.joined(separator: ", ") }
            .sheet(isPresented: $choosingModel) { AttentionModelPicker(store: store) }
            .sheet(isPresented: $comparing) { AttentionComparisonView(store: store) }
    }

    private func saveAliases() {
        let values = aliases.split(separator: ",").map { String($0).trimmed }.filter { !$0.isEmpty }
        if values != store.profile.aliases { store.profile.aliases = values }
    }
    private func runTest() {
        testing = true; testResult = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let verdict = try await attention.test()
                testFailed = false
                testResult = L("Works: “%@”, %.2f. %@", verdict.level.title, verdict.probability, verdict.reason)
            } catch {
                testFailed = true; testResult = error.localizedDescription
            }
        }
    }
}
