import ConferenceCore
import Foundation
import SwiftUI

/// Agent-runtime integration for the talk controller. Active only when
/// `AttentionStore.agentAssistantEnabled` is on; otherwise the existing
/// single-command interpreter path runs unchanged.
extension AssistantTalkController {
    /// The bounded agent loop for one user turn. `external` callers (MCP) can
    /// never inherit a meeting's send-without-asking privilege.
    func runAgent(_ input: String, external: Bool = false, source: AssistantInputSource = .typed) async {
        guard attention != nil else { return }
        activeInputSource = external ? .externalMCP : source
        do {
            let environment = try await makeAgentEnvironment(external: external, source: activeInputSource)
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
            if let proposal {
                ruleProposalReview = proposal
            } else if let answer = agentRuntime.items.last(where: { $0.kind == .assistant }) {
                if activeInputSource.isVoice {
                    lastVoiceAnswer = answer.text
                }
                autoAuditionIfNeeded(id: answer.id, text: answer.text, source: activeInputSource)
            }
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

    private func makeAgentEnvironment(external: Bool, source: AssistantInputSource = .typed) async throws -> AssistantAgentEnvironment {
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
        if let provider = attention.externalToolProvider {
            await registry.registerMeetingMCPTools(provider, includeAdditionalReads: attention.store.agentExternalToolsEnabled)
        }
        let globalDefault = attention.store.agentMeetingSendDefault
        let overrides = sendPolicyOverrides
        return AssistantAgentEnvironment(
            registry: registry,
            model: provider.agentModel(key: attention.store.apiKey(for: provider)),
            context: AssistantNativeToolProvider.context(snapshot: snapshot),
            approvalPolicy: { _, action in
                // The app owns this gate. External callers can never inherit any send
                // privilege; direct chat/voice/reaction sends follow persisted/per-meeting
                // policy while voice commands auto-run safe control actions.
                let sendDecision = AssistantMeetingSendGate.approval(
                    external: external, action: action, selectedMeetingID: snapshot.contextMeetingID,
                    override: action.meetingID.flatMap { overrides[$0] },
                    globalDefault: globalDefault)
                if external { return sendDecision }
                if AssistantVoiceApprovalPolicy.shouldAutoApprove(
                    actionKind: action.kind.rawValue,
                    inputSource: source,
                    sendsWithoutAsking: sendDecision == .allow) {
                    return .allow
                }
                return sendDecision
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
            command = .init(action: .setAttention, meetingID: action.meetingID, mode: action.mode,
                            scope: action.scope, text: action.text, participate: action.participate)
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
        return try await execute(command, context: makeContext(), attention: attention,
            id: action.id, revision: "\(action.revision):" + action.payloadHash)
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
        let assistant = attention.store.assistant
        let cards = attention.store.meetingLibrary.cards
        let titles = Dictionary(uniqueKeysWithValues: cards.compactMap { card in
            card.outcomeID.map { ($0, card.title) }
        })
        let outcomes = assistant.outcomes.map { outcome in
            AssistantOutcomeRecord(id: outcome.id, meetingID: outcome.meetingID, title: titles[outcome.id] ?? outcome.meetingTitle,
                                   roomIdentity: outcome.invitation.flatMap { MeetingRoomIdentity($0)?.displayDetails } ?? "",
                                   seriesID: outcome.seriesID, endedAt: outcome.endedAt, summary: outcome.summary,
                                   decisions: outcome.decisions,
                                   tasks: outcome.tasks.map { task in
                                       .init(text: task.text, owner: task.owner, dueAt: task.dueAt, done: task.done,
                                             dueDay: task.dueDay, personal: assistant.taskProfile.owns(task),
                                             archived: !assistant.isTaskOperational(task))
                                   },
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

    // MARK: - Deterministic Voice & Offline Shortcuts

    /// Handles unambiguous voice/offline commands (monthly counts, joining current meeting,
    /// muting mic, switching into Participate mode) without requiring a remote LLM round-trip.
    func runDeterministicCommandIfApplicable(_ input: String, source: AssistantInputSource) async -> String? {
        guard let attention else { return nil }
        let lower = input.lowercased().replacingOccurrences(of: "ё", with: "е")
        let isRussian = lower.range(of: #"\p{Cyrillic}"#, options: .regularExpression) != nil || attention.language.hasPrefix("ru")
        let now = attention.now()

        // 1. Meeting count query (e.g. "сколько было встреч в этом месяце?" / "how many meetings this month?")
        let asksCount = lower.contains("сколько") || lower.contains("количеств") || lower.contains("how many") || lower.contains("count of")
        let mentionsMeeting = lower.contains("встреч") || lower.contains("созвон") || lower.contains("митинг") || lower.contains("meeting") || lower.contains("call")
        if asksCount && mentionsMeeting {
            let cal = Calendar.current
            let scopeMonth = lower.contains("месяц") || lower.contains("month")
            let scopeWeek = lower.contains("недел") || lower.contains("week")
            let scopeToday = lower.contains("сегодн") || lower.contains("today")

            struct CountedMeeting { let title: String; let date: Date }
            var seenIDs = Set<UUID>()
            var matched: [CountedMeeting] = []

            func matchesPeriod(_ date: Date) -> Bool {
                if scopeToday { return cal.isDate(date, inSameDayAs: now) }
                if scopeWeek { return cal.isDate(date, equalTo: now, toGranularity: .weekOfYear) }
                // Default to current month when "this month" or unqualified count is asked
                if scopeMonth || (!scopeWeek && !scopeToday) {
                    return cal.isDate(date, equalTo: now, toGranularity: .month)
                }
                return true
            }

            for outcome in attention.store.assistant.outcomes {
                let referenceDate = outcome.endedAt
                guard matchesPeriod(referenceDate) else { continue }
                let dedupeID = outcome.meetingID ?? outcome.id
                guard seenIDs.insert(dedupeID).inserted else { continue }
                matched.append(.init(title: outcome.meetingTitle, date: referenceDate))
            }
            for live in attention.meetings() where !live.isClosed {
                guard seenIDs.insert(live.workspaceSessionID).inserted else { continue }
                matched.append(.init(title: live.title, date: now))
            }

            let count = matched.count
            if isRussian {
                if count == 0 {
                    return scopeToday ? "Сегодня встреч пока не было." : (scopeWeek ? "На этой неделе встреч пока не было." : "В этом месяце записанных встреч пока не было.")
                }
                let titles = matched.prefix(4).map { "«\($0.title)»" }.joined(separator: ", ")
                let suffix = count > 4 ? " и ещё \(count - 4)" : ""
                let period = scopeToday ? "Сегодня" : (scopeWeek ? "На этой неделе" : "В этом месяце")
                return "\(period) было \(count) встреч: \(titles)\(suffix)."
            } else {
                if count == 0 {
                    return scopeToday ? "You have had no meetings today." : (scopeWeek ? "You have had no meetings this week." : "You have had no recorded meetings this month.")
                }
                let titles = matched.prefix(4).map { $0.title }.joined(separator: ", ")
                let suffix = count > 4 ? " and \(count - 4) more" : ""
                let period = scopeToday ? "Today" : (scopeWeek ? "This week" : "This month")
                return "\(period) you had \(count) meeting(s): \(titles)\(suffix)."
            }
        }

        // 2. Join current meeting (auto-executes immediately for voice input)
        let asksJoin = lower.contains("подключ") || lower.contains("зайди") || lower.contains("войди")
            || lower.contains("join") || lower.contains("connect me")
        let mentionsCurrentOrMeeting = lower.contains("текущ") || lower.contains("сейчас") || lower.contains("current")
            || lower.contains("следующ") || lower.contains("next") || mentionsMeeting
        if asksJoin && mentionsCurrentOrMeeting && AssistantVoiceApprovalPolicy.shouldAutoApprove(
            actionKind: "join", inputSource: source, sendsWithoutAsking: false) {
            let candidates = attention.joinableTargets(now)
            if let best = CurrentMeetingTargetResolver.bestCurrentMeeting(from: candidates, now: now) {
                let targetID = best.activeSessionID ?? best.id
                let command = AssistantCommand(action: .join, meetingID: targetID)
                do {
                    return try await execute(command, context: makeContext(), attention: attention, originalInput: input)
                } catch {
                    return error.localizedDescription
                }
            }
            return isRussian ? "Не найдена текущая или ближайшая встреча со ссылкой для подключения." : "No ongoing or upcoming meeting with a join link was found."
        }

        // 3. Mute microphone
        let asksMute = lower.contains("замут") || lower.contains("выключи микрофон") || lower.contains("отключи микрофон")
            || (lower.contains("mute") && (lower.contains("mic") || lower.contains("микрофон") || lower == "mute"))
        if asksMute {
            let command = AssistantCommand(action: .mute, meetingID: reconcileMeetingTarget())
            return try? await execute(command, context: makeContext(), attention: attention, originalInput: input)
        }

        // 4. Switch to Participate mode (with optional spoken context)
        let asksParticipate = lower.contains("режим участия") || lower.contains("включи участие")
            || lower.contains("participat")
        if asksParticipate {
            guard let id = reconcileMeetingTarget(),
                  let model = attention.meetings().first(where: { $0.sessionID == id && !$0.isClosed }) else {
                return isRussian ? "Сначала откройте или подключитесь к встрече." : "Join or open a meeting first."
            }
            let objective = Self.extractParticipationObjective(from: input)
            attention.onRequestParticipationMode?(model, objective)
            if objective.isEmpty {
                return isRussian
                    ? "Включаю режим участия для «\(model.title)» — надиктуйте контекст или цель."
                    : "Opening Participation mode for “\(model.title)” — speak your context or goal."
            } else {
                return isRussian
                    ? "Режим участия включён для «\(model.title)» с задачей: \(objective)"
                    : "Participation enabled for “\(model.title)”: \(objective)"
            }
        }

        return nil
    }

    private nonisolated static func extractParticipationObjective(from input: String) -> String {
        let lower = input.lowercased().replacingOccurrences(of: "ё", with: "е")
        for marker in ["с контекстом ", "контекст:", "контекст ", "с целью ", "цель:", "цель ", "with context ", "context:", "goal:"] {
            if let range = lower.range(of: marker) {
                let tailStart = input.index(input.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let extracted = String(input[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !extracted.isEmpty {
                    return String(extracted.prefix(180))
                }
            }
        }
        return ""
    }
}

// MARK: - Conversation rendering

/// One user turn in the agent timeline: the user message, one collapsed activity row for
/// raw tool/source noise, visible errors, the final answer with its source chips, and any
/// clarification. Raw `rocknroll_*` identifiers stay behind the Details disclosure.
struct AssistantAgentTurnView: View {
    let turn: AssistantAgentTurn
    var historyAction: ((AssistantEvidenceSource) -> (() -> Void)?)? = nil
    var auditioningItemID: UUID? = nil
    var onToggleAudition: ((AssistantConversationItem) -> Void)? = nil
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
                    AssistantAgentItemView(
                        item: answer,
                        historyAction: historyAction,
                        isAuditioning: auditioningItemID == answer.id,
                        onToggleAudition: onToggleAudition.map { toggle in { toggle(answer) } })
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
    var historyAction: ((AssistantEvidenceSource) -> (() -> Void)?)? = nil
    var isAuditioning = false
    var onToggleAudition: (() -> Void)? = nil

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
            if item.kind == .assistant, let onToggleAudition {
                Button(action: onToggleAudition) {
                    Label(isAuditioning ? L("Stop") : L("Speak"),
                          systemImage: isAuditioning ? "stop.circle.fill" : "speaker.wave.2")
                        .font(.caption2)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(isAuditioning ? Color.accentColor : .secondary)
                .accessibilityIdentifier("assistant.agent.audition")
            }
            if !item.sources.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(item.sources) { source in
                            if let action = historyAction?(source) {
                                Button(action: action) { sourceChip(source) }.buttonStyle(.link)
                            } else {
                                sourceChip(source).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }.frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }

    private func sourceChip(_ source: AssistantEvidenceSource) -> some View {
        Label(source.title, systemImage: sourceIcon(source.kind))
            .font(.caption2)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
            .help(source.at.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? source.kind)
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
