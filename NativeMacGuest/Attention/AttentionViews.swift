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
    var openAssistant: () -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(attention.cards) { card in AttentionCardView(attention: attention, card: card) }
            if !attention.overflowMomentIDs.isEmpty {
                Button(action: openAssistant) {
                    Label(L("+%ld in Assistant", attention.overflowMomentIDs.count), systemImage: "tray.full")
                        .font(.callout.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 8)
                        .background(.regularMaterial, in: Capsule())
                }.buttonStyle(.plain).accessibilityIdentifier("attention.overflow")
            }
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
            if !card.readOnly, (!card.channels.isEmpty || card.canSpeak) && !declining { AttentionReplyView(attention: attention, card: card) }
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
                    if !card.readOnly {
                        Button(L("Open meeting")) { attention.open(card) }.buttonStyle(.borderedProminent)
                            .disabled(card.speaking)
                            .keyboardShortcut(card.draft == nil ? .defaultAction : nil)
                    }
                    Button(L("Why")) { attention.inspecting = card }
                    Spacer(minLength: 4)
                    if !card.readOnly, card.verdict.level == .soon {
                        Button(L("Dismiss")) { attention.dismiss(card) }.buttonStyle(.borderless).disabled(card.speaking)
                    }
                    if !card.readOnly {
                        Button(L("Decline")) { declining = true }.buttonStyle(.borderless).foregroundStyle(.red).disabled(card.speaking)
                    }
                }
            }
        }
        .padding(12).frame(width: 380, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(card.verdict.level.color).frame(width: 4).padding(.vertical, 10) }
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain).accessibilityIdentifier("attention.card")
        .onChange(of: card.id) { _ in declining = false; note = "" }
        .onChange(of: card.readOnly) { readOnly in if readOnly { declining = false; note = "" } }
    }
}

/// Ranked drafted replies and a reaction on a card. Choosing a stance only puts
/// its text in the editor; Send, Say it, or a reaction is always a separate act.
struct AttentionReplyView: View {
    @ObservedObject var attention: AttentionCoordinator
    let card: AttentionCoordinator.Card
    @State private var text = ""
    @State private var edited = false
    @State private var customHint = ""
    @State private var showsCustomHint = false

