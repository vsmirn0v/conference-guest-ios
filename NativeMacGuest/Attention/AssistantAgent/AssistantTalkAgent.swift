import ConferenceCore
import Foundation
import SwiftUI

/// Agent-runtime integration for the talk controller. Active only when
/// `AttentionStore.agentAssistantEnabled` is on; otherwise the existing
/// single-command interpreter path runs unchanged.
extension AssistantTalkController {
    /// The bounded agent loop for one user turn. `external` callers (MCP) can
    /// never inherit a meeting's send-without-asking privilege.
    func runAgent(_ input: String, external: Bool = false) async {
        guard let attention else { return }
        do {
            let environment = try await makeAgentEnvironment(external: external)
            agentEnvironment = environment
            let result = await agentRuntime.submit(input, environment: environment)
            handleAgentOutcome(result)
        } catch is CancellationError { return }
        catch { agentAppend(error.localizedDescription) }
    }

    func handleAgentOutcome(_ result: Result<AssistantAgentRunOutcome, Error>) {
        switch result {
        case .success(.approvalRequired(let approval)):
            agentPending = approval
        case .success(.completed(_, _, let proposal)):
            // A proposal only opens a native review card; enabling is a separate act.
            if let proposal { ruleProposalReview = proposal }
        case .success(.needsUserInput):
            break
        case .failure(let error):
            guard !(error is CancellationError) else { break }
            agentAppend(error.localizedDescription)
        }
    }

    /// Approval decision for an agent-produced outward action.
    func confirmAgentPending() {
        guard agentPending != nil else { return }
        let result = agentPending
        agentPending = nil
        Task { @MainActor [weak self] in
            guard let self, let result else { return }
            self.handleAgentOutcome(await self.agentRuntime.resumePendingApproval(approved: true))
        }
    }

