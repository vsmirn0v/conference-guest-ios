import AVFoundation
import Combine
import ConferenceCore
import Foundation

/// Bounds only synthesis; the owner cancels the timer as soon as it completes.
@MainActor
enum GuestVoiceSynthesisDeadline {
    static func schedule(_ deadline: Date, onExpiry: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow))) }
            catch { return }
            guard !Task.isCancelled else { return }
            onExpiry()
        }
    }
}

struct ParticipationAudience: Equatable {
    let sessionID: UUID
    let room: MeetingRoomIdentity
    let providerRoom: String
    let providerGroup: String
    let localParticipant: String
    let members: [String: String]
    let connection: ObjectIdentifier
}

struct ParticipationSetup: Equatable {
    let audience: ParticipationAudience
    let provider: AttentionProvider
    let rosterEpoch: UInt64
    let voice: AssistantVoiceConfiguration

    func matches(_ current: Self?, output: ParticipationOutput) -> Bool {
        guard let current else { return false }
        return audience == current.audience && provider == current.provider && rosterEpoch == current.rosterEpoch
            && (output != .voice || voice == current.voice)
    }

    func knowledgeContext(title: String, expiresAt: Date) -> ParticipationKnowledgeReviewContext? {
        guard provider.kind == .apple else { return nil }
        let room = audience.room
        let identity = [room.engine.rawValue, room.origin, room.room, audience.providerRoom, audience.providerGroup]
            .map { String($0.utf8.count) + ":" + $0 }.joined()
        return .init(audience: .init(sessionID: audience.sessionID, roomIdentity: identity, rosterEpoch: rosterEpoch),
            meetingTitle: title, processorID: "apple-system-on-device",
            processorLabel: provider.title, processingDescription: L("Approved excerpts are processed on this Mac."),
            expiresAt: expiresAt)
    }
}

@MainActor
final class ParticipationCoordinator: ObservableObject {
    enum Status: String {
        case inactive, observing, paused, review, unavailable

        var title: String {
            switch self {
            case .inactive: L("Participate")
            case .observing: L("Participating")
            case .paused: L("Participation paused")
            case .review: L("Participation needs review")
            case .unavailable: L("Participation unavailable")
            }
        }
    }

    enum Reason: String {
        case userPaused, audienceChanged, connectionChanged, meetingAccessLost
        case processorChanged, processorKeyUnavailable, processorFailed
        case noteAccessExpired, noteAccessChanged, noteUnavailable, replyChannelChanged
        case storageFailed, assistantDisabled, meetingEnded, modeChanged
        case setupChanged, voiceUnavailable, voiceChanged, noteVoiceProcessor

        var message: String {
            switch self {
            case .userPaused: L("You paused participation. Private help continues.")
            case .audienceChanged: L("The participant list changed. Review the current audience before restarting.")
            case .connectionChanged: L("The meeting connection changed. Review the meeting before restarting.")
            case .meetingAccessLost: L("The participant list or chat became unavailable. Review the meeting once access returns.")
            case .processorChanged: L("The Assistant model changed. Review its processing settings before restarting.")
            case .processorKeyUnavailable: L("The Assistant model needs an API key. Add it in Assistant Settings before restarting.")
            case .processorFailed: L("The Assistant model could not finish checking a reply. Check the model in Assistant Settings, then restart.")
            case .noteAccessExpired: L("Access to the approved notes expired. Review the notes before using them again.")
            case .noteAccessChanged: L("The approved notes changed. Review the updated sources before restarting.")
            case .noteUnavailable: L("An approved note changed or could not be read. Review the notes before using them again.")
            case .replyChannelChanged: L("The reply channel changed. Start participation to approve the new channel.")
            case .storageFailed: L("The assistant could not save its activity on this Mac. Check local storage before restarting.")
            case .assistantDisabled: L("Assistant was turned off. Turn it on in Settings and start participation again.")
            case .meetingEnded: L("Participation ended when you left the meeting.")
            case .modeChanged: L("Participation ended when you changed Assistant modes.")
            case .setupChanged: L("The meeting or processor changed during setup. Review the current settings and try again.")
            case .voiceUnavailable: L("Voice replies became unavailable. Choose Chat or rejoin with Voice replies enabled.")
            case .voiceChanged: L("The reply voice changed. Review the selected voice before restarting.")
            case .noteVoiceProcessor: L("Choose an on-device voice or Chat to use approved notes.")
            }
        }
    }

    enum DecisionStage: String { case observation, planning, assessment, admission, synthesis, playback }

    enum DecisionReason: String {
        case waitingForTurn, checking, quiet, invalidEvidence, assessmentDeclined, privateInsight
        case sourceUnavailable, processorFailed, resourcesBusy, evaluationLimit
        case superseded, expired, rateLimited, duplicateReply, someoneSpeaking, replyAdmitted
        case voiceBusy, voiceUnavailable, voiceTooLong, synthesisFailed, audioNotStarted, audioStarted
    }

    struct DecisionProgress: Equatable {
        let stage: DecisionStage
        let reason: DecisionReason
    }

    struct WorkspaceDraft: Identifiable, Equatable {
        let id: String
        let text: String
    }

    private struct DecisionTrace {
        let grantID: UUID
        let revision: Int
        let output: ParticipationOutput
        let source: ParticipationObservation.Source
    }

    private enum AudiencePolicy: String {
        case liveSession, reviewedRoster
    }

    @Published private(set) var status: Status = .inactive
    @Published private(set) var reason: Reason?
    @Published private(set) var latestDecision: DecisionProgress?
    var statusDetail: String { reason.map { status.title + ". " + $0.message } ?? status.title }
    @Published private(set) var queuedText: String?
    @Published private(set) var workspaceQueuedDraft: WorkspaceDraft?
    @Published private(set) var workspaceHeldDraft: WorkspaceDraft?
    @Published private(set) var workspaceGuidance: [String] = []
    private(set) var workspacePauseID: UUID?
    @Published private(set) var privateInsight: String?
    @Published private(set) var receipts: [ParticipationReceipt] = []
    @Published private(set) var voiceReplies: [ParticipationVoiceReply] = []
    @Published private(set) var voiceInProgress = false
    @Published private(set) var receiptWarning = false
    @Published private(set) var rosterEpoch: UInt64 = 0
    @Published private(set) var revokedNoteIDs: Set<UUID> = []
    private(set) var startFailure: Reason?

    private struct Grant {
        let id = UUID()
        var setup: ParticipationSetup
        let audiencePolicy: AudiencePolicy
        let objective: String
        let output: ParticipationOutput
        let planner: ParticipationPlanner
        let attentionStore: AttentionStore
        let store: ParticipationReceiptStore
        var sources: ParticipationSourceBinding
    }

    private struct Turn {
        let line: ParticipationLine
        let timestamp: Date
        let source: ParticipationObservation.Source
        let participantID: String?
        let spokenAt: Date?
    }

    private struct Pending {
        let text: String
        let store: ParticipationReceiptStore
        let permit: GuestChatDispatchPermit
        let audience: ParticipationAudience
        var workspaceReplyID: String? = nil
    }

    private struct DraftContext {
        let turn: Turn
        let trace: DecisionTrace
    }

