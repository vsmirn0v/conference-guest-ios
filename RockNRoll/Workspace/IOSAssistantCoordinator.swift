import ConferenceCore
import Foundation
import UserNotifications
#if canImport(FoundationModels)
import FoundationModels
#endif

enum IOSMeetingAssistantMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case off
    case mentions
    case follow
    case participating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return L("Off")
        case .mentions: return L("Mentions")
        case .follow: return L("Follow")
        case .participating: return L("Participate")
        }
    }

    var shortTitle: String {
        switch self {
        case .off: return L("Off")
        case .mentions: return L("Mentions")
        case .follow: return L("Follow")
        case .participating: return L("Participate")
        }
    }

    var subtitle: String {
        switch self {
        case .off:
            return L("Assistant stays quiet for this meeting.")
        case .mentions:
            return L("Alerts you when your name or alias is mentioned or you are directly addressed.")
        case .follow:
            return L("Follows the conversation and alerts you when your input or decision is needed.")
        case .participating:
            return L("Tracks the meeting and drafts or delivers chat and voice replies on your behalf.")
        }
    }

    var symbol: String {
        switch self {
        case .off: return "bell.slash"
        case .mentions: return "at.badge.plus"
        case .follow: return "eye"
        case .participating: return "waveform.and.person.filled"
        }
    }

    /// Compatible string value for `SyncedMeetingContextSettings.attentionMode`.
    var syncedRawValue: String? {
        switch self {
        case .off: return "off"
        case .mentions: return "mentions"
        case .follow: return "watch"
        case .participating: return nil
        }
    }

    init?(syncedRawValue: String?) {
        guard let raw = syncedRawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else { return nil }
        switch raw {
        case "off": self = .off
        case "mentions": self = .mentions
        case "watch", "follow": self = .follow
        case "participating": self = .participating
        default: return nil
        }
    }
}

enum IOSParticipationOutput: String, Codable, CaseIterable, Sendable, Identifiable {
    case chat
    case voice
    case voiceAndChat

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return L("Chat message")
        case .voice: return L("Voice reply")
        case .voiceAndChat: return L("Voice & Chat")
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "bubble.left.and.text.bubble.right"
        case .voice: return "waveform"
        case .voiceAndChat: return "waveform.badge.mic"
        }
    }
}

struct IOSParticipationConfig: Codable, Equatable, Sendable {
    var askBeforeSending: Bool = true
    var defaultOutput: IOSParticipationOutput = .chat
    var goal: String = ""
    var replyStyle: String = "Concise, natural, first-person"
}

struct IOSAssistantAlertCard: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var controllerID: UUID
    var workspaceSessionID: UUID?
    var meetingTitle: String
    var mode: IOSMeetingAssistantMode
    var urgency: IOSAssistantVerdict.Urgency
    var createdAt: Date
    var reason: String
    var excerpt: String
    var suggestedReply: String
    var deliveredAutomatically: Bool = false
    var deliveryNote: String? = nil
    var dismissed: Bool = false
}

struct IOSAssistantActivityItem: Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var controllerID: UUID
    var meetingTitle: String
    var mode: IOSMeetingAssistantMode
    var at: Date
    var summary: String
    var deliveredChannel: String?
}

struct IOSAssistantEvaluationRequest: Sendable {
    var mode: IOSMeetingAssistantMode
    var meetingTitle: String
    var participantNames: [String]
    var userAliases: [String]
    var contextAbout: String
    var contextMatters: String
    var contextNever: String
    var guidanceRules: [String]
    var participationGoal: String
    var replyStyle: String
    var notesDraft: String
    var recentEvents: [SyncedTranscriptEvent]
    var language: String
}

struct IOSAssistantVerdict: Equatable, Sendable {
    enum Urgency: String, Codable, Sendable {
        case none
        case soon
        case now
    }

    var needsUser: Bool
    var urgency: Urgency
    var reason: String
    var suggestedReply: String?
    var confidence: Double

    static let quiet = IOSAssistantVerdict(
        needsUser: false,
        urgency: .none,
        reason: "",
        suggestedReply: nil,
        confidence: 0
    )
}

protocol IOSAssistantEvaluating: Sendable {
    func evaluate(_ request: IOSAssistantEvaluationRequest) async throws -> IOSAssistantVerdict
}

@MainActor
struct IOSAssistantSessionBridge {
    var controllerID: UUID
    var title: String
    var roomKey: String
    var calendarSeriesKey: String?
    var localDisplayName: String
    var participantNames: [String]
    var canSendChat: Bool
    var isMicUnmuted: Bool
    var isForeground: Bool
    var ensureTranscription: @MainActor () async -> Void
    var sendChat: @MainActor (String) async throws -> Void
    var speakVoice: @MainActor (String) async throws -> Void
}

