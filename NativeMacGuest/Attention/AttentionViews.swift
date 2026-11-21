import AppKit
import AVFoundation
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
                        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
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
                    (Text(line.speaker).fontWeight(.semibold) + Text(" — " + line.text)).font(.callout).foregroundStyle(.primary).lineLimit(3)
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
        // Shared screens can be bright white; keep the card opaque so every label stays legible.
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
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
              ReplyStance.normalize(preferred) == ReplyStance.normalize(first.stance) else { return nil }
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
                Text(variant.stanceTitle).lineLimit(1)
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
    @State private var sameRoomTransition: SameRoomMeetingTransitionMode?
    @State private var tuning: ThresholdTuner.Result?
    @State private var tuneMessage: String?

    init(store: AttentionStore, target: AttentionCoordinator.PresetTarget) {
        self.store = store; self.target = target
        let existing = store.preset(room: target.invitation, latest: target.latest, series: target.seriesID)
            ?? MeetingPreset(title: target.title, bindings: [.room(target.invitation.absoluteString)])
        _preset = State(initialValue: existing)
        _people = State(initialValue: existing.people.joined(separator: ", "))
        _appliesToSeries = State(initialValue: target.seriesID.map { existing.bindings.contains(.calendarSeries($0)) } ?? false)
        _sameRoomTransition = State(initialValue: store.savedSameRoomTransition(
            room: target.invitation, latest: target.latest, series: target.seriesID))
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
                    LabeledContent(L("Urgency")) {
                        NativeSegmentedControl(
                            label: L("Urgency"),
                            selection: $preset.urgency,
                            options: [
                                .init(value: .quiet, title: L("Quiet")),
                                .init(value: .normal, title: L("Normal")),
                                .init(value: .eager, title: L("Eager")),
                            ]
                        )
                    }
                    Text(L("Threshold %.2f. Your approvals lower it and declines raise it.", preset.threshold)).font(.caption).foregroundStyle(.secondary)
                    Toggle(L("Draft chat replies and reactions for this meeting"),
                           isOn: Binding(get: { preset.repliesAllowed }, set: { preset.suggestReplies = $0 }))
                    Picker(target.seriesID != nil ? L("Back-to-back in this series") : L("Back-to-back in this room"),
                           selection: $sameRoomTransition) {
                        Text(L("Use default")).tag(SameRoomMeetingTransitionMode?.none)
                        ForEach(SameRoomMeetingTransitionMode.allCases, id: \.self) {
                            Text($0.title).tag(SameRoomMeetingTransitionMode?.some($0))
                        }
                    }
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
        if let series = target.seriesID {
            store.setSameRoomTransition(sameRoomTransition, room: target.invitation, latest: target.latest,
                                        series: series, title: target.title)
        } else {
            value.sameRoomTransition = sameRoomTransition
        }
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
    var onSelect: ((AttentionModelInfo) -> Void)? = nil
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
                            if let onSelect { onSelect(model) } else { store.provider.adopt(model: model.id, contextLength: model.contextLength) }
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

private struct PushToTalkWarning: View {
    @ObservedObject var talk: AssistantTalkController
    var body: some View {
        if let warning = talk.hotKeyWarning {
            Text(warning).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct HeadphoneApproval: View {
    @ObservedObject var store: AttentionStore
    var output: AssistantHeadphoneRoute.Snapshot?
    var canApprove: Bool {
        guard let output else { return false }
        return !AssistantHeadphoneRoute.isHeadphoneSource(output.source) && AssistantHeadphoneRoute.isPeripheralTransport(output.transport)
    }
    var body: some View {
        if let output {
            if AssistantHeadphoneRoute.isHeadphoneSource(output.source) {
                Text(L("Headphones detected.")).font(.caption).foregroundStyle(.secondary)
            } else if canApprove {
                NativeSettingsSwitch(title: L("This is a headphone"), isOn: Binding(
                    get: { store.headphoneUIDs.contains(output.uid) }, set: { store.setHeadphoneApproved(output.uid, $0) }),
                    id: "settings.headphone-approval")
                Text(L("For a headset macOS does not report as a headphone jack. Built-in and external speakers cannot be marked."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Task-focused Assistant settings destinations. Kept in the workspace so deep
/// links, such as the voice-model status indicator, open the intended section.
enum NativeDesktopAssistantSettingsArea: String, CaseIterable, Identifiable {
    case overview, attention, voice, models, replies, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: L("Overview")
        case .attention: L("Meeting alerts")
        case .voice: L("Voice & speaking")
        case .models: L("AI providers")
        case .replies: L("Replies & actions")
        case .privacy: L("Memory & privacy")
        }
    }
}

/// Settings → Assistant: attention, models, memory, voice and what leaves this Mac.
struct NativeDesktopIntelligenceSettings: View {
    @ObservedObject var store: AttentionStore
    @ObservedObject var attention: AttentionCoordinator
    @Binding var area: NativeDesktopAssistantSettingsArea
    var directNavigation = false
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
    @State private var auditionPreviewing = false
    @State private var auditionMessage: String?
    /// A result from an earlier preview must not overwrite a newer preparation.
    @State private var voicePreviewGeneration = UUID()
    @ObservedObject private var listen = ListenModelStore.shared
    @ObservedObject private var clone = VoiceCloneStore.shared
    @StateObject private var headphones = HeadphoneOutputMonitor()

    /// Provider and model as one line; the Apple judge has no model name to show.
    private func describe(_ provider: AttentionProvider) -> String {
        let title = provider.kind == .rapidMLX && !provider.onThisMac ? L("Rapid-MLX server") : provider.title
        return provider.kind == .apple || provider.model.trimmed.isEmpty ? title : title + " · " + provider.model
    }
    private func roleRow(_ role: String, _ value: String, local: Bool, detail: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(role).frame(width: 110, alignment: .leading).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(value).lineLimit(1)
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            Text(local ? L("On this Mac") : L("External")).font(.caption2.weight(.semibold))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .foregroundStyle(local ? Color.green : Color.blue)
                .overlay(Capsule().stroke(local ? Color.green : Color.blue, lineWidth: 1))
        }
    }
    /// The key for another role's provider, when it is not the judge's kind.
    @ViewBuilder private func keyField(for provider: AttentionProvider, text: Binding<String>, id: String) -> some View {
        if provider.needsKey && provider.kind != store.provider.kind {
            HStack {
                SecureField(store.hasKey(for: provider) ? L("Saved in the keychain") : L("API key for %@", provider.title), text: text)
                    .nativeSettingAnchor(id, nativeControlFocus: true)
                Button(L("Save")) { store.setAPIKey(text.wrappedValue, for: provider); text.wrappedValue = "" }
                    .disabled(text.wrappedValue.trimmed.isEmpty)
                if store.hasKey(for: provider) { Button(L("Remove")) { store.setAPIKey("", for: provider) } }
            }
        }
    }
    private var outcomeSharingCaption: String {
        if !store.enabled { return L("Attention is off, so a meeting outcome is not sent.") }
        if !store.remoteOutcomes || !store.generateOutcomes {
            return L("The transcript is sent only when Attention is on and you allow it here.")
        }
        return L("When you leave, the transcript and chat are sent to %@.", store.effectiveWriter.host)
    }
    private var voiceTitle: String {
        switch store.voiceEngine {
        case .system: L("The macOS voice")
        case .rapidMLX: (voiceOnThisMac ? L("Rapid-MLX on this Mac") : L("Rapid-MLX voice server")) + " · " + store.voiceModel
        case .personal: L("Your Personal Voice")
        case .cloned: L("Your voice, on the Neural Engine")
        }
    }

    private var voiceSummary: String {
        guard store.voiceEngine == .cloned else { return voiceTitle }
        if clone.gpuReady, clone.preparation != .ready {
            return L("Your voice") + " · " + L("GPU fallback available")
        }
        switch clone.preparation {
        case .failed: return voiceTitle + " · " + L("Needs attention")
        case .preparing: return voiceTitle + " · " + L("Preparing…")
        case .ready: return voiceTitle + " · " + (clone.ready ? L("Ready") : L("Setup needed"))
        case .idle: return voiceTitle
        }
    }

    private var voiceOnThisMac: Bool {
        guard store.voiceEngine == .rapidMLX else { return true }
        guard let host = URL(string: store.voiceBaseURL.trimmed)?.host?.lowercased() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    private func settingsLink(_ destination: NativeDesktopAssistantSettingsArea, detail: String) -> some View {
        Button { area = destination } label: {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(destination.title)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(destination.title)
            .accessibilityHint(detail)
            .accessibilityIdentifier("assistant.settings." + destination.rawValue)
    }

    var body: some View {
        Form {
            if !directNavigation {
            Section {
                Picker(L("Assistant settings"), selection: $area) {
                    ForEach(NativeDesktopAssistantSettingsArea.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }.pickerStyle(.menu).accessibilityIdentifier("assistant.settings.section")
                if area == .overview {
                    settingsLink(.attention, detail: L("When to notify you and which meetings to follow"))
                    settingsLink(.voice, detail: voiceSummary)
                    settingsLink(.models, detail: describe(store.provider))
                    settingsLink(.replies, detail: L("Drafts, agent and meeting actions"))
                    settingsLink(.privacy, detail: L("Memory, retention and data destinations"))
                    Text(L("Meeting audio goes to participants when your microphone is on. Depending on your settings, meeting text may also go to configured providers."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            }
            if area == .attention {
            Section(L("Meeting alerts")) {
                NativeSettingsSwitch(title: L("Tell me when a meeting needs me"), isOn: $store.enabled,
                                     id: "settings.alerts", accessibilityID: "attention.enabled")
                Text(L("While you are in several meetings, a judge model reads the last three minutes of each meeting you are not looking at and shows a card when one needs you. It needs a transcript: turn on Transcription, or use the meeting's own.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                NativeSettingsSwitch(title: L("Pause on battery power"), isOn: $store.pauseOnBattery,
                                     id: "settings.battery")
                if let error = attention.lastError { Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            }
            Section {
                AttentionSituationDefaults(store: store)
                Text(L("Mentions: a card when someone names you or asks you directly, and only urgent ones otherwise. Watch: also when the discussion concerns you. A meeting's own choice, from its row, its control bar or its instructions, comes first.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text(L("Attention by situation")) }
                .disabled(!store.enabled)
            }
            if area == .models {
            Section(L("On-device models")) {
                LocalModelStatusIndicator(models: attention.localModels, settingsID: "settings.assistant-model-status")
                Text(L("Readiness and memory of the speech and voice models that run on this Mac. A model can be ready while not loaded; it loads when a meeting needs it."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Roles")) {
                roleRow(L("Speech recognition"), listen.enabled ? (listen.selected?.title ?? L("Off")) : L("Off"), local: true,
                        detail: L("%@ of speech models on this Mac", ByteCountFormatter.string(fromByteCount: listen.installedSize, countStyle: .file)))
                roleRow(L("Meeting alerts provider"), describe(store.provider), local: store.provider.onThisMac)
                if let strong = store.escalationProvider {
                    roleRow(L("When unsure"), describe(strong), local: strong.onThisMac)
                }
                roleRow(L("Writing provider"), describe(store.effectiveWriter), local: store.effectiveWriter.onThisMac)
                roleRow(L("Voice"), voiceTitle, local: voiceOnThisMac)
            }
            }
            if area == .attention {
            Section(L("About you")) {
                TextField(L("Your name"), text: $store.profile.name, prompt: Text(L("As people say it in meetings"))).nativeSettingAnchor("settings.names", nativeControlFocus: true)
                TextField(L("Other names"), text: $aliases, prompt: Text(L("Nicknames, separated by commas")))
                    .onSubmit(saveAliases).onChange(of: aliases) { _ in saveAliases() }.nativeSettingAnchor("settings.aliases", nativeControlFocus: true)
                TextField(L("Your role"), text: $store.profile.role, prompt: Text(L("For example: infrastructure lead, owns DNS and certificates"))).nativeSettingAnchor("settings.role", nativeControlFocus: true)
            }
            }
            if area == .models {
            Section(L("Models")) {
                NativeSettingsPopup(
                    title: L("Provider"),
                    selection: Binding(get: { store.provider.kind }, set: { kind in
                        if kind != store.provider.kind { store.provider = AttentionProvider.defaults[kind] ?? store.provider }
                    }),
                    choices: AttentionProvider.Kind.allCases,
                    titleForChoice: { AttentionProvider.defaults[$0]?.title ?? $0.rawValue },
                    id: "settings.provider",
                    fallbackFor: (store.provider.kind == .apple ? Set(["settings.provider-address", "settings.provider-model", "settings.provider-choose"]) : Set<String>())
                        .union(store.provider.needsKey ? [] : ["settings.api-key"])
                )
                if store.provider.kind == .apple {
                    Text(L("Apple's on-device model judges here. Meetings in a language it does not know, such as Russian, are translated to English on this Mac first; the card's reason and drafted replies are translated back.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let reason = AppleOnDeviceJudge.unavailableReason { Text(reason).font(.caption).foregroundStyle(.orange) }
                } else {
                    TextField(L("Address"), text: $store.provider.baseURL).nativeSettingAnchor("settings.provider-address", nativeControlFocus: true)
                    if store.provider.endpoint == nil { Text(L("Enter an http or https address.")).font(.caption).foregroundStyle(.red) }
                    else if !store.provider.onThisMac {
                        Text(L("When enabled, Assistant may send meeting text to %@.", store.provider.host))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        TextField(L("Model"), text: Binding(get: { store.provider.model },
                            set: { store.provider.adoptTyped($0) })).nativeSettingAnchor("settings.provider-model", nativeControlFocus: true)
                        NativeSettingsButton(title: L("Choose…"), id: "settings.provider-choose") { choosingModel = true }
                            .disabled(store.provider.endpoint == nil)
                            .help(L("Pick from the models this provider offers"))
                    }
                }
                if store.provider.kind == .rapidMLX { RapidMLXStatusView(store: store) }
                if store.provider.needsKey {
                    HStack {
                        SecureField(store.hasKey ? L("Saved in the keychain") : L("API key"), text: $key).accessibilityIdentifier("attention.key").nativeSettingAnchor("settings.api-key", nativeControlFocus: true)
                        Button(L("Save")) { store.setAPIKey(key); key = "" }.disabled(key.trimmed.isEmpty)
                        if store.hasKey { Button(L("Remove")) { store.setAPIKey("") } }
                    }
                    Text(L("The key is stored in this Mac's keychain and sent only to the address above.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    NativeSettingsButton(title: L("Compare models…"), id: "settings.provider-compare") { comparing = true }
                        .disabled(store.provider.endpoint == nil || store.provider.needsKey && !store.hasKey || store.provider.kind == .apple)
                        .help(L("Run your saved decisions through another model and see how it agrees with your choices"))
                    NativeSettingsButton(title: testing ? L("Testing…") : L("Test"), id: "settings.provider-test") { runTest() }
                        .disabled(testing || !store.ready && !(store.provider.configured && (!store.provider.needsKey || store.hasKey)))
                    if let testResult { Text(testResult).font(.caption).foregroundStyle(testFailed ? Color.red : .secondary).lineLimit(3) }
                }
                NativeSettingsPopup(
                    title: L("When the judge is unsure, ask"),
                    selection: Binding(get: { store.escalationProvider?.kind }, set: { kind in
                        store.escalationProvider = kind.flatMap { AttentionProvider.defaults[$0] }
                    }),
                    choices: [nil] + AttentionProvider.Kind.allCases
                        .filter { $0 != .custom && $0 != store.provider.kind }
                        .map(Optional.some),
                    titleForChoice: { kind in
                        guard let kind else { return L("Nobody") }
                        return AttentionProvider.defaults[kind]?.title ?? kind.rawValue
                    },
                    id: "settings.escalation",
                    fallbackFor: (store.escalationProvider == nil || store.escalationProvider?.kind == .apple ? Set(["settings.escalation-model"]) : Set<String>())
                        .union(store.escalationProvider?.needsKey == true ? [] : ["settings.escalation-key"])
                )
                if let strong = store.escalationProvider {
                    if strong.kind != .apple {
                        TextField(L("Model to ask"), text: Binding(get: { store.escalationProvider?.model ?? "" },
                                                                   set: { store.escalationProvider?.model = $0 }))
                            .nativeSettingAnchor("settings.escalation-model", nativeControlFocus: true)
                    }
                    keyField(for: strong, text: $escalationKey, id: "settings.escalation-key")
                    if strong.needsKey && !store.hasKey(for: strong) {
                        Text(L("Asking needs an API key for %@.", strong.title)).font(.caption).foregroundStyle(.orange)
                    }
                    Text(L("When the first judge's probability is between 0.35 and 0.65, the same text goes to this one and its answer decides the card. The decision log keeps both answers.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            }
            if area == .models {
            Section(L("Provider for replies and summaries")) {
                NativeSettingsPopup(
                    title: L("Provider for replies and summaries"),
                    selection: Binding(get: { store.writerProvider?.kind }, set: { kind in
                        store.writerProvider = kind.flatMap { AttentionProvider.defaults[$0] }
                    }),
                    choices: [nil] + AttentionProvider.Kind.allCases.filter { $0 != .custom }.map(Optional.some),
                    titleForChoice: { kind in
                        guard let kind else { return L("The judge's provider") }
                        return AttentionProvider.defaults[kind]?.title ?? kind.rawValue
                    },
                    id: "settings.writer",
                    fallbackFor: (store.writerProvider == nil || store.writerProvider?.kind == .apple ? Set(["settings.writer-model"]) : Set<String>())
                        .union(store.writerProvider?.needsKey != true || store.writerProvider?.kind == store.provider.kind ? ["settings.writer-key"] : [])
                )
                if let kind = store.writerProvider?.kind, kind != .apple {
                    TextField(L("Writer model"), text: Binding(get: { store.writerProvider?.model ?? "" },
                                                              set: { store.writerProvider?.adoptTyped($0) })).nativeSettingAnchor("settings.writer-model", nativeControlFocus: true)
                    keyField(for: store.effectiveWriter, text: $writerKey, id: "settings.writer-key")
                    if store.effectiveWriter.needsKey && !store.hasKey(for: store.effectiveWriter) {
                        Text(L("The writer needs an API key for %@.", store.effectiveWriter.title)).font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            }
            if area == .replies {
            Section(L("Replies")) {
                NativeSettingsSwitch(title: L("Draft chat replies and reactions on cards"), isOn: $store.draftReplies,
                                     id: "settings.drafts", fallbackFor: store.effectiveWriter.onThisMac ? [] : ["settings.local-drafts"],
                                     accessibilityID: "attention.replies")
                Text(L("When a meeting that needs you accepts chat or reactions, the card offers a short reply written by the same model. Nothing is sent until you press Send or a reaction, and you can edit the text first.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(L("How you write"), text: Binding(get: { store.profile.replyStyle ?? "" },
                                                           set: { store.profile.replyStyle = $0.trimmed.isEmpty ? nil : $0 }),
                          prompt: Text(L("For example: brief and informal, no emoji")))
                    .nativeSettingAnchor("settings.reply-style", nativeControlFocus: true).disabled(!store.draftReplies)
                settingsLink(.models, detail: L("Provider for replies and summaries") + ": " + describe(store.effectiveWriter))
                if store.effectiveWriter.onThisMac {
                    NativeSettingsSwitch(title: L("Draft with the model on this Mac anyway"), isOn: $store.localDrafts,
                                         id: "settings.local-drafts")
                        .disabled(!store.draftReplies)
                    Text(L("Small models on this Mac judge well, but in tests they answered questions for you (confirmed things, chose options). While the judge runs here, cards offer reactions only unless you turn this on.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section(L("Meeting outcomes")) {
                NativeSettingsSwitch(title: L("Create a meeting outcome when I leave"), isOn: $store.generateOutcomes,
                                     id: "settings.outcomes", fallbackFor: store.effectiveWriter.onThisMac ? ["settings.remote-outcomes"] : [],
                                     accessibilityID: "assistant.outcomes")
                Text(L("Outcomes keep an editable summary, decisions, tasks and open questions on this Mac."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if store.effectiveWriter.onThisMac {
                    Text(L("They are written on this Mac. Nothing is sent."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else {
                    NativeSettingsSwitch(title: L("Allow sending the transcript to %@ when I leave", store.effectiveWriter.host),
                                         isOn: $store.remoteOutcomes, id: "settings.remote-outcomes",
                                         accessibilityID: "assistant.outcomes.remote")
                        .disabled(!store.enabled || !store.generateOutcomes)
                    Text(outcomeSharingCaption).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                NativeSettingsPopup(
                    title: L("Back-to-back meetings in the same room"),
                    selection: $store.sameRoomTransitionDefault,
                    choices: SameRoomMeetingTransitionMode.allCases,
                    titleForChoice: \.title,
                    id: "settings.outcomes-same-room",
                    accessibilityID: "assistant.outcomes.sameRoom"
                )
                Text(L("When a new scheduled meeting starts in a room you are already connected to, Rock'N'Roll updates the meeting title and can either start a fresh summary and note or keep one combined session."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section(L("Agent")) {
                NativeSettingsSwitch(title: L("Answer with the bounded agent (typed tools, grounded sources)"),
                                     isOn: $store.agentAssistantEnabled, id: "settings.agent",
                                     fallbackFor: store.agentAssistantEnabled ? [] : ["settings.agent-mcp", "settings.meeting-sends"],
                                     accessibilityID: "assistant.agent.enabled")
                if store.agentAssistantEnabled {
                    NativeSettingsSwitch(title: L("Also offer read-only MCP tools"), isOn: $store.agentExternalToolsEnabled,
                                         id: "settings.agent-mcp", accessibilityID: "assistant.agent.externalTools")
                    NativeSettingsPopup(
                        title: L("Meeting sends"),
                        selection: $store.agentMeetingSendDefault,
                        choices: AssistantMeetingSendDefault.allCases,
                        titleForChoice: { choice in
                            switch choice {
                            case .sendImmediately: L("Send immediately")
                            case .askEveryTime: L("Ask every time")
                            }
                        },
                        id: "settings.meeting-sends",
                        accessibilityID: "assistant.agent.meetingSendDefault"
                    )
                    Text(L("Applies to direct chat, spoken replies, and reactions in the selected active meeting. Joining, leaving, muting, reminders, automation, and external (MCP) requests always ask."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(L("Off by default. Exposes the app's MCP server tools to the agent as read-only sources. Outward actions still ask natively."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            }
            if area == .privacy {
                Section(L("Memory")) { AssistantMemorySettings(attention: attention) }
            }
            if area == .voice {
            Section(L("Talk to Assistant")) {
                NativeSettingsSwitch(title: L("Hands-free “Rock” wake word"), isOn: $store.wakeWordEnabled,
                                     id: "settings.wake-word", accessibilityID: "assistant.wakeWordEnabled")
                Text(L("Always ready when you are in the app or muted in a call. Pauses automatically while your meeting microphone is unmuted or while Assistant speaks. Say “Rock, …” or “Рок, …” followed by a request."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                NativeSettingsSwitch(title: L("Hold ⌥Space to talk to Assistant"), isOn: $store.pushToTalk,
                                     id: "settings.push-talk", accessibilityID: "assistant.pushToTalk")
                Text(L("Hold it in this app or while another app is in front. While it is on, ⌥Space is not typed into any app, including as a non-breaking space. The microphone is held back from the meeting and speech is recognized on this Mac only while the key is held, and listening stops within 30 seconds if the key release is missed. You can also type every command."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                PushToTalkWarning(talk: attention.talk)
            }
            Section(L("Assistant reply voice")) {
                Picker(L("Audition voice"), selection: $store.assistantAuditionVoice) {
                    Section(L("Neural presets (VoxCPM2)")) {
                        ForEach(AssistantVoxVoicePreset.allCases) { preset in
                            Text(preset.localizedTitle).tag(AssistantAuditionVoiceSelection.voxPreset(preset))
                        }
                    }
                    Section(L("Personal & Cloned")) {
                        if clone.available {
                            Text(L("My cloned voice")).tag(AssistantAuditionVoiceSelection.clonedVoice)
                        }
                        Text(L("Personal Voice")).tag(AssistantAuditionVoiceSelection.personalVoice)
                    }
                    Section(L("macOS system voices")) {
                        Text(L("System voice (automatic)")).tag(AssistantAuditionVoiceSelection.systemVoice(identifier: ""))
                        ForEach(Self.systemVoiceChoices(), id: \.identifier) { voice in
                            Text("\(voice.name) (\(voice.language))").tag(AssistantAuditionVoiceSelection.systemVoice(identifier: voice.identifier))
                        }
                    }
                }
                .accessibilityIdentifier("assistant.auditionVoice")
                if case .voxPreset(let preset) = store.assistantAuditionVoice {
                    Text(preset.localizedSubtitle + " " + L("Uses on-device VoxCPM2 when downloaded, or falls back to the macOS voice."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                } else if store.assistantAuditionVoice == .clonedVoice && clone.stored == nil {
                    Text(L("Record your cloned voice below first, or responses will fall back to the macOS voice."))
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    NativeSettingsButton(title: auditionPreviewing ? L("Preparing…") : L("Preview assistant voice"), id: "settings.audition-preview") {
                        previewAuditionVoice()
                    }
                    .disabled(auditionPreviewing)
                    if let auditionMessage {
                        Text(auditionMessage).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                NativeSettingsSwitch(title: L("Speak voice-triggered replies aloud"), isOn: $store.autoAuditionVoiceReplies,
                                     id: "settings.auto-audition-voice", accessibilityID: "assistant.autoAuditionVoice")
                NativeSettingsSwitch(title: L("Speak typed replies aloud"), isOn: $store.autoAuditionTypedReplies,
                                     id: "settings.auto-audition-typed", accessibilityID: "assistant.autoAuditionTyped")
            }
            Section(L("Hear answers privately")) {
                let approval = HeadphoneApproval(store: store, output: headphones.output)
                NativeSettingsSwitch(title: L("Speak Assistant answers in headphones"), isOn: $store.talkBack,
                                     id: "settings.talk-back", fallbackFor: approval.canApprove ? [] : ["settings.headphone-approval"],
                                     accessibilityID: "assistant.talkBack")
                Text(L("Off by default. Answers play for a headphone jack, or for a Bluetooth or USB device you mark below. Speakers stay off, and sound never goes into a meeting."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                approval
            }
            Section(L("Speaking voice")) {
                NativeSettingsPopup(
                    title: L("Speak replies with"),
                    selection: $store.voiceEngine,
                    choices: VoiceEngine.allCases.filter { $0 != .cloned || clone.available || store.voiceEngine == .cloned },
                    titleForChoice: { choice in
                        switch choice {
                        case .system: L("The macOS voice")
                        case .rapidMLX: L("Rapid-MLX voice server")
                        case .personal: L("Your Personal Voice")
                        case .cloned: L("Your voice, on the Neural Engine")
                        }
                    },
                    id: "settings.voice-engine",
                    fallbackFor: (store.voiceEngine == .rapidMLX ? Set<String>() : ["settings.voice-model", "settings.voice-description", "settings.voice-address"])
                        .union(store.voiceEngine == .cloned && clone.available && clone.model != nil ? [] : ["settings.saved-voice", "settings.voice-preparation", "settings.voice-download", "settings.voice-delete", "settings.voice-gpu", "settings.voice-gpu-remove"])
                        .union(store.voiceEngine == .cloned && clone.available && clone.model != nil && clone.gpuModel == nil ? ["settings.voice-gpu", "settings.voice-gpu-remove"] : [])
                )
                if store.voiceEngine == .cloned {
                    if clone.available {
                        VoiceCloneSettingsView(clone: clone, listen: listen) {
                            voicePreviewGeneration = UUID()
                            voiceMessage = nil; voiceFailed = false
                        }
                    } else {
                        Text(VoiceSynthesisError.cloneUnsupported.localizedDescription).font(.caption).foregroundStyle(.orange)
                    }
                }
                if store.voiceEngine == .personal {
                    Text(L("Uses the Personal Voice you created in System Settings → Accessibility. macOS asks once whether this app may use it. It speaks the language it was recorded in.")).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.voiceEngine == .rapidMLX {
                    TextField(L("Voice model"), text: $store.voiceModel).nativeSettingAnchor("settings.voice-model", nativeControlFocus: true)
                    TextField(L("How the voice sounds"), text: $store.voiceDescription, axis: .vertical).lineLimit(1...3).nativeSettingAnchor("settings.voice-description", nativeControlFocus: true)
                    TextField(L("Address"), text: $store.voiceBaseURL).nativeSettingAnchor("settings.voice-address", nativeControlFocus: true)
                    if let host = store.voiceConfiguration.speechHost {
                        Text(L("Text for spoken replies is sent to the configured voice server at %@.", host))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Text(L("Start Rapid-MLX with --enable-audio. The first reply loads the voice model and takes longer.")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    NativeSettingsButton(title: previewing ? L("Preparing…") : L("Listen"), id: "settings.voice-preview") {
                        previewVoice()
                    }
                    .disabled(previewing)
                    if let voiceMessage { Text(voiceMessage).font(.caption).foregroundStyle(voiceFailed ? Color.red : .secondary).lineLimit(3) }
                }
                Text(L("“Say it” on a card speaks the reply into that meeting while your microphone is held back. Listen plays only on this Mac.")).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            }
            if area == .privacy {
            Section(L("What leaves this Mac")) {
                if store.provider.onThisMac {
                    Label(store.provider.kind == .apple ? L("The judge runs on this Mac: meeting text, instructions and your profile stay here.")
                          : L("The judge runs on this Mac at %@: meeting text, instructions and your profile stay here.", store.provider.host), systemImage: "laptopcomputer")
                        .nativeSettingAnchor("settings.privacy")
                } else {
                    Label(L("For each meeting you are not looking at: its last three minutes of text and chat, its instructions and your profile go to %@, at most six times a minute.", store.provider.host), systemImage: "arrow.up.forward")
                        .nativeSettingAnchor("settings.privacy")
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
                if store.effectiveWriter.onThisMac {
                    if store.generateOutcomes {
                        Label(L("Meeting outcomes and Since then summaries are created on this Mac."), systemImage: "doc.text")
                    } else {
                        Label(L("Meeting outcomes are off. Since then summaries are created on this Mac."), systemImage: "doc.text")
                    }
                } else if store.shouldCaptureOutcome {
                    Label(L("Creating a meeting outcome or Since then summary sends the meeting transcript and chat to %@.", store.effectiveWriter.host), systemImage: "arrow.up.forward")
                } else {
                    Label(L("Since then sends the transcript and chat to %@ when you ask. Leaving a meeting does not.", store.effectiveWriter.host), systemImage: "arrow.up.forward")
                }
                if !store.provider.onThisMac {
                    Label(L("Typed and locally recognized commands send your request and current meeting and Moment names to %@.", store.provider.host), systemImage: "arrow.up.forward")
                }
                Label(L("Meeting audio is sent to participants when your microphone is on. Spoken replies can also be sent to a meeting."), systemImage: "mic")
                if store.voiceEngine == .rapidMLX, let host = store.voiceConfiguration.speechHost {
                    Label(L("Text for spoken replies is sent to the configured voice server at %@.", host), systemImage: "arrow.up.forward")
                }
                Label(L("Decisions are kept on this Mac for 30 days so you can see why a card appeared."), systemImage: "clock")
            }.font(.callout)
            }
            if area == .attention {
            Section(L("Meeting instructions")) {
                Text(L("Add instructions from a meeting's or favorite's menu.")).foregroundStyle(.secondary)
                    .nativeSettingAnchor("settings.instructions")
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
            }
        }.formStyle(.grouped).nativeSettingsReveal()
            .onAppear {
                aliases = store.profile.aliases.joined(separator: ", ")
                if directNavigation && area == .overview { area = .attention }
            }
            .onChange(of: clone.preparation) { preparation in
                guard store.voiceEngine == .cloned else { return }
                switch preparation {
                case .preparing, .ready:
                    // Clear an old preview error when preparation progresses. A
                    // preview can itself start preparation, so don't cancel it.
                    if voiceFailed { voiceMessage = nil; voiceFailed = false }
                case .idle, .failed: break
                }
            }
            .onChange(of: store.voiceEngine) { _ in
                voicePreviewGeneration = UUID()
                voiceMessage = nil; voiceFailed = false
            }
            .onChange(of: area) { destination in
                if destination != .voice {
                    voicePreviewGeneration = UUID()
                    voiceMessage = nil; voiceFailed = false
                }
            }
            .onDisappear {
                voicePreviewGeneration = UUID()
            }
            .sheet(isPresented: $choosingModel) { AttentionModelPicker(store: store) }
            .sheet(isPresented: $comparing) { AttentionComparisonView(store: store) }
    }

    private func previewVoice() {
        let generation = UUID()
        voicePreviewGeneration = generation
        previewing = true; voiceMessage = nil
        Task { @MainActor in
            defer { previewing = false }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let text = L("I'm in another meeting right now, I'll answer in a couple of minutes.")
                let buffer: AVAudioPCMBuffer
                if store.voiceEngine == .cloned {
                    // ANE specialization can ignore cancellation; a GPU worker can
                    // be stopped safely when its preview expires.
                    let synthesis = Task { try await attention.synthesize(text) }
                    // GPU fallback can take substantially longer than the
                    // warm Neural Engine for the same saved-voice utterance.
                    let seconds: UInt64 = clone.preparation != .ready && clone.gpuReady ? 120 : 30
                    guard let result = await VoicePreviewWait.result(of: synthesis, timeoutNanoseconds: seconds * 1_000_000_000) else {
                        if clone.activeSpeechBackend == .gpu { synthesis.cancel() }
                        probeLog("voice-preview-deadline", ["seconds": seconds])
                        throw VoiceSynthesisError.clonePreviewWaiting
                    }
                    buffer = try result.get()
                } else {
                    buffer = try await attention.synthesize(text)
                }
                guard generation == voicePreviewGeneration else { return }
                try VoicePreviewPlayer.shared.play(buffer)
                voiceFailed = false
                voiceMessage = L("Ready in %.1f s.", ProcessInfo.processInfo.systemUptime - started)
            } catch {
                guard generation == voicePreviewGeneration else { return }
                // The model row already owns its actionable, localized failure.
                if store.voiceEngine == .cloned, !clone.ready, case .failed = clone.preparation {
                    voiceFailed = false; voiceMessage = nil
                } else {
                    voiceFailed = true; voiceMessage = error.localizedDescription
                }
            }
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

    private func previewAuditionVoice() {
        auditionPreviewing = true
        auditionMessage = nil
        let selection = store.assistantAuditionVoice
        Task { @MainActor in
            defer { auditionPreviewing = false }
            do {
                let sample = L("Hello! This is how Assistant answers sound on this Mac.")
                let buffer = try await VoiceSynthesis.audition(sample, selection: selection)
                try VoicePreviewPlayer.shared.play(buffer)
                auditionMessage = selection.localizedSummary
            } catch {
                auditionMessage = error.localizedDescription
            }
        }
    }

    private static func systemVoiceChoices() -> [AVSpeechSynthesisVoice] {
        let preferredPrefixes = ["ru", "en"]
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { voice in
                if #available(macOS 14.0, *), voice.voiceTraits.contains(.isNoveltyVoice) {
                    return false
                }
                return preferredPrefixes.contains(where: { voice.language.lowercased().hasPrefix($0) })
            }
            .sorted { lhs, rhs in
                if lhs.quality != rhs.quality { return lhs.quality.rawValue > rhs.quality.rawValue }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .prefix(12)
            .map { $0 }
    }
}

/// Compact floating HUD shown outside the Assistant tab while listening for "Рок / Rock",
/// recognizing push-to-talk, auditioning an answer, or waiting for voice action confirmation.
struct AssistantVoiceHUDView: View {
    @ObservedObject var attention: AttentionCoordinator
    @ObservedObject private var speech: AssistantSpeechInputCoordinator
    @ObservedObject private var talk: AssistantTalkController
    var openAssistant: () -> Void

    init(attention: AttentionCoordinator, openAssistant: @escaping () -> Void) {
        self.attention = attention
        self.openAssistant = openAssistant
        _speech = ObservedObject(wrappedValue: attention.speech)
        _talk = ObservedObject(wrappedValue: attention.talk)
    }

    private var isVisible: Bool {
        speech.wakeArmed
            || speech.mode == .pushToTalk
            || talk.listening
            || talk.working
            || talk.auditioningItemID != nil
            || talk.pending != nil
            || talk.agentPending != nil
    }

    var body: some View {
        if isVisible {
            HStack(spacing: 12) {
                Image(systemName: iconName)
                    .font(.title3)
                    .foregroundStyle(iconTint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.subheadline.weight(.semibold)).lineLimit(1)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if talk.pending != nil || talk.agentPending != nil {
                    Button(L("Confirm")) {
                        if talk.agentPending != nil { talk.confirmAgentPending() }
                        else { talk.confirmPending() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(L("Cancel"), role: .cancel) {
                        if talk.agentPending != nil { talk.cancelAgentPending() }
                        else { talk.cancelPending() }
                    }
                    .controlSize(.small)
                }
                if talk.auditioningItemID != nil {
                    Button(L("Stop")) { talk.stopAudition() }
                        .controlSize(.small)
                }
                Button(L("Assistant"), action: openAssistant)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.quaternary))
            .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var iconName: String {
        if talk.auditioningItemID != nil { return "speaker.wave.2.fill" }
        if talk.listening || speech.mode == .pushToTalk || speech.wakeArmed { return "waveform.circle.fill" }
        return "sparkles"
    }

    private var iconTint: Color {
        if talk.pending != nil || talk.agentPending != nil { return .orange }
        if talk.auditioningItemID != nil { return .accentColor }
        return .teal
    }

    private var headline: String {
        if let pending = talk.agentPending { return pending.title }
        if let pending = talk.pending { return pending.title }
        if talk.auditioningItemID != nil { return L("Assistant speaking") }
        if talk.working { return L("Thinking…") }
        if talk.listening || speech.mode == .pushToTalk { return L("Listening…") }
        if speech.wakeArmed { return L("Rock is listening…") }
        return L("Assistant")
    }

    private var detail: String? {
        if let pending = talk.agentPending, !pending.detail.isEmpty { return pending.detail }
        if let pending = talk.pending, !pending.detail.isEmpty { return pending.detail }
        if !speech.livePartialText.isEmpty { return speech.livePartialText }
        if talk.auditioningItemID != nil { return talk.lastVoiceAnswer }
        return nil
    }
}