    private var workspaceCandidateContext: DraftContext?
    private var workspaceHeldContext: DraftContext?
    private weak var model: NativeDesktopMeetingModel?
    private var latestAudience: ParticipationAudience?
    private var grant: Grant?
    private var planned: Task<Void, Never>?
    private var voicePlayback: GuestAutonomousVoicePlayback?
    private var voiceTask: Task<Void, Never>?
    private var voiceEchoWindows: [(start: Date, end: Date?)] = []
    private var recentTranscriptObservations: [ParticipationObservation] = []
    private var sourceExpiry: Task<Void, Never>?
    private var turns: [Turn] = []
    private var seen: [String: Date] = [:]
    private var watermark = 0
    private var attempts: [Date] = []
    private var unsolicited: [Date] = []
    private var sentText: [(Date, String)] = []
    private var evaluations: [Date] = []
    private var pending: [String: Pending] = [:]
    private var workspaceOutboundTasks: [UUID: Task<Void, Never>] = [:]
    private var startedAt: Date = .distantFuture
    private var liveAudienceChanged = false
    private var newestTurnAt: Date = .distantPast
    private var settings: Set<AnyCancellable> = []
    #if DEBUG
    private var observationFixture: (audience: ParticipationAudience, trigger: (ParticipationLine) -> Void)?
    var planForTesting: ((ParticipationInput) async throws -> ParticipationDecision)?
    var assessForTesting: ((ParticipationDecision, String, ParticipationInput) async throws -> Bool)?
    var decisionDelayForTesting: Duration?
    var allowsUnavailableAppleForTesting = false

    func observeForTesting(audience: ParticipationAudience, enteredAt: Date, trigger: @escaping (ParticipationLine) -> Void) {
        observationFixture = (audience, trigger)
        beginObserving()
        startedAt = enteredAt
        newestTurnAt = enteredAt
    }
    var candidateRevisionForTesting: Int { watermark }