struct IOSAssistantLLMService: IOSAssistantEvaluating {
    let configProvider: @Sendable () async -> PortableOutcomeConfiguration
    let apiKeyProvider: @Sendable (PortableOutcomeProviderKind) -> String?
    let urlSession: URLSession

    init(
        configProvider: @escaping @Sendable () async -> PortableOutcomeConfiguration,
        apiKeyProvider: @escaping @Sendable (PortableOutcomeProviderKind) -> String?,
        urlSession: URLSession = .shared
    ) {
        self.configProvider = configProvider
        self.apiKeyProvider = apiKeyProvider
        self.urlSession = urlSession
    }

    func evaluate(_ request: IOSAssistantEvaluationRequest) async throws -> IOSAssistantVerdict {
        let config = await configProvider()
        let messages = Self.buildMessages(for: request)

        switch config.providerKind {
        case .preferMac, .appleOnDevice:
            #if canImport(FoundationModels)
            if #available(iOS 26.0, macOS 26.0, *),
               SystemLanguageModel.default.availability == .available {
                let modelSession = LanguageModelSession(instructions: messages[0]["content"]!)
                let response = try await modelSession.respond(to: messages[1]["content"]!)
                return try Self.parseVerdict(response.content)
            }
            #endif
            throw PortableOutcomeError.notConfigured

        case .openAI, .openRouter, .custom:
            guard let endpoint = config.endpoint else {
                throw PortableOutcomeError.notConfigured
            }
            let rawModel = config.model.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = rawModel.isEmpty ? config.providerKind.defaultModel : rawModel
            guard !model.isEmpty else {
                throw PortableOutcomeError.notConfigured
            }
            let key = apiKeyProvider(config.providerKind)
            if config.providerKind.needsKey && (key?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false) {
                throw PortableOutcomeError.missingKey
            }

            let body: [String: Any] = [
                "model": model,
                "messages": messages,
                "temperature": 0.1,
                "max_tokens": 500,
                "response_format": ["type": "json_object"]
            ]
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.timeoutInterval = 30
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let key, !key.isEmpty {
                urlRequest.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await urlSession.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PortableOutcomeError.transport(L("The assistant provider returned an error."))
            }
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                throw PortableOutcomeError.invalidResponse
            }
            return try Self.parseVerdict(content)
        }
    }

    static func buildMessages(for req: IOSAssistantEvaluationRequest) -> [[String: String]] {
        let transcriptLines = req.recentEvents.suffix(24).map { ev in
            let speaker = ev.isOwn ? "Me" : ((ev.speaker?.isEmpty == false) ? ev.speaker! : "Participant")
            let prefix = ev.kind == "chat" ? "[chat] " : ""
            return "\(speaker): \(prefix)\(ev.text)"
        }.joined(separator: "\n")

        let modeRule: String
        switch req.mode {
        case .off:
            modeRule = "Assistant is OFF."
        case .mentions:
            modeRule = "Only trigger needs_user=true when the user (aliases: \(req.userAliases.joined(separator: ", "))) is mentioned by name, role, or asked an urgent direct question."
        case .follow:
            modeRule = "Trigger needs_user=true whenever the conversation needs the user's attention, opinion, decision, action item, or mentions their area."
        case .participating:
            modeRule = "Actively participate on the user's behalf: determine when a concise first-person response is helpful or expected, and write suggested_reply in first person matching the meeting language (\(req.language)). Goal: \(req.participationGoal.isEmpty ? "Help answer direct questions and confirm ownership concisely." : req.participationGoal). Style: \(req.replyStyle)."
        }

        let system = """
        You are an unobtrusive live meeting assistant watching an ongoing call for the user.
        Return ONLY valid JSON with keys:
        {"needs_user": boolean, "urgency": "none"|"soon"|"now", "reason": string, "suggested_reply": string|null, "confidence": number}
        Mode instruction: \(modeRule)
        Keep `reason` concise (<= 16 words) in the user language (\(req.language)).
        Only set `suggested_reply` when responding makes sense or the user wants a reply draft.
        Never invent facts not present in the transcript or notes.
        """

        var userParts: [String] = ["Meeting: \(req.meetingTitle)"]
        if !req.userAliases.isEmpty {
            userParts.append("User aliases: \(req.userAliases.joined(separator: ", "))")
        }
        if !req.participantNames.isEmpty {
            userParts.append("Participants: \(req.participantNames.joined(separator: ", "))")
        }
        if !req.contextAbout.isEmpty { userParts.append("About this meeting: \(req.contextAbout)") }
        if !req.contextMatters.isEmpty { userParts.append("Matters most: \(req.contextMatters)") }
        if !req.contextNever.isEmpty { userParts.append("Ignore / never flag: \(req.contextNever)") }
        if !req.guidanceRules.isEmpty { userParts.append("Rules:\n- " + req.guidanceRules.joined(separator: "\n- ")) }
        if !req.notesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            userParts.append("User notes:\n\(req.notesDraft.prefix(800))")
        }
        userParts.append("Recent conversation:\n\(transcriptLines)")

        return [
            ["role": "system", "content": system],
            ["role": "user", "content": userParts.joined(separator: "\n\n")]
        ]
    }

    static func parseVerdict(_ raw: String) throws -> IOSAssistantVerdict {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonString: String
        if let start = trimmed.firstIndex(of: "{"), let end = trimmed.lastIndex(of: "}") {
            jsonString = String(trimmed[start...end])
        } else {
            jsonString = trimmed
        }
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PortableOutcomeError.invalidResponse
        }
        let needs = obj["needs_user"] as? Bool ?? false
        let rawUrgency = (obj["urgency"] as? String ?? (needs ? "soon" : "none")).lowercased()
        let urgency = IOSAssistantVerdict.Urgency(rawValue: rawUrgency) ?? (needs ? .soon : .none)
        let reason = (obj["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let reply = (obj["suggested_reply"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let confidence = (obj["confidence"] as? NSNumber)?.doubleValue ?? (needs ? 0.75 : 0.2)
        return IOSAssistantVerdict(
            needsUser: needs && urgency != .none,
            urgency: needs ? urgency : .none,
            reason: reason,
            suggestedReply: reply?.isEmpty == true ? nil : reply,
            confidence: confidence
        )
    }
}