    func cancelAgentPending() {
        guard agentPending != nil else { return }
        agentPending = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.handleAgentOutcome(await self.agentRuntime.resumePendingApproval(approved: false))
        }
    }

    /// Enable a reviewed rule. `unattended` is a deliberate native grant bound to
    /// this exact revision; ask-each-time remains the default.
    func enableReviewedRule(unattended: Bool) {
        guard let proposal = ruleProposalReview, let attention else { return }
        ruleProposalReview = nil
        let rule = attention.ruleStore.propose(proposal)
        attention.ruleStore.enable(id: rule.id)
        if unattended { attention.ruleStore.setUnattendedGrant(id: rule.id, granted: true) }
    }

    func discardReviewedRule() {
        ruleProposalReview = nil
        agentAppend(L("Rule discarded. Nothing was enabled or sent."))
    }

    func agentNewConversation() { agentRuntime.newConversation(); ruleProposalReview = nil; agentPending = nil }

    // MARK: Environment

    private func makeAgentEnvironment(external: Bool) async throws -> AssistantAgentEnvironment {
        guard let attention else { throw AssistantAgentError.unsupported }
        let snapshot = makeAgentSnapshot()
        let provider = attention.store.provider
        let hooks = AssistantNativeToolProvider.Hooks(
            executeAction: { [weak self] action in
                guard let self else { throw AssistantAgentError.unsupported }
                return try await self.executeAgentAction(action)
            },
            readNote: { [weak self] sessionID in
                guard let self else { return nil }
                return await self.attention?.store.meetingLibrary.note(sessionID: sessionID)
            })
        let registry = AssistantNativeToolProvider.registry(snapshot: snapshot, hooks: hooks)
        // External MCP tools are read-only and gated by the persisted trust policy.
        if attention.store.agentExternalToolsEnabled, let externalProvider = attention.externalToolProvider {
            let trust = AssistantExternalToolTrust(disabled: false,
                                                   enabledServers: [assistantMCPLoopbackServerID],
                                                   readOnlyServers: [assistantMCPLoopbackServerID])
            registry.register(externalTools: await AssistantExternalToolPolicy.exposedTools(
                externalProvider, serverID: assistantMCPLoopbackServerID, trust: trust))
        }
        let globalDefault = attention.store.agentMeetingSendDefault
        let overrides = sendPolicyOverrides
        return AssistantAgentEnvironment(
            registry: registry,
            model: provider.agentModel(key: attention.store.apiKey(for: provider)),
            context: AssistantNativeToolProvider.context(snapshot: snapshot),
            approvalPolicy: { _, action in
                // The app owns this gate. External callers can never inherit any send
                // privilege; direct chat/voice/reaction sends to the selected active
                // meeting follow the persisted default and the per-meeting override
                // captured when this environment was built.
                AssistantMeetingSendGate.approval(
                    external: external, action: action, selectedMeetingID: snapshot.contextMeetingID,
                    override: action.meetingID.flatMap { overrides[$0] },
                    globalDefault: globalDefault)
            },
            actionCoordinator: attention.actionCoordinator,
            approvalTitle: { call, action in Self.agentApprovalTitle(call, action) },
            approvalDetail: { _, action in
                if !action.text.isEmpty { return action.text }
                return action.reaction.map { $0.emoji } ?? ""
            })
    }

    nonisolated static func agentApprovalTitle(_ call: AssistantAgentToolCall, _ action: AssistantCanonicalAction) -> String {
        switch action.kind {
        case .setAttention: return L("Set attention in this meeting?")
        case .join: return L("Join this meeting?")
        case .leave: return L("Leave this meeting?")
        case .mute: return L("Mute the microphone?")
        case .sendChat: return L("Send this chat message?")
        case .say: return L("Speak this into the meeting?")
        case .react: return L("Send this reaction?")
        case .remind: return L("Set this reminder?")
        case .remember: return L("Remember this?")
        case .readChat: return call.name
        }
    }

    /// Canonical actions execute through the same validated executor as typed commands.
    private func executeAgentAction(_ action: AssistantCanonicalAction) async throws -> String {
        guard let attention else { throw AssistantAgentError.unsupported }
        let command: AssistantCommand
        switch action.kind {
        case .setAttention:
            command = .init(action: .setAttention, meetingID: action.meetingID, mode: action.mode, scope: action.scope)
        case .join:
            command = .init(action: .join, meetingID: action.meetingID)
        case .leave:
            command = .init(action: .leave, meetingID: action.meetingID)
        case .mute:
            command = .init(action: .mute, meetingID: action.meetingID)
        case .sendChat:
            command = .init(action: .sendChat, meetingID: action.meetingID, text: action.text)
        case .say:
            command = .init(action: .say, meetingID: action.meetingID, text: action.text)
        case .react:
            command = .init(action: .react, meetingID: action.meetingID, reaction: action.reaction)
        case .readChat:
            command = .init(action: .readChat, meetingID: action.meetingID, count: action.minutes)
        case .remind:
            command = .init(action: .remind, momentID: action.momentID, at: action.at)
        case .remember:
            command = .init(action: .remember, text: action.text)
        }
        return try await execute(command, context: makeContext(), attention: attention)
    }

    // MARK: Snapshot

    /// A serializable, per-turn view of native authority. Tools never receive
    /// live domain objects; typed IDs in arguments are checked against this data.
    func makeAgentSnapshot() -> AssistantNativeSnapshot {
        guard let attention else {
            return .init(now: Date(), timeZoneIdentifier: TimeZone.current.identifier, language: "en",
                         contextMeetingID: nil, profileNames: [], meetings: [], outcomes: [], notes: [], moments: [],
                         memories: [], calendar: [], actionTargets: [], settings: [:])
        }
        let now = attention.now()
        let profile = attention.store.profile
        let profileNames = profile.names(fallback: "")
        let meetings = attention.meetings().map { model -> AssistantMeetingRecord in
            let room = MeetingRoomIdentity(model.invitation, engine: model.kind)
            let coverage = model.transcriptionSince != nil
                ? L("Full: local transcription is running on this Mac.")
                : L("Partial: only what the app captured while you were present.")
            return .init(id: model.sessionID, title: model.title, active: !model.isClosed,
                         roomIdentity: room?.displayDetails ?? "",
                         invitationSummary: room.map { "\($0.origin) · \($0.room)" } ?? "",
                         seriesID: model.calendarSeriesID,
                         displayName: model.participants.first { $0.isLocal }?.name ?? "",
                         participants: model.participants.map { $0.name },
                         transcript: model.transcript.map {
                             .init(id: $0.id, speaker: $0.participantName, text: $0.text, at: $0.sentAt)
                         },
                         chat: model.chat.items.map {
                             .init(id: $0.id, speaker: $0.sender, text: $0.text, at: $0.sentAt)
                         },
                         transcriptCoverage: coverage,
                         canSendChat: model.chat.canSend, canReact: model.canReact,
                         supportsVoiceReply: model.supportsVoiceReply,
                         microphoneOn: model.assistantMicrophoneOn, soundOn: true,
                         outcomeID: nil)
        }
        let outcomes = attention.store.assistant.outcomes.map { outcome in
            AssistantOutcomeRecord(id: outcome.id, meetingID: outcome.meetingID, title: outcome.meetingTitle,
                                   roomIdentity: outcome.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails } ?? "",
                                   seriesID: outcome.seriesID, endedAt: outcome.endedAt, summary: outcome.summary,
                                   decisions: outcome.decisions,
                                   tasks: outcome.tasks.map { .init(text: $0.text, owner: $0.owner, dueAt: $0.dueAt, done: $0.done) },
                                   openQuestions: outcome.openQuestions)
        }
        let notes = attention.store.meetingLibrary.cards.filter(\.hasNotes).map { card in
            AssistantNoteRecord(id: card.noteID ?? card.sessionID, meetingID: card.sessionID,
                                meetingTitle: card.title, revision: card.noteRevision,
                                updatedAt: card.updatedAt, preview: card.notePreview ?? "")
        }
        let moments = attention.store.momentHistory.moments.map {
            AssistantMomentRecord(id: $0.id, meetingID: $0.meetingID, title: $0.meetingTitle,
                                  reason: $0.verdict.reason, createdAt: $0.createdAt, state: $0.state.rawValue)
        }
        let memories = attention.store.assistant.memories.map {
            AssistantMemoryRecord(id: $0.id, kind: $0.kind.rawValue, text: $0.text, updatedAt: $0.updatedAt)
        }
        let calendar = attention.calendarOccurrences().map { occurrence in
            AssistantCalendarOccurrence(id: occurrence.id, seriesID: occurrence.seriesID,
                                        calendarID: occurrence.calendarID, calendarTitle: occurrence.calendarTitle,
                                        title: occurrence.title, start: occurrence.start, end: occurrence.end,
                                        allDay: occurrence.allDay,
                                        roomIdentity: occurrence.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails } ?? "")
        }
        let targets = makeContext().meetings.map {
            AssistantActionTarget(id: $0.id, title: $0.title, invitation: $0.invitation,
                                  active: $0.active, meetingID: $0.active ? $0.id : nil)
        }
        let store = attention.store
        let settings: [String: String] = [
            "voice_engine": store.voiceEngine.rawValue,
            "talk_back": store.talkBack ? "on" : "off",
            "provider_host": providerHost(store.provider),
            "outcomes_enabled": store.generateOutcomes ? "on" : "off",
            "push_to_talk": store.pushToTalk ? "on" : "off",
        ]
        return .init(now: now, timeZoneIdentifier: TimeZone.current.identifier,
                     language: Bundle.main.preferredLocalizations.first ?? "en",
                     contextMeetingID: targetMeetingID, profileNames: profileNames, meetings: meetings,
                     outcomes: outcomes, notes: notes, moments: moments, memories: memories, calendar: calendar,
                     actionTargets: targets, settings: settings)
    }

    private func providerHost(_ provider: AttentionProvider) -> String {
        guard let host = URLComponents(string: provider.baseURL)?.host else { return provider.baseURL }
        return provider.model + " @ " + host
    }

    private func agentAppend(_ text: String) {
        // Errors outside a run surface as a system entry in the agent conversation.
        agentRuntime.appendSystemForUI(text)
    }
}

