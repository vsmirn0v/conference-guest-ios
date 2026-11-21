import AVFoundation
import Combine
import ConferenceCore
import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

@MainActor final class IOSAssistantTalkController: ObservableObject {
    struct Message: Identifiable, Equatable {
        enum Role: String, Equatable {
            case user
            case assistant
            case system
        }

        let id: UUID
        let role: Role
        let text: String
        let at: Date

        init(id: UUID = UUID(), role: Role, text: String, at: Date = Date()) {
            self.id = id
            self.role = role
            self.text = text
            self.at = at
        }
    }

    enum ActionKind: String, Equatable {
        case join
        case mute
        case participate
        case setMode
        case sendChat
        case leave
        case addTask
    }

    struct PendingApproval: Identifiable, Equatable {
        let id: UUID
        let kind: ActionKind
        let title: String
        let detail: String
        let targetID: UUID?
        let text: String
        let candidate: JoinableMeetingCandidate?
    }

    @Published var draft = ""
    @Published private(set) var messages: [Message] = []
    @Published private(set) var working = false
    @Published private(set) var listening = false
    @Published private(set) var pendingApproval: PendingApproval?
    @Published private(set) var auditioningMessageID: UUID?
    @Published private(set) var lastVoiceAnswer: String?
    @Published var audioError: String?
    @Published var targetControllerID: UUID?

    weak var workspace: IOSWorkspaceCoordinator?
    weak var assistant: IOSAssistantCoordinator?
    var speech: IOSAssistantSpeechCoordinator?
    let voiceStore: IOSVoiceStore

    var now: () -> Date = Date.init
    var isInActiveCall: () -> Bool = { false }
    var sessionsProvider: (() -> [IOSMeetingSessionItem])?
    var tasksProvider: (() -> [IOSMeetingTaskItem])?
    var joinableTargets: (Date) -> [JoinableMeetingCandidate] = { _ in [] }
    var activeMeetingsProvider: () -> [(id: UUID, title: String, isUnmuted: Bool, canSendChat: Bool, sessionID: UUID?)] = { [] }
    var onJoinCandidate: ((JoinableMeetingCandidate) -> Bool)?
    var onMuteMeeting: ((UUID?) -> String?)?
    var onLeaveMeeting: ((UUID?) async -> Bool)?
    var onSendChat: ((UUID, String) async throws -> Void)?
    var onRequestParticipation: ((UUID, String) -> Void)?
    var llmResponderOverride: ((String) async throws -> String)?

    private var auditionTask: Task<Void, Never>?
    private var holdLimitTask: Task<Void, Never>?

    init(
        workspace: IOSWorkspaceCoordinator? = nil,
        assistant: IOSAssistantCoordinator? = nil,
        speech: IOSAssistantSpeechCoordinator? = nil,
        voiceStore: IOSVoiceStore = .shared
    ) {
        self.workspace = workspace
        self.assistant = assistant
        self.speech = speech
        self.voiceStore = voiceStore
    }

    deinit {
        auditionTask?.cancel()
        holdLimitTask?.cancel()
    }

    func submitDraft() {
        let clean = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        draft = ""
        Task { @MainActor [weak self] in
            await self?.run(clean, source: .typed)
        }
    }

    func submitSuggestion(_ prompt: String) {
        let clean = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        Task { @MainActor [weak self] in
            await self?.run(clean, source: .typed)
        }
    }

    func newConversation() {
        stopAudition()
        pendingApproval = nil
        messages.removeAll()
        lastVoiceAnswer = nil
        audioError = nil
    }

    func run(_ input: String, source: AssistantInputSource = .typed) async {
        let clean = String(input.trimmingCharacters(in: .whitespacesAndNewlines).prefix(2000))
        guard !clean.isEmpty, !working else { return }
        if pendingApproval != nil {
            append(.system, L("Confirm or cancel the pending action first."))
            return
        }

        append(.user, clean)
        working = true
        defer { working = false }

        if let deterministic = await handleDeterministicCommandIfMatched(clean, source: source) {
            recordAnswer(deterministic, source: source)
            return
        }

        if let override = llmResponderOverride {
            do {
                let answer = try await override(clean)
                recordAnswer(answer, source: source)
            } catch {
                append(.system, error.localizedDescription)
            }
            return
        }

        let answer = await answerWithWorkspaceOrAI(clean)
        recordAnswer(answer, source: source)
    }