@MainActor
final class IOSAssistantCoordinator: ObservableObject {
    private enum Keys {
        static let foregroundDefault = "ios.assistant.defaultForegroundMode"
        static let backgroundDefault = "ios.assistant.defaultBackgroundMode"
        static let roomModes = "ios.assistant.roomModes"
        static let participation = "ios.assistant.participationConfig"
    }

    @Published var defaultForegroundMode: IOSMeetingAssistantMode {
        didSet { preferences.set(defaultForegroundMode.rawValue, forKey: Keys.foregroundDefault) }
    }
    @Published var defaultBackgroundMode: IOSMeetingAssistantMode {
        didSet { preferences.set(defaultBackgroundMode.rawValue, forKey: Keys.backgroundDefault) }
    }
    @Published var participationConfig: IOSParticipationConfig {
        didSet { persistParticipationConfig() }
    }

    @Published private(set) var sessionModeOverrides: [UUID: IOSMeetingAssistantMode] = [:]
    @Published private(set) var sessionParticipationOutputs: [UUID: IOSParticipationOutput] = [:]
    @Published private(set) var sessionParticipationGoals: [UUID: String] = [:]
    @Published private(set) var sessionAskBeforeSending: [UUID: Bool] = [:]
    @Published private(set) var roomModeOverrides: [String: IOSMeetingAssistantMode] = [:]
    @Published private(set) var pausedParticipatingSessions: Set<UUID> = []
    @Published private(set) var evaluatingSessions: Set<UUID> = []
    @Published private(set) var alertCards: [IOSAssistantAlertCard] = []
    @Published private(set) var activityLog: [IOSAssistantActivityItem] = []
    @Published private(set) var lastStatusNoteBySession: [UUID: String] = [:]
    @Published private(set) var lastError: String?

    private weak var workspace: IOSWorkspaceCoordinator?
    private let preferences: UserDefaults
    private let evaluator: any IOSAssistantEvaluating
    private let resolveBridge: (UUID) -> IOSAssistantSessionBridge?
    private let scheduleNotification: (IOSAssistantAlertCard) async -> Void
    private let evaluationCooldown: TimeInterval
    private let mentionCooldown: TimeInterval
    private let nowProvider: () -> Date
    private let modelAvailableOverride: (() -> Bool)?

    var onBannerAlert: ((IOSAssistantAlertCard) -> Void)?
    var onSessionModeChanged: ((UUID, IOSMeetingAssistantMode, Bool) -> Void)?

    private var eventBuffers: [UUID: [SyncedTranscriptEvent]] = [:]
    private var seenEventIDs: [UUID: Set<String>] = [:]
    private var lastEvaluatedAt: [UUID: Date] = [:]
    private var lastMentionTriggerAt: [UUID: Date] = [:]
    private var evaluationTasks: [UUID: Task<Void, Never>] = [:]
    private var foregroundControllerID: UUID?