// MARK: - Conversation rendering

/// One user turn in the agent timeline: the user message, one collapsed activity row for
/// raw tool/source noise, visible errors, the final answer with its source chips, and any
/// clarification. Raw `rocknroll_*` identifiers stay behind the Details disclosure.
struct AssistantAgentTurnView: View {
    let turn: AssistantAgentTurn
    @State private var showsDetails = false

    private var answer: AssistantConversationItem? { turn.activity.last(where: { $0.kind == .assistant }) }
    private var clarifications: [AssistantConversationItem] { turn.activity.filter { $0.kind == .clarification } }
    private var errors: [AssistantConversationItem] { turn.activity.filter { $0.isError } }
    /// Raw steps collapse into the activity row; approvals render as their own prominent
    /// card elsewhere, and the answer, clarifications and errors stay visible.
    private var steps: [AssistantConversationItem] {
        turn.activity.filter { $0.kind == .tool || $0.kind == .approval }
    }

    var body: some View {
        VStack(spacing: 6) {
            if !turn.userText.isEmpty {
                Text(turn.userText).textSelection(.enabled).padding(10)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .leading, spacing: 6) {
                if !steps.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: errors.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                        Text(L("%ld steps", steps.count)).font(.caption)
                        Spacer()
                        Button { showsDetails.toggle() } label: {
                            Label(L("Details"), systemImage: "chevron.right")
                                .labelStyle(.titleOnly)
                                .rotationEffect(.degrees(showsDetails ? 90 : 0))
                        }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .accessibilityIdentifier("assistant.turn.details")
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    if showsDetails {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(steps.enumerated()), id: \.element.id) { index, item in
                                HStack(alignment: .firstTextBaseline, spacing: 4) {
                                    Text("\(index + 1).").foregroundStyle(.secondary)
                                    Text(L("%@: %@", Self.friendlyToolName(item), item.text))
                                }
                                .font(.caption)
                                .foregroundStyle(item.isError ? Color.red : Color.secondary)
                                .textSelection(.enabled)
                            }
                        }
                        .padding(.leading, 14)
                        .transition(.opacity)
                    }
                }
                ForEach(errors) { item in
                    AssistantAgentItemView(item: item)
                }
                if let answer {
                    AssistantAgentItemView(item: answer)
                }
                ForEach(clarifications) { item in
                    AssistantAgentItemView(item: item)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Hide the internal `rocknroll_` prefix by default; the raw name stays in diagnostics.
    static func friendlyToolName(_ item: AssistantConversationItem) -> String {
        let raw = item.toolName ?? item.kind.rawValue
        return raw.hasPrefix("rocknroll_") ? String(raw.dropFirst("rocknroll_".count)) : raw
    }
}

/// One structured entry in the agent conversation: text, source chips and status.
struct AssistantAgentItemView: View {
    let item: AssistantConversationItem

