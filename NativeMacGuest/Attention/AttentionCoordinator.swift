import AVFoundation
import ConferenceCore
import Foundation
import UserNotifications

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

/// Judges each meeting as closely as its attention mode asks (by default: off for meetings
/// with sound on, closely when silenced)
/// and raises a card when one needs you. One judge call runs at a time across meetings, at most six a minute.
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
        /// Exact local excerpts given to this Moment's judge and writer.
        var memory: [AssistantMemoryExcerpt] = []
        var workspaceGuidance: [String] = []
        var workspaceGuidanceRevisions: [UUID] = []
        var workspaceWriterInput: [MeetingWorkspaceEvent.SourceSnapshot] = []
        /// Historical evidence only: no open, delivery, or learning controls.
        var readOnly = false
        var speaking = false
        var drafting = false
        var draftError: String?
        var evidence: [AttentionWindow.Line] { verdict.evidence.compactMap { window.line(id: $0) } }
        /// You are working on a reply: a newer verdict does not replace the card.
        var engaged: Bool { draft != nil || drafting || speaking }
        /// The meeting's mode when judged, and whether the window named or asked you.
        var mode: AttentionMode = .watch
        var mentioned = false
    }
    /// A mode you chose for one meeting, until you leave it or until `until`.
    struct ModeOverride: Equatable {
        var mode: AttentionMode
        var until: Date?
    }
    struct MeetingState: Equatable {
        var verdict: AttentionVerdict?
        var judgedAt: Date?
        var fingerprint: String?
        var seenLines: Set<String> = []
        var shownEvidence: Set<String> = []
        var heldUntil: Date?
        var override: ModeOverride?
        var error: String?
        var participants: Set<String>?
        var changes: [(name: String, joined: Bool, at: Date)] = []
        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.verdict == rhs.verdict && lhs.judgedAt == rhs.judgedAt && lhs.fingerprint == rhs.fingerprint &&
            lhs.override == rhs.override && lhs.error == rhs.error && lhs.heldUntil == rhs.heldUntil
        }
    }
    /// Where a meeting's current mode comes from, most specific first.
    enum ModeSource: Equatable {
        case meeting(until: Date?)
        case series
        case situation(AttentionSituation)
    }
    struct ResolvedMode: Equatable {
        let mode: AttentionMode
        let source: ModeSource
    }
    /// How long a mode you chose for one meeting lasts.
    enum ModeScope: Equatable {
        case untilLeave
        case minutes(Int)
        /// Every occurrence of this meeting: its room and calendar series.
        case series
    }

    static let interval: TimeInterval = 20
    /// In Mentions, a window nobody named you in is still checked this often for something urgent.
    static let mentionsInterval: TimeInterval = 120
    /// In Mentions, a card without your name needs a "now" verdict at least this sure.
    static let mentionsUrgency = 0.8
    static let holdNow: TimeInterval = 120
    static let callsPerMinute = 6
    static let maxCards = 2
    /// A judge on this Mac costs nothing per call: plugged in and cool, it checks twice as often.
    static let localInterval: TimeInterval = 10
    static let localCallsPerMinute = 12

    @Published private(set) var cards: [Card] = []
    /// Current qualifying cards displaced by the two-card overlay, never historical unread items.
    @Published private(set) var overflowMomentIDs: Set<UUID> = []
    /// A Moment selected in Assistant; deliberately separate from the overlay.
    @Published var selectedCard: Card?
    @Published var requestedMomentID: UUID?
    @Published private(set) var summaryByMoment: [UUID: String] = [:]
    @Published private(set) var summarizing: UUID?
    @Published private(set) var summaryErrorByMoment: [UUID: String] = [:]
    @Published private(set) var reminderErrorByMoment: [UUID: String] = [:]
    @Published private(set) var states: [UUID: MeetingState] = [:]
    @Published private(set) var lastError: String?
    @Published private(set) var judging: UUID?
    @Published private(set) var outcomeStatus: [UUID: String] = [:]
    @Published private(set) var outcomeError: [UUID: String] = [:]
    @Published var requestedOutcomeSessionID: UUID?
    @Published private(set) var workspaceFollowingPauses: [UUID: UUID] = [:]
    private var workspacePauseRevisions: [UUID: UUID] = [:]

    let store: AttentionStore
    var meetings: () -> [NativeDesktopMeetingModel] = { [] }
    /// The meeting is in front of you; its mode then follows the on-screen default (Off unless changed).
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
    var makeJudge: (AttentionProvider, String?) -> any AttentionJudge = { $0.client(key: $1) }
    var makeWriter: (AttentionProvider, String?) -> any ReplyWriter = { $0.client(key: $1) }
    var makeSummarizer: (AttentionProvider, String?) -> any MomentSummarizer = { provider, key in
        provider.client(key: key) as any MomentSummarizer
    }
    var makeOutcomeWriter: (AttentionProvider, String?) -> any MeetingOutcomeWriter = { provider, key in
        provider.client(key: key) as any MeetingOutcomeWriter
    }
    var scheduleOutcomeReminder: (MeetingOutcome, MeetingOutcomeTask, Date) async throws -> Void = { outcome, task, at in
        let content = UNMutableNotificationContent()
        content.title = L("Task from %@", outcome.meetingTitle)
        content.body = task.text
        content.sound = .default
        let request = UNNotificationRequest(identifier: "meeting-task-" + task.id.uuidString,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false))
        try await UNUserNotificationCenter.current().add(request)
    }
    var cancelTaskReminder: (UUID) -> Void = { id in
        let center = UNUserNotificationCenter.current()
        let identifier = "meeting-task-" + id.uuidString
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
    }
    var scheduleReminder: (AttentionMoment, Date) async throws -> Void = { moment, at in
        let content = UNMutableNotificationContent()
        content.title = L("Reminder: %@", moment.meetingTitle)
        content.body = moment.verdict.reason
        content.categoryIdentifier = CalendarReminderBroker.attentionCategory
        content.userInfo = ["momentID": moment.id.uuidString]
        content.sound = .default
        let request = UNNotificationRequest(identifier: "attention-reminder-" + moment.id.uuidString,
            content: content, trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, at.timeIntervalSinceNow), repeats: false))
        try await UNUserNotificationCenter.current().add(request)
    }
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
    lazy var talk = AssistantTalkController(attention: self)
    /// Readiness and residency of the local speech and voice models, for the
    /// toolbar indicator and Settings. Owns no model resources itself.
    lazy var localModels = LocalModelStatusStore(store: store)
    /// Standing automation rules (proposals, enabled/paused state, pending outward
    /// actions, audit). Persisted beside the other Attention state.
    let ruleStore: AssistantRuleStore
    /// Shared action identity/dedupe for every outward action, from agent runs and rules.
    let actionCoordinator = AssistantActionCoordinator()
    /// Future native calendar occurrences for the agent's read-only calendar tools.
    var calendarOccurrences: () -> [CalendarMeeting] = { [] }
    /// External tool source (the app's MCP loopback today; external MCP servers later).
    var externalToolProvider: (any AssistantExternalToolProviding)?

    private var loop: Task<Void, Never>?
    private var calls: [Date] = []
    private var outcomeCaptures: Set<UUID> = []
    private var overflowMeetingByMomentID: [UUID: UUID] = [:]
    private var remindingMoments: Set<UUID> = []
    private var reminderCancellationTask: Task<Void, Never>?
    /// Situation at the moment leave started. Hangup turns sound off while the
    /// meeting is still on screen; that teardown is not the user silencing it.
    private var situationAtLeave: [UUID: AttentionSituation] = [:]

    init(store: AttentionStore = .shared) {
        self.store = store
        ruleStore = AssistantRuleStore(root: store.root)
    }

    /// Feed a deterministic mention event to the rule evaluator. Mentioning never
    /// speaks by itself: a matched enabled rule only queues an outward action for
    /// the native approval path, subject to cooldown and event dedupe.
    private func handleRuleMention(model: NativeDesktopMeetingModel, fresh: [AttentionWindow.Line], at: Date) {
        guard let line = fresh.first(where: { $0.mentionsYou && !$0.isYou }) else { return }
        let event = AssistantRuleMentionEvent(id: model.sessionID.uuidString + "|" + line.id,
                                              meetingID: model.sessionID, meetingTitle: model.title, at: at,
                                              supportsVoiceReply: voiceAvailable(model),
                                              canSendChat: model.chat.canSend)
        ruleStore.handleMention(event, now: at)
    }

    /// Execute one rule-pending outward action after native approval. Expiry,
    /// double-apply and capability failures are observed states, never fallbacks.
    func executeRuleAction(_ pending: AssistantRulePendingAction) async -> String {
        guard pending.expiresAt > now() else {
            ruleStore.expirePendingActions()
            return AssistantAgentError.approvalExpired.localizedDescription ?? "Expired"
        }
        guard let model = meetings().first(where: { $0.sessionID == pending.meetingID && !$0.isClosed }),
              voiceAvailable(model) else {
            ruleStore.actionDenied(pending.id)
            return AssistantAgentError.unsupported.localizedDescription ?? "Unsupported"
        }
        let id = "rule:" + pending.id.uuidString
        let evidence: [MeetingWorkspaceEvent.SourceSnapshot] = [
            .init(id: "rule:" + pending.ruleID.uuidString, title: L("Automation rule"), text: pending.ruleText,
                  revision: String(pending.ruleRevision), capturedAt: pending.createdAt),
            .init(id: "voice:" + pending.voiceID, title: L("Voice"), text: pending.voiceID,
                  revision: nil, capturedAt: pending.createdAt),
            .init(id: "event:" + pending.eventKey, title: pending.meetingTitle, text: nil,
                  revision: pending.action.payloadHash, capturedAt: pending.createdAt),
            .init(id: "expires:" + pending.meetingID.uuidString, title: L("Approval expires"), text: nil,
                  revision: nil, capturedAt: pending.expiresAt)
        ]
        do {
            try await speakWorkspaceApprovedCommand(pending.ruleText, in: model, id: id,
                source: "ruleVoice", evidence: evidence) {
                try self.actionCoordinator.approved(pending.action)
            }
            actionCoordinator.applied(pending.action)
            ruleStore.actionExecuted(pending.id)
            return L("Spoken into “%@”.", pending.meetingTitle)
        } catch {
            actionCoordinator.failed(pending.action)
            ruleStore.actionDenied(pending.id)
            return error.localizedDescription
        }
    }

    func start() {
        guard loop == nil else { return }
        loop = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await tick()
                await reconcileTaskReminderCancellations()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
    func stop() {
        loop?.cancel(); loop = nil
        for model in meetings() { model.participation.stop() }
    }
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

    // MARK: Modes

    /// Sound off beats on screen: a meeting you look at with its sound off is one you
    /// rely on the assistant to follow, so it stays judged while visible.
    /// A meeting that is already leaving keeps the situation recorded by `noteLeave`.
    func situation(_ model: NativeDesktopMeetingModel) -> AttentionSituation {
        if model.isClosed, let kept = situationAtLeave[model.sessionID] { return kept }
        return liveSituation(model)
    }
    /// Records the situation while sound is still the user's setting. Call this
    /// before leave turns playout off. A second call keeps the first recording.
    func noteLeave(_ model: NativeDesktopMeetingModel) {
        guard !model.isClosed, situationAtLeave[model.sessionID] == nil else { return }
        situationAtLeave[model.sessionID] = liveSituation(model)
    }
    /// Drops the recording once the meeting has left the screen.
    func forgetLeave(_ meetingID: UUID) {
        situationAtLeave[meetingID] = nil
    }
    private func liveSituation(_ model: NativeDesktopMeetingModel) -> AttentionSituation {
        if !model.snapshot.playoutOn { return .silenced }
        return isOnScreen(model) ? .onScreen : .background
    }
    /// Your choice for this meeting, else its series' or room's mode, else the situation's.
    func resolvedMode(_ model: NativeDesktopMeetingModel) -> ResolvedMode {
        if workspaceFollowingPauses[model.sessionID] != nil {
            return .init(mode: .off, source: .meeting(until: nil))
        }
        if model.participation.status != .inactive {
            return .init(mode: .watch, source: .meeting(until: nil))
        }
        if let override = states[model.sessionID]?.override, (override.until ?? .distantFuture) > now() {
            return .init(mode: override.mode, source: .meeting(until: override.until))
        }
        if let mode = store.preset(room: model.invitation, series: model.calendarSeriesID)?.mode {
            return .init(mode: mode, source: .series)
        }
        let situation = situation(model)
        return .init(mode: store.mode(for: situation), source: .situation(situation))
    }
    func setMode(_ mode: AttentionMode, for model: NativeDesktopMeetingModel, scope: ModeScope = .untilLeave) {
        model.participation.stop()
        let id = model.sessionID
        workspaceFollowingPauses[id] = nil
        switch scope {
        case .untilLeave: states[id, default: .init()].override = .init(mode: mode, until: nil)
        case .minutes(let minutes): states[id, default: .init()].override = .init(mode: mode, until: now().addingTimeInterval(Double(minutes) * 60))
        case .series:
            store.setMeetingMode(mode, room: model.invitation, series: model.calendarSeriesID, title: model.title)
            states[id]?.override = nil
        }
        if mode == .off {
            for card in cards where card.meetingID == id { miss(card) }
            clearOverflow(forMeeting: id)
        }
        store.assistant.observeModeChange(mode, meetingTitle: model.title, invitation: model.invitation, series: model.calendarSeriesID, now: now())
        probeLog("attention-mode", ["mode": mode.rawValue, "scope": String(describing: scope)])
    }
    /// Drops your choice for this meeting (and its series' mode, when `series`), back to the defaults.
    func resetMode(for model: NativeDesktopMeetingModel, series: Bool = false) {
        model.participation.stop()
        workspaceFollowingPauses[model.sessionID] = nil
        states[model.sessionID]?.override = nil
        if series, store.preset(room: model.invitation, series: model.calendarSeriesID)?.mode != nil {
            store.setMeetingMode(nil, room: model.invitation, series: model.calendarSeriesID, title: model.title)
        }
        if resolvedMode(model).mode == .off {
            for card in cards where card.meetingID == model.sessionID { miss(card) }
            clearOverflow(forMeeting: model.sessionID)
        }
    }
    /// Off → Mentions → Watch → Off, for this meeting until you leave.
    func cycleMode(for model: NativeDesktopMeetingModel) {
        if model.participation.status != .inactive {
            setMode(.off, for: model)
            return
        }
        let all = AttentionMode.allCases, current = resolvedMode(model).mode
        setMode(all[((all.firstIndex(of: current) ?? 0) + 1) % all.count], for: model)
    }

    func pauseWorkspaceFollowing(_ model: NativeDesktopMeetingModel) -> UUID? {
        let id = model.sessionID
        guard !model.isClosed, workspaceFollowingPauses[id] == nil else { return nil }
        let token = UUID()
        workspaceFollowingPauses[id] = token
        workspacePauseRevisions[id] = token
        model.cancelWorkspaceApprovedOutputs()
        for card in cards where card.meetingID == id { miss(card) }
        clearOverflow(forMeeting: id)
        return token
    }

    func resumeWorkspaceFollowing(_ model: NativeDesktopMeetingModel, pause token: UUID) {
        let id = model.sessionID
        guard workspaceFollowingPauses[id] == token, !model.isClosed else { return }
        var state = states[id] ?? .init()
        let current = now()
        let window = buildWindow(model, state: state, now: current)
        state.fingerprint = window.fingerprint
        state.seenLines.formUnion(window.lines.map(\.id))
        state.judgedAt = current
        states[id] = state
        workspaceFollowingPauses[id] = nil
    }

    func workspaceInstructions(for model: NativeDesktopMeetingModel) -> [String] {
        store.workspaceGuidance.instructions(for: model) + model.participation.workspaceGuidance
    }

    private func workspaceGuidanceRevisions(for model: NativeDesktopMeetingModel) -> [UUID] {
        store.workspaceGuidance.revisions(for: model)
    }

    @discardableResult func applyWorkspaceGuidance(_ text: String, for model: NativeDesktopMeetingModel) -> Bool {
        guard model.participation.applyWorkspaceGuidance(text, for: model) else { return false }
        for card in cards where card.meetingID == model.sessionID { miss(card) }
        clearOverflow(forMeeting: model.sessionID)
        states[model.sessionID]?.fingerprint = nil
        return true
    }

    /// Why a meeting is not judged right now, or nil when it is.
    func waitingReason(_ model: NativeDesktopMeetingModel) -> String? {
        if !store.enabled { return L("Attention is off.") }
        if !store.ready { return L("Finish setting up the judge in Settings → Assistant.") }
        let resolved = resolvedMode(model)
        if resolved.mode == .off {
            switch resolved.source {
            case .meeting: return L("Off for this meeting.")
            case .series: return L("Off for every occurrence of this meeting.")
            case .situation(.onScreen): return L("You are looking at this meeting.")
            case .situation(.background): return L("Off for meetings in the background.")
            case .situation(.silenced): return L("Off for silenced meetings.")
            }
        }
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
        return nil
    }
    func eligible(_ model: NativeDesktopMeetingModel) -> Bool { !model.isClosed && waitingReason(model) == nil }

    // MARK: Outcomes and controlled learning

    /// Snapshots the conversation synchronously, then writes the outcome after leave.
    /// No model call, file I/O or await is placed on the leave-critical path.
    @discardableResult func captureOutcome(for model: NativeDesktopMeetingModel) -> Bool {
        let id = model.sessionID
        if outcomeCaptures.contains(id) { return true }
        guard store.shouldCaptureOutcome else { return false }
        let window = MeetingOutcomePrompt.window(title: model.title, transcript: model.transcript,
            chat: model.chat.items, yourName: model.displayName, now: now(),
            // Only Apple's on-device model uses the compact window. Rapid-MLX and other writers use the remote window,
            // sized from the catalogued context length, or from a small default when that length was never stored.
            onDevice: store.effectiveWriter.kind == .apple,
            contextTokens: store.outcomeContextTokens)
        guard !window.lines.isEmpty else { return false }
        outcomeCaptures.insert(id)
        let endedAt = now()
        let draft = MeetingOutcome(meetingID: id, meetingTitle: model.title, invitation: model.invitation,
            seriesID: model.calendarSeriesID, endedAt: endedAt, summary: "")
        let input = MeetingOutcomeInput(request: .init(meetingTitle: model.title, endedAt: endedAt,
            window: window, language: language), provider: store.effectiveWriter)
        runOutcome(for: id) { library, owner in
            let persisted = try await library.startOutcome(draft, input: input, owner: owner)
            return (persisted, input)
        }
        return true
    }

    func retryOutcome(for sessionID: UUID, outcomeID: UUID) {
        runOutcome(for: sessionID) { [self] library, owner in
            guard let input = try await library.outcomeInput(outcomeID) else { return nil }
            try checkOutcomeProvider(input.provider)
            guard let draft = try await library.claimOutcomeRetry(outcomeID, owner: owner) else { return nil }
            return (draft, input)
        }
    }

    private func checkOutcomeProvider(_ provider: AttentionProvider) throws {
        guard store.shouldCaptureOutcome else { throw MeetingOutcomeFailure.configuration }
        let current = store.effectiveWriter
        guard provider.kind == current.kind, provider.endpoint == current.endpoint, provider.model == current.model else {
            throw MeetingOutcomeFailure.destinationChanged
        }
    }

    private func runOutcome(for sessionID: UUID, claim: @escaping @MainActor
        (MeetingLibraryStore, String) async throws -> (MeetingOutcome, MeetingOutcomeInput)?) {
        guard outcomeStatus[sessionID] == nil else { return }
        outcomeStatus[sessionID] = L("Preparing the meeting outcome…")
        outcomeError[sessionID] = nil
        let owner = UUID().uuidString
        Task { @MainActor [weak self] in
            guard let self else { return }
            let library = store.meetingLibrary
            defer { outcomeStatus[sessionID] = nil }
            do {
                await store.waitForMeetingLibrary()
                guard let (draft, input) = try await claim(library.store, owner) else { return }
                await library.refresh()
                let started = ProcessInfo.processInfo.systemUptime
                var outcome = draft
                var failure: MeetingOutcomeFailure?
                do {
                    try checkOutcomeProvider(input.provider)
                    let writer = makeOutcomeWriter(input.provider, store.apiKey(for: input.provider))
                    let content = try await writer.outcome(input.request)
                    try Task.checkCancellation()
                    outcome.summary = content.summary
                    outcome.decisions = content.decisions
                    outcome.tasks = content.tasks
                    outcome.openQuestions = content.openQuestions
                } catch {
                    failure = MeetingOutcomeFailure(writerError: error)
                    var fields: [String: Any] = [
                        "error": failure?.rawValue ?? "unknown", "attempt": owner,
                        "providerKind": input.provider.kind.rawValue,
                        "elapsedMs": Int((ProcessInfo.processInfo.systemUptime - started) * 1000),
                    ]
                    if case .http(let status, _) = error as? AttentionJudgeError { fields["httpStatus"] = status }
                    probeLog("assistant-outcome-failed", fields)
                }
                let ready = try await store.publishOutcomeMutation {
                    let commit = try await library.store.finishOutcome(outcome, owner: owner, errorCode: failure?.rawValue)
                    return failure == nil ? commit : nil
                }
                if ready != nil {
                    probeLog("assistant-outcome", ["lines": input.request.window.lines.count,
                        "decisions": outcome.decisions.count, "tasks": outcome.tasks.count])
                }
                await library.refresh()
            } catch {
                let failure = error as? MeetingOutcomeFailure ?? .storage
                outcomeError[sessionID] = failure.localizedDescription
                probeLog("assistant-outcome-failed", ["error": failure.rawValue, "attempt": owner])
            }
        }
    }

    func remind(_ task: MeetingOutcomeTask, in outcome: MeetingOutcome) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let due = task.deadline(calendar: .current)
                let at = due.flatMap { $0 > now() ? $0 : nil } ?? now().addingTimeInterval(3600)
                try await scheduleEligibleTaskReminder(outcomeID: outcome.id, taskID: task.id, at: at)
            } catch { outcomeError[outcome.id] = error.localizedDescription }
        }
    }

    func setTaskDone(_ row: PersonalTaskRow, done: Bool) async throws {
        await store.waitForOutcomeWrites()
        let completedAt = now()
        if try await store.publishOutcomeMutation({
            try await store.meetingLibrary.store.changeTask(outcomeID: row.outcomeID, taskID: row.id) {
                $0.setDone(done, at: completedAt)
            }
        }) != nil {
            await store.meetingLibrary.refresh()
        }
        await reconcileTaskReminderCancellations()
    }

    func setTaskArchived(_ row: PersonalTaskRow, archived: Bool) async throws {
        await store.waitForOutcomeWrites()
        let assistant = store.assistant
        assistant.taskArchiveDates[row.id] = try await store.meetingLibrary.store.setTaskArchived(
            taskID: row.id, profile: assistant.taskProfile, archived: archived)
        await reconcileTaskReminderCancellations()
        if !archived,
           let task = try await store.meetingLibrary.store.outcome(row.outcomeID)?.tasks.first(where: { $0.id == row.id }),
           let at = task.reminderAt, at > now() {
            try await scheduleEligibleTaskReminder(outcomeID: row.outcomeID, taskID: row.id, at: at)
        }
    }

    func reviewTaskCandidate(_ candidate: MeetingOutcomeTask, in outcome: MeetingOutcome,
                             accept: Bool, matchedTaskID: UUID? = nil) {
        guard var current = store.assistant.outcomes.first(where: { $0.id == outcome.id }),
              let index = current.taskReviewCandidates.firstIndex(where: { $0.id == candidate.id }) else { return }
        if let matchedTaskID {
            guard current.tasks.contains(where: { $0.id == matchedTaskID }) else { return }
            current.taskReviewMatches[candidate.id] = matchedTaskID
        }
        current.taskReviewCandidates.remove(at: index)
        if accept { current.tasks.append(candidate) }
        store.assistant.updateOutcome(current)
    }

    private func scheduleEligibleTaskReminder(outcomeID: UUID, taskID: UUID, at: Date) async throws {
        await store.waitForMeetingLibrary()
        await store.waitForOutcomeWrites()
        let library = store.meetingLibrary.store
        guard let outcome = try await library.outcome(outcomeID),
              let task = outcome.tasks.first(where: { $0.id == taskID }),
              try await library.taskReminderAllowed(taskID, profile: store.assistant.taskProfile),
              at > now() else { return }
        try await scheduleOutcomeReminder(outcome, task, at)
        do {
            await store.waitForOutcomeWrites()
            if try await store.publishOutcomeMutation({
                try await library.recordTaskReminder(outcomeID: outcomeID, taskID: taskID,
                                                     profile: store.assistant.taskProfile, at: at)
            }) != nil {
                return
            }
        } catch {
            cancelTaskReminder(taskID)
            throw error
        }
        cancelTaskReminder(taskID)
    }

    func reconcileTaskReminderCancellations() async {
        if let reminderCancellationTask {
            await reminderCancellationTask.value
            return
        }
        let reconciliation = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { reminderCancellationTask = nil }
            let library = store.meetingLibrary.store
            while let ids = try? await library.taskReminderCancellations(), !ids.isEmpty {
                for id in ids {
                    cancelTaskReminder(id)
                    do { try await library.acknowledgeTaskReminderCancellation(id) }
                    catch { return }
                }
            }
        }
        reminderCancellationTask = reconciliation
        await reconciliation.value
    }


    func keepSuggestion(_ id: UUID, editedText: String? = nil) {
        guard let suggestion = store.assistant.suggestions.first(where: { $0.id == id }) else { return }
        if suggestion.kind == .meetingMode, let mode = suggestion.mode, let invitation = suggestion.invitation {
            let title = suggestion.meetingTitle?.trimmed.isEmpty == false ? suggestion.meetingTitle! : (invitation.host ?? L("Meeting"))
            store.setMeetingMode(mode, room: invitation, series: suggestion.seriesID, title: title)
        } else if suggestion.kind == .replyStyle {
            store.profile.replyStyle = editedText?.trimmed.isEmpty == false ? editedText : suggestion.proposedText
        }
        store.assistant.keepSuggestion(id, editedText: editedText)
    }

    /// The open meeting this outcome may be posted to. The session that produced it wins.
    /// A later occurrence of the same room is offered only when it is the sole open match,
    /// and the caller confirms before anything is sent.
    func outcomeChatTarget(_ outcome: MeetingOutcome) -> NativeDesktopMeetingModel? {
        let open = meetings().filter { !$0.isClosed && $0.chat.canSend }
        if let id = outcome.meetingID, let exact = open.first(where: { $0.sessionID == id }) { return exact }
        guard let invitation = outcome.invitation else { return nil }
        let sameRoom = open.filter { $0.invitation == invitation }
        return sameRoom.count == 1 ? sameRoom[0] : nil
    }

    @discardableResult func sendOutcome(_ outcome: MeetingOutcome, to meetingID: UUID) -> Bool {
        guard let model = meetings().first(where: { $0.sessionID == meetingID && !$0.isClosed && $0.chat.canSend }) else { return false }
        let sameSession = outcome.meetingID == model.sessionID
        let soleLater = !sameSession && outcomeChatTarget(outcome)?.sessionID == model.sessionID
        guard sameSession || soleLater else { return false }
        return deliverChat(model, outcome.shareText)
    }

    // MARK: Ticking

    /// Observes every meeting, drops stale cards, and judges at most one meeting.
    func tick() async {
        let current = now(), list = meetings()
        ruleStore.expirePendingActions(now: current)
        let ids = Set(list.map(\.sessionID))
        states = states.filter { ids.contains($0.key) }
        if workspaceFollowingPauses.keys.contains(where: { !ids.contains($0) }) {
            workspaceFollowingPauses = workspaceFollowingPauses.filter { ids.contains($0.key) }
        }
        workspacePauseRevisions = workspacePauseRevisions.filter { ids.contains($0.key) }
        // A mode chosen for a while returns to the defaults when its time is up.
        for (id, state) in states where (state.override?.until ?? .distantFuture) <= current { states[id]?.override = nil }
        let activeOpenIDs = Set(list.filter { !$0.isClosed && resolvedMode($0).mode != .off }.map(\.sessionID))
        for (momentID, meetingID) in overflowMeetingByMomentID where !activeOpenIDs.contains(meetingID) {
            removeOverflow(momentID)
        }
        for card in cards {
            guard let model = list.first(where: { $0.sessionID == card.meetingID }),
                  !model.isClosed, resolvedMode(model).mode != .off else { miss(card); continue }
            if card.verdict.level == .now, let held = states[card.meetingID]?.heldUntil,
               held <= current, !card.engaged { miss(card) }
        }
        if let selected = selectedCard, !selected.readOnly,
           !list.contains(where: { $0.sessionID == selected.meetingID && !$0.isClosed }) {
            selectedCard?.channels = ReplyChannels()
            selectedCard?.canDraft = false
            selectedCard?.canSpeak = false
            selectedCard?.readOnly = true
            selectedCard?.drafting = false
            selectedCard?.speaking = false
        }
        for model in list { observeParticipants(model, now: current) }
        guard judging == nil else { return }
        calls.removeAll { current.timeIntervalSince($0) > 60 }
        guard calls.count < callsPerMinuteLimit else { return }
        var best: (model: NativeDesktopMeetingModel, window: AttentionWindow, mode: AttentionMode, mentioned: Bool, trigger: Bool, last: Date)?
        for model in list where eligible(model) {
            let mode = resolvedMode(model).mode
            let state = states[model.sessionID] ?? .init()
            let window = buildWindow(model, state: state, now: current)
            guard !window.isEmpty, window.fingerprint != state.fingerprint else { continue }
            let fresh = window.lines.filter { !state.seenLines.contains($0.id) }
            let question = window.unansweredQuestion(now: current, after: state.judgedAt)
            // Named, or asked where the question can only be for you (just you and one other).
            let mentioned = fresh.contains { $0.mentionsYou && !$0.isYou } ||
                question.map { $0.mentionsYou || window.participantCount <= 2 } == true
            if mentioned { handleRuleMention(model: model, fresh: fresh, at: current) }
            let trigger: Bool, cadence: TimeInterval
            switch mode {
            case .off: continue
            case .mentions:
                trigger = mentioned; cadence = Self.mentionsInterval
            case .watch:
                trigger = mentioned || question != nil || state.changes.contains { !$0.joined && $0.at > (state.judgedAt ?? .distantPast) }
                cadence = interval
            }
            let last = state.judgedAt ?? .distantPast
            guard trigger || current.timeIntervalSince(last) >= cadence else { continue }
            if let chosen = best, (chosen.trigger && !trigger) || (chosen.trigger == trigger && chosen.last <= last) { continue }
            best = (model, window, mode, mentioned, trigger, last)
        }
        guard let best else { return }
        await judge(best.model, window: best.window, mode: best.mode, mentioned: best.mentioned, at: current)
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

    private func judge(_ model: NativeDesktopMeetingModel, window: AttentionWindow, mode: AttentionMode, mentioned: Bool, at time: Date) async {
        let id = model.sessionID
        let pauseRevision = workspacePauseRevisions[id]
        let guidanceRevisions = workspaceGuidanceRevisions(for: model)
        judging = id; calls.append(time)
        defer { judging = nil }
        let preset = store.preset(room: model.invitation, series: model.calendarSeriesID)
        let channels = store.draftReplies && (preset?.repliesAllowed ?? true) ? replyChannels(model) : ReplyChannels()
        let memory = store.assistant.retrieve(meetingTitle: model.title, invitation: model.invitation,
            series: model.calendarSeriesID, people: model.participants.filter { !$0.isLocal }.map(\.name))
        let request = JudgeRequest(window: window, preset: preset, profile: store.profile, yourName: model.displayName,
                                   language: language, replyChannels: channels, memory: memory,
                                   workspaceGuidance: workspaceInstructions(for: model))
        let provider = store.provider
        let decisionID = UUID()
        do {
            var result: JudgeResult
            var judgedBy = provider, first: (verdict: AttentionVerdict, model: String)?
            do { result = try await makeJudge(provider, store.apiKey(for: provider)).judge(request) }
            catch is CancellationError { throw CancellationError() }
            catch {
                // The first judge failed outright (e.g. the system model is unavailable):
                // the escalation judge, when set, decides instead of leaving the window unjudged.
                guard let strong = store.escalationProvider, strong != provider, strong.configured,
                      !strong.needsKey || store.hasKey(for: strong) else { throw error }
                probeLog("attention-judge-fallback", ["error": String(describing: error)])
                calls.append(now())
                result = try await makeJudge(strong, store.apiKey(for: strong)).judge(request)
                judgedBy = strong
            }
            // An unsure first judge hands the same window to the stronger one.
            if judgedBy == provider, let strong = store.escalation(for: result.verdict),
               calls.filter({ now().timeIntervalSince($0) <= 60 }).count < callsPerMinuteLimit {
                calls.append(now())
                do {
                    let second = try await makeJudge(strong, store.apiKey(for: strong)).judge(request)
                    first = (result.verdict, provider.model)
                    result = .init(verdict: second.verdict, latency: result.latency + second.latency)
                    judgedBy = strong
                } catch is CancellationError { throw CancellationError() }
                catch { probeLog("attention-escalation-failed", ["error": String(describing: error)]) }
            }
            guard workspacePauseRevisions[id] == pauseRevision, workspaceFollowingPauses[id] == nil,
                  let model = meetings().first(where: { $0.sessionID == id }), !model.isClosed,
                  request.workspaceGuidance == workspaceInstructions(for: model),
                  guidanceRevisions == workspaceGuidanceRevisions(for: model) else { return }
            var state = states[id] ?? .init()
            state.verdict = result.verdict; state.judgedAt = now(); state.fingerprint = window.fingerprint; state.error = nil
            state.seenLines.formUnion(window.lines.map(\.id))
            lastError = nil
            let threshold = preset?.threshold ?? AttentionUrgency.normal.baseThreshold
            let card = Card(id: decisionID, meetingID: id, meetingTitle: model.title, invitation: model.invitation,
                seriesID: model.calendarSeriesID, verdict: result.verdict, window: window, presetID: preset?.id, threshold: threshold,
                provider: judgedBy.host, model: judgedBy.model, latency: result.latency, createdAt: now(), channels: channels,
                canDraft: store.draftsAllowed, canSpeak: store.draftReplies && (preset?.repliesAllowed ?? true) && voiceAvailable(model),
                memory: memory, workspaceGuidance: request.workspaceGuidance, workspaceGuidanceRevisions: guidanceRevisions,
                mode: mode, mentioned: mentioned)
            let outcome = apply(card, state: &state), shown = outcome == .shown
            // The judge suggests answering in writing: have a draft ready on the card.
            if shown, card.canDraft, [.chat, .reaction].contains(result.verdict.action), !channels.isEmpty,
               calls.filter({ now().timeIntervalSince($0) <= 60 }).count < callsPerMinuteLimit {
                draftReply(decisionID)
            }
            states[id] = state
            store.log(.init(id: decisionID, at: now(), meetingTitle: model.title, meetingID: id, invitation: model.invitation,
                seriesID: model.calendarSeriesID, presetID: preset?.id, window: window, verdict: result.verdict,
                provider: judgedBy.host, model: judgedBy.model, latencyMilliseconds: Int(result.latency * 1000),
                outcome: outcome, messages: AttentionPrompt.messages(request), threshold: threshold,
                firstVerdict: first?.verdict, firstModel: first?.model, mode: mode, mentioned: mentioned, memory: memory))
            probeLog("attention-verdict", ["level": result.verdict.level.rawValue, "probability": result.verdict.probability,
                "mode": mode.rawValue, "mentioned": mentioned,
                "lines": window.lines.count, "latencyMs": Int(result.latency * 1000), "shown": shown,
                "escalated": first != nil, "firstProbability": first?.verdict.probability ?? -1, "outcome": outcome.rawValue])
        } catch is CancellationError {
            return
        } catch {
            guard workspacePauseRevisions[id] == pauseRevision, workspaceFollowingPauses[id] == nil else { return }
            var state = states[id] ?? .init()
            state.judgedAt = now(); state.error = error.localizedDescription
            states[id] = state; lastError = error.localizedDescription
            store.log(.init(id: decisionID, at: now(), meetingTitle: model.title, presetID: preset?.id, window: nil, verdict: nil,
                provider: provider.host, model: provider.model, outcome: .failed, error: String(describing: error)))
            probeLog("attention-failed", ["error": String(describing: error)])
        }
    }

    /// Shows, keeps or removes this meeting's card. "Now" holds for two minutes
    /// unless you act; a card never repeats for evidence already shown. A card that
    /// qualifies but loses to two more urgent ones changes nothing and is logged as
    /// `crowdedOut`, so its evidence can still raise a card later.
    private func apply(_ card: Card, state: inout MeetingState) -> AttentionDecisionRecord.Outcome {
        let verdict = card.verdict, current = card.createdAt
        let existing = cards.first { $0.meetingID == card.meetingID }
        var qualifies = verdict.level != .no && verdict.probability >= card.threshold
        // In Mentions, a window that did not name or ask you raises a card only when it is urgent.
        if card.mode == .mentions && !card.mentioned {
            qualifies = qualifies && verdict.level == .now && verdict.probability >= Self.mentionsUrgency
        }
        // A card you are replying from stays until you send, dismiss or decline it.
        if existing?.engaged == true {
            if qualifies { insertOverflow(card.id, meetingID: card.meetingID) }
            return qualifies ? .crowdedOut : .belowThreshold
        }
        let held = existing?.verdict.level == .now && (state.heldUntil ?? .distantPast) > current
        let repeated = !verdict.evidence.isEmpty && Set(verdict.evidence).isSubset(of: state.shownEvidence)
        guard qualifies, !repeated else {
            if let existing, !held { miss(existing) }
            return .belowThreshold
        }
        if held && verdict.level < .now {
            insertOverflow(card.id, meetingID: card.meetingID)
            return .crowdedOut
        }
        var proposed = cards.filter { $0.meetingID != card.meetingID } + [card]
        proposed.sort { $0.verdict.level == $1.verdict.level ? $0.createdAt > $1.createdAt : $0.verdict.level > $1.verdict.level }
        guard proposed.prefix(Self.maxCards).contains(where: { $0.id == card.id }) else {
            insertOverflow(card.id, meetingID: card.meetingID)
            return .crowdedOut
        }
        removeOverflow(card.id)
        let retained = Array(proposed.prefix(Self.maxCards))
        for old in cards where !retained.contains(where: { $0.id == old.id }) { miss(old, overflow: true) }
        cards = retained
        state.shownEvidence.formUnion(verdict.evidence)
        if verdict.level == .now { state.heldUntil = current.addingTimeInterval(Self.holdNow); notify(card) }
        return .shown
    }

    // MARK: Your decisions

    private func actionableCard(_ fallback: Card) -> Card? {
        if let state = store.momentHistory.moment(fallback.id)?.state,
           [.answered, .dismissed, .notForMe].contains(state) {
            return nil
        }
        let card = currentCard(fallback.id) ?? fallback
        guard !card.readOnly, workspaceFollowingPauses[card.meetingID] == nil else { return nil }
        if let model = meetings().first(where: { $0.sessionID == card.meetingID }),
           card.workspaceGuidance != workspaceInstructions(for: model)
            || card.workspaceGuidanceRevisions != workspaceGuidanceRevisions(for: model) { return nil }
        return card
    }

    func open(_ card: Card) {
        guard let current = actionableCard(card), !current.speaking else { return }
        feedback(current, decision: .approved, reason: nil, note: nil, outcome: .opened)
        openMeeting(current.meetingID)
    }
    func dismiss(_ card: Card) {
        guard let current = actionableCard(card), !current.speaking else { return }
        remove(current)
        log(current, outcome: .dismissed, reason: nil)
    }
    func decline(_ card: Card, reason: PresetExample.DeclineReason, note: String? = nil) {
        guard let current = actionableCard(card), !current.speaking else { return }
        feedback(current, decision: .declined, reason: reason, note: note, outcome: .declined)
        if reason == .alreadyKnown {
            let topic = note?.trimmed.isEmpty == false ? note! : current.verdict.reason
            store.assistant.suggestKnownTopic(topic, meetingTitle: current.meetingTitle, invitation: current.invitation, series: current.seriesID)
        }
    }

    // MARK: Moments

    /// Resolves legacy Moments only when exactly one open meeting matches.
    func meeting(for moment: AttentionMoment) -> NativeDesktopMeetingModel? {
        let list = meetings().filter { !$0.isClosed }
        if let id = moment.meetingID, let exact = list.first(where: { $0.sessionID == id }) { return exact }
        if let invitation = moment.invitation {
            let matches = list.filter { $0.invitation == invitation }
            if matches.count == 1 { return matches[0] }
        }
        if let presetID = moment.presetID {
            let matches = list.filter { store.preset(room: $0.invitation, series: $0.calendarSeriesID)?.id == presetID }
            if matches.count == 1 { return matches[0] }
        }
        let matches = list.filter { $0.title.caseInsensitiveCompare(moment.meetingTitle) == .orderedSame }
        return matches.count == 1 ? matches[0] : nil
    }

    func showMoment(_ id: UUID) {
        requestedMomentID = id
        if let moment = store.momentHistory.moment(id) { selectMoment(moment) }
    }

    func selectMoment(_ moment: AttentionMoment) {
        if let card = cards.first(where: { $0.id == moment.id }) { selectedCard = card; return }
        let model = meeting(for: moment)
        let terminal = [.answered, .dismissed, .notForMe].contains(moment.state)
        let preset = moment.presetID.flatMap(store.preset(id:)) ?? model.flatMap { store.preset(room: $0.invitation, series: $0.calendarSeriesID) }
        let allowed = !terminal && (model.map { store.draftReplies && (preset?.repliesAllowed ?? true) && !$0.isClosed } ?? false)
        selectedCard = Card(id: moment.id, meetingID: model?.sessionID ?? moment.meetingID ?? UUID(), meetingTitle: moment.meetingTitle,
            invitation: model?.invitation ?? moment.invitation ?? URL(string: "about:blank")!, seriesID: model?.calendarSeriesID ?? moment.seriesID,
            verdict: moment.verdict, window: moment.window ?? AttentionWindow(meetingTitle: moment.meetingTitle, lines: [], reactions: [],
                joined: [], left: [], participantCount: model?.participants.count ?? 0, microphoneOn: model?.snapshot.microphoneOn ?? false,
                soundOn: model?.snapshot.playoutOn ?? false, builtAt: moment.createdAt),
            presetID: moment.presetID, threshold: moment.threshold, provider: moment.provider, model: moment.model,
            latency: moment.latency, createdAt: moment.createdAt,
            channels: model.map { allowed ? replyChannels($0) : ReplyChannels() } ?? ReplyChannels(), draft: moment.draft,
            canDraft: allowed && store.draftsAllowed, canSpeak: allowed && (model.map(voiceAvailable) ?? false),
            memory: moment.memory, readOnly: terminal || (model?.isClosed ?? true), mode: moment.mode, mentioned: moment.mentioned)
    }

    private var pendingSeenIDs: [UUID] = []
    private var seenCoalesce: Task<Void, Never>?

    /// Rows appear together as the list scrolls. One journal update covers the burst,
    /// instead of a file write and a workspace refresh per row.
    func markVisibleMomentsSeen(_ moments: [AttentionMoment]) {
        for moment in moments where [.live, .missed].contains(moment.state) {
            if store.momentHistory.moment(moment.id)?.seen == true { continue }
            if !pendingSeenIDs.contains(moment.id) { pendingSeenIDs.append(moment.id) }
        }
        guard !pendingSeenIDs.isEmpty, seenCoalesce == nil else { return }
        seenCoalesce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard let self else { return }
            self.seenCoalesce = nil
            let ids = self.pendingSeenIDs
            self.pendingSeenIDs.removeAll()
            guard !ids.isEmpty else { return }
            self.store.markMomentsSeen(ids, at: self.now())
        }
    }

    private func insertOverflow(_ id: UUID, meetingID: UUID) {
        overflowMomentIDs.insert(id)
        overflowMeetingByMomentID[id] = meetingID
    }
    private func removeOverflow(_ id: UUID) {
        overflowMomentIDs.remove(id)
        overflowMeetingByMomentID.removeValue(forKey: id)
    }
    private func clearOverflow(forMeeting meetingID: UUID) {
        for (id, owner) in overflowMeetingByMomentID where owner == meetingID {
            overflowMomentIDs.remove(id)
            overflowMeetingByMomentID.removeValue(forKey: id)
        }
    }
    private func clearAllOverflow() {
        overflowMomentIDs.removeAll()
        overflowMeetingByMomentID.removeAll()
    }

    private func miss(_ card: Card, overflow: Bool = false) {
        guard cards.contains(where: { $0.id == card.id }) else { return }
        cards.removeAll { $0.id == card.id }
        states[card.meetingID]?.heldUntil = nil
        if overflow {
            insertOverflow(card.id, meetingID: card.meetingID)
        } else if cards.isEmpty {
            clearAllOverflow()
        }
        log(card, outcome: .missed, reason: nil)
    }

    private func currentCard(_ id: UUID) -> Card? { cards.first { $0.id == id } ?? (selectedCard?.id == id ? selectedCard : nil) }
    private func updateCard(_ id: UUID, _ change: (inout Card) -> Void) {
        if let index = cards.firstIndex(where: { $0.id == id }) { change(&cards[index]) }
        if selectedCard?.id == id { change(&selectedCard!) }
    }

    func remind(_ moment: AttentionMoment) {
        guard !remindingMoments.contains(moment.id),
              (store.momentHistory.moment(moment.id)?.reminderAt ?? moment.reminderAt) == nil else { return }
        remindingMoments.insert(moment.id)
        reminderErrorByMoment[moment.id] = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { remindingMoments.remove(moment.id) }
            do { try await remind(moment, at: now().addingTimeInterval(600)) }
            catch { reminderErrorByMoment[moment.id] = error.localizedDescription }
        }
    }

    func remind(_ moment: AttentionMoment, at: Date) async throws {
        try await scheduleReminder(moment, at)
        store.log(.init(at: now(), meetingTitle: moment.meetingTitle, meetingID: moment.meetingID,
            invitation: moment.invitation, seriesID: moment.seriesID, presetID: moment.presetID,
            provider: moment.provider, model: moment.model, outcome: .reminded, decisionID: moment.id, reminderAt: at))
    }

    func summarize(_ moment: AttentionMoment) async {
        guard summarizing == nil else { return }
        summaryErrorByMoment[moment.id] = nil
        guard let model = meeting(for: moment), !model.isClosed else {
            summaryErrorByMoment[moment.id] = L("The meeting is not open, so there is no later conversation to summarize."); return
        }
        let window = AttentionWindowBuilder.build(.init(title: model.title, transcript: model.transcript,
            chat: model.chat.items, reactions: [], participantCount: model.participants.count,
            yourNames: store.profile.names(fallback: model.displayName), microphoneOn: model.snapshot.microphoneOn,
            soundOn: model.snapshot.playoutOn, now: now(), after: moment.createdAt))
        guard !window.lines.isEmpty else { summaryByMoment[moment.id] = L("No later transcript or chat yet."); return }
        summarizing = moment.id
        defer { summarizing = nil }
        let provider = store.effectiveWriter
        do {
            let summary = try await makeSummarizer(provider, store.apiKey(for: provider)).summarize(.init(moment: moment, window: window, language: language))
            try Task.checkCancellation()
            summaryByMoment[moment.id] = summary
        } catch is CancellationError { return }
        catch { summaryErrorByMoment[moment.id] = error.localizedDescription }
    }

    // MARK: Replies

    /// Drafts ranked replies or a reaction for a card. Nothing is sent: you choose,
    /// edit and send a variant, or explicitly discard it.
    func draftReply(_ cardID: UUID, hint: String? = nil) {
        guard let card = currentCard(cardID), workspaceFollowingPauses[card.meetingID] == nil, card.canDraft, !card.drafting,
              !card.channels.isEmpty || card.canSpeak,
              let model = meetings().first(where: { $0.sessionID == card.meetingID }), !model.isClosed else { return }
        updateCard(cardID) { $0.drafting = true; $0.draftError = nil }
        calls.append(now())
        let preset = card.presetID.flatMap(store.preset(id:))
        // A reply that can be spoken is written like a chat message.
        var channels = card.channels
        if card.canSpeak { channels.chat = true }
        let request = ReplyRequest(judge: JudgeRequest(window: card.window, preset: preset, profile: store.profile,
            yourName: model.displayName, language: language, replyChannels: channels, memory: card.memory,
            workspaceGuidance: workspaceInstructions(for: model)),
            verdict: card.verdict, redraftHint: hint)
        let requestedAt = now()
        let writerInput = ReplyPrompt.messages(request).enumerated().compactMap { index, message -> MeetingWorkspaceEvent.SourceSnapshot? in
            guard let content = message["content"] else { return nil }
            return .init(id: "writer:\(index)", title: L("Instructions used for this reply"),
                text: String(content.prefix(32_768)), revision: ParticipationReceipt.hash(content), capturedAt: requestedAt)
        }
        let guidanceRevisions = workspaceGuidanceRevisions(for: model)
        let pauseRevision = workspacePauseRevisions[model.sessionID]
        let provider = store.effectiveWriter, writer = makeWriter(provider, store.apiKey(for: provider))
        Task { @MainActor [weak self] in
            do {
                let result = try await writer.draft(request)
                guard let self, currentCard(cardID) != nil else { return }
                guard request.judge.workspaceGuidance == workspaceInstructions(for: model),
                      guidanceRevisions == workspaceGuidanceRevisions(for: model),
                      workspacePauseRevisions[model.sessionID] == pauseRevision,
                      workspaceFollowingPauses[model.sessionID] == nil else {
                    updateCard(cardID) { $0.drafting = false }
                    return
                }
                let ranked = result.draft.ranked(preferredStance: store.assistant.preferredStance(), edits: preset?.replyEdits ?? [])
                updateCard(cardID) {
                    $0.drafting = false
                    $0.draft = ranked
                    $0.workspaceGuidance = request.judge.workspaceGuidance
                    $0.workspaceGuidanceRevisions = guidanceRevisions
                    $0.workspaceWriterInput = writerInput
                }
                store.log(.init(at: now(), meetingTitle: card.meetingTitle, meetingID: card.meetingID, invitation: card.invitation,
                    seriesID: card.seriesID, presetID: card.presetID, provider: provider.host, model: provider.model,
                    latencyMilliseconds: Int(result.latency * 1000), outcome: .drafted, decisionID: cardID,
                    replyMessages: ReplyPrompt.messages(request), draft: ranked, memory: card.memory))
                probeLog("attention-draft", ["chat": !ranked.chat.isEmpty, "reaction": ranked.reaction != nil,
                    "variants": ranked.variants?.count ?? 0, "latencyMs": Int(result.latency * 1000)])
            } catch {
                guard let self, currentCard(cardID) != nil else { return }
                updateCard(cardID) { $0.drafting = false }
                if error is CancellationError { return }
                updateCard(cardID) { $0.draftError = error.localizedDescription }
                store.log(.init(at: now(), meetingTitle: card.meetingTitle, meetingID: card.meetingID, invitation: card.invitation,
                    seriesID: card.seriesID, presetID: card.presetID, provider: provider.host, model: provider.model,
                    outcome: .draftFailed, error: String(describing: error), decisionID: cardID))
                probeLog("attention-draft-failed", ["error": String(describing: error)])
            }
        }
    }

    /// Chooses which variant the editable field contains. Selection never sends it.
    func selectVariant(_ variant: ReplyVariant, for card: Card) {
        guard let draft = currentCard(card.id)?.draft, draft.availableVariants.contains(where: { $0.id == variant.id }) else { return }
        updateCard(card.id) { card in
            card.draft?.chat = variant.text
        }
        store.assistant.observeVariant(variant.stance)
    }

    /// Sends the text you approved into the meeting's chat and counts as an approval.
    @discardableResult func sendReply(_ card: Card, text: String) -> Bool {
        let clean = text.trimmed
        guard let current = actionableCard(card), !current.speaking, !clean.isEmpty, current.channels.chat,
              let model = meetings().first(where: { $0.sessionID == current.meetingID }), !model.isClosed else {
            setDraftError(L("The meeting did not accept the message. Open the meeting to answer."), card: card); return false
        }
        do { try sendWorkspaceApprovedChat(clean, to: model, evidence: workspaceEvidence(current)) }
        catch {
            setDraftError(error.localizedDescription, card: card)
            return false
        }
        feedback(current, decision: .approved, reason: nil, note: nil, outcome: .replied,
                 sent: clean, reaction: nil, edited: clean != current.draft?.chat.trimmed)
        // A rewritten draft teaches the writer how you put things.
        if let draft = current.draft?.chat.trimmed, !draft.isEmpty, draft != clean,
           let preset = current.presetID.flatMap(store.preset(id:)) ?? store.preset(room: current.invitation, series: current.seriesID) {
            store.recordEdit(.init(at: now(), draft: draft, sent: clean), in: preset)
        }
        return true
    }

    func sendWorkspaceApprovedChat(_ text: String, to model: NativeDesktopMeetingModel,
        id: UUID = UUID(), evidence: [MeetingWorkspaceEvent.SourceSnapshot]) throws {
        let id = id.uuidString.lowercased(), clean = text.trimmed
        let journal = model.workspaceJournal, linked = model.approvedWorkspaceChatLink(id: id)
        if let journal, !journal.recordAssistantReply(sessionID: model.sessionID, id: id, text: clean,
            source: "approvedChat", status: .sending, sourceSnapshots: evidence, linkedChatID: linked) {
            throw MeetingLibraryError.persistenceFailed(L("The assistant could not save its activity on this Mac. Check local storage before restarting."))
        }
        guard model.withApprovedWorkspaceChat(id: id, { deliverChat(model, clean) }) else {
            journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: .failed, isPrivate: true)
            throw AssistantCommandError.unsupported
        }
        if linked == nil { journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: .submitted) }
    }

    func sendWorkspaceApprovedReaction(_ reaction: MeetingReaction, to model: NativeDesktopMeetingModel,
        id: UUID = UUID(), evidence: [MeetingWorkspaceEvent.SourceSnapshot]) throws {
        let id = id.uuidString.lowercased(), journal = model.workspaceJournal
        if let journal, !journal.recordAction(sessionID: model.sessionID, text: reaction.emoji,
            source: "approvedReaction", id: id, status: .queued, isPrivate: false, sourceSnapshots: evidence) {
            throw AssistantCommandError.unsupported
        }
        model.withApprovedWorkspaceReaction(id: id) { deliverReaction(model, reaction) }
        if !model.canCorrelateApprovedWorkspaceReaction {
            journal?.updateActionStatus(sessionID: model.sessionID, id: id, status: .submitted)
        }
    }

    func speakWorkspaceApprovedCommand(_ text: String, in model: NativeDesktopMeetingModel, id: String,
        source: String, evidence: [MeetingWorkspaceEvent.SourceSnapshot],
        beforeSynthesis: @escaping @MainActor () throws -> Void = {}) async throws {
        let journal = model.workspaceJournal
        let canSpeak = model.participationMeetingSoundOn && model.canSpeakApprovedWorkspaceReply &&
            workspaceFollowingPauses[model.sessionID] == nil && !model.workspaceApprovedVoiceInProgress && !model.isClosed
        if let journal, !journal.recordAssistantReply(sessionID: model.sessionID, id: id, text: text,
            source: source, status: canSpeak ? .queued : .held, isPrivate: true, sourceSnapshots: evidence) {
            throw MeetingLibraryError.persistenceFailed(L("The assistant could not save its activity on this Mac. Check local storage before restarting."))
        }
        guard canSpeak, let task = model.startWorkspaceApprovedVoice({ [self] () -> Result<Void, Error> in
            var attempted = false
            do {
                try Task.checkCancellation()
                try beforeSynthesis()
                let buffer = try await synthesize(text)
                try Task.checkCancellation()
                guard model.participationMeetingSoundOn, model.canSpeakApprovedWorkspaceReply,
                      workspaceFollowingPauses[model.sessionID] == nil else { throw CancellationError() }
                if let journal, !journal.recordAssistantReply(sessionID: model.sessionID, id: id, text: text,
                    source: source, status: .sending, sourceSnapshots: evidence) {
                    throw MeetingLibraryError.persistenceFailed(L("The meeting conversation could not be read."))
                }
                attempted = true
                try await deliverVoice(model, buffer)
                journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: .spoken)
                return .success(())
            } catch {
                let status = workspaceVoiceStatus(error, attempted: attempted)
                journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: status,
                    isPrivate: status == .cancelled || status == .held ? true : nil)
                return .failure(error)
            }
        }) else { throw AssistantCommandError.unsupported }
        try await withTaskCancellationHandler {
            try await task.value.get()
        } onCancel: {
            task.cancel()
        }
    }

    /// Sends one reaction into the meeting and counts as an approval.
    @discardableResult func sendReaction(_ card: Card, _ reaction: MeetingReaction) -> Bool {
        guard let current = actionableCard(card), !current.speaking, current.channels.reactions.contains(reaction),
              let model = meetings().first(where: { $0.sessionID == current.meetingID }), !model.isClosed else {
            setDraftError(L("The meeting did not accept the reaction. Open the meeting to answer."), card: card); return false
        }
        do { try sendWorkspaceApprovedReaction(reaction, to: model, evidence: workspaceEvidence(current)) }
        catch {
            setDraftError(error.localizedDescription, card: card)
            return false
        }
        feedback(current, decision: .approved, reason: nil, note: nil, outcome: .reacted,
                 sent: nil, reaction: reaction, edited: reaction != current.draft?.reaction)
        return true
    }

    /// Speaks the text into the meeting with the chosen voice. Your microphone is held
    /// back while it plays; counts as an approval once it has played.
    func sayReply(_ card: Card, text: String) {
        let clean = text.trimmed
        guard let current = actionableCard(card), current.canSpeak, !clean.isEmpty, !current.speaking,
              let model = meetings().first(where: { $0.sessionID == current.meetingID }), !model.isClosed,
              !model.workspaceApprovedVoiceInProgress else {
            setDraftError(L("This meeting cannot play a spoken reply now. Open the meeting to answer."), card: card); return
        }
        let id = UUID().uuidString
        let journal = model.workspaceJournal
        let evidence = workspaceEvidence(current)
        guard model.participationMeetingSoundOn, model.canSpeakApprovedWorkspaceReply else {
            journal?.recordAssistantReply(sessionID: model.sessionID, id: id, text: clean, source: "approvedVoice",
                status: .held, isPrivate: true, sourceSnapshots: evidence)
            setDraftError(L("This meeting cannot play a spoken reply now. Open the meeting to answer."), card: card)
            return
        }
        if let journal, !journal.recordAssistantReply(sessionID: model.sessionID, id: id, text: clean,
            source: "approvedVoice", status: .queued, isPrivate: true, sourceSnapshots: evidence) {
            setDraftError(L("The assistant could not save its activity on this Mac. Check local storage before restarting."), card: card)
            return
        }
        updateCard(card.id) { $0.speaking = true; $0.draftError = nil }
        let pauseRevision = workspacePauseRevisions[model.sessionID]
        let soundRevision = model.workspaceSoundRevision
        model.startWorkspaceApprovedVoice { [weak self] in
            guard let self else { return }
            let started = ProcessInfo.processInfo.systemUptime
            var playbackAttempted = false
            do {
                let buffer = try await synthesize(clean)
                let synthesized = ProcessInfo.processInfo.systemUptime
                guard !Task.isCancelled, workspacePauseRevisions[model.sessionID] == pauseRevision,
                      workspaceFollowingPauses[model.sessionID] == nil, !model.isClosed,
                      current.workspaceGuidance == workspaceInstructions(for: model),
                      current.workspaceGuidanceRevisions == workspaceGuidanceRevisions(for: model),
                      model.canSpeakApprovedWorkspaceReply, model.participationMeetingSoundOn,
                      model.workspaceSoundRevision == soundRevision else {
                    journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: .held)
                    throw CancellationError()
                }
                if let journal, !journal.recordAssistantReply(sessionID: model.sessionID, id: id, text: clean,
                    source: "approvedVoice", status: .sending, sourceSnapshots: evidence) {
                    throw MeetingLibraryError.persistenceFailed(L("The meeting conversation could not be read."))
                }
                playbackAttempted = true
                try await deliverVoice(model, buffer)
                journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: .spoken)
                probeLog("attention-spoken", ["voice": store.voiceEngine.rawValue, "seconds": Double(buffer.frameLength) / buffer.format.sampleRate,
                    "synthesisMs": Int((synthesized - started) * 1000)])
                // Playback already happened. If the card was closed or dismissed while it played,
                // still record the spoken reply and clear `speaking`.
                if let finished = actionableCard(current) {
                    feedback(finished, decision: .approved, reason: nil, note: nil, outcome: .spoken,
                             sent: clean, reaction: nil, edited: clean != finished.draft?.chat.trimmed)
                } else {
                    let finished = currentCard(card.id) ?? current
                    updateCard(finished.id) { $0.speaking = false }
                    log(finished, outcome: .spoken, reason: nil, sent: clean, reaction: nil,
                        edited: clean != finished.draft?.chat.trimmed)
                }
            } catch {
                if journal?.session(id: model.sessionID)?.events.first(where: { $0.id == "assistant:" + id })?.status != .held {
                    let status = workspaceVoiceStatus(error, attempted: playbackAttempted)
                    journal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: status,
                        isPrivate: status == .cancelled || status == .held ? true : nil)
                }
                updateCard(card.id) {
                    $0.speaking = false
                    if !(error is CancellationError) { $0.draftError = error.localizedDescription }
                }
            }
        }
    }

    private func workspaceVoiceStatus(_ error: Error, attempted: Bool) -> MeetingWorkspaceEvent.Status {
        if error is CancellationError { return attempted ? .cancelled : .held }
        if let error = error as? NativeDesktopMeetingModel.VoiceReplyError {
            switch error {
            case .playback, .mute: return .unknown
            case .playedMute: return .spoken
            case .interrupted: return .interrupted
            case .unavailable, .notTalkMeeting, .gate, .microphone, .sample: return .failed
            }
        }
        return attempted ? .unknown : .failed
    }

    private func workspaceEvidence(_ card: Card) -> [MeetingWorkspaceEvent.SourceSnapshot] {
        let observed = card.createdAt
        var result: [MeetingWorkspaceEvent.SourceSnapshot] = [
            .init(id: "reason", title: L("Why this reply"), text: card.verdict.reason, revision: nil, capturedAt: observed)
        ]
        let cited = Set(card.verdict.evidence)
        result += card.window.lines.map {
            .init(id: cited.contains($0.id) ? "trigger:" + $0.id : $0.id,
                title: $0.speaker, text: $0.text, revision: ParticipationReceipt.hash($0.text), capturedAt: observed)
        }
        result += card.memory.map {
            .init(id: $0.id, title: L("Assistant memory"), text: $0.text, revision: $0.sourceID.uuidString, capturedAt: observed)
        }
        result += card.workspaceGuidance.enumerated().map { index, guidance in
            .init(id: "guidance:\(index)", title: L("Private guidance"), text: guidance,
                revision: ParticipationReceipt.hash(guidance), capturedAt: observed)
        }
        result += card.workspaceWriterInput
        return result
    }

    func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        if let synthesizeOverride { return try await synthesizeOverride(text) }
        return try await store.voiceConfiguration.synthesize(text)
    }

    private func setDraftError(_ message: String, card: Card) { updateCard(card.id) { $0.draftError = message } }

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
        removeOverflow(card.id)
        if cards.isEmpty { clearAllOverflow() }
        if selectedCard?.id == card.id {
            selectedCard?.channels = ReplyChannels()
            selectedCard?.canDraft = false
            selectedCard?.canSpeak = false
            selectedCard?.readOnly = true
            selectedCard?.drafting = false
            selectedCard?.speaking = false
        }
        states[card.meetingID]?.heldUntil = nil
    }
    private func log(_ card: Card, outcome: AttentionDecisionRecord.Outcome, reason: PresetExample.DeclineReason?,
                     sent: String? = nil, reaction: MeetingReaction? = nil, edited: Bool? = nil) {
        store.log(.init(at: now(), meetingTitle: card.meetingTitle, meetingID: card.meetingID, invitation: card.invitation,
            seriesID: card.seriesID, presetID: card.presetID, provider: card.provider, model: card.model,
            outcome: outcome, declineReason: reason, decisionID: card.id, sent: sent, reaction: reaction, edited: edited))
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