    /// A text field when there is a draft, or when you can only write or speak the reply yourself.
    private var showsField: Bool {
        card.draft != nil || (!card.canDraft && (card.channels.chat || card.canSpeak))
    }
    private var variants: [ReplyVariant] { Array(card.draft?.availableVariants.prefix(3) ?? []) }
    private var usual: ReplyVariant? {
        guard let preferred = attention.store.assistant.preferredStance(), let first = variants.first,
              preferred.caseInsensitiveCompare(first.stance) == .orderedSame else { return nil }
        return first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if card.drafting || card.speaking {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(card.speaking ? L("Speaking the reply into the meeting…") : L("Drafting a reply…")).font(.caption).foregroundStyle(.secondary)
                }
            } else {
                if variants.count > 1 {
                    HStack(spacing: 5) {
                        ForEach(variants) { variant in variantButton(variant) }
                    }
                }
                if showsField {
                    TextField(card.channels.chat ? L("Reply in the meeting chat") : L("Reply to say in the meeting"), text: $text, axis: .vertical)
                        .lineLimit(1...4).textFieldStyle(.roundedBorder).accessibilityIdentifier("attention.reply")
                        .onChange(of: text) { value in edited = value != (card.draft?.chat ?? "") }
                }
                HStack(spacing: 6) {
                    if showsField && card.channels.chat {
                        Button(L("Send")) { attention.sendReply(card, text: text) }
                            .buttonStyle(.borderedProminent).disabled(text.trimmed.isEmpty)
                            .accessibilityLabel(L("Send")).accessibilityIdentifier("attention.reply.send")
                            .keyboardShortcut(.return, modifiers: .command).help(L("Send this message to the meeting chat (⌘↩)"))
                    }
                    if showsField && card.canSpeak {
                        Button { attention.sayReply(card, text: text) } label: { Label(L("Say it"), systemImage: "speaker.wave.2") }
                            .disabled(text.trimmed.isEmpty)
                            .keyboardShortcut(.return, modifiers: .option)
                            .help(L("Speak this reply into the meeting; your microphone is held back while it plays (⌥↩)"))
                    }
                    if let reaction = card.draft?.reaction {
                        Button(reaction.emoji) { attention.sendReaction(card, reaction) }.help(L("Send this reaction"))
                    }
                    if !card.channels.reactions.isEmpty { reactionMenu }
                    Spacer(minLength: 4)
                    if card.canDraft {
                        if card.draft == nil {
                            Button(card.channels.chat || card.canSpeak ? L("Draft a reply") : L("Suggest a reaction")) { attention.draftReply(card.id) }
                                .controlSize(.small)
                        } else {
                            Menu {
                                Button(L("Shorter")) { redraft(L("Make it shorter.")) }
                                Button(L("Firmer")) { redraft(L("Make it firmer and more direct.")) }
                                Button(L("In English")) { redraft(L("Write the reply in English.")) }
                                Button(L("Custom direction…")) { showsCustomHint.toggle() }
                                Divider()
                                Button(L("Redraft")) { redraft(nil) }
                            } label: { Text(L("More…")) }
                                .menuStyle(.borderlessButton).fixedSize().controlSize(.small)
                        }
                    }
                }
                if showsCustomHint && card.canDraft {
                    HStack(spacing: 6) {
                        TextField(L("How should the reply change?"), text: $customHint)
                            .textFieldStyle(.roundedBorder).controlSize(.small)
                            .onSubmit { redraft(customHint) }
                        Button(L("Redraft")) { redraft(customHint) }.controlSize(.small).disabled(customHint.trimmed.isEmpty)
                    }
                }
            }
            if let error = card.draftError { Text(error).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        }
        .onAppear { text = card.draft?.chat ?? "" }
        .onChange(of: card.draft) { draft in if !edited { text = draft?.chat ?? "" } }
    }

    private func variantButton(_ variant: ReplyVariant) -> some View {
        Button {
            edited = false; text = variant.text
            attention.selectVariant(variant, for: card)
        } label: {
            HStack(spacing: 4) {
                Text(variant.stance).lineLimit(1)
                if variant.id == usual?.id { Text(L("Your usual")).font(.caption2).foregroundStyle(.secondary) }
            }
        }
        .buttonStyle(.bordered)
        .background(variant.text == card.draft?.chat ? Color.accentColor.opacity(0.16) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 6))
        .controlSize(.small).accessibilityIdentifier("attention.reply.variant")
    }

    private func redraft(_ hint: String?) {
        edited = false; showsCustomHint = false
        attention.draftReply(card.id, hint: hint)
    }

    private var reactionMenu: some View {
        Menu {
            ForEach(card.channels.reactions, id: \.self) { reaction in
                Button(reaction.emoji) { attention.sendReaction(card, reaction) }
            }
        } label: { Image(systemName: "face.smiling") }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel(L("Send a reaction")).help(L("Send a reaction"))
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
            GroupBox(L("Memory used")) {
                VStack(alignment: .leading, spacing: 5) {
                    if card.memory.isEmpty {
                        Text(L("No local memory excerpts were included.")).foregroundStyle(.secondary)
                    } else {
                        ForEach(card.memory) { excerpt in
                            Text("\(excerpt.kind.title): \(excerpt.text)").font(.callout).textSelection(.enabled)
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
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
                if !card.readOnly {
                    Button(L("Edit instructions")) {
                        attention.inspecting = nil
                        attention.editingPreset = .init(invitation: card.invitation, seriesID: card.seriesID, title: card.meetingTitle)
                    }
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
    @State private var tuning: ThresholdTuner.Result?
    @State private var tuneMessage: String?

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
                    Picker(L("Attention"), selection: $preset.mode) {
                        Text(L("By situation")).tag(AttentionMode?.none)
                        ForEach(AttentionMode.allCases, id: \.self) { Text($0.title).tag(AttentionMode?.some($0)) }
                    }
                    Picker(L("Urgency"), selection: $preset.urgency) {
                        Text(L("Quiet")).tag(AttentionUrgency.quiet); Text(L("Normal")).tag(AttentionUrgency.normal); Text(L("Eager")).tag(AttentionUrgency.eager)
                    }.pickerStyle(.segmented)
                    Text(L("Threshold %.2f. Your approvals lower it and declines raise it.", preset.threshold)).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Draft chat replies and reactions for this meeting"),
                           isOn: Binding(get: { preset.repliesAllowed }, set: { preset.suggestReplies = $0 }))
                    if target.seriesID != nil { Toggle(L("Use for every meeting in this calendar series"), isOn: $appliesToSeries) }
                }
                Section(L("Learned from you")) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button(L("Tune threshold from your choices")) { tune() }
                            if let tuning, abs(tuning.threshold - preset.threshold) > 0.001 {
                                Button(L("Use %.2f", tuning.threshold)) { applyTuning(tuning) }
                            }
                        }
                        if let tuneMessage { Text(tuneMessage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
                    }
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
    /// Replays this meeting's saved verdicts under every threshold and finds the one
    /// that matches your Open, reply, reaction and Decline choices best.
    private func tune() {
        let cases = ComparisonLoader.load(store.decisionFiles()).cases.filter { $0.presetID == preset.id }
        tuning = ThresholdTuner.best(cases, current: preset.threshold)
        if let tuning {
            tuneMessage = L("At %.2f the judge's saved verdicts match %ld of your %ld choices here; at the current %.2f, %ld.",
                            tuning.threshold, tuning.agreed, tuning.labelled, preset.threshold, tuning.currentAgreed)
        } else {
            tuneMessage = L("Needs at least %ld cards here that you opened, answered or declined, with both kinds among them.", ThresholdTuner.minimumChoices)
        }
    }
    private func applyTuning(_ result: ThresholdTuner.Result) {
        let base = preset.urgency.baseThreshold
        preset.thresholdAdjustment = min(MeetingPreset.thresholdRange.upperBound - base, max(MeetingPreset.thresholdRange.lowerBound - base, result.threshold - base))
        tuneMessage = L("Threshold set to %.2f. Save to keep it.", preset.threshold)
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

/// Whether Rapid-MLX answers on this Mac and has the chosen model, with the
/// commands to install and start it when it does not.
struct RapidMLXStatusView: View {
    @ObservedObject var store: AttentionStore
    /// Rapid-MLX serves one model and lists it by its full name, not the alias the judge sends.
    enum Status: Equatable { case checking, running(serving: String?), stopped(String) }
    @State private var status = Status.checking

    static let installCommands = """
    python3 -m venv ~/.rapid-mlx/venv
    ~/.rapid-mlx/venv/bin/pip install "rapid-mlx[audio]==1.0.1"
    ~/.rapid-mlx/venv/bin/rapid-mlx --no-telemetry serve qwen3.5-4b-4bit --host 127.0.0.1 --port 8000 --enable-audio
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                switch status {
                case .checking: ProgressView().controlSize(.small); Text(L("Checking Rapid-MLX…")).foregroundStyle(.secondary)
                case .running(let serving):
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(L("Rapid-MLX is running with %@.", serving ?? store.provider.model))
                case .stopped: Image(systemName: "xmark.circle.fill").foregroundStyle(.red); Text(L("Rapid-MLX does not answer at %@.", store.provider.host))
                }
                Spacer()
                Button(L("Check again")) { Task { await check() } }.controlSize(.small)
            }.font(.callout)
            if case .stopped = status {
                Text(L("Install it once, then start it (needs Python 3.12 or later):")).font(.caption).foregroundStyle(.secondary)
                Text(Self.installCommands).font(.caption.monospaced()).textSelection(.enabled)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        .task(id: store.provider.baseURL + store.provider.model) { await check() }
    }

    private func check() async {
        status = .checking
        do {
            let models = try await AttentionModelCatalog.fetch(store.provider, key: nil)
            status = .running(serving: models.first { $0.id == store.provider.model }?.id ?? models.first?.id)
        } catch { status = .stopped(error.localizedDescription) }
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

/// Settings → Assistant: attention, models, memory, voice and what leaves this Mac.
struct NativeDesktopIntelligenceSettings: View {
    @ObservedObject var store: AttentionStore
    @ObservedObject var attention: AttentionCoordinator
    @State private var key = ""
    @State private var writerKey = ""
    @State private var escalationKey = ""
    @State private var aliases = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var choosingModel = false
    @State private var comparing = false
    @State private var previewing = false
    @State private var voiceMessage: String?
    @State private var voiceFailed = false
    @ObservedObject private var listen = ListenModelStore.shared
    @ObservedObject private var clone = VoiceCloneStore.shared

    /// Provider and model as one line; the Apple judge has no model name to show.
    private func describe(_ provider: AttentionProvider) -> String {
        provider.kind == .apple || provider.model.trimmed.isEmpty ? provider.title : provider.title + " · " + provider.model
    }
    private func roleRow(_ role: String, _ value: String, local: Bool, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(role).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(local ? L("On this Mac") : L("Cloud")).font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundStyle(local ? Color.green : Color.blue)
                .overlay(Capsule().stroke(local ? Color.green : Color.blue, lineWidth: 1))
        }
    }
    /// The key for another role's provider, when it is not the judge's kind.
    @ViewBuilder private func keyField(for provider: AttentionProvider, text: Binding<String>) -> some View {
        if provider.needsKey && provider.kind != store.provider.kind {
            HStack {
                SecureField(store.hasKey(for: provider) ? L("Saved in the keychain") : L("API key for %@", provider.title), text: text)
                Button(L("Save")) { store.setAPIKey(text.wrappedValue, for: provider); text.wrappedValue = "" }
                    .disabled(text.wrappedValue.trimmed.isEmpty)
                if store.hasKey(for: provider) { Button(L("Remove")) { store.setAPIKey("", for: provider) } }
            }
        }
    }
    private var voiceTitle: String {
        switch store.voiceEngine {
        case .system: L("The macOS voice")
        case .rapidMLX: L("Rapid-MLX on this Mac") + " · " + store.voiceModel
        case .personal: L("Your Personal Voice")
        case .cloned: L("Your voice, on the Neural Engine")
        }
    }

    var body: some View {
        Form {
            Section(L("Attention")) {
                Toggle(L("Tell me when a meeting needs me"), isOn: $store.enabled).accessibilityIdentifier("attention.enabled")
                Text(L("While you are in several meetings, a judge model reads the last three minutes of each meeting you are not looking at and shows a card when one needs you. It needs a transcript: turn on Transcription, or use the meeting's own.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(L("Pause on battery power"), isOn: $store.pauseOnBattery)
                Toggle(L("Create a meeting outcome when I leave"), isOn: $store.generateOutcomes)
                    .accessibilityIdentifier("assistant.outcomes")
                Text(L("Outcomes keep an editable summary, decisions, tasks and open questions on this Mac. Nothing is shared automatically."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error = attention.lastError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Section {
                AttentionSituationDefaults(store: store)
                Text(L("Mentions: a card when someone names you or asks you directly, and only urgent ones otherwise. Watch: also when the discussion concerns you. A meeting's own choice, from its row, its control bar or its instructions, comes first.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text(L("Attention by situation")) }
                .disabled(!store.enabled)
            Section(L("Roles")) {
                roleRow(L("Listen"), listen.enabled ? (listen.selected?.title ?? L("Off")) : L("Off"), local: true,
                        detail: L("%@ of speech models on this Mac", ByteCountFormatter.string(fromByteCount: listen.installedSize, countStyle: .file)))
                roleRow(L("Judge"), describe(store.provider), local: store.provider.onThisMac)
                if let strong = store.escalationProvider {
                    roleRow(L("When unsure"), describe(strong), local: strong.onThisMac)
                }
                roleRow(L("Write"), describe(store.effectiveWriter), local: store.effectiveWriter.onThisMac)
                roleRow(L("Voice"), voiceTitle, local: true)
            }
            Section(L("About you")) {
                TextField(L("Your name"), text: $store.profile.name, prompt: Text(L("As people say it in meetings")))
                TextField(L("Other names"), text: $aliases, prompt: Text(L("Nicknames, separated by commas")))
                    .onSubmit(saveAliases).onChange(of: aliases) { _ in saveAliases() }
                TextField(L("Your role"), text: $store.profile.role, prompt: Text(L("For example: infrastructure lead, owns DNS and certificates")))
            }
            Section(L("Models")) {
                Picker(L("Provider"), selection: Binding(get: { store.provider.kind }, set: { kind in
                    if kind != store.provider.kind { store.provider = AttentionProvider.defaults[kind] ?? store.provider }
                })) { ForEach(AttentionProvider.Kind.allCases, id: \.self) { Text(AttentionProvider.defaults[$0]?.title ?? $0.rawValue).tag($0) } }
                if store.provider.kind == .apple {
                    Text(L("Apple's on-device model judges here. Meetings in a language it does not know, such as Russian, are translated to English on this Mac first; the card's reason and drafted replies are translated back.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = AppleOnDeviceJudge.unavailableReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                } else {
                    TextField(L("Address"), text: $store.provider.baseURL)
                    if store.provider.endpoint == nil { Text(L("Enter an http or https address.")).font(.caption).foregroundStyle(.red) }
                    HStack {
                        TextField(L("Model"), text: $store.provider.model)
                        Button(L("Choose…")) { choosingModel = true }.disabled(store.provider.endpoint == nil)
                            .help(L("Pick from the models this provider offers"))
                    }
                }
                if store.provider.kind == .rapidMLX { RapidMLXStatusView(store: store) }
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
                        .disabled(store.provider.endpoint == nil || store.provider.needsKey && !store.hasKey || store.provider.kind == .apple)
                        .help(L("Run your saved decisions through another model and see how it agrees with your choices"))
                    Button(testing ? L("Testing…") : L("Test")) { runTest() }.disabled(testing || !store.ready && !(store.provider.configured && (!store.provider.needsKey || store.hasKey)))
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(testFailed ? Color.red : .secondary).lineLimit(3) }
                }
                Picker(L("When the judge is unsure, ask"), selection: Binding(get: { store.escalationProvider?.kind }, set: { kind in
                    store.escalationProvider = kind.flatMap { AttentionProvider.defaults[$0] }
                })) {
                    Text(L("Nobody")).tag(AttentionProvider.Kind?.none)
                    ForEach(AttentionProvider.Kind.allCases.filter { $0 != .custom && $0 != store.provider.kind }, id: \.self) { kind in
                        Text(AttentionProvider.defaults[kind]?.title ?? kind.rawValue).tag(AttentionProvider.Kind?.some(kind))
                    }
                }
                if let strong = store.escalationProvider {
                    if strong.kind != .apple {
                        TextField(L("Model to ask"), text: Binding(get: { store.escalationProvider?.model ?? "" },
                                                                   set: { store.escalationProvider?.model = $0 }))
                    }
                    keyField(for: strong, text: $escalationKey)
                    if strong.needsKey && !store.hasKey(for: strong) {
                        Text(L("Asking needs an API key for %@.", strong.title)).font(.caption).foregroundStyle(.orange)
                    }
                    Text(L("When the first judge's probability is between 0.35 and 0.65, the same text goes to this one and its answer decides the card. The decision log keeps both answers.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
                Picker(L("Write replies with"), selection: Binding(get: { store.writerProvider?.kind }, set: { kind in
                    store.writerProvider = kind.flatMap { AttentionProvider.defaults[$0] }
                })) {
                    Text(L("The judge's provider")).tag(AttentionProvider.Kind?.none)
                    ForEach(AttentionProvider.Kind.allCases.filter { $0 != .custom }, id: \.self) { kind in
                        Text(AttentionProvider.defaults[kind]?.title ?? kind.rawValue).tag(AttentionProvider.Kind?.some(kind))
                    }
                }.disabled(!store.draftReplies)
                if let kind = store.writerProvider?.kind, kind != .apple {
                    TextField(L("Writer model"), text: Binding(get: { store.writerProvider?.model ?? "" },
                                                              set: { store.writerProvider?.model = $0 }))
                        .disabled(!store.draftReplies)
                    keyField(for: store.effectiveWriter, text: $writerKey)
                    if store.effectiveWriter.needsKey && !store.hasKey(for: store.effectiveWriter) {
                        Text(L("The writer needs an API key for %@.", store.effectiveWriter.title)).font(.caption).foregroundStyle(.orange)
                    }
                }
                if store.effectiveWriter.onThisMac {
                    Toggle(L("Draft with the model on this Mac anyway"), isOn: $store.localDrafts).disabled(!store.draftReplies)
                    Text(L("Small models on this Mac judge well, but in tests they answered questions for you (confirmed things, chose options). While the judge runs here, cards offer reactions only unless you turn this on.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("Memory")) {
                AssistantMemorySettings(attention: attention)
            }
            Section(L("Voice")) {
                Toggle(L("Hold ⌥Space to talk to Assistant"), isOn: $store.pushToTalk)
                    .accessibilityIdentifier("assistant.pushToTalk")
                Text(L("While held, your microphone is held back from the meeting and speech is recognized only on this Mac. You can also type every command."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle(L("Speak Assistant answers in headphones"), isOn: $store.talkBack)
                    .accessibilityIdentifier("assistant.talkBack")
                Text(L("Off by default. Answers play only when the Mac's output is explicitly a headphone data source, never into a meeting."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker(L("Speak replies with"), selection: $store.voiceEngine) {
                    Text(L("The macOS voice")).tag(VoiceEngine.system)
                    Text(L("Rapid-MLX on this Mac")).tag(VoiceEngine.rapidMLX)
                    Text(L("Your Personal Voice")).tag(VoiceEngine.personal)
                    if clone.available || store.voiceEngine == .cloned {
                        Text(L("Your voice, on the Neural Engine")).tag(VoiceEngine.cloned)
                    }
                }
                if store.voiceEngine == .cloned {
                    if clone.available {
                        VoiceCloneSettingsView(clone: clone, listen: listen)
                    } else {
                        Text(VoiceSynthesisError.cloneUnsupported.localizedDescription).font(.caption).foregroundStyle(.orange)
                    }
                }
                if store.voiceEngine == .personal {
                    Text(L("Uses the Personal Voice you created in System Settings → Accessibility. macOS asks once whether this app may use it. It speaks the language it was recorded in.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.voiceEngine == .rapidMLX {
                    TextField(L("Voice model"), text: $store.voiceModel)
                    TextField(L("How the voice sounds"), text: $store.voiceDescription, axis: .vertical).lineLimit(1...3)
                    TextField(L("Address"), text: $store.voiceBaseURL)
                    Text(L("Start Rapid-MLX with --enable-audio. The first reply loads the voice model and takes longer.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(previewing ? L("Preparing…") : L("Listen")) { previewVoice() }.disabled(previewing)
                    if let voiceMessage { Text(voiceMessage).font(.caption).foregroundStyle(voiceFailed ? Color.red : .secondary).lineLimit(3) }
                }
                Text(L("“Say it” on a card speaks the reply into that meeting while your microphone is held back. It needs Voice replies (experimental) in Settings → General, for meetings joined after turning it on. Listen plays only on this Mac.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section(L("What leaves this Mac")) {
                if store.provider.onThisMac {
                    Label(store.provider.kind == .apple ? L("The judge runs on this Mac: meeting text, instructions and your profile stay here.")
                          : L("The judge runs on this Mac at %@: meeting text, instructions and your profile stay here.", store.provider.host), systemImage: "laptopcomputer")
                } else {
                    Label(L("For each meeting you are not looking at: its last three minutes of text and chat, its instructions and your profile go to %@, at most six times a minute.", store.provider.host), systemImage: "arrow.up.forward")
                }
                if let strong = store.escalationProvider, !strong.onThisMac {
                    Label(L("When the judge is unsure, the same text goes to %@.", strong.host), systemImage: "arrow.up.forward")
                }
                if store.draftsAllowed {
                    if store.effectiveWriter.onThisMac {
                        Label(L("Replies are drafted on this Mac. What you send goes to the meeting, as if you typed it."), systemImage: "text.bubble")
                    } else {
                        Label(L("Drafting a reply sends the same meeting text and the judge's reason to %@. What you send goes to the meeting, as if you typed it.", store.effectiveWriter.host), systemImage: "text.bubble")
                    }
                }
                Label(L("Judge and reply requests include up to five relevant excerpts from the Memory shown above; they go to the configured provider."), systemImage: "brain")
                if store.generateOutcomes {
                    if store.effectiveWriter.onThisMac {
                        Label(L("Meeting outcomes and Since then summaries are created on this Mac."), systemImage: "doc.text")
                    } else {
                        Label(L("Creating a meeting outcome or Since then summary sends the meeting transcript and chat to %@.", store.effectiveWriter.host), systemImage: "arrow.up.forward")
                    }
                }
                if !store.provider.onThisMac {
                    Label(L("Typed and locally recognized commands send your request and current meeting and Moment names to %@.", store.provider.host), systemImage: "arrow.up.forward")
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

    private func previewVoice() {
        previewing = true; voiceMessage = nil
        Task { @MainActor in
            defer { previewing = false }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let buffer = try await attention.synthesize(L("I'm in another meeting right now, I'll answer in a couple of minutes."))
                try VoicePreviewPlayer.shared.play(buffer)
                voiceFailed = false
                voiceMessage = L("Ready in %.1f s.", ProcessInfo.processInfo.systemUptime - started)
            } catch { voiceFailed = true; voiceMessage = error.localizedDescription }
        }
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
