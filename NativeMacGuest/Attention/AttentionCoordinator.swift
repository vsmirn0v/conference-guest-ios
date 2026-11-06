import AVFoundation
import ConferenceCore
import Foundation

/// The system's memory pressure, so a judge on this Mac can step aside.
final class AttentionMemoryPressure: @unchecked Sendable {
    static let shared = AttentionMemoryPressure()
    private let lock = NSLock()
    private var level: DispatchSource.MemoryPressureEvent = .normal
    private let source: DispatchSourceMemoryPressure
    var pressured: Bool { lock.lock(); defer { lock.unlock() }; return level.contains(.warning) || level.contains(.critical) }
    private init() {
        source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let event = source.data
            lock.lock(); level = event; lock.unlock()
            probeLog("attention-memory-pressure", ["warning": event.contains(.warning), "critical": event.contains(.critical)])
        }
        source.activate()
    }
}

/// Judges every meeting you are not looking at and raises a card when one needs
/// you. One judge call runs at a time across meetings, at most six a minute.
@MainActor final class AttentionCoordinator: ObservableObject {
    struct Card: Identifiable, Equatable {
        /// The decision this card shows.
        let id: UUID
        let meetingID: UUID
        let meetingTitle: String
        let invitation: URL
        let seriesID: String?
        let verdict: AttentionVerdict
        let window: AttentionWindow
        let presetID: UUID?
        let threshold: Double
        let provider: String
        let model: String
        let latency: TimeInterval
        let createdAt: Date
        /// How you can answer from the card; empty when replies are off or the meeting accepts none.
        var channels = ReplyChannels()
        var draft: ReplyDraft?
        /// The provider may draft; otherwise the card offers reactions only.
        var canDraft = true
        /// The meeting can play a spoken reply ("Say it").
        var canSpeak = false
        var speaking = false
        var drafting = false
        var draftError: String?
        var evidence: [AttentionWindow.Line] { verdict.evidence.compactMap { window.line(id: $0) } }
        /// You are working on a reply: a newer verdict does not replace the card.
        var engaged: Bool { draft != nil || drafting || speaking }
    }
    struct MeetingState: Equatable {
        var verdict: AttentionVerdict?
        var judgedAt: Date?
        var fingerprint: String?
        var seenLines: Set<String> = []
        var shownEvidence: Set<String> = []
        var heldUntil: Date?
        var paused = false
        var error: String?
        var participants: Set<String>?
        var changes: [(name: String, joined: Bool, at: Date)] = []
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.verdict == rhs.verdict && lhs.judgedAt == rhs.judgedAt && lhs.fingerprint == rhs.fingerprint &&
            lhs.paused == rhs.paused && lhs.error == rhs.error && lhs.heldUntil == rhs.heldUntil
        }
    }

    static let interval: TimeInterval = 20
    static let holdNow: TimeInterval = 120
    static let callsPerMinute = 6
    static let maxCards = 2
    /// A judge on this Mac costs nothing per call: plugged in and cool, it checks twice as often.
    static let localInterval: TimeInterval = 10
    static let localCallsPerMinute = 12

    @Published private(set) var cards: [Card] = []
    @Published private(set) var states: [UUID: MeetingState] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var judging: UUID?

    let store: AttentionStore
    var meetings: () -> [NativeDesktopMeetingModel] = { [] }
    /// The meeting is in front of you: the judge leaves it alone.
    var isOnScreen: (NativeDesktopMeetingModel) -> Bool = { _ in false }
    var power: () -> NativeDesktopPowerSnapshot = NativeDesktopPowerSnapshot.current
    var thermalState: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }
    var memoryPressured: () -> Bool = { AttentionMemoryPressure.shared.pressured }
    /// The judge runs on this Mac and the Mac can afford more frequent checks.
    var fastLocal: Bool {
        store.provider.onThisMac && power().pluggedIn && [.nominal, .fair].contains(thermalState()) && !memoryPressured()
    }
    var interval: TimeInterval { fastLocal ? Self.localInterval : Self.interval }
    var callsPerMinuteLimit: Int { fastLocal ? Self.localCallsPerMinute : Self.callsPerMinute }
    /// The meeting produces text: the service transcribes it, or this Mac does.
    var hasTranscript: (NativeDesktopMeetingModel) -> Bool = { $0.transcriptionIndicator == .on || $0.transcriptionIndicator == .local }
    var openMeeting: (UUID) -> Void = { _ in }
    var notify: (Card) -> Void = { _ in }
    var makeJudge: (AttentionProvider, String?) -> any AttentionJudge = { OpenAIChatJudge(provider: $0, key: $1) }
    var makeWriter: (AttentionProvider, String?) -> any ReplyWriter = { OpenAIChatJudge(provider: $0, key: $1) }
    /// What the meeting accepts from you right now.
    var replyChannels: (NativeDesktopMeetingModel) -> ReplyChannels = { model in
        ReplyChannels(chat: model.chat.canSend, reactions: model.canReact ? MeetingReaction.allCases : [])
    }
    /// Sends through the meeting's own chat; false when it did not accept the text.
    var deliverChat: (NativeDesktopMeetingModel, String) -> Bool = { $0.chat.send($1) }
    var deliverReaction: (NativeDesktopMeetingModel, MeetingReaction) -> Void = { $0.sendReaction($1) }
    /// The meeting can take a spoken reply (voice replies are on and it joined with them).
    var voiceAvailable: (NativeDesktopMeetingModel) -> Bool = { $0.supportsVoiceReply }
    var deliverVoice: (NativeDesktopMeetingModel, AVAudioPCMBuffer) async throws -> Void = { try await $0.speak($1) }
    /// Replaces the configured voice, for tests.
    var synthesizeOverride: ((String) async throws -> AVAudioPCMBuffer)?
    var now: () -> Date = Date.init
    var language: String = Bundle.main.preferredLocalizations.first ?? "en"

    private var loop: Task<Void, Never>?
    private var calls: [Date] = []

    init(store: AttentionStore = .shared) { self.store = store }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stop() { loop?.cancel(); loop = nil }
    deinit { loop?.cancel() }

    // MARK: Sheets

    /// A room (and the calendar series it was joined from) whose instructions are edited.
    struct PresetTarget: Identifiable, Equatable {
        let id = UUID()
        let invitation: URL
        var latest: URL? = nil
        var seriesID: String? = nil
        let title: String
    }
    @Published var inspecting: Card?
    @Published var editingPreset: PresetTarget?
    func editInstructions(for model: NativeDesktopMeetingModel) {
        editingPreset = .init(invitation: model.invitation, seriesID: model.calendarSeriesID, title: model.title)
    }

    // MARK: Queries for views

    func card(for meetingID: UUID) -> Card? { cards.first { $0.meetingID == meetingID } }
    func state(for meetingID: UUID) -> MeetingState? { states[meetingID] }
    func isPaused(_ meetingID: UUID) -> Bool { states[meetingID]?.paused == true }
    func setPaused(_ paused: Bool, meetingID: UUID) {
        states[meetingID, default: .init()].paused = paused
        if paused { cards.removeAll { $0.meetingID == meetingID } }
    }

    /// Why a meeting is not judged right now, or nil when it is.
    func waitingReason(_ model: NativeDesktopMeetingModel) -> String? {
        if !store.enabled { return L("Attention is off.") }
        if !store.ready { return L("Finish setting up the judge in Settings → Intelligence.") }
        if isPaused(model.sessionID) { return L("Paused for this meeting.") }
        if !model.connected { return L("Not connected.") }
        if !hasTranscript(model) {
            return L("No transcript: turn on transcription on this Mac or in the meeting.")
        }
        if store.pauseOnBattery && !power().pluggedIn { return L("Paused on battery power.") }
        // A judge on this Mac competes with the meetings for heat, energy and memory.
        if store.provider.onThisMac {
            if [.serious, .critical].contains(thermalState()) { return L("Paused while this Mac is hot.") }
            if power().lowPowerMode { return L("Paused in Low Power Mode.") }
            if memoryPressured() { return L("Paused while this Mac is low on memory.") }
        }
        if isOnScreen(model) { return L("You are looking at this meeting.") }
        return nil
    }
    func eligible(_ model: NativeDesktopMeetingModel) -> Bool { !model.isClosed && waitingReason(model) == nil }

    // MARK: Ticking

    /// Observes every meeting, drops stale cards, and judges at most one meeting.
    func tick() async {
        let current = now(), list = meetings()
        let ids = Set(list.map(\.sessionID))
        states = states.filter { ids.contains($0.key) }
        cards.removeAll { card in
            guard let model = list.first(where: { $0.sessionID == card.meetingID }) else { return true }
            return isOnScreen(model) || model.isClosed
        }
        for model in list { observeParticipants(model, now: current) }
        guard judging == nil else { return }
        calls.removeAll { current.timeIntervalSince($0) > 60 }
        guard calls.count < callsPerMinuteLimit else { return }
        var best: (model: NativeDesktopMeetingModel, window: AttentionWindow, trigger: Bool, last: Date)?
        for model in list where eligible(model) {
            let state = states[model.sessionID] ?? .init()
            let window = buildWindow(model, state: state, now: current)
            guard !window.isEmpty, window.fingerprint != state.fingerprint else { continue }
            let fresh = window.lines.filter { !state.seenLines.contains($0.id) }
            let trigger = fresh.contains { $0.mentionsYou && !$0.isYou } ||
                state.changes.contains { !$0.joined && $0.at > (state.judgedAt ?? .distantPast) }
            let last = state.judgedAt ?? .distantPast
            guard trigger || current.timeIntervalSince(last) >= interval else { continue }
            if let chosen = best, (chosen.trigger && !trigger) || (chosen.trigger == trigger && chosen.last <= last) { continue }
            best = (model, window, trigger, last)
        }
        guard let best else { return }
        await judge(best.model, window: best.window, at: current)
    }

    private func observeParticipants(_ model: NativeDesktopMeetingModel, now: Date) {
        guard model.connected else { return }
        let names = Set(model.participants.filter { !$0.isLocal }.map(\.name))
        var state = states[model.sessionID] ?? .init()
        if let previous = state.participants {
            for name in names.subtracting(previous) { state.changes.append((name, true, now)) }
            for name in previous.subtracting(names) { state.changes.append((name, false, now)) }
        }
        state.participants = names
        state.changes.removeAll { now.timeIntervalSince($0.at) > AttentionWindowBuilder.span }
        if states[model.sessionID] == nil || states[model.sessionID]?.participants != names || !state.changes.isEmpty {
            states[model.sessionID] = state
        }
    }

    func buildWindow(_ model: NativeDesktopMeetingModel, state: MeetingState? = nil, now: Date? = nil) -> AttentionWindow {
        let state = state ?? states[model.sessionID] ?? .init()
        return AttentionWindowBuilder.build(.init(title: model.title, transcript: model.transcript, chat: model.chat.items,
            reactions: model.chat.reactionHistory.events, participantCount: model.participants.count,
            joined: state.changes.filter(\.joined).map(\.name), left: state.changes.filter { !$0.joined }.map(\.name),
            yourNames: store.profile.names(fallback: model.displayName), microphoneOn: model.snapshot.microphoneOn,
            soundOn: model.snapshot.playoutOn, now: now ?? self.now()))
    }

    private func judge(_ model: NativeDesktopMeetingModel, window: AttentionWindow, at time: Date) async {
        let id = model.sessionID
        judging = id; calls.append(time)
        defer { judging = nil }
        let preset = store.preset(room: model.invitation, series: model.calendarSeriesID)
        let channels = store.draftReplies && (preset?.repliesAllowed ?? true) ? replyChannels(model) : ReplyChannels()
        let request = JudgeRequest(window: window, preset: preset, profile: store.profile, yourName: model.displayName,
                                   language: language, replyChannels: channels)
        let provider = store.provider
        let decisionID = UUID()
        do {
            let result = try await makeJudge(provider, store.apiKey()).judge(request)
            guard let model = meetings().first(where: { $0.sessionID == id }), !model.isClosed else { return }
            var state = states[id] ?? .init()
            state.verdict = result.verdict; state.judgedAt = now(); state.fingerprint = window.fingerprint; state.error = nil
            state.seenLines.formUnion(window.lines.map(\.id))
            lastError = nil
            let threshold = preset?.threshold ?? AttentionUrgency.normal.baseThreshold
            let card = Card(id: decisionID, meetingID: id, meetingTitle: model.title, invitation: model.invitation,
                seriesID: model.calendarSeriesID, verdict: result.verdict, window: window, presetID: preset?.id, threshold: threshold,
                provider: provider.host, model: provider.model, latency: result.latency, createdAt: now(), channels: channels,
                canDraft: store.draftsAllowed, canSpeak: store.draftReplies && (preset?.repliesAllowed ?? true) && voiceAvailable(model))
            let shown = apply(card, state: &state)
            // The judge suggests answering in writing: have a draft ready on the card.
            if shown, card.canDraft, [.chat, .reaction].contains(result.verdict.action), !channels.isEmpty,
               calls.filter({ now().timeIntervalSince($0) <= 60 }).count < callsPerMinuteLimit {
                draftReply(decisionID)
            }
            states[id] = state
            store.log(.init(id: decisionID, at: now(), meetingTitle: model.title, presetID: preset?.id, window: window, verdict: result.verdict,
                provider: provider.host, model: provider.model, latencyMilliseconds: Int(result.latency * 1000),
                outcome: shown ? .shown : .belowThreshold, messages: AttentionPrompt.messages(request), threshold: threshold))
            probeLog("attention-verdict", ["level": result.verdict.level.rawValue, "probability": result.verdict.probability,
                "lines": window.lines.count, "latencyMs": Int(result.latency * 1000), "shown": shown])
        } catch is CancellationError {
            return
        } catch {
            var state = states[id] ?? .init()
            state.judgedAt = now(); state.error = error.localizedDescription
            states[id] = state; lastError = error.localizedDescription
            store.log(.init(id: decisionID, at: now(), meetingTitle: model.title, presetID: preset?.id, window: nil, verdict: nil,
                provider: provider.host, model: provider.model, outcome: .failed, error: String(describing: error)))
            probeLog("attention-failed", ["error": String(describing: error)])
        }
    }

    /// Shows, keeps or removes this meeting's card. "Now" holds for two minutes
    /// unless you act; a card never repeats for evidence already shown.
    private func apply(_ card: Card, state: inout MeetingState) -> Bool {
        let verdict = card.verdict, current = card.createdAt
        let existing = cards.first { $0.meetingID == card.meetingID }
        // A card you are replying from stays until you send, dismiss or decline it.
        if existing?.engaged == true { return false }
        let held = existing?.verdict.level == .now && (state.heldUntil ?? .distantPast) > current
        let qualifies = verdict.level != .no && verdict.probability >= card.threshold
        let repeated = !verdict.evidence.isEmpty && Set(verdict.evidence).isSubset(of: state.shownEvidence)
        guard qualifies, !repeated else {
            if existing != nil, !held { cards.removeAll { $0.meetingID == card.meetingID } }
            return false
        }
        if held && verdict.level < .now { return false }
        cards.removeAll { $0.meetingID == card.meetingID }
        cards.append(card)
        state.shownEvidence.formUnion(verdict.evidence)
        if verdict.level == .now { state.heldUntil = current.addingTimeInterval(Self.holdNow) }
        cards.sort { $0.verdict.level == $1.verdict.level ? $0.createdAt > $1.createdAt : $0.verdict.level > $1.verdict.level }
        if cards.count > Self.maxCards { cards.removeLast(cards.count - Self.maxCards) }
        if verdict.level == .now, cards.contains(where: { $0.id == card.id }) { notify(card) }
        return cards.contains { $0.id == card.id }
    }

    // MARK: Your decisions

    func open(_ card: Card) {
        feedback(card, decision: .approved, reason: nil, note: nil, outcome: .opened)
        openMeeting(card.meetingID)
    }
    func dismiss(_ card: Card) {
        remove(card)
        log(card, outcome: .dismissed, reason: nil)
    }
    func decline(_ card: Card, reason: PresetExample.DeclineReason, note: String? = nil) {
        feedback(card, decision: .declined, reason: reason, note: note, outcome: .declined)
    }

    // MARK: Replies

    /// Drafts a chat reply or reaction for a card. Nothing is sent: you send,
    /// edit or discard the draft on the card.
    func draftReply(_ cardID: UUID) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }), cards[index].canDraft, !cards[index].drafting,
              !cards[index].channels.isEmpty || cards[index].canSpeak,
              let model = meetings().first(where: { $0.sessionID == cards[index].meetingID }), !model.isClosed else { return }
        let card = cards[index]
        cards[index].drafting = true; cards[index].draftError = nil
        calls.append(now())
        let preset = card.presetID.flatMap(store.preset(id:))
        // A reply that can be spoken is written like a chat message.
        var channels = card.channels
        if card.canSpeak { channels.chat = true }
        let request = ReplyRequest(judge: JudgeRequest(window: card.window, preset: preset, profile: store.profile,
            yourName: model.displayName, language: language, replyChannels: channels), verdict: card.verdict)
        let provider = store.effectiveWriter, writer = makeWriter(provider, store.apiKey())
        Task { @MainActor [weak self] in
            do {
                let result = try await writer.draft(request)
                guard let self, let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
                cards[index].drafting = false; cards[index].draft = result.draft
                store.log(.init(at: now(), meetingTitle: card.meetingTitle, presetID: card.presetID, window: nil, verdict: nil,
                    provider: provider.host, model: provider.model, latencyMilliseconds: Int(result.latency * 1000), outcome: .drafted,
                    decisionID: cardID, replyMessages: ReplyPrompt.messages(request), draft: result.draft))
                probeLog("attention-draft", ["chat": !result.draft.chat.isEmpty, "reaction": result.draft.reaction != nil,
                    "latencyMs": Int(result.latency * 1000)])
            } catch {
                guard let self, let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
                cards[index].drafting = false
                if error is CancellationError { return }
                cards[index].draftError = error.localizedDescription
                store.log(.init(at: now(), meetingTitle: card.meetingTitle, presetID: card.presetID, window: nil, verdict: nil,
                    provider: provider.host, model: provider.model, outcome: .draftFailed, error: String(describing: error), decisionID: cardID))
                probeLog("attention-draft-failed", ["error": String(describing: error)])
            }
        }
    }

    /// Sends the text you approved into the meeting's chat and counts as an approval.
    @discardableResult func sendReply(_ card: Card, text: String) -> Bool {
        let clean = text.trimmed
        guard !clean.isEmpty, card.channels.chat,
              let model = meetings().first(where: { $0.sessionID == card.meetingID }), !model.isClosed, deliverChat(model, clean) else {
            setDraftError(L("The meeting did not accept the message. Open the meeting to answer."), card: card); return false
        }
        feedback(card, decision: .approved, reason: nil, note: nil, outcome: .replied,
                 sent: clean, reaction: nil, edited: clean != card.draft?.chat.trimmed)
        // A rewritten draft teaches the writer how you put things.
        if let draft = card.draft?.chat.trimmed, !draft.isEmpty, draft != clean,
           let preset = card.presetID.flatMap(store.preset(id:)) ?? store.preset(room: card.invitation, series: card.seriesID) {
            store.recordEdit(.init(at: now(), draft: draft, sent: clean), in: preset)
        }
        return true
    }

    /// Sends one reaction into the meeting and counts as an approval.
    @discardableResult func sendReaction(_ card: Card, _ reaction: MeetingReaction) -> Bool {
        guard card.channels.reactions.contains(reaction),
              let model = meetings().first(where: { $0.sessionID == card.meetingID }), !model.isClosed else {
            setDraftError(L("The meeting did not accept the reaction. Open the meeting to answer."), card: card); return false
        }
        deliverReaction(model, reaction)
        feedback(card, decision: .approved, reason: nil, note: nil, outcome: .reacted,
                 sent: nil, reaction: reaction, edited: reaction != card.draft?.reaction)
        return true
    }

    /// Speaks the text into the meeting with the chosen voice. Your microphone is held
    /// back while it plays; counts as an approval once it has played.
    func sayReply(_ card: Card, text: String) {
        let clean = text.trimmed
        guard let index = cards.firstIndex(where: { $0.id == card.id }), card.canSpeak, !clean.isEmpty, !cards[index].speaking,
              let model = meetings().first(where: { $0.sessionID == card.meetingID }), !model.isClosed else {
            setDraftError(L("This meeting cannot play a spoken reply now. Open the meeting to answer."), card: card); return
        }
        cards[index].speaking = true; cards[index].draftError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            do {
                let buffer = try await synthesize(clean)
                let synthesized = ProcessInfo.processInfo.systemUptime
                try await deliverVoice(model, buffer)
                probeLog("attention-spoken", ["voice": store.voiceEngine.rawValue, "seconds": Double(buffer.frameLength) / buffer.format.sampleRate,
                    "synthesisMs": Int((synthesized - started) * 1000)])
                feedback(card, decision: .approved, reason: nil, note: nil, outcome: .spoken,
                         sent: clean, reaction: nil, edited: clean != card.draft?.chat.trimmed)
            } catch {
                guard let index = cards.firstIndex(where: { $0.id == card.id }) else { return }
                cards[index].speaking = false
                if !(error is CancellationError) { cards[index].draftError = error.localizedDescription }
            }
        }
    }

    func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        if let synthesizeOverride { return try await synthesizeOverride(text) }
        switch store.voiceEngine {
        case .system: return try await VoiceSynthesis.system(text)
        case .rapidMLX:
            return try await VoiceSynthesis.rapidMLX(text, baseURL: store.voiceBaseURL, model: store.voiceModel, description: store.voiceDescription)
        }
    }

    private func setDraftError(_ message: String, card: Card) {
        if let index = cards.firstIndex(where: { $0.id == card.id }) { cards[index].draftError = message }
    }

    private func feedback(_ card: Card, decision: PresetExample.Decision, reason: PresetExample.DeclineReason?, note: String?,
                          outcome: AttentionDecisionRecord.Outcome, sent: String? = nil, reaction: MeetingReaction? = nil, edited: Bool? = nil) {
        remove(card)
        let preset = card.presetID.flatMap(store.preset(id:)) ??
            store.presetForFeedback(room: card.invitation, latest: nil, series: card.seriesID, title: card.meetingTitle)
        let excerpt = card.evidence.map { "\($0.speaker): \($0.text)" }.joined(separator: " / ")
        store.record(.init(at: now(), level: card.verdict.level, decision: decision, declineReason: reason, note: note,
            excerpt: excerpt.isEmpty ? card.verdict.reason : excerpt, reason: card.verdict.reason), in: preset)
        log(card, outcome: outcome, reason: reason, sent: sent, reaction: reaction, edited: edited)
    }
    private func remove(_ card: Card) {
        cards.removeAll { $0.id == card.id }
        states[card.meetingID]?.heldUntil = nil
    }
    private func log(_ card: Card, outcome: AttentionDecisionRecord.Outcome, reason: PresetExample.DeclineReason?,
                     sent: String? = nil, reaction: MeetingReaction? = nil, edited: Bool? = nil) {
        store.log(.init(at: now(), meetingTitle: card.meetingTitle, presetID: card.presetID, window: nil, verdict: nil,
            provider: card.provider, model: card.model, outcome: outcome, declineReason: reason, decisionID: card.id,
            sent: sent, reaction: reaction, edited: edited))
    }

    // MARK: Settings test

    /// Sends a fixed sample meeting to the configured provider.
    func test() async throws -> AttentionVerdict {
        let now = Date()
        let you = store.profile.name.trimmed.isEmpty ? L("Alex") : store.profile.name.trimmed
        let lines = [
            GuestMeetingMessage(id: "t1", participantID: "a", participantName: "Anna", text: L("Let's review the release plan."), sentAt: now.addingTimeInterval(-50), isOwn: false),
            GuestMeetingMessage(id: "t2", participantID: "b", participantName: "Igor", text: L("The certificates expire on Friday."), sentAt: now.addingTimeInterval(-30), isOwn: false),
            GuestMeetingMessage(id: "t3", participantID: "a", participantName: "Anna", text: L("%@, can you confirm the DNS switch is ready? We are waiting for you.", you), sentAt: now.addingTimeInterval(-10), isOwn: false),
        ]
        let window = AttentionWindowBuilder.build(.init(title: L("Sample meeting"), transcript: lines, chat: [], reactions: [],
            participantCount: 3, yourNames: store.profile.names(fallback: you), microphoneOn: false, soundOn: false, now: now))
        let request = JudgeRequest(window: window, preset: nil, profile: store.profile, yourName: you, language: language)
        return try await makeJudge(store.provider, store.apiKey()).judge(request).verdict
    }
}