    init(
        workspace: IOSWorkspaceCoordinator?,
        preferences: UserDefaults = .standard,
        evaluator: (any IOSAssistantEvaluating)? = nil,
        modelAvailable: (() -> Bool)? = nil,
        evaluationCooldown: TimeInterval = 12,
        mentionCooldown: TimeInterval = 8,
        now: @escaping () -> Date = Date.init,
        resolveBridge: @escaping (UUID) -> IOSAssistantSessionBridge?,
        scheduleNotification: ((IOSAssistantAlertCard) async -> Void)? = nil
    ) {
        self.workspace = workspace
        self.preferences = preferences
        self.modelAvailableOverride = modelAvailable
        if let evaluator {
            self.evaluator = evaluator
        } else {
            let keychain = workspace?.keychain ?? WorkspaceAPIKeychain()
            self.evaluator = IOSAssistantLLMService(
                configProvider: { @MainActor [weak workspace] in workspace?.outcomeConfig ?? PortableOutcomeConfiguration() },
                apiKeyProvider: { keychain.read(kind: $0) }
            )
        }
        self.evaluationCooldown = evaluationCooldown
        self.mentionCooldown = mentionCooldown
        self.nowProvider = now
        self.resolveBridge = resolveBridge
        if let scheduleNotification {
            self.scheduleNotification = scheduleNotification
        } else {
            self.scheduleNotification = { card in
                guard NSClassFromString("XCTestCase") == nil else { return }
                let center = UNUserNotificationCenter.current()
                let settings = await center.notificationSettings()
                guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
                let content = UNMutableNotificationContent()
                content.title = card.meetingTitle
                content.body = card.reason
                content.sound = .default
                content.userInfo = ["controllerID": card.controllerID.uuidString]
                let req = UNNotificationRequest(
                    identifier: "ios-assistant-\(card.id.uuidString)",
                    content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
                )
                try? await center.add(req)
            }
        }

        self.defaultForegroundMode = preferences.string(forKey: Keys.foregroundDefault)
            .flatMap(IOSMeetingAssistantMode.init(rawValue:)) ?? .off
        self.defaultBackgroundMode = preferences.string(forKey: Keys.backgroundDefault)
            .flatMap(IOSMeetingAssistantMode.init(rawValue:)) ?? .off

        if let data = preferences.data(forKey: Keys.participation),
           let decoded = try? JSONDecoder().decode(IOSParticipationConfig.self, from: data) {
            self.participationConfig = decoded
        } else {
            self.participationConfig = IOSParticipationConfig()
        }

        if let rawRooms = preferences.dictionary(forKey: Keys.roomModes) as? [String: String] {
            var loaded: [String: IOSMeetingAssistantMode] = [:]
            for (k, v) in rawRooms {
                if let m = IOSMeetingAssistantMode(rawValue: v) { loaded[k] = m }
            }
            self.roomModeOverrides = loaded
        }
    }

    // MARK: - Mode Resolution & Configuration

    func resolvedMode(for controllerID: UUID) -> IOSMeetingAssistantMode {
        if let explicit = sessionModeOverrides[controllerID] {
            return explicit
        }
        if let bridge = resolveBridge(controllerID) {
            if let localRoom = roomModeOverrides[bridge.roomKey] {
                return localRoom
            }
            if let series = bridge.calendarSeriesKey,
               let syncedSeries = workspace?.settings(for: "series:\(series)")?.attentionMode?.value,
               let mapped = IOSMeetingAssistantMode(syncedRawValue: syncedSeries) {
                return mapped
            }
            if !bridge.roomKey.isEmpty,
               let syncedRoom = workspace?.settings(for: "room:\(bridge.roomKey)")?.attentionMode?.value,
               let mapped = IOSMeetingAssistantMode(syncedRawValue: syncedRoom) {
                return mapped
            }
            if let syncedAll = workspace?.settings(for: "all")?.attentionMode?.value,
               let mapped = IOSMeetingAssistantMode(syncedRawValue: syncedAll) {
                return mapped
            }
            return bridge.isForeground ? defaultForegroundMode : defaultBackgroundMode
        }
        return controllerID == foregroundControllerID ? defaultForegroundMode : defaultBackgroundMode
    }

    func effectiveAskBeforeSending(for controllerID: UUID) -> Bool {
        sessionAskBeforeSending[controllerID] ?? participationConfig.askBeforeSending
    }