    private var isUser: Bool { item.kind == .user }
    private var chip: String? {
        switch item.kind {
        case .tool: return item.toolName.map { L("tool · %@", $0) }
        case .approval: return L("approval")
        case .clarification: return L("clarifies")
        case .system: return item.isError ? L("error") : nil
        case .user, .assistant: return nil
        }
    }

    var body: some View {
        VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
            if let chip {
                Text(chip).font(.caption2).foregroundStyle(.secondary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            }
            Text(item.text).textSelection(.enabled).padding(10)
                .background(isUser ? Color.accentColor.opacity(0.1)
                            : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            if !item.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.sources) { source in
                            Label(source.title, systemImage: sourceIcon(source.kind))
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
                                .help(source.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? source.kind)
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func sourceIcon(_ kind: String) -> String {
        switch kind {
        case "outcome": return "checklist"
        case "transcript": return "waveform"
        case "chat": return "bubble.left"
        case "calendar": return "calendar"
        case "memory": return "brain"
        case "meeting": return "person.3"
        default: return "doc"
        }
    }
}

/// Native review card for a model-proposed standing rule. Enabling is explicit
/// and produces no immediate action; the unattended grant is opt-in per revision.
struct AssistantRuleReviewCard: View {
    let proposal: AssistantAutomationRuleProposal
    let onEnable: (Bool) -> Void
    let onDiscard: () -> Void
    @State private var unattended = false

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("Automation rule: mention reply")).font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text(L("Trigger")).foregroundStyle(.secondary)
                        Text(L("When someone mentions you"))
                    }
                    GridRow {
                        Text(L("Scope")).foregroundStyle(.secondary)
                        Text(L("All eligible current and future meetings"))
                    }
                    GridRow {
                        Text(L("Voice")).foregroundStyle(.secondary)
                        Text(proposal.voiceID)
                    }
                    GridRow {
                        Text(L("Reply")).foregroundStyle(.secondary)
                        Text("“\(proposal.text)”").textSelection(.enabled)
                    }
                    GridRow {
                        Text(L("Cooldown")).foregroundStyle(.secondary)
                        Text(L("%ld s after one handled mention", Int(proposal.cooldownSeconds)))
                    }
                }.font(.callout)
                Toggle(L("Allow this exact rule revision to speak without asking"), isOn: $unattended)
                    .font(.callout)
                Text(L("Default: the app asks before each reply. Enabling the rule sends nothing now."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(L("Enable rule")) { onEnable(unattended) }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("assistant.rule.enable")
                    Button(L("Cancel"), role: .cancel) { onDiscard() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