    func confirmPendingApproval() {
        guard let pending = pendingApproval else { return }
        pendingApproval = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let reply: String
            switch pending.kind {
            case .join:
                if let candidate = pending.candidate, onJoinCandidate?(candidate) == true {
                    reply = L("Joining “%@”.", candidate.title)
                } else {
                    reply = L("Unable to join the meeting right now.")
                }
            case .sendChat:
                guard let id = pending.targetID else {
                    append(.system, L("No active meeting is selected."))
                    return
                }
                do {
                    if let onSendChat {
                        try await onSendChat(id, pending.text)
                    } else if let assistant {
                        try await assistant.sendManualChat(controllerID: id, text: pending.text)
                    }
                    reply = L("Sent to chat: %@", pending.text)
                } catch {
                    append(.system, error.localizedDescription)
                    return
                }
            case .leave:
                let ok = await onLeaveMeeting?(pending.targetID) ?? false
                reply = ok ? L("Left the meeting.") : L("Could not leave the meeting right now.")
            case .mute, .participate, .setMode, .addTask:
                reply = L("Done.")
            }
            recordAnswer(reply, source: .typed)
        }
    }

    func cancelPendingApproval() {
        guard pendingApproval != nil else { return }
        pendingApproval = nil
        append(.assistant, L("Cancelled. Nothing was sent."))
    }

    // MARK: - Push-to-Talk

    func togglePushToTalk() {
        if listening {
            stopPushToTalk()
        } else {
            startPushToTalk()
        }
    }

    func startPushToTalk() {
        guard !listening, !working, let speech else { return }
        audioError = nil
        Task { @MainActor [weak self] in
            guard let self else { return }
            let started = await speech.beginPushToTalkCapture()
            guard started else {
                switch speech.lastStartFailure {
                case .audioBusy:
                    self.audioError = L("Microphone input is busy during another call or audio session.")
                case .audioUnavailable:
                    self.audioError = L("Microphone input could not be started.")
                case .alreadyActive:
                    break
                case .microphoneDenied, .none:
                    self.audioError = L("Microphone permission is needed to listen.")
                }
                return
            }
            self.listening = true
            self.holdLimitTask?.cancel()
            self.holdLimitTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard let self, !Task.isCancelled, self.listening else { return }
                self.stopPushToTalk()
            }
        }
    }

    func stopPushToTalk() {
        holdLimitTask?.cancel()
        holdLimitTask = nil
        guard listening, let speech else { return }
        listening = false
        let samples = speech.finishPushToTalkCapture()
        Task { @MainActor [weak self] in
            guard let self, samples.count >= 3_200 else { return }
            guard let text = await speech.transcribeSamples(samples)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else {
                self.append(.system, L("No speech was recognized."))
                return
            }
            await self.run(text, source: .voicePushToTalk)
        }
    }

    // MARK: - Voice Auditioning

    func toggleAudition(messageID: UUID, text: String) {
        if auditioningMessageID == messageID {
            stopAudition()
        } else {
            startAudition(messageID: messageID, text: text)
        }
    }

    func stopAudition() {
        auditionTask?.cancel()
        auditionTask = nil
        auditioningMessageID = nil
        IOSVoicePreviewPlayer.shared.stop()
        speech?.setSpeakingResponse(false)
    }

    private func startAudition(messageID: UUID, text: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        stopAudition()
        auditioningMessageID = messageID
        audioError = nil
        speech?.setSpeakingResponse(true)
        auditionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let buffer = try await self.voiceStore.synthesizeAssistantResponse(clean)
                guard !Task.isCancelled, self.auditioningMessageID == messageID else { return }
                try IOSVoicePreviewPlayer.shared.play(buffer) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.auditioningMessageID == messageID else { return }
                        self.auditioningMessageID = nil
                        self.speech?.setSpeakingResponse(false)
                    }
                }
            } catch is CancellationError {
                self.speech?.setSpeakingResponse(false)
            } catch {
                if self.auditioningMessageID == messageID {
                    self.auditioningMessageID = nil
                    self.audioError = error.localizedDescription
                }
                self.speech?.setSpeakingResponse(false)
            }
        }
    }

    private func recordAnswer(_ text: String, source: AssistantInputSource) {
        let message = Message(role: .assistant, text: text, at: now())
        messages.append(message)
        if source.isVoice {
            lastVoiceAnswer = text
        }
        let shouldAutoSpeak = (source.isVoice && voiceStore.autoAuditionVoiceReplies)
            || (!source.isVoice && source != .externalMCP && voiceStore.autoAuditionTypedReplies)
        let usesLoudspeakerInCall = isInActiveCall() && Self.isSpeakerOutputActive
        if shouldAutoSpeak && !usesLoudspeakerInCall {
            startAudition(messageID: message.id, text: text)
        }
    }

    private static var isSpeakerOutputActive: Bool {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard !outputs.isEmpty else { return false }
        return outputs.allSatisfy { $0.portType == .builtInSpeaker }
    }

    private func append(_ role: Message.Role, _ text: String) {
        messages.append(Message(role: role, text: text, at: now()))
    }

    // MARK: - Command & Query Resolution

    private func resolvedTargetMeetingID() -> UUID? {
        let active = activeMeetingsProvider()
        if let targetControllerID, active.contains(where: { $0.id == targetControllerID }) {
            return targetControllerID
        }
        return active.first?.id
    }

    private func handleDeterministicCommandIfMatched(_ input: String, source: AssistantInputSource) async -> String? {
        let lower = input.lowercased().replacingOccurrences(of: "ё", with: "е")
        let currentNow = now()

        // 1. Meeting count query (e.g. "сколько было встреч в этом месяце?")
        let asksCount = lower.contains("сколько") || lower.contains("количеств") || lower.contains("how many") || lower.contains("count")
        let mentionsMeeting = lower.contains("встреч") || lower.contains("созвон") || lower.contains("митинг") || lower.contains("meeting") || lower.contains("call")
        if asksCount && mentionsMeeting {
            let cal = Calendar.current
            let scopeToday = lower.contains("сегодн") || lower.contains("today")
            let scopeWeek = lower.contains("недел") || lower.contains("week")

            func matchesPeriod(_ date: Date) -> Bool {
                if scopeToday { return cal.isDate(date, inSameDayAs: currentNow) }
                if scopeWeek { return cal.isDate(date, equalTo: currentNow, toGranularity: .weekOfYear) }
                return cal.isDate(date, equalTo: currentNow, toGranularity: .month)
            }

            var seen = Set<UUID>()
            var titles: [String] = []

            let sessions = sessionsProvider?() ?? workspace?.sessions ?? []
            for session in sessions where matchesPeriod(session.startedAt) {
                guard seen.insert(session.id).inserted else { continue }
                titles.append(session.title)
            }
            for live in activeMeetingsProvider() {
                let dedupeID = live.sessionID ?? live.id
                guard seen.insert(dedupeID).inserted else { continue }
                titles.append(live.title)
            }

            let count = titles.count
            if count == 0 {
                return scopeToday
                    ? L("You have had no meetings today.")
                    : (scopeWeek
                        ? L("You have had no meetings this week.")
                        : L("You have had no recorded meetings this month."))
            }
            let headTitles = titles.prefix(4).joined(separator: ", ")
            let summaryList = count > 4 ? L("%@ and %ld more", headTitles, count - 4) : headTitles
            let countClause = scopeToday
                ? L("Today you had %ld meetings", count)
                : (scopeWeek
                    ? L("This week you had %ld meetings", count)
                    : L("This month you had %ld meetings", count))
            return L("%@: %@.", countClause, summaryList)
        }

        // 2. Join current meeting
        let asksJoin = lower.contains("подключ") || lower.contains("зайди") || lower.contains("войди")
            || lower.contains("join") || lower.contains("connect me")
        let mentionsTarget = lower.contains("текущ") || lower.contains("сейчас") || lower.contains("current")
            || lower.contains("следующ") || lower.contains("next") || mentionsMeeting
        if asksJoin && mentionsTarget {
            let candidates = joinableTargets(currentNow)
            guard let best = CurrentMeetingTargetResolver.bestCurrentMeeting(from: candidates, now: currentNow) else {
                return L("No ongoing or upcoming meeting with a join link was found.")
            }
            if AssistantVoiceApprovalPolicy.shouldAutoApprove(actionKind: "join", inputSource: source, sendsWithoutAsking: false) {
                if onJoinCandidate?(best) == true {
                    return L("Joining “%@”.", best.title)
                }
                return L("Unable to join “%@”.", best.title)
            } else {
                pendingApproval = PendingApproval(
                    id: UUID(),
                    kind: .join,
                    title: L("Join “%@”?", best.title),
                    detail: best.invitation.absoluteString,
                    targetID: best.id,
                    text: "",
                    candidate: best
                )
                return L("Confirm joining “%@”.", best.title)
            }
        }

        // 3. Mute mic
        let asksMute = lower.contains("замут") || lower.contains("выключи микрофон") || lower.contains("отключи микрофон")
            || (lower.contains("mute") && (lower.contains("mic") || lower.contains("микрофон") || lower == "mute"))
        if asksMute {
            return onMuteMeeting?(resolvedTargetMeetingID()) ?? L("No active call to mute.")
        }

        // 4. Participate mode switch
        let asksParticipate = lower.contains("режим участия") || lower.contains("включи участие") || lower.contains("participat")
        if asksParticipate {
            guard let targetID = resolvedTargetMeetingID() else {
                return L("Join an active meeting first.")
            }
            let objective = Self.extractObjective(from: input)
            onRequestParticipation?(targetID, objective)
            if objective.isEmpty {
                return L("Opening Participation mode — speak your meeting context.")
            } else {
                return L("Participation enabled: %@", objective)
            }
        }

        // 5. Leave active call (ALWAYS requires confirmation per A2)
        let asksLeave = lower.contains("покин") || lower.contains("выйд") || lower.contains("заверш")
            || (lower.contains("leave") && (mentionsMeeting || lower == "leave"))
        if asksLeave {
            guard let targetID = resolvedTargetMeetingID(),
                  let active = activeMeetingsProvider().first(where: { $0.id == targetID }) else {
                return L("No active meeting.")
            }
            pendingApproval = PendingApproval(
                id: UUID(),
                kind: .leave,
                title: L("Leave “%@”?", active.title),
                detail: L("The meeting outcome will be saved in Workspace."),
                targetID: active.id,
                text: "",
                candidate: nil
            )
            return L("Please confirm leaving “%@”.", active.title)
        }

        // 6. Send chat message (asks unless askBeforeSending == false)
        if let chatText = Self.extractChatText(from: input, lower: lower) {
            guard let targetID = resolvedTargetMeetingID(),
                  let active = activeMeetingsProvider().first(where: { $0.id == targetID }) else {
                return L("No active meeting.")
            }
            guard active.canSendChat else {
                return L("Chat is unavailable in “%@”.", active.title)
            }
            let sendsWithoutAsking = !(assistant?.effectiveAskBeforeSending(for: active.id) ?? true)
            if AssistantVoiceApprovalPolicy.shouldAutoApprove(
                actionKind: "sendChat",
                inputSource: source,
                sendsWithoutAsking: sendsWithoutAsking
            ) {
                do {
                    if let onSendChat {
                        try await onSendChat(active.id, chatText)
                    } else if let assistant {
                        try await assistant.sendManualChat(controllerID: active.id, text: chatText)
                    }
                    return L("Sent to chat: %@", chatText)
                } catch {
                    return error.localizedDescription
                }
            } else {
                pendingApproval = PendingApproval(
                    id: UUID(),
                    kind: .sendChat,
                    title: L("Send message to “%@”?", active.title),
                    detail: chatText,
                    targetID: active.id,
                    text: chatText,
                    candidate: nil
                )
                return L("Review message before sending to “%@”.", active.title)
            }
        }

        // 7. Open tasks
        let asksTasks = (lower.contains("задач") || lower.contains("tasks") || lower.contains("to-do"))
            && (lower.contains("мои") || lower.contains("открыт") || lower.contains("какие") || lower.contains("список")
                || lower.contains("what") || lower.contains("my") || lower.contains("list"))
        if asksTasks {
            let sourceTasks = tasksProvider?() ?? workspace?.tasks ?? []
            let open = sourceTasks.filter { task in
                !task.done && (workspace?.taskArchivedAt(task) == nil)
            }
            if open.isEmpty {
                return L("You have no open tasks.")
            }
            let bullets = open.prefix(8).map { "• \($0.text)" }.joined(separator: "\n")
            return L("Open tasks (%ld):", open.count) + "\n" + bullets
        }

        return nil
    }

    private func answerWithWorkspaceOrAI(_ query: String) async -> String {
        let hits = await (workspace?.search(query: query) ?? [])
        let cal = Calendar.current
        let currentNow = now()
        let monthCount = workspace?.sessions.filter { cal.isDate($0.startedAt, equalTo: currentNow, toGranularity: .month) }.count ?? 0
        let openTasks = workspace?.tasks.filter { !$0.done && workspace?.taskArchivedAt($0) == nil }.prefix(6).map(\.text) ?? []
        let candidates = joinableTargets(currentNow).prefix(4).map(\.title)
        let snippets = hits.prefix(5).map { "\($0.title) (\($0.startedAt.formatted(date: .abbreviated, time: .shortened))): \($0.snippet)" }

        let contextText = """
        Current date: \(currentNow.formatted(date: .abbreviated, time: .shortened))
        Meetings this month: \(monthCount)
        Open tasks: \(openTasks.isEmpty ? "none" : openTasks.joined(separator: "; "))
        Upcoming or ongoing meetings: \(candidates.isEmpty ? "none" : candidates.joined(separator: ", "))
        Search matches: \(snippets.isEmpty ? "none" : snippets.joined(separator: "\n"))
        """

        if let workspace, let config = try? workspace.permittedAIConfiguration() {
            let systemPrompt = "You are Rock, a concise voice assistant inside Rock'N'Roll. Answer the user's question in their language strictly from the provided workspace context. Never invent meetings or facts."
            let userPrompt = "Question: \(query)\n\nWorkspace context:\n\(contextText)"

            switch config.providerKind {
            case .preferMac, .appleOnDevice:
                #if canImport(FoundationModels)
                if #available(iOS 26.0, macOS 26.0, *),
                   SystemLanguageModel.default.availability == .available {
                    do {
                        let session = LanguageModelSession(instructions: systemPrompt)
                        let response = try await session.respond(to: userPrompt)
                        let trimmed = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !trimmed.isEmpty { return trimmed }
                    } catch {}
                }
                #endif
            case .openAI, .openRouter, .custom:
                if let endpoint = config.endpoint, !config.resolvedModel.isEmpty {
                    let key = workspace.readAPIKey(for: config.providerKind)
                    let messages: [[String: String]] = [
                        ["role": "system", "content": systemPrompt],
                        ["role": "user", "content": userPrompt]
                    ]
                    let body = PortableOutcomeService.requestBody(
                        messages: messages, model: config.resolvedModel, provider: config.providerKind,
                        tokenLimit: 600, temperature: 0.2
                    )
                    var request = URLRequest(url: endpoint)
                    request.httpMethod = "POST"
                    request.timeoutInterval = 30
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !key.isEmpty { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
                    if let bodyData = try? JSONSerialization.data(withJSONObject: body) {
                        request.httpBody = bodyData
                        if let (data, response) = try? await MeetingAITransfer.send(request, using: .shared),
                           let http = response as? HTTPURLResponse,
                           (200..<300).contains(http.statusCode),
                           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           let choices = root["choices"] as? [[String: Any]],
                           let message = choices.first?["message"] as? [String: Any],
                           let content = message["content"] as? String {
                            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty { return trimmed }
                        }
                    }
                }
            }
        }

        if !snippets.isEmpty {
            return snippets.joined(separator: "\n\n")
        }
        return L("No exact matches found. Ask about monthly meetings, open tasks, or say “Rock, join current meeting”.")
    }

    private nonisolated static func extractObjective(from input: String) -> String {
        let lower = input.lowercased().replacingOccurrences(of: "ё", with: "е")
        for marker in ["с контекстом ", "контекст:", "контекст ", "с целью ", "цель:", "цель ", "with context ", "context:", "goal:"] {
            if let range = lower.range(of: marker) {
                let tailStart = input.index(input.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let clean = String(input[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { return String(clean.prefix(180)) }
            }
        }
        return ""
    }

    private nonisolated static func extractChatText(from input: String, lower: String) -> String? {
        for marker in ["напиши в чат ", "отправь в чат ", "скажи в чате ", "send chat ", "send in chat ", "write in chat "] {
            if let range = lower.range(of: marker) {
                let tailStart = input.index(input.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: range.upperBound))
                let text = String(input[tailStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : String(text.prefix(1000))
            }
        }
        return nil
    }
}