    func effectiveParticipationOutput(for controllerID: UUID) -> IOSParticipationOutput {
        sessionParticipationOutputs[controllerID] ?? participationConfig.defaultOutput
    }

    func effectiveParticipationGoal(for controllerID: UUID) -> String {
        sessionParticipationGoals[controllerID] ?? participationConfig.goal
    }

    func isPausedForMicrophone(controllerID: UUID) -> Bool {
        pausedParticipatingSessions.contains(controllerID) && resolvedMode(for: controllerID) == .participating
    }

    func hasModelConfigured() -> Bool {
        modelAvailableOverride?()
            ?? (workspace?.outcomeConfig.hasOnDeviceOrRemoteWriter ?? PortableOutcomeConfiguration.isAppleOnDeviceAvailable)
    }

    func setMode(_ mode: IOSMeetingAssistantMode, for controllerID: UUID, rememberForRoom: Bool = false) {
        sessionModeOverrides[controllerID] = mode
        if let bridge = resolveBridge(controllerID) {
            if rememberForRoom, !bridge.roomKey.isEmpty {
                roomModeOverrides[bridge.roomKey] = mode
                persistRoomModes()
                if let synced = mode.syncedRawValue {
                    let scopeKey = "room:\(bridge.roomKey)"
                    Task { [weak workspace] in
                        await workspace?.saveContextAttentionMode(
                            synced,
                            scopeKey: scopeKey,
                            scopeKind: .room,
                            title: bridge.title
                        )
                    }
                }
            }
            if mode == .participating && bridge.isMicUnmuted {
                pausedParticipatingSessions.insert(controllerID)
                lastStatusNoteBySession[controllerID] = L("Paused while your microphone is unmuted.")
            } else {
                pausedParticipatingSessions.remove(controllerID)
                lastStatusNoteBySession[controllerID] = nil
            }
            if mode != .off {
                requestNotificationPermissionIfNeeded()
                Task { await bridge.ensureTranscription() }
            }
        }
        onSessionModeChanged?(controllerID, mode, isPausedForMicrophone(controllerID: controllerID))
    }

    func setParticipationOptions(
        for controllerID: UUID,
        askBeforeSending: Bool,
        output: IOSParticipationOutput,
        goal: String
    ) {
        sessionAskBeforeSending[controllerID] = askBeforeSending
        sessionParticipationOutputs[controllerID] = output
        sessionParticipationGoals[controllerID] = goal
    }

    func activePresentationChanged(foregroundControllerID: UUID?) {
        let previous = self.foregroundControllerID
        self.foregroundControllerID = foregroundControllerID
        if let previous, let bridge = resolveBridge(previous) {
            let mode = resolvedMode(for: previous)
            onSessionModeChanged?(previous, mode, isPausedForMicrophone(controllerID: previous))
            if mode != .off {
                Task { await bridge.ensureTranscription() }
            }
        }
        if let foregroundControllerID, let bridge = resolveBridge(foregroundControllerID) {
            let mode = resolvedMode(for: foregroundControllerID)
            onSessionModeChanged?(foregroundControllerID, mode, isPausedForMicrophone(controllerID: foregroundControllerID))
            if mode != .off {
                Task { await bridge.ensureTranscription() }
            }
        }
    }

    func handleMicrophoneChange(controllerID: UUID, unmuted: Bool) {
        let mode = resolvedMode(for: controllerID)
        if unmuted {
            if mode == .participating {
                pausedParticipatingSessions.insert(controllerID)
                lastStatusNoteBySession[controllerID] = L("Paused while your microphone is unmuted.")
            }
        } else if pausedParticipatingSessions.remove(controllerID) != nil {
            lastStatusNoteBySession[controllerID] = mode == .participating ? L("Active again now that mic is muted.") : nil
        }
        onSessionModeChanged?(controllerID, mode, isPausedForMicrophone(controllerID: controllerID))
    }

    func sessionEnded(controllerID: UUID) {
        evaluationTasks[controllerID]?.cancel()
        evaluationTasks.removeValue(forKey: controllerID)
        eventBuffers.removeValue(forKey: controllerID)
        seenEventIDs.removeValue(forKey: controllerID)
        lastEvaluatedAt.removeValue(forKey: controllerID)
        lastMentionTriggerAt.removeValue(forKey: controllerID)
        sessionModeOverrides.removeValue(forKey: controllerID)
        sessionParticipationOutputs.removeValue(forKey: controllerID)
        sessionParticipationGoals.removeValue(forKey: controllerID)
        sessionAskBeforeSending.removeValue(forKey: controllerID)
        pausedParticipatingSessions.remove(controllerID)
        evaluatingSessions.remove(controllerID)
        lastStatusNoteBySession.removeValue(forKey: controllerID)
        alertCards.removeAll { $0.controllerID == controllerID }
    }