    func seedPendingChatForTesting() throws -> GuestChatDispatchPermit {
        guard let grant else { throw NativeDesktopGuestError.notConnected }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture)
        pending[UUID().uuidString] = Pending(text: "Pending", store: grant.store, permit: permit, audience: grant.setup.audience)
        return permit
    }

    func seedDispatchedChatForTesting(id: String, text: String) throws {
        guard let grant else { throw NativeDesktopGuestError.notConnected }
        let permit = GuestChatDispatchPermit(deadline: .distantFuture)
        guard permit.dispatch({}) else { throw NativeDesktopGuestError.notConnected }
        let receipt = ParticipationReceipt(id: ParticipationReceipt.hash(id), sessionID: grant.setup.audience.sessionID,
            grantID: grant.id, payloadHash: ParticipationReceipt.hash(text), evidenceRevisions: [],
            createdAt: Date(), updatedAt: Date(), state: .reserved, providerMessageID: id)
        try grant.store.reserve(receipt)
        receipts.insert(receipt, at: 0)
        pending[id] = Pending(text: text, store: grant.store, permit: permit, audience: grant.setup.audience)
    }
    #endif

    func setup(for model: NativeDesktopMeetingModel, store: AttentionStore) -> ParticipationSetup? {
        guard store.enabled, let audience = model.participationAudience, supports(store.provider),
              !store.provider.needsKey || store.hasKey(for: store.provider) else { return nil }
        return ParticipationSetup(audience: audience, provider: store.provider, rosterEpoch: rosterEpoch, voice: store.voiceConfiguration)
    }

    private func supports(_ provider: AttentionProvider) -> Bool {
        #if DEBUG
        if allowsUnavailableAppleForTesting, provider.kind == .apple { return true }
        #endif
        return ParticipationPlanner.supports(provider)
    }

    func start(_ approved: ParticipationSetup, objective: String, model: NativeDesktopMeetingModel, store: AttentionStore,
               context: ParticipationKnowledgeReviewContext? = nil,
               notes: [ParticipationKnowledgeApproval] = [], output: ParticipationOutput = .chat) -> Bool {
        let noteIDs = Set(notes.map(\.id))
        guard let current = setup(for: model, store: store), approved.matches(current, output: .chat) else {
            return rejectStart(.setupChanged)
        }
        guard output != .voice || approved.voice == current.voice else { return rejectStart(.voiceChanged) }
        guard noteIDs.isDisjoint(with: revokedNoteIDs) else { return rejectStart(.noteAccessChanged) }
        guard output != .voice || model.participationVoiceAvailable else { return rejectStart(.voiceUnavailable) }
        guard output != .voice || approved.voice.engine != .rapidMLX || notes.isEmpty else {
            return rejectStart(.noteVoiceProcessor)
        }
        if let context, context != approved.knowledgeContext(title: model.title, expiresAt: context.expiresAt) {
            return rejectStart(.noteAccessChanged)
        }
        guard let sources = ParticipationSourceBinding(context: notes.isEmpty ? nil : context, approvals: notes)
        else { return rejectStart(.noteUnavailable) }
        startFailure = nil
        clearGrant(preserving: noteIDs)
        self.model = model
        latestAudience = approved.audience
        liveAudienceChanged = false
        grant = Grant(setup: approved, audiencePolicy: notes.isEmpty ? .liveSession : .reviewedRoster,
            objective: String(objective.trimmed.prefix(180)), output: output,
            planner: ParticipationPlanner(provider: approved.provider, key: store.apiKey(for: approved.provider)),
            attentionStore: store, store: ParticipationReceiptStore(root: store.root), sources: sources)
        // These settings emit synchronously on the main actor, before their
        // stored values change. A running writer's permit is revoked here.
        store.$enabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.stop(.assistantDisabled) }
        }.store(in: &settings)
        store.$provider.dropFirst().sink { [weak self] provider in
            if provider != approved.provider { self?.requireReview(.processorChanged) }
        }.store(in: &settings)
        store.$keyedKinds.dropFirst().sink { [weak self] keyedKinds in
            if approved.provider.needsKey && !keyedKinds.contains(approved.provider.kind) {
                self?.requireReview(.processorKeyUnavailable)
            }
        }.store(in: &settings)
        store.$profile.removeDuplicates().dropFirst().sink { [weak self] _ in self?.yieldToUser() }.store(in: &settings)
        store.$presets.removeDuplicates().dropFirst().sink { [weak self] _ in self?.yieldToUser() }.store(in: &settings)
        let scopes = MeetingWorkspaceGuidance.scopes(for: model)
        store.workspaceGuidance.$rules.map { $0.filter { scopes.contains($0.scope) } }.removeDuplicates().dropFirst()
            .sink { [weak self] _ in self?.yieldToUser() }.store(in: &settings)
        model.$title.removeDuplicates().dropFirst().sink { [weak self] _ in self?.yieldToUser() }.store(in: &settings)
        store.notes.participationDraftChanges(sessionID: model.sessionID).sink { [weak self] in self?.yieldToUser() }
            .store(in: &settings)
        if output == .voice {
            Publishers.CombineLatest4(store.$voiceEngine, store.$voiceBaseURL, store.$voiceModel, store.$voiceDescription)
                .map { AssistantVoiceConfiguration(engine: $0, baseURL: $1, model: $2, description: $3,
                                                   cloneRecordedAt: approved.voice.cloneRecordedAt) }
                .dropFirst()
                .sink { [weak self] voice in
                    if voice != approved.voice { self?.requireReview(.voiceChanged, revokeSources: false) }
                }
                .store(in: &settings)
            if approved.voice.engine == .cloned {
                VoiceCloneStore.shared.$stored.dropFirst().sink { [weak self] stored in
                    if stored?.recordedAt != approved.voice.cloneRecordedAt {
                        self?.requireReview(.voiceChanged, revokeSources: false)
                    }
                }.store(in: &settings)
            }
        }
        if let expiry = sources.context?.expiresAt, let grantID = grant?.id {
            sourceExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
                catch { return }
                if let self, self.grant?.id == grantID { self.requireReview(.noteAccessExpired) }
            }
        }
        beginObserving(event: "started")
        store.lastParticipationOutput = output
        return true
    }

    private func rejectStart(_ reason: Reason) -> Bool {
        startFailure = reason
        probeLog("participation-lifecycle", ["state": status.rawValue, "action": "startRejected", "reason": reason.rawValue])
        return false
    }

    func pause() {
        guard status == .observing else { return }
        model?.cancelWorkspaceApprovedOutputs()
        cancelOutbound()
        workspacePauseID = UUID()
        transition(to: .paused, reason: .userPaused)
    }

    func resume() {
        guard status == .paused, let grant else { return }
        if let change = Self.audienceChange(from: grant.setup.audience, to: model?.participationAudience) {
            requireReview(change)
            return
        }
        if let context = grant.sources.context, Date() >= context.expiresAt {
            requireReview(.noteAccessExpired)
            return
        }
        beginObserving(event: "resumed")
    }

    func requireReview(_ reason: Reason, revokeSources: Bool = true) {
        guard grant != nil else { return }
        cancelOutbound()
        if revokeSources {
            sourceExpiry?.cancel(); sourceExpiry = nil
            revokeBoundNotes()
            grant?.sources = .empty
        }
        privateInsight = nil
        transition(to: .review, reason: reason)
    }

    var sourceContext: ParticipationKnowledgeReviewContext? { grant?.sources.context }
    var objective: String { grant?.objective ?? "" }
    var output: ParticipationOutput { grant?.output ?? .chat }

    @discardableResult func applyWorkspaceGuidance(_ text: String, for meeting: NativeDesktopMeetingModel) -> Bool {
        let clean = text.trimmed
        guard meeting.participation === self, meeting.connected, !meeting.isClosed, !clean.isEmpty,
              clean.count <= MeetingWorkspaceGuidance.maximumLength,
              workspaceGuidance.reduce(clean.count, { $0 + $1.count }) <= MeetingWorkspaceGuidance.maximumScopeLength
        else { return false }
        yieldToUser()
        privateInsight = nil
        workspaceGuidance.append(clean)
        meeting.workspaceJournal?.recordGuidance(sessionID: meeting.sessionID, text: clean, source: "live")
        return true
    }

    @discardableResult func holdWorkspaceDraft(id: String) -> Bool {
        guard let draft = workspaceQueuedDraft, draft.id == id, let context = workspaceCandidateContext else { return false }
        workspaceHeldDraft = draft
        workspaceHeldContext = context
        cancelCandidate(workspaceStatus: .held)
        return true
    }

    @discardableResult func saveWorkspaceDraft(id: String, text: String) -> Bool {
        let clean = text.trimmed
        guard workspaceHeldDraft?.id == id, validWorkspaceDraftText(clean), let model,
              !model.isClosed else { return false }
        if workspaceHeldDraft?.text == clean { return true }
        guard model.workspaceJournal?.reviseHeldReply(sessionID: model.sessionID, id: id, text: clean) == true else { return false }
        workspaceHeldDraft = .init(id: id, text: clean)
        return true
    }

    func canRequeueWorkspaceDraft(id: String) -> Bool {
        guard let context = workspaceHeldContext, workspaceHeldDraft?.id == id,
              let grant, grant.id == context.trace.grantID, status == .observing,
              workspaceQueuedDraft == nil, !voiceInProgress, let model, model.participationMeetingSoundOn,
              grant.output != .voice || model.participationVoiceEligible,
              turns.last?.line == context.turn.line, Date().timeIntervalSince(context.turn.timestamp) <= 30,
              grant.setup.rosterEpoch == rosterEpoch, model.participationAudience == grant.setup.audience
        else { return false }
        return true
    }

    @discardableResult func requeueWorkspaceDraft(id: String, text: String) -> Bool {
        guard canRequeueWorkspaceDraft(id: id), saveWorkspaceDraft(id: id, text: text),
              let draft = workspaceHeldDraft, let context = workspaceHeldContext else { return false }
        yieldToUser()
        workspaceHeldDraft = nil
        workspaceHeldContext = nil
        let prior = context.trace
        let trace = DecisionTrace(grantID: prior.grantID, revision: watermark, output: prior.output, source: prior.source)
        noteDecision(.checking, at: .planning, trace)
        planned = Task { [weak self] in
            await self?.evaluate(trace, turn: context.turn, revisedDraft: draft.text)
        }
        return true
    }

    private func validWorkspaceDraftText(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 600 && text.split(whereSeparator: \.isWhitespace).count <= 60
            && !text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || $0.properties.generalCategory == .format }
    }
    #if DEBUG
    func setVoicePlaybackForTesting(_ permit: GuestAutonomousVoicePlayback, reply: ParticipationVoiceReply? = nil) {
        voicePlayback = permit
        voiceInProgress = true
        if let reply { voiceReplies.append(reply) }
    }
    #endif

    func interruptVoice() {
        guard let voicePlayback else { return }
        voicePlayback.cancel()
        voiceTask?.cancel()
    }

    func stopVoiceAndWait() async {
        guard voicePlayback != nil else { return }
        let task = voiceTask
        interruptVoice()
        await task?.value
    }

    func waitForWorkspaceOutbound() async {
        for task in Array(workspaceOutboundTasks.values) { await task.value }
    }

    func workspaceSoundTurnedOff() {
        if let draft = workspaceQueuedDraft { privateInsight = draft.text }
        cancelCandidate(workspaceStatus: .held)
        workspaceHeldDraft = nil
        workspaceHeldContext = nil
        cancelPendingDispatch()
    }

    func setVoiceLocalGain(_ gain: Float) { voicePlayback?.setLocalGain(gain) }
    var approvedNotes: [ParticipationKnowledgeApproval] {
        guard let sources = grant?.sources else { return [] }
        return sources.approvals.filter { sources.scope.contains($0.grant) }
    }

    func revokeSource(_ id: UUID) {
        guard let grant, grant.sources.approvals.contains(where: { $0.id == id }) else {
            revokedNoteIDs.insert(id)
            return
        }
        requireReview(.noteAccessChanged, revokeSources: false)
        revokedNoteIDs.insert(id)
        grant.sources.revokeAll()
        let remaining = grant.sources.approvals.filter { $0.id != id }
        self.grant?.sources = ParticipationSourceBinding(context: grant.sources.context, approvals: remaining) ?? .empty
    }

    func stop(_ reason: Reason = .modeChanged) {
        let wasActive = grant != nil || status != .inactive
        clearGrant(preserving: [])
        if wasActive { transition(to: .inactive, reason: reason, event: "stopped") }
    }

    private func clearGrant(preserving notes: Set<UUID>) {
        cancelOutbound()
        sourceExpiry?.cancel(); sourceExpiry = nil
        revokeBoundNotes(preserving: notes)
        settings.removeAll()
        grant = nil
        workspaceHeldDraft = nil
        workspaceHeldContext = nil
        privateInsight = nil
    }

    private func revokeBoundNotes(preserving notes: Set<UUID> = []) {
        guard let sources = grant?.sources else { return }
        sources.revokeAll()
        revokedNoteIDs.formUnion(sources.approvals.lazy.map(\.id).filter { !notes.contains($0) })
    }

    func cancelCandidate(workspaceStatus: MeetingWorkspaceEvent.Status = .cancelled) {
        interruptVoice()
        planned?.cancel()
        planned = nil
        queuedText = nil
        if let draft = workspaceQueuedDraft, let model {
            model.workspaceJournal?.updateReplyStatus(sessionID: model.sessionID, id: draft.id, status: workspaceStatus)
        }
        workspaceQueuedDraft = nil
        workspaceCandidateContext = nil
        watermark += 1
        latestDecision = nil
    }

    func yieldToUser() {
        cancelCandidate()
        cancelPendingDispatch()
    }

    func cancelPendingDispatch() {
        for action in pending.values { action.permit.cancel() }
    }

    private func cancelOutbound() {
        yieldToUser()
        turns.removeAll()
        recentTranscriptObservations.removeAll()
    }

    private func beginObserving(event: String = "started") {
        startedAt = Date()
        newestTurnAt = startedAt
        turns.removeAll()
        privateInsight = nil
        transition(to: .observing, event: event)
    }

    private func transition(to status: Status, reason: Reason? = nil, event: String? = nil) {
        guard self.status != status || self.reason != reason || event != nil else { return }
        var fields: [String: Any] = ["state": status.rawValue, "action": event ?? status.rawValue]
        if let reason { fields["reason"] = reason.rawValue }
        if let grant {
            fields["output"] = grant.output.rawValue
            fields["audienceCount"] = grant.setup.audience.members.count
            fields["audiencePolicy"] = grant.audiencePolicy.rawValue
            fields["noteCount"] = grant.sources.approvals.count
        }
        probeLog("participation-lifecycle", fields)
        self.reason = reason
        self.status = status
        if let model {
            model.workspaceJournal?.recordAction(sessionID: model.sessionID,
                text: reason?.message ?? status.title, source: "participation." + (reason?.rawValue ?? status.rawValue))
        }
    }

    private static func audienceChange(from approved: ParticipationAudience, to current: ParticipationAudience?) -> Reason? {
        guard let current else { return .meetingAccessLost }
        guard approved.connection == current.connection, approved.sessionID == current.sessionID,
              approved.room == current.room, approved.providerRoom == current.providerRoom,
              approved.providerGroup == current.providerGroup, approved.localParticipant == current.localParticipant
        else { return .connectionChanged }
        return approved.members == current.members ? nil : .audienceChanged
    }

    /// Call synchronously on transport/permissions/roster changes, including
    /// changes while the popover and meeting window are hidden.
    func updateAudience(_ actual: ParticipationAudience?) {
        guard latestAudience != actual else { return }
        latestAudience = actual
        let nextEpoch = rosterEpoch &+ 1
        if let grant, status == .observing, grant.audiencePolicy == .liveSession,
           let actual, Self.audienceChange(from: grant.setup.audience, to: actual) == .audienceChanged {
            cancelOutbound()
            seen.removeAll()
            self.grant?.setup = ParticipationSetup(audience: actual, provider: grant.setup.provider,
                                                   rosterEpoch: nextEpoch, voice: grant.setup.voice)
            liveAudienceChanged = true
            beginObserving(event: "liveAudienceUpdated")
        } else if let grant, status == .observing || status == .paused,
                  let change = Self.audienceChange(from: grant.setup.audience, to: actual) {
            requireReview(change)
        }
        rosterEpoch = nextEpoch
    }

    func observe(_ features: GuestMeetingSnapshot, transcriptSource: ParticipationTranscriptSource,
                 localTranscript: [ParticipationLocalTranscriptLine]) {
        observeEchoes(features.messages)
        guard status == .observing else { return }
        #if DEBUG
        if let fixture = observationFixture {
            if let turn = consume(features, transcriptSource: transcriptSource, localTranscript: localTranscript,
                                  audience: fixture.audience) {
                fixture.trigger(turn.line)
            }
            return
        }
        #endif
        guard let grant, let latest = consume(features, transcriptSource: transcriptSource,
                                              localTranscript: localTranscript, audience: grant.setup.audience) else { return }
        let trace = DecisionTrace(grantID: grant.id, revision: watermark, output: grant.output, source: latest.source)
        noteDecision(.waitingForTurn, at: .observation, trace)
        planned = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.decisionDelay ?? .seconds(5))
                await self?.evaluate(trace, turn: latest)
            } catch is CancellationError {
                self?.noteDecision(.superseded, at: .observation, trace)
            } catch {
                self?.noteDecision(.superseded, at: .observation, trace)
            }
        }
    }

    private func consume(_ features: GuestMeetingSnapshot, transcriptSource: ParticipationTranscriptSource,
                         localTranscript: [ParticipationLocalTranscriptLine], audience: ParticipationAudience) -> Turn? {
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 180 }
        var events = features.messages.suffix(40).map { ParticipationObservation($0, source: .chat) }
        switch transcriptSource {
        case .unavailable: break
        case .service:
            if features.transcriptionStatus == .active && features.permissions.canViewTranscript {
                events += features.transcript.suffix(40).map { ParticipationObservation($0, source: .serviceTranscript) }
            }
        case .localRoomAudio:
            events += localTranscript.suffix(40).map(ParticipationObservation.init)
        }
        if liveAudienceChanged {
            // A delayed provider event can arrive after the roster update even
            // though its turn belongs to the previous audience.
            events.removeAll { event in
                guard let spokenAt = event.spokenAt else { return true }
                return spokenAt < startedAt
            }
        }
        let currentLines = Dictionary(events.compactMap { event -> (String, String)? in
            guard event.delivery == .sent,
                  let line = event.line(members: audience.members, localParticipant: audience.localParticipant) else { return nil }
            return (line.id, line.text)
        }, uniquingKeysWith: { _, newest in newest })
        // History and transcription are mutable snapshots. An edit, removal
        // or permission change invalidates work built from the previous view.
        if turns.contains(where: { currentLines[$0.line.id] != $0.line.text }) {
            yieldToUser()
            privateInsight = nil
            turns.removeAll { currentLines[$0.line.id] != $0.line.text }
        }
        recentTranscriptObservations.removeAll { now.timeIntervalSince($0.receivedAt ?? .distantPast) > 45 }
        let fresh = events.compactMap { event -> Turn? in
            guard seen[event.id] == nil else { return nil }
            guard let line = event.line(members: audience.members, localParticipant: audience.localParticipant) else {
                if event.source == .localTranscript, let timestamp = event.receivedAt {
                    seen[event.id] = timestamp
                    noteLocal("speaker-scope-rejected")
                }
                return nil
            }
            guard let timestamp = event.isFresh(enteredAt: startedAt, now: now, own: line.own),
                  !line.text.trimmed.isEmpty else { return nil }
            seen[event.id] = timestamp
            if (line.own || event.source == .localTranscript),
               voiceEchoWindows.contains(where: { event.overlapsVoice(start: $0.start, end: $0.end ?? now) }) {
                if event.source == .localTranscript { noteLocal("voice-echo-window") }
                return nil
            }
            // Exact cross-channel echo suppression using the native sender identity.
            let echoed = events.contains { other in
                guard event.source != .chat, other.source == .chat, let participantID = event.participantID,
                      other.participantID == participantID, let otherTime = other.receivedAt else { return false }
                return event.text == other.text && abs(timestamp.timeIntervalSince(otherTime)) <= 12
            }
            guard !echoed else { return nil }
            if event.source != .chat {
                guard !recentTranscriptObservations.contains(where: event.duplicatesTranscript) else { return nil }
                recentTranscriptObservations.append(event)
                if recentTranscriptObservations.count > 80 { recentTranscriptObservations.removeFirst() }
            }
            if event.source == .localTranscript { noteLocal(line.speakerVerified ? "accepted-identified" : "accepted-unidentified") }
            return Turn(line: line, timestamp: timestamp, source: event.source,
                        participantID: event.participantID, spokenAt: event.spokenAt)
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.line.id < $1.line.id
        }
        guard let latest = fresh.last else { return nil }
        if seen.count > 512 {
            let recent = seen.sorted { $0.value > $1.value }.prefix(512)
            seen = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
        turns = Array((turns + fresh).filter { now.timeIntervalSince($0.timestamp) < 120 }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.line.id < $1.line.id
        }.suffix(12))
        if latest.source == .localTranscript, latest.timestamp <= newestTurnAt {
            if turns.contains(where: { $0.line.id == latest.line.id }) { yieldToUser() }
            return nil
        }
        newestTurnAt = max(newestTurnAt, latest.timestamp)
        yieldToUser()
        return latest.line.own ? nil : latest
    }

    func beginVoiceEchoWindow() {
        voiceEchoWindows.append((Date(), nil))
        if voiceEchoWindows.count > 4 { voiceEchoWindows.removeFirst() }
    }

    func endVoiceEchoWindow() {
        if let last = voiceEchoWindows.indices.last { voiceEchoWindows[last].end = Date() }
    }

    private func noteLocal(_ result: String) {
        probeLog("participation-local-transcript", ["result": result])
    }

    private var decisionDelay: Duration {
        #if DEBUG
        if let decisionDelayForTesting { return decisionDelayForTesting }
        #endif
        return .seconds(5)
    }

    private func noteDecision(_ reason: DecisionReason, at stage: DecisionStage, _ trace: DecisionTrace,
                              kind: ParticipationDecision.Kind? = nil,
                              assessment: ParticipationPlanner.AssessmentOutcome? = nil) {
        var fields = ["stage": stage.rawValue, "reason": reason.rawValue,
            "output": trace.output.rawValue, "source": trace.source.rawValue]
        if let kind { fields["kind"] = kind.rawValue }
        if let assessment { fields["assessment"] = assessment.rawValue }
        probeLog("participation-decision", fields)
        if status == .observing, grant?.id == trace.grantID, watermark == trace.revision {
            latestDecision = .init(stage: stage, reason: reason)
        }
    }

    private func handoffAntecedent(for turn: Turn) -> ParticipationLine? {
        guard turns.last?.line.id == turn.line.id, turn.source == .localTranscript,
              !turn.line.own, turn.line.speakerVerified, let participantID = turn.participantID,
              let spokenAt = turn.spokenAt, let prior = turns.dropLast().last,
              prior.source == .localTranscript, !prior.line.own, prior.line.speakerVerified,
              prior.participantID == participantID else { return nil }
        // Local capture may overlap at a segment boundary because of preroll.
        // Only the immediately preceding segment from this sender is eligible.
        let gap = spokenAt.timeIntervalSince(prior.timestamp)
        return (-0.35...5).contains(gap) ? prior.line : nil
    }

    private func handoffLocalNames(for turn: Turn, audience: ParticipationAudience) -> [String] {
        guard let speaker = turn.participantID, let localName = audience.members[audience.localParticipant] else { return [] }
        let locale = Locale(identifier: "und")
        func nameParts(_ name: String) -> [String] {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
                .split(whereSeparator: \.isWhitespace).map(String.init)
        }
        let localParts = nameParts(localName)
        let possibleRecipients = audience.members.compactMap { id, name in id == speaker ? nil : nameParts(name) }
        // Only exact display-name prefixes unique among possible recipients
        // can bind the name extracted from the preceding audio fragment.
        return localParts.indices.compactMap { index in
            let prefix = Array(localParts[...index])
            let matches = possibleRecipients.filter { $0.starts(with: prefix) }
            return matches.count == 1 ? prefix.joined(separator: " ") : nil
        }
    }

    private func decisionGrant(_ trace: DecisionTrace, turn: Turn, stage: DecisionStage) -> Grant? {
        let grant = current(trace.grantID, revision: trace.revision, turn: turn)
        if grant == nil {
            let reason: DecisionReason = Date().timeIntervalSince(turn.timestamp) > 30 ? .expired : .superseded
            noteDecision(reason, at: stage, trace)
        }
        return grant
    }

    private func decisionSources(_ grant: Grant, _ trace: DecisionTrace, turn: Turn, stage: DecisionStage,
                                 matching query: String? = nil) async -> [ParticipationSource]? {
        guard let sources = await checkedSources(grant, matching: query) else {
            noteDecision(Task.isCancelled ? .superseded : .sourceUnavailable, at: stage, trace)
            return nil
        }
        return decisionGrant(trace, turn: turn, stage: stage) == nil ? nil : sources
    }

    private func processorFailed(at stage: DecisionStage, _ trace: DecisionTrace) {
        if Task.isCancelled || grant?.id != trace.grantID || watermark != trace.revision {
            noteDecision(.superseded, at: stage, trace)
            return
        }
        noteDecision(.processorFailed, at: stage, trace)
        cancelOutbound()
        transition(to: .unavailable, reason: .processorFailed)
    }

    private func evaluate(_ trace: DecisionTrace, turn: Turn, revisedDraft: String? = nil) async {
        guard let grant = decisionGrant(trace, turn: turn, stage: .planning),
              let model,
              let sources = await decisionSources(grant, trace, turn: turn, stage: .planning, matching: turn.line.text)
        else { return }
        let now = Date()
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical || AttentionMemoryPressure.shared.pressured {
            noteDecision(.resourcesBusy, at: .planning, trace)
            return
        }
        evaluations = evaluations.filter { now.timeIntervalSince($0) < 60 }
        guard evaluations.count < 12 else { noteDecision(.evaluationLimit, at: .planning, trace); return }
        evaluations.append(now)
        let antecedent = handoffAntecedent(for: turn)
        var context = await ParticipationContext.read(model: model, store: grant.attentionStore,
            query: [antecedent?.text, turn.line.text].compactMap { $0 }.joined(separator: " "), includeVault: false)
        guard decisionGrant(trace, turn: turn, stage: .planning) != nil else { return }
        guard context.validates(model: model, store: grant.attentionStore) else {
            noteDecision(.sourceUnavailable, at: .planning, trace)
            return
        }
        var input = ParticipationInput(objective: grant.objective, trigger: turn.line.id,
            turns: turns.map(\.line), sources: sources + context.sources, output: grant.output,
            localAttendeeName: grant.setup.audience.members[grant.setup.audience.localParticipant].map { String($0.prefix(80)) },
            triggerSource: turn.source, attendeeCount: grant.setup.audience.members.count,
            handoffAntecedent: antecedent,
            handoffLocalNames: handoffLocalNames(for: turn, audience: grant.setup.audience),
            replyInstructions: context.instructions, vaultAvailable: context.canSearchVault && turn.line.speakerVerified)
        var plannedDecision: ParticipationDecision
        noteDecision(.checking, at: .planning, trace)
        do {
            plannedDecision = try await plan(input, using: grant.planner)
            let query = plannedDecision.vaultQuery.trimmed
            if !query.isEmpty {
                guard decisionGrant(trace, turn: turn, stage: .planning) != nil else { return }
                guard input.vaultAvailable, query.count <= 180, query.utf8.count <= 600,
                      plannedDecision.kind == .quiet, plannedDecision.text.isEmpty,
                      plannedDecision.citations.isEmpty, !plannedDecision.directlyAddressed,
                      context.validates(model: model, store: grant.attentionStore) else {
                    noteDecision(.invalidEvidence, at: .planning, trace)
                    return
                }
                context = await ParticipationContext.read(model: model, store: grant.attentionStore, query: query, includeVault: true)
                guard decisionGrant(trace, turn: turn, stage: .planning) != nil else { return }
                guard context.validates(model: model, store: grant.attentionStore) else {
                    noteDecision(.sourceUnavailable, at: .planning, trace)
                    return
                }
                input.sources = sources + context.sources.filter {
                    $0.id != ParticipationSource.meetingMetadataID || plannedDecision.asksAboutCurrentMeeting
                }
                input.replyInstructions = context.instructions
                input.vaultAvailable = false
                input.vaultLookupCompleted = true
                plannedDecision = try await plan(input, using: grant.planner)
            }
        } catch { processorFailed(at: .planning, trace); return }
        guard decisionGrant(trace, turn: turn, stage: .planning) != nil else { return }
        if plannedDecision.kind == .quiet {
            noteDecision(.quiet, at: .planning, trace)
            return
        }
        if let revisedDraft {
            guard plannedDecision.kind != .privateInsight else { return }
            if let opening = plannedDecision.authorizedOpening {
                guard revisedDraft.hasPrefix(opening + " ") else { return }
                plannedDecision.text = String(revisedDraft.dropFirst(opening.count + 1))
            } else {
                plannedDecision.text = revisedDraft
            }
        }
        guard let decision = plannedDecision.grounded(in: input), let draft = decision.validated(in: input) else {
            noteDecision(.invalidEvidence, at: .planning, trace)
            return
        }
        guard await decisionSources(grant, trace, turn: turn, stage: .assessment) != nil else { return }
        guard context.validates(model: model, store: grant.attentionStore) else {
            noteDecision(.sourceUnavailable, at: .assessment, trace)
            return
        }
        let assessment: ParticipationPlanner.AssessmentOutcome
        noteDecision(.checking, at: .assessment, trace, kind: decision.kind)
        do {
            #if DEBUG
            if let assessForTesting {
                assessment = try await assessForTesting(decision, draft, input) ? .approved : .generatedDeclined
            }
            else { assessment = try await grant.planner.assess(decision, draft: draft, in: input) }
            #else
            assessment = try await grant.planner.assess(decision, draft: draft, in: input)
            #endif
        } catch { processorFailed(at: .assessment, trace); return }
        guard decisionGrant(trace, turn: turn, stage: .assessment) != nil else { return }
        guard assessment == .approved else {
            noteDecision(.assessmentDeclined, at: .assessment, trace, kind: decision.kind, assessment: assessment)
            return
        }
        guard await decisionSources(grant, trace, turn: turn, stage: .admission) != nil else { return }
        let archiveID = workspaceReplyID(for: turn, trace: trace)
        let archiveSources = workspaceSources(input: input, decision: decision)
        if decision.kind == .privateInsight {
            privateInsight = draft
            model.workspaceJournal?.recordAssistantReply(sessionID: model.sessionID, id: archiveID, text: draft,
                source: "assistantInsight", status: .privateOnly, isPrivate: true, sourceSnapshots: archiveSources)
            noteDecision(.privateInsight, at: .admission, trace)
            return
        }
        let directlyAddressed = decision.directlyAddressed && turn.line.speakerVerified
        if let reason = postRefusal(draft, directlyAddressed: directlyAddressed) {
            noteDecision(reason, at: .admission, trace)
            return
        }
        var archivedCandidate = false
        if !directlyAddressed || revisedDraft != nil {
            queuedText = draft
            archivedCandidate = model.workspaceJournal?.recordAssistantReply(sessionID: model.sessionID, id: archiveID,
                text: draft, source: grant.output.rawValue, status: .queued, isPrivate: true,
                sourceSnapshots: archiveSources) ?? false
            if archivedCandidate {
                workspaceQueuedDraft = .init(id: archiveID, text: draft)
                workspaceCandidateContext = .init(turn: turn, trace: trace)
            }
            do { try await Task.sleep(for: decisionDelay) }
            catch { noteDecision(.superseded, at: .admission, trace); return }
        }
        defer {
            if archivedCandidate, model.workspaceJournal?.session(id: model.sessionID)?.events
                .first(where: { $0.id == "assistant:" + archiveID })?.status == .queued {
                model.workspaceJournal?.updateReplyStatus(sessionID: model.sessionID, id: archiveID, status: .cancelled)
            }
            if workspaceQueuedDraft?.id == archiveID {
                workspaceQueuedDraft = nil
                workspaceCandidateContext = nil
            }
        }
        if self.grant?.id == trace.grantID, watermark == trace.revision {
            queuedText = nil
        }
        guard decisionGrant(trace, turn: turn, stage: .admission) != nil else { return }
        if let reason = postRefusal(draft, directlyAddressed: directlyAddressed) {
            noteDecision(reason, at: .admission, trace)
            return
        }
        guard await context.revalidate(model: model, store: grant.attentionStore),
              context.validates(model: model, store: grant.attentionStore) else {
            noteDecision(.sourceUnavailable, at: .admission, trace)
            return
        }
        guard decisionGrant(trace, turn: turn, stage: .admission) != nil else { return }
        guard model.participationMeetingSoundOn else {
            model.workspaceJournal?.recordAssistantReply(sessionID: model.sessionID, id: archiveID, text: draft,
                source: grant.output.rawValue, status: .held, isPrivate: true, sourceSnapshots: archiveSources)
            privateInsight = draft
            return
        }
        guard !model.participationSomeoneSpeaking else {
            noteDecision(.someoneSpeaking, at: .admission, trace)
            return
        }
        workspaceQueuedDraft = nil
        workspaceCandidateContext = nil
        noteDecision(.replyAdmitted, at: .admission, trace)
        if grant.output == .voice {
            await dispatchVoice(draft, for: turn, grant: grant, context: context, trace: trace,
                directlyAddressed: directlyAddressed, archiveID: archiveID, archiveSources: archiveSources)
        } else {
            await dispatch(draft, for: turn, grant: grant, context: context, trace: trace,
                directlyAddressed: directlyAddressed, archiveID: archiveID, archiveSources: archiveSources)
        }
    }

    private func plan(_ input: ParticipationInput, using planner: ParticipationPlanner) async throws -> ParticipationDecision {
        #if DEBUG
        if let planForTesting { return try await planForTesting(input) }
        #endif
        return try await planner.plan(input)
    }

    private func current(_ id: UUID, revision: Int, turn: Turn) -> Grant? {
        guard !Task.isCancelled, status == .observing, let grant, grant.id == id, watermark == revision,
              grant.setup.rosterEpoch == rosterEpoch,
              model?.participationAudience == grant.setup.audience,
              Date().timeIntervalSince(turn.timestamp) <= 30 else { return nil }
        if let expiry = grant.sources.context?.expiresAt, Date() >= expiry {
            requireReview(.noteAccessExpired)
            return nil
        }
        return grant
    }

    private func checkedSources(_ grant: Grant, matching query: String? = nil) async -> [ParticipationSource]? {
        let binding = grant.sources
        guard !binding.approvals.isEmpty else { return [] }
        let sources = await binding.readBounded(matching: query)
        if sources == nil, !Task.isCancelled, self.grant?.id == grant.id { requireReview(.noteUnavailable) }
        return sources
    }

    private func postRefusal(_ draft: String, directlyAddressed: Bool) -> DecisionReason? {
        guard !directlyAddressed else { return nil }
        let now = Date()
        attempts = attempts.filter { now.timeIntervalSince($0) < 900 }
        unsolicited = unsolicited.filter { now.timeIntervalSince($0) < 900 }
        sentText = sentText.filter { now.timeIntervalSince($0.0) < 900 }
        if sentText.contains(where: { $0.1 == draft }) { return .duplicateReply }
        guard attempts.last.map({ now.timeIntervalSince($0) >= 30 }) ?? true,
              unsolicited.count < 3, unsolicited.last.map({ now.timeIntervalSince($0) >= 180 }) ?? true
        else { return .rateLimited }
        return nil
    }

    private func workspaceReplyID(for turn: Turn, trace: DecisionTrace) -> String {
        [ParticipationReceipt.hash(turn.line.id), trace.grantID.uuidString, String(trace.revision)].joined(separator: ":")
    }

    private func workspaceSources(input: ParticipationInput, decision: ParticipationDecision,
                                  at: Date = .now) -> [MeetingWorkspaceEvent.SourceSnapshot] {
        var result: [MeetingWorkspaceEvent.SourceSnapshot] = [
            .init(id: "objective", title: L("Participation objective"), text: input.objective, revision: nil, capturedAt: at)
        ]
        if let trigger = input.currentTurn {
            result.append(.init(id: "trigger:" + trigger.id, title: trigger.speaker, text: trigger.text,
                revision: ParticipationReceipt.hash(trigger.text), capturedAt: at))
        }
        result += input.turns.filter { $0.id != input.trigger }.map {
            .init(id: $0.id, title: $0.speaker, text: $0.text, revision: nil, capturedAt: at)
        }
        result += input.sources.map {
            .init(id: $0.id, title: $0.title, text: $0.text, revision: $0.revision, capturedAt: at)
        }
        if let antecedent = input.handoffAntecedent, !result.contains(where: { $0.id == antecedent.id }) {
            result.append(.init(id: antecedent.id, title: antecedent.speaker, text: antecedent.text,
                                revision: nil, capturedAt: at))
        }
        if let instructions = input.replyInstructions {
            let guidance: [(String, String, String?)] = [
                ("meetingAbout", L("About this meeting"), instructions.meetingAbout),
                ("meetingPriorities", L("Meeting priorities"), instructions.meetingPriorities),
                ("meetingAvoid", L("Avoid in replies"), instructions.meetingAvoid),
                ("meetingNote", L("Meeting notes"), instructions.meetingNote),
                ("userRole", L("Your role"), instructions.userRole),
                ("replyStyle", L("Reply style"), instructions.replyStyle),
                ("liveGuidance", L("Private guidance"), instructions.workspaceLiveGuidance?.joined(separator: "\n")),
                ("reviewGuidance", L("Review guidance"), instructions.workspaceReviewGuidance?.joined(separator: "\n"))
            ]
            result += guidance.compactMap { id, title, text in
                text.map { .init(id: "guidance:" + id, title: title, text: $0, revision: nil, capturedAt: at) }
            }
        }
        let citations: [MeetingWorkspaceEvent.SourceSnapshot] = decision.citations.enumerated().map { index, citation in
            .init(id: "citation:\(index):" + citation.id, title: L("Cited evidence"), text: citation.quote,
                  revision: result.first(where: { $0.id == citation.id })?.revision, capturedAt: at)
        }
        result += citations
        return result
    }

    private func dispatch(_ text: String, for turn: Turn, grant: Grant, context: ParticipationContext.Snapshot,
                          trace: DecisionTrace, directlyAddressed: Bool, archiveID: String,
                          archiveSources: [MeetingWorkspaceEvent.SourceSnapshot]) async {
        guard let model else { return }
        let now = Date()
        let receipt = ParticipationReceipt(id: ParticipationReceipt.hash(turn.line.id),
            sessionID: model.sessionID, grantID: grant.id, payloadHash: ParticipationReceipt.hash(text),
            evidenceRevisions: grant.sources.revisions + context.sources.map(\.revision), createdAt: now, updatedAt: now,
            state: .reserved, providerMessageID: UUID().uuidString.lowercased())
        let messageID = receipt.providerMessageID!
        if let journal = model.workspaceJournal,
           !journal.recordAssistantReply(sessionID: model.sessionID, id: archiveID, text: text, source: "chat",
                status: .sending, at: now, sourceSnapshots: archiveSources, linkedChatID: "chat:guest:" + messageID) {
            storageFailed(grantID: grant.id)
            return
        }
        do { try grant.store.reserve(receipt) }
        catch {
            model.workspaceJournal?.updateReplyStatus(sessionID: model.sessionID, id: archiveID, status: .cancelled)
            storageFailed(grantID: grant.id)
            return
        }
        let binding = grant.sources
        let expiry = min(turn.timestamp.addingTimeInterval(30), binding.context?.expiresAt ?? .distantFuture)
        let needsValidation = !binding.approvals.isEmpty || context.hasVaultSources
        let permit = needsValidation ? GuestChatDispatchPermit(deadline: expiry) {
            (binding.approvals.isEmpty || (try? binding.read()) != nil) && context.validateVaultSources()
        } : GuestChatDispatchPermit(deadline: expiry)
        let vaultChange = context.cancelOnVaultChange { permit.cancel() }
        let persistedNoteChange = context.cancelOnPersistedNoteChange { permit.cancel() }
        defer { vaultChange?.cancel(); persistedNoteChange?.cancel() }
        pending[messageID] = Pending(text: text, store: grant.store, permit: permit, audience: grant.setup.audience,
                                     workspaceReplyID: archiveID)
        let outboundID = UUID()
        workspaceOutboundTasks[outboundID] = planned
        defer { workspaceOutboundTasks[outboundID] = nil }
        receipts.insert(receipt, at: 0)
        // Charge attempts before leaving the main actor. Unknown effects can
        // never free budget for retries or additional traffic.
        attempts.append(now)
        if !directlyAddressed { unsolicited.append(now) }
        sentText.append((now, text))
        let state: ParticipationReceipt.State
        do {
            try await model.sendParticipationChat(text, id: messageID, audience: grant.setup.audience, permit: permit)
            state = permit.didDispatch ? .serverAccepted : .cancelled
        } catch {
            if !permit.didDispatch { state = .cancelled }
            else if case GuestTransportError.server = error { state = .failed }
            else { state = .unknown }
        }
        record(messageID, state)
        if permit.validationFailed, self.grant?.id == grant.id, status == .observing {
            noteDecision(.sourceUnavailable, at: .admission, trace)
            if !binding.approvals.isEmpty, (await binding.readBounded(matching: nil)) == nil,
               self.grant?.id == grant.id, status == .observing { requireReview(.noteUnavailable) }
        }
        // Retain a short window for a late echo. No retries or replay.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.pending[messageID] = nil
        }
    }

    private func dispatchVoice(_ draft: String, for turn: Turn, grant: Grant, context: ParticipationContext.Snapshot, trace: DecisionTrace,
                               directlyAddressed: Bool, archiveID: String,
                               archiveSources: [MeetingWorkspaceEvent.SourceSnapshot]) async {
        guard let model else { noteDecision(.superseded, at: .synthesis, trace); return }
        let journal = model.workspaceJournal
        if let journal, journal.session(id: model.sessionID)?.events.contains(where: { $0.id == "assistant:" + archiveID }) != true,
           !journal.recordAssistantReply(sessionID: model.sessionID, id: archiveID, text: draft, source: "voice",
                status: .queued, isPrivate: true, sourceSnapshots: archiveSources) {
            storageFailed(grantID: grant.id)
            return
        }
        var archiveTerminal: MeetingWorkspaceEvent.Status = .held
        defer {
            journal?.updateReplyStatus(sessionID: model.sessionID, id: archiveID, status: archiveTerminal,
                                       isPrivate: archiveTerminal == .cancelled ? true : nil)
        }
        guard voicePlayback == nil else { noteDecision(.voiceBusy, at: .synthesis, trace); return }
        let id = ParticipationReceipt.hash(turn.line.id)
        guard !voiceReplies.contains(where: { $0.id == id }) else {
            noteDecision(.duplicateReply, at: .synthesis, trace)
            return
        }
        let now = Date()
        voiceReplies.append(.init(id: id, text: draft, createdAt: now, status: .textOnly))
        if voiceReplies.count > 50 { voiceReplies.removeFirst(voiceReplies.count - 50) }
        guard !model.voiceReplyActive else { noteDecision(.voiceBusy, at: .synthesis, trace); return }
        guard model.participationVoiceEligible else {
            privateInsight = draft
            noteDecision(.voiceUnavailable, at: .synthesis, trace)
            return
        }
        guard draft.split(whereSeparator: \.isWhitespace).count <= 35 else {
            noteDecision(.voiceTooLong, at: .synthesis, trace)
            return
        }

        let expiry = min(turn.timestamp.addingTimeInterval(30), grant.sources.context?.expiresAt ?? .distantFuture)
        let permit = GuestAutonomousVoicePlayback(deadline: expiry)
        voicePlayback = permit
        let interruptOnContextChange: @Sendable () -> Void = { [weak self, weak permit] in
            Task { @MainActor in
                guard let self, let permit, self.voicePlayback === permit else { return }
                self.interruptVoice()
            }
        }
        let vaultChange = context.cancelOnVaultChange(interruptOnContextChange)
        let persistedNoteChange = context.cancelOnPersistedNoteChange(interruptOnContextChange)
        voiceTask = planned
        let outboundID = UUID()
        workspaceOutboundTasks[outboundID] = planned
        voiceInProgress = true
        setVoiceStatus(.preparing, for: id)
        defer {
            vaultChange?.cancel()
            persistedNoteChange?.cancel()
            voicePlayback = nil
            voiceTask = nil
            workspaceOutboundTasks[outboundID] = nil
            voiceInProgress = false
            if permit.started { endVoiceEchoWindow() }
        }
        let language = VoiceSynthesis.language(of: draft) ?? Locale.preferredLanguages.first ?? "en-US"
        let buffer: AVAudioPCMBuffer
        noteDecision(.checking, at: .synthesis, trace)
        guard Date() < expiry else {
            noteDecision(.expired, at: .synthesis, trace)
            setVoiceStatus(.textOnly, for: id)
            return
        }
        let synthesisRequest = UUID()
        let synthesisExpiry: Task<Void, Never>? = grant.setup.voice.engine == .cloned
            ? GuestVoiceSynthesisDeadline.schedule(expiry) { [weak self, weak permit] in
                guard let self, let permit, self.voicePlayback === permit, !permit.started else { return }
                Task { await VoiceCloneStore.shared.cancelGPURequest(synthesisRequest) }
            } : nil
        do {
            defer { synthesisExpiry?.cancel() }
            buffer = try await grant.setup.voice.synthesize(draft, language: language, session: ParticipationNoRedirect.session,
                                                             cloneRequest: synthesisRequest, cloneDeadline: expiry)
            try Task.checkCancellation()
        } catch {
            if Task.isCancelled || !permit.canStart {
                noteDecision(Date() >= expiry ? .expired : .superseded, at: .synthesis, trace)
                setVoiceStatus(.textOnly, for: id)
            } else {
                archiveTerminal = .failed
                probeLog("participation-voice", ["voice": grant.setup.voice.engine.rawValue, "result": "synthesisFailed"])
                noteDecision(.synthesisFailed, at: .synthesis, trace)
                setVoiceStatus(.synthesisFailed, for: id)
            }
            return
        }
        guard await context.revalidate(model: model, store: grant.attentionStore) else {
            noteDecision(.sourceUnavailable, at: .synthesis, trace)
            setVoiceStatus(.textOnly, for: id)
            return
        }
        let failure: DecisionReason?
        if Double(buffer.frameLength) / buffer.format.sampleRate > 18 { failure = .voiceTooLong }
        else if current(grant.id, revision: trace.revision, turn: turn) == nil || !permit.canStart {
            failure = Date() >= expiry ? .expired : .superseded
        } else if !model.participationVoiceEligible { failure = .voiceUnavailable }
        else if model.participationSomeoneSpeaking { failure = .someoneSpeaking }
        else { failure = nil }
        if let failure {
            noteDecision(failure, at: .synthesis, trace)
            setVoiceStatus(.textOnly, for: id)
            return
        }
        let receipt = ParticipationReceipt(id: id, sessionID: model.sessionID, grantID: grant.id,
            payloadHash: ParticipationReceipt.hash(draft), evidenceRevisions: grant.sources.revisions + context.sources.map(\.revision),
            createdAt: now, updatedAt: Date(), state: .reserved, providerMessageID: nil, output: .voice)
        if let journal, !journal.recordAssistantReply(sessionID: model.sessionID, id: archiveID, text: draft,
                source: "voice", status: .sending, sourceSnapshots: archiveSources) {
            archiveTerminal = .cancelled
            setVoiceStatus(.textOnly, for: id)
            storageFailed(grantID: grant.id)
            return
        }
        do { try grant.store.reserve(receipt) }
        catch {
            archiveTerminal = .cancelled
            setVoiceStatus(.textOnly, for: id)
            storageFailed(grantID: grant.id)
            return
        }
        receipts.insert(receipt, at: 0)
        attempts.append(now)
        if !directlyAddressed { unsolicited.append(now) }
        sentText.append((now, draft))

        let outcome = await model.playParticipationVoice(buffer, audience: grant.setup.audience, permit: permit,
            preflight: {
                guard self.decisionGrant(trace, turn: turn, stage: .playback) != nil else { return false }
                guard await self.decisionSources(grant, trace, turn: turn, stage: .playback) != nil else { return false }
                if !context.hasVaultSources { return true }
                return await ParticipationSourceBinding.withReadDeadline { context.validateVaultSources() } == true
            }, canStart: {
                self.current(grant.id, revision: trace.revision, turn: turn) != nil
                    && context.validates(model: model, store: grant.attentionStore)
            }, onStarted: {
                self.beginVoiceEchoWindow()
                self.setVoiceStatus(.speaking, for: id)
                self.noteDecision(.audioStarted, at: .playback, trace)
            })
        probeLog("participation-voice", ["voice": grant.setup.voice.engine.rawValue, "result": String(describing: outcome)])
        let result: (ParticipationVoiceReply.Status, ParticipationReceipt.State)
        switch outcome {
        case .notStarted: result = (.textOnly, .cancelled); archiveTerminal = .cancelled
        case .completed: result = (.completed, .voicePlayed); archiveTerminal = .spoken
        case .interrupted: result = (.interrupted, .voiceInterrupted); archiveTerminal = .interrupted
        case .unknown: result = (.unknown, .unknown); archiveTerminal = .unknown
        }
        if outcome == .notStarted, latestDecision?.stage != .playback { noteDecision(.audioNotStarted, at: .playback, trace) }
        setVoiceStatus(result.0, for: id)
        record(receipt.id, grantID: grant.id, state: result.1, store: grant.store)
    }

    private func setVoiceStatus(_ status: ParticipationVoiceReply.Status, for id: String) {
        guard let index = voiceReplies.firstIndex(where: { $0.id == id }) else { return }
        voiceReplies[index].status = status
    }

    private func storageFailed(grantID: UUID) {
        receiptWarning = true
        if grant?.id == grantID, status == .observing {
            cancelOutbound()
            transition(to: .unavailable, reason: .storageFailed)
        }
    }

    private func observeEchoes(_ messages: [GuestMeetingMessage]) {
        guard let model else { return }
        for message in messages where message.isOwn && message.receivedAt != nil {
            guard let action = pending[message.id], action.permit.didDispatch, message.text == action.text,
                  model.participationConnection == action.audience.connection,
                  message.participantID == action.audience.localParticipant,
                  let receivedAt = message.receivedAt else { continue }
            // Correlate the own echo before consuming new turns. Echo
            // suppression cannot depend on which words were sent.
            seen[ParticipationObservation(message, source: .chat).id] = receivedAt
            record(message.id, .confirmed)
        }
    }

    private func record(_ messageID: String, _ state: ParticipationReceipt.State) {
        guard let action = pending[messageID],
              let receipt = receipts.first(where: { $0.providerMessageID == messageID }) else { return }
        if let model, let id = action.workspaceReplyID {
            let status: MeetingWorkspaceEvent.Status = switch state {
            case .reserved: .sending
            case .cancelled: .cancelled
            case .failed: .failed
            case .unknown: .unknown
            case .serverAccepted: .accepted
            case .confirmed: .sent
            case .voicePlayed: .spoken
            case .voiceInterrupted: .interrupted
            }
            model.workspaceJournal?.updateReplyStatus(sessionID: model.sessionID, id: id, status: status,
                                                       isPrivate: status == .cancelled ? true : nil)
        }
        record(receipt.id, grantID: receipt.grantID, state: state, store: action.store)
    }

    private func record(_ id: String, grantID: UUID, state: ParticipationReceipt.State, store: ParticipationReceiptStore) {
        guard let index = receipts.firstIndex(where: { $0.id == id && $0.grantID == grantID }),
              receipts[index].state != .confirmed, receipts[index].state != state else { return }
        var receipt = receipts[index]
        receipt.state = state
        receipt.updatedAt = Date()
        do {
            try store.update(receipt)
            receipts[index] = receipt
        } catch {
            storageFailed(grantID: grantID)
        }
    }
}
