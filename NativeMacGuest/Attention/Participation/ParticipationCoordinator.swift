import Combine
import ConferenceCore
import Foundation

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
    enum Status: Equatable {
        case inactive, observing, paused, review, unavailable

        var title: String {
            switch self {
            case .inactive: L("Participate")
            case .observing: L("Participating")
            case .paused, .review, .unavailable: L("Participation paused")
            }
        }
    }

    static let attribution = "Rock’n’Roll Assistant: "

    @Published private(set) var status: Status = .inactive
    @Published private(set) var queuedText: String?
    @Published private(set) var privateInsight: String?
    @Published private(set) var receipts: [ParticipationReceipt] = []
    @Published private(set) var receiptWarning = false
    @Published private(set) var rosterEpoch: UInt64 = 0
    @Published private(set) var revokedNoteIDs: Set<UUID> = []

    private struct Grant {
        let id = UUID()
        let setup: ParticipationSetup
        let objective: String
        let planner: ParticipationPlanner
        let store: ParticipationReceiptStore
        var sources: ParticipationSourceBinding
    }

    private struct Turn {
        let line: ParticipationLine
        let timestamp: Date
    }

    private struct Pending {
        let text: String
        let store: ParticipationReceiptStore
        let permit: GuestChatDispatchPermit
        let audience: ParticipationAudience
    }

    private weak var model: NativeDesktopMeetingModel?
    private var latestAudience: ParticipationAudience?
    private var grant: Grant?
    private var planned: Task<Void, Never>?
    private var sourceExpiry: Task<Void, Never>?
    private var turns: [Turn] = []
    private var seen: [String: Date] = [:]
    private var watermark = 0
    private var attempts: [Date] = []
    private var unsolicited: [Date] = []
    private var sentText: [(Date, String)] = []
    private var evaluations: [Date] = []
    private var pending: [String: Pending] = [:]
    private var startedAt: Date = .distantFuture
    private var settings: Set<AnyCancellable> = []

    func setup(for model: NativeDesktopMeetingModel, store: AttentionStore) -> ParticipationSetup? {
        guard store.enabled, let audience = model.participationAudience, ParticipationPlanner.supports(store.provider),
              !store.provider.needsKey || store.hasKey(for: store.provider) else { return nil }
        return ParticipationSetup(audience: audience, provider: store.provider, rosterEpoch: rosterEpoch)
    }

    func start(_ approved: ParticipationSetup, objective: String, model: NativeDesktopMeetingModel, store: AttentionStore,
               context: ParticipationKnowledgeReviewContext? = nil,
               notes: [ParticipationKnowledgeApproval] = []) -> Bool {
        let noteIDs = Set(notes.map(\.id))
        guard setup(for: model, store: store) == approved, noteIDs.isDisjoint(with: revokedNoteIDs) else { return false }
        if let context, context != approved.knowledgeContext(title: model.title, expiresAt: context.expiresAt) {
            return false
        }
        guard let sources = ParticipationSourceBinding(context: notes.isEmpty ? nil : context, approvals: notes)
        else { return false }
        clearGrant(preserving: noteIDs)
        self.model = model
        grant = Grant(setup: approved, objective: String(objective.trimmed.prefix(180)),
            planner: ParticipationPlanner(provider: approved.provider, key: store.apiKey(for: approved.provider)),
            store: ParticipationReceiptStore(root: store.root), sources: sources)
        // These settings emit synchronously on the main actor, before their
        // stored values change. A running writer's permit is revoked here.
        store.$enabled.dropFirst().sink { [weak self] enabled in
            if !enabled { self?.stop() }
        }.store(in: &settings)
        store.$provider.dropFirst().sink { [weak self] provider in
            if provider != approved.provider { self?.requireReview() }
        }.store(in: &settings)
        store.$keyedKinds.dropFirst().sink { [weak self] keyedKinds in
            if approved.provider.needsKey && !keyedKinds.contains(approved.provider.kind) { self?.requireReview() }
        }.store(in: &settings)
        if let expiry = sources.context?.expiresAt, let grantID = grant?.id {
            sourceExpiry = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) }
                catch { return }
                if let self, self.grant?.id == grantID { self.requireReview() }
            }
        }
        beginObserving()
        return true
    }

    func pause() {
        guard status == .observing else { return }
        cancelOutbound()
        status = .paused
    }

    func resume() {
        guard status == .paused, let grant, model?.participationAudience == grant.setup.audience,
              grant.sources.context.map({ Date() < $0.expiresAt }) ?? true else { requireReview(); return }
        beginObserving()
    }

    func requireReview(revokeSources: Bool = true) {
        guard grant != nil else { return }
        cancelOutbound()
        if revokeSources {
            sourceExpiry?.cancel(); sourceExpiry = nil
            revokeBoundNotes()
            grant?.sources = .empty
        }
        privateInsight = nil
        status = .review
    }

    var sourceContext: ParticipationKnowledgeReviewContext? { grant?.sources.context }
    var objective: String { grant?.objective ?? "" }
    var approvedNotes: [ParticipationKnowledgeApproval] {
        guard let sources = grant?.sources else { return [] }
        return sources.approvals.filter { sources.scope.contains($0.grant) }
    }

    func revokeSource(_ id: UUID) {
        guard let grant, grant.sources.approvals.contains(where: { $0.id == id }) else {
            revokedNoteIDs.insert(id)
            return
        }
        requireReview(revokeSources: false)
        revokedNoteIDs.insert(id)
        grant.sources.revokeAll()
        let remaining = grant.sources.approvals.filter { $0.id != id }
        self.grant?.sources = ParticipationSourceBinding(context: grant.sources.context, approvals: remaining) ?? .empty
    }

    func stop() {
        clearGrant(preserving: [])
    }

    private func clearGrant(preserving notes: Set<UUID>) {
        cancelOutbound()
        sourceExpiry?.cancel(); sourceExpiry = nil
        revokeBoundNotes(preserving: notes)
        settings.removeAll()
        grant = nil
        privateInsight = nil
        status = .inactive
    }

    private func revokeBoundNotes(preserving notes: Set<UUID> = []) {
        guard let sources = grant?.sources else { return }
        sources.revokeAll()
        revokedNoteIDs.formUnion(sources.approvals.lazy.map(\.id).filter { !notes.contains($0) })
    }

    func cancelCandidate() {
        planned?.cancel()
        planned = nil
        queuedText = nil
        watermark += 1
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
    }

    private func beginObserving() {
        startedAt = Date()
        turns.removeAll()
        privateInsight = nil
        status = .observing
    }

    /// Call synchronously on transport/permissions/roster changes, including
    /// changes while the popover and meeting window are hidden.
    func updateAudience(_ actual: ParticipationAudience?) {
        guard latestAudience != actual else { return }
        latestAudience = actual
        rosterEpoch &+= 1
        if let grant, actual != grant.setup.audience { requireReview() }
    }

    func observe(_ features: GuestMeetingSnapshot) {
        observeEchoes(features.messages)
        guard status == .observing, let grant else { return }
        let now = Date()
        seen = seen.filter { now.timeIntervalSince($0.value) < 180 }
        let events = features.messages.suffix(40).map { ("chat", $0) }
            + (features.transcriptionStatus == .active && features.permissions.canViewTranscript
                ? features.transcript.suffix(40).map { ("transcript", $0) } : [])
        let currentLines = Dictionary(events.compactMap { channel, event -> (String, String)? in
            guard event.delivery == .sent, grant.setup.audience.members[event.participantID] != nil else { return nil }
            return (channel + ":" + event.id, String(event.text.prefix(600)))
        }, uniquingKeysWith: { _, newest in newest })
        // History and transcription are mutable snapshots. An edit, removal
        // or permission change invalidates work built from the previous view.
        if turns.contains(where: { currentLines[$0.line.id] != $0.line.text }) {
            yieldToUser()
            privateInsight = nil
            turns.removeAll { currentLines[$0.line.id] != $0.line.text }
        }
        let fresh = events.compactMap { channel, event -> Turn? in
            let own = event.isOwn || event.participantID == grant.setup.audience.localParticipant
            guard let timestamp = event.receivedAt ?? (own && event.delivery == .pending ? event.sentAt : nil),
                  timestamp > startedAt, now.timeIntervalSince(timestamp) < 45,
                  event.sentAt.map({ abs(timestamp.timeIntervalSince($0)) < 120 }) ?? true,
                  event.delivery == .sent || (own && event.delivery == .pending),
                  let name = grant.setup.audience.members[event.participantID],
                  !event.text.hasPrefix(Self.attribution), !event.text.trimmed.isEmpty else { return nil }
            let id = channel + ":" + event.id
            guard seen[id] == nil else { return nil }
            seen[id] = timestamp
            // Exact cross-channel echo suppression using the native sender identity.
            let echoed = events.contains { otherChannel, other in
                guard channel == "transcript", otherChannel == "chat", other.participantID == event.participantID,
                      let otherTime = other.receivedAt else { return false }
                return event.text == other.text && abs(timestamp.timeIntervalSince(otherTime)) <= 12
            }
            guard !echoed else { return nil }
            return Turn(line: .init(id: id, channel: channel, speaker: String(name.prefix(80)),
                text: String(event.text.prefix(600)), own: own),
                timestamp: timestamp)
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return $0.line.id < $1.line.id
        }
        guard let latest = fresh.last else { return }
        yieldToUser()
        if seen.count > 512 {
            let recent = seen.sorted { $0.value > $1.value }.prefix(512)
            seen = Dictionary(uniqueKeysWithValues: recent.map { ($0.key, $0.value) })
        }
        turns = Array((turns + fresh).filter { now.timeIntervalSince($0.timestamp) < 120 }.suffix(12))
        guard !latest.line.own else { return }
        let revision = watermark
        planned = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
                try await self?.evaluate(grantID: grant.id, revision: revision, turn: latest)
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.grant?.id == grant.id, self.watermark == revision else { return }
                self.cancelOutbound()
                self.status = .unavailable
            }
        }
    }

    private func evaluate(grantID: UUID, revision: Int, turn: Turn) async throws {
        guard let grant = current(grantID, revision: revision, turn: turn),
              let sources = await checkedSources(grant, matching: turn.line.text),
              current(grantID, revision: revision, turn: turn) != nil else { return }
        let now = Date()
        let thermal = ProcessInfo.processInfo.thermalState
        if thermal == .critical || AttentionMemoryPressure.shared.pressured { return }
        evaluations = evaluations.filter { now.timeIntervalSince($0) < 60 }
        guard evaluations.count < 3 else { return }
        evaluations.append(now)
        let input = ParticipationInput(objective: grant.objective, trigger: turn.line.id,
            turns: turns.map(\.line), sources: sources)
        let decision = try await grant.planner.plan(input)
        guard let draft = decision.validated(in: input),
              current(grantID, revision: revision, turn: turn) != nil,
              await checkedSources(grant) != nil,
              current(grantID, revision: revision, turn: turn) != nil else { return }
        guard try await grant.planner.assess(decision, in: input),
              current(grantID, revision: revision, turn: turn) != nil,
              await checkedSources(grant) != nil,
              current(grantID, revision: revision, turn: turn) != nil else { return }
        if decision.kind == .privateInsight {
            privateInsight = draft
            return
        }
        guard canPost(draft, directlyAddressed: decision.directlyAddressed) else { return }
        if !decision.directlyAddressed {
            queuedText = draft
            try await Task.sleep(for: .seconds(5))
        }
        guard current(grantID, revision: revision, turn: turn) != nil,
              canPost(draft, directlyAddressed: decision.directlyAddressed),
              let model, !model.participationSomeoneSpeaking else { queuedText = nil; return }
        queuedText = nil
        await dispatch(draft, for: turn, grant: grant, directlyAddressed: decision.directlyAddressed)
    }

    private func current(_ id: UUID, revision: Int, turn: Turn) -> Grant? {
        guard !Task.isCancelled, status == .observing, let grant, grant.id == id, watermark == revision,
              grant.setup.rosterEpoch == rosterEpoch,
              model?.participationAudience == grant.setup.audience,
              Date().timeIntervalSince(turn.timestamp) <= 30 else { return nil }
        if let expiry = grant.sources.context?.expiresAt, Date() >= expiry {
            requireReview()
            return nil
        }
        return grant
    }

    private func checkedSources(_ grant: Grant, matching query: String? = nil) async -> [ParticipationSource]? {
        let binding = grant.sources
        guard !binding.approvals.isEmpty else { return [] }
        let sources = await Task.detached(priority: .utility) { try? binding.read(matching: query) }.value
        if sources == nil, self.grant?.id == grant.id { requireReview() }
        return sources
    }

    private func canPost(_ draft: String, directlyAddressed: Bool) -> Bool {
        let now = Date()
        attempts = attempts.filter { now.timeIntervalSince($0) < 900 }
        unsolicited = unsolicited.filter { now.timeIntervalSince($0) < 900 }
        sentText = sentText.filter { now.timeIntervalSince($0.0) < 900 }
        guard attempts.count < 6, attempts.last.map({ now.timeIntervalSince($0) >= 30 }) ?? true,
              !sentText.contains(where: { $0.1 == draft }) else { return false }
        return directlyAddressed || (unsolicited.count < 3 && (unsolicited.last.map { now.timeIntervalSince($0) >= 180 } ?? true))
    }

    private func dispatch(_ draft: String, for turn: Turn, grant: Grant, directlyAddressed: Bool) async {
        guard let model else { return }
        let text = Self.attribution + draft
        let now = Date()
        let receipt = ParticipationReceipt(id: ParticipationReceipt.hash(turn.line.id),
            sessionID: model.sessionID, grantID: grant.id, payloadHash: ParticipationReceipt.hash(text),
            evidenceRevisions: grant.sources.revisions, createdAt: now, updatedAt: now,
            state: .reserved, providerMessageID: UUID().uuidString.lowercased())
        do { try grant.store.reserve(receipt) }
        catch {
            receiptWarning = true
            cancelOutbound()
            status = .unavailable
            return
        }
        let binding = grant.sources
        let expiry = min(turn.timestamp.addingTimeInterval(30), binding.context?.expiresAt ?? .distantFuture)
        let permit = binding.approvals.isEmpty ? GuestChatDispatchPermit(deadline: expiry)
            : GuestChatDispatchPermit(deadline: expiry) { (try? binding.read()) != nil }
        let messageID = receipt.providerMessageID!
        pending[messageID] = Pending(text: text, store: grant.store, permit: permit, audience: grant.setup.audience)
        receipts.insert(receipt, at: 0)
        // Charge attempts before leaving the main actor. Unknown effects can
        // never free budget for retries or additional traffic.
        attempts.append(now)
        if !directlyAddressed { unsolicited.append(now) }
        sentText.append((now, draft))
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
        if permit.validationFailed, self.grant?.id == grant.id { requireReview() }
        // Retain a short window for a late echo. No retries or replay.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(45))
            self?.pending[messageID] = nil
        }
    }

    private func observeEchoes(_ messages: [GuestMeetingMessage]) {
        guard let model else { return }
        for message in messages where message.isOwn && message.receivedAt != nil {
            guard let action = pending[message.id], action.permit.didDispatch, message.text == action.text,
                  model.participationConnection == action.audience.connection,
                  message.participantID == action.audience.localParticipant else { continue }
            record(message.id, .confirmed)
        }
    }

    private func record(_ messageID: String, _ state: ParticipationReceipt.State) {
        guard let action = pending[messageID], let index = receipts.firstIndex(where: { $0.providerMessageID == messageID }),
              receipts[index].state != .confirmed, receipts[index].state != state else { return }
        var receipt = receipts[index]
        receipt.state = state
        receipt.updatedAt = Date()
        do {
            try action.store.update(receipt)
            receipts[index] = receipt
        } catch {
            receiptWarning = true
            cancelOutbound()
            status = grant == nil ? .inactive : .unavailable
        }
    }
}