    // MARK: - Live Event Observation & Evaluation

    func observeEvents(_ events: [SyncedTranscriptEvent], for controllerID: UUID) {
        guard !events.isEmpty else { return }
        var seen = seenEventIDs[controllerID] ?? []
        var buffer = eventBuffers[controllerID] ?? []
        var freshEvents: [SyncedTranscriptEvent] = []

        for ev in events {
            guard !seen.contains(ev.id) else { continue }
            seen.insert(ev.id)
            let clean = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, ev.kind == "transcript" || ev.kind == "chat" else { continue }
            buffer.append(ev)
            if !ev.isOwn {
                freshEvents.append(ev)
            }
        }
        if buffer.count > 80 {
            buffer.removeFirst(buffer.count - 80)
        }
        seenEventIDs[controllerID] = seen
        eventBuffers[controllerID] = buffer

        guard !freshEvents.isEmpty else { return }
        let mode = resolvedMode(for: controllerID)
        guard mode != .off else { return }
        if mode == .participating && isPausedForMicrophone(controllerID: controllerID) {
            return
        }

        let bridge = resolveBridge(controllerID)
        let aliases = collectedAliases(for: bridge)
        let mention = Self.findMention(in: freshEvents, aliases: aliases)

        if mode == .mentions && mention == nil && !hasModelConfigured() {
            return
        }

        let now = nowProvider()
        if let mention {
            if let last = lastMentionTriggerAt[controllerID], now.timeIntervalSince(last) < mentionCooldown {
                return
            }
            lastMentionTriggerAt[controllerID] = now
            scheduleEvaluation(controllerID: controllerID, localMention: mention, recentEvents: buffer, force: true)
            return
        }

        guard mode == .follow || mode == .participating else { return }
        if let last = lastEvaluatedAt[controllerID], now.timeIntervalSince(last) < evaluationCooldown {
            return
        }
        scheduleEvaluation(controllerID: controllerID, localMention: nil, recentEvents: buffer, force: false)
    }

    /// Directly evaluates recent events immediately (handy for tests and manual "Check now" taps).
    func evaluateNow(
        controllerID: UUID,
        localMention: (event: SyncedTranscriptEvent, alias: String)? = nil
    ) async {
        let buffer = eventBuffers[controllerID] ?? []
        guard !buffer.isEmpty else { return }
        let mention = localMention ?? Self.findMention(in: buffer.suffix(5).filter { !$0.isOwn }, aliases: collectedAliases(for: resolveBridge(controllerID)))
        await performEvaluation(controllerID: controllerID, localMention: mention, recentEvents: buffer)
    }

    private func scheduleEvaluation(
        controllerID: UUID,
        localMention: (event: SyncedTranscriptEvent, alias: String)?,
        recentEvents: [SyncedTranscriptEvent],
        force: Bool
    ) {
        if evaluationTasks[controllerID] != nil && !force { return }
        evaluationTasks[controllerID]?.cancel()
        evaluationTasks[controllerID] = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performEvaluation(controllerID: controllerID, localMention: localMention, recentEvents: recentEvents)
            self.evaluationTasks.removeValue(forKey: controllerID)
        }
    }

    private func performEvaluation(
        controllerID: UUID,
        localMention: (event: SyncedTranscriptEvent, alias: String)?,
        recentEvents: [SyncedTranscriptEvent]
    ) async {
        let mode = resolvedMode(for: controllerID)
        guard mode != .off else { return }
        if mode == .participating && isPausedForMicrophone(controllerID: controllerID) { return }

        let bridge = resolveBridge(controllerID)
        let title = bridge?.title ?? L("Meeting")
        lastEvaluatedAt[controllerID] = nowProvider()
        evaluatingSessions.insert(controllerID)
        defer { evaluatingSessions.remove(controllerID) }

        var verdict: IOSAssistantVerdict?
        if hasModelConfigured() {
            let roomSettings = bridge.flatMap { workspace?.settings(for: "room:\($0.roomKey)") }
            let seriesSettings = bridge?.calendarSeriesKey.flatMap { workspace?.settings(for: "series:\($0)") }
            let allSettings = workspace?.settings(for: "all")
            let settings = seriesSettings ?? roomSettings ?? allSettings

            let req = IOSAssistantEvaluationRequest(
                mode: mode,
                meetingTitle: title,
                participantNames: bridge?.participantNames ?? [],
                userAliases: collectedAliases(for: bridge),
                contextAbout: settings?.about?.value ?? "",
                contextMatters: settings?.matters?.value ?? "",
                contextNever: settings?.never?.value ?? "",
                guidanceRules: (settings?.guidanceRules.values.map(\.value).filter { !$0.deleted }.map(\.text)) ?? [],
                participationGoal: effectiveParticipationGoal(for: controllerID),
                replyStyle: participationConfig.replyStyle,
                notesDraft: workspace?.workspaceSessionID(forControllerID: controllerID).flatMap { workspace?.noteDraft(for: $0) } ?? "",
                recentEvents: Array(recentEvents.suffix(24)),
                language: Locale.current.language.languageCode?.identifier ?? "en"
            )
            do {
                verdict = try await evaluator.evaluate(req)
                lastError = nil
            } catch {
                lastError = error.localizedDescription
            }
        }

        if let verdict, verdict.needsUser {
            await handleVerdict(
                verdict,
                controllerID: controllerID,
                mode: mode,
                bridge: bridge,
                fallbackExcerpt: Self.formatExcerpt(from: localMention?.event ?? recentEvents.last)
            )
            return
        }

        // Fallback deterministic alert when local mention matched even without a working LLM.
        if let localMention {
            let speaker = localMention.event.speaker ?? L("Someone")
            let fallback = IOSAssistantVerdict(
                needsUser: true,
                urgency: .now,
                reason: L("%@ mentioned \"%@\"", speaker, localMention.alias),
                suggestedReply: mode == .participating ? L("Got it, looking into it now.") : nil,
                confidence: 1.0
            )
            await handleVerdict(
                fallback,
                controllerID: controllerID,
                mode: mode,
                bridge: bridge,
                fallbackExcerpt: Self.formatExcerpt(from: localMention.event)
            )
        } else if mode != .mentions && !hasModelConfigured() {
            lastStatusNoteBySession[controllerID] = L("Local mention detection active. Configure Apple Intelligence or an AI API key for full context.")
        }
    }

    private func handleVerdict(
        _ verdict: IOSAssistantVerdict,
        controllerID: UUID,
        mode: IOSMeetingAssistantMode,
        bridge: IOSAssistantSessionBridge?,
        fallbackExcerpt: String
    ) async {
        let title = bridge?.title ?? L("Meeting")
        let workspaceSID = workspace?.workspaceSessionID(forControllerID: controllerID)
        let replyText = (verdict.suggestedReply ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedReason = verdict.reason.isEmpty ? L("Your attention is requested.") : verdict.reason
        // Check duplicate active card for the same utterance and reason
        if alertCards.contains(where: {
            !$0.dismissed && $0.controllerID == controllerID && $0.reason == resolvedReason && $0.excerpt == fallbackExcerpt
        }) {
            return
        }

        var deliveredAutomatically = false
        var deliveryNote: String?

        if mode == .participating,
           !effectiveAskBeforeSending(for: controllerID),
           !replyText.isEmpty,
           !(bridge?.isMicUnmuted ?? false),
           let bridge {
            let output = effectiveParticipationOutput(for: controllerID)
            var sentChannels: [String] = []
            do {
                switch output {
                case .chat:
                    if bridge.canSendChat {
                        try await bridge.sendChat(replyText)
                        sentChannels.append(L("Chat"))
                    }
                case .voice:
                    try await bridge.speakVoice(replyText)
                    sentChannels.append(L("Voice"))
                case .voiceAndChat:
                    if bridge.canSendChat {
                        try await bridge.sendChat(replyText)
                        sentChannels.append(L("Chat"))
                    }
                    try await bridge.speakVoice(replyText)
                    sentChannels.append(L("Voice"))
                }
                if !sentChannels.isEmpty {
                    deliveredAutomatically = true
                    deliveryNote = L("Delivered via %@", sentChannels.joined(separator: " + "))
                    recordActivity(
                        controllerID: controllerID,
                        title: title,
                        mode: mode,
                        summary: replyText,
                        channel: sentChannels.joined(separator: " + ")
                    )
                }
            } catch {
                lastError = error.localizedDescription
                deliveryNote = error.localizedDescription
            }
        }

        let card = IOSAssistantAlertCard(
            controllerID: controllerID,
            workspaceSessionID: workspaceSID,
            meetingTitle: title,
            mode: mode,
            urgency: verdict.urgency,
            createdAt: nowProvider(),
            reason: resolvedReason,
            excerpt: fallbackExcerpt,
            suggestedReply: replyText,
            deliveredAutomatically: deliveredAutomatically,
            deliveryNote: deliveryNote
        )

        alertCards.insert(card, at: 0)
        if alertCards.count > 25 {
            alertCards.removeLast(alertCards.count - 25)
        }
        recordActivity(
            controllerID: controllerID,
            title: title,
            mode: mode,
            summary: card.reason,
            channel: deliveredAutomatically ? deliveryNote : nil
        )
        onBannerAlert?(card)
        if !(bridge?.isForeground ?? false) || !deliveredAutomatically {
            await scheduleNotification(card)
        }
    }

    // MARK: - Card Actions

    func updateCardDraft(_ cardID: UUID, text: String) {
        guard let idx = alertCards.firstIndex(where: { $0.id == cardID }) else { return }
        alertCards[idx].suggestedReply = text
    }

    func dismissCard(_ cardID: UUID) {
        alertCards.removeAll { $0.id == cardID }
    }

    func sendCardToChat(_ cardID: UUID) async throws {
        guard let idx = alertCards.firstIndex(where: { $0.id == cardID }) else { return }
        let card = alertCards[idx]
        let text = card.suggestedReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bridge = resolveBridge(card.controllerID) else { return }
        try await bridge.sendChat(text)
        alertCards[idx].deliveredAutomatically = false
        alertCards[idx].deliveryNote = L("Sent to chat")
        recordActivity(controllerID: card.controllerID, title: card.meetingTitle, mode: card.mode, summary: text, channel: L("Chat"))
    }

    func speakCardReply(_ cardID: UUID) async throws {
        guard let idx = alertCards.firstIndex(where: { $0.id == cardID }) else { return }
        let card = alertCards[idx]
        let text = card.suggestedReply.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let bridge = resolveBridge(card.controllerID) else { return }
        try await bridge.speakVoice(text)
        alertCards[idx].deliveryNote = L("Spoken in call")
        recordActivity(controllerID: card.controllerID, title: card.meetingTitle, mode: card.mode, summary: text, channel: L("Voice"))
    }

    // MARK: - Mention Detection & Helpers

    static func findMention(in events: [SyncedTranscriptEvent], aliases: [String]) -> (event: SyncedTranscriptEvent, alias: String)? {
        let cleanAliases = aliases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 }
        guard !cleanAliases.isEmpty else { return nil }

        for ev in events.reversed() {
            guard !ev.isOwn else { continue }
            let text = ev.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            for alias in cleanAliases {
                let escaped = NSRegularExpression.escapedPattern(for: alias)
                let pattern = "(?i)(?:^|[^\\p{L}\\p{N}])@?" + escaped + "(?:$|[^\\p{L}\\p{N}])"
                if let regex = try? NSRegularExpression(pattern: pattern),
                   regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                    return (ev, alias)
                }
            }
        }
        return nil
    }

    private func collectedAliases(for bridge: IOSAssistantSessionBridge?) -> [String] {
        var result: [String] = []
        if let name = bridge?.localDisplayName.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            result.append(name)
            if let firstToken = name.split(separator: " ").first, firstToken.count >= 2 {
                result.append(String(firstToken))
            }
        }
        if let profile = workspace?.taskProfile {
            if let assignee = profile.assigneeID?.trimmingCharacters(in: .whitespacesAndNewlines), !assignee.isEmpty {
                result.append(assignee)
            }
            for alias in profile.aliases {
                let clean = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                if !clean.isEmpty { result.append(clean) }
            }
        }
        return Array(Set(result))
    }

    private static func formatExcerpt(from event: SyncedTranscriptEvent?) -> String {
        guard let event else { return "" }
        let speaker = event.speaker?.isEmpty == false ? "\(event.speaker!): " : ""
        return speaker + event.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func recordActivity(controllerID: UUID, title: String, mode: IOSMeetingAssistantMode, summary: String, channel: String?) {
        activityLog.insert(IOSAssistantActivityItem(
            controllerID: controllerID,
            meetingTitle: title,
            mode: mode,
            at: nowProvider(),
            summary: summary,
            deliveredChannel: channel
        ), at: 0)
        if activityLog.count > 40 {
            activityLog.removeLast(activityLog.count - 40)
        }
    }

    private func persistRoomModes() {
        preferences.set(roomModeOverrides.mapValues(\.rawValue), forKey: Keys.roomModes)
    }

    private func persistParticipationConfig() {
        if let data = try? JSONEncoder().encode(participationConfig) {
            preferences.set(data, forKey: Keys.participation)
        }
    }

    private func requestNotificationPermissionIfNeeded() {
        guard NSClassFromString("XCTestCase") == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}
