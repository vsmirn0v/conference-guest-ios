import Foundation
import CoreFoundation

/// A room can include non-boolean metadata beside permission flags. Extract
/// each actual JSON boolean independently; numbers and strings grant nothing.
enum GuestPermissionValues {
    private static let protectedKeys: Set<String> = [
        "canViewParticipants", "canViewChat", "canSendChatMessage", "canSendReaction",
        "canViewTranscription", "canStartTranscription", "canShareScreen", "canShareCamera", "canShareMicrophone"
    ]
    static func extract(_ raw: Any?) -> [String: Bool] {
        guard let values = raw as? [String: Any] else { return [:] }
        return values.reduce(into: [:]) { result, entry in
            if let value = entry.value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() {
                result[entry.key] = value.boolValue
            } else if protectedKeys.contains(entry.key) {
                // An explicitly malformed security flag cannot retain an old grant.
                result[entry.key] = false
            }
        }
    }
    static func fieldType(_ value: Any?) -> String {
        guard let value else { return "missing" }
        if value is NSNull { return "null" }
        if let number = value as? NSNumber {
            return CFGetTypeID(number) == CFBooleanGetTypeID() ? "bool" : "number"
        }
        if value is String { return "string" }
        if value is [String: Any] { return "object" }
        if value is [Any] { return "array" }
        return "other"
    }
    static func logShape(_ raw: Any?, source: String) {
        let values = raw as? [String: Any]
        let booleanCount = values?.values.filter { value in
            guard let number = value as? NSNumber else { return false }
            return CFGetTypeID(number) == CFBooleanGetTypeID()
        }.count ?? 0
        probeLog("guest-permissions-shape", ["source": source,
            "container": raw == nil ? "missing" : values == nil ? fieldType(raw) : "object",
            "entries": values?.count ?? 0, "booleanEntries": booleanCount,
            "canViewTranscriptionType": fieldType(values?["canViewTranscription"]),
            "canStartTranscriptionType": fieldType(values?["canStartTranscription"])])
    }
}

/// Values and envelopes below follow the preserved official Jazz Web SDK 26.11.23
/// and its transcription/chat plugins, not the legacy XMPP message format.
public enum GuestMeetingReaction: String, CaseIterable, Sendable {
    case heart = "RED_HEART", like = "THUMBS_UP", smile = "FACE_WITH_TEARS_OF_JOY"
    case applause = "PARTY_POPPER", fire = "FIRE", wave = "WAVING_HAND", handshake = "HANDSHAKE"
    case thanks = "FOLDED_HANDS", thinking = "THINKING_FACE", sad = "CRYING_FACE"
    case dislike = "THUMBS_DOWN", surprise = "FACE_SCREAMING_IN_FEAR"
    public var symbol: String {
        switch self {
        case .heart: "❤️"; case .like: "👍"; case .smile: "😂"; case .applause: "🎉"
        case .fire: "🔥"; case .wave: "👋"; case .handshake: "🤝"; case .thanks: "🙏"
        case .thinking: "🤔"; case .sad: "😢"; case .dislike: "👎"; case .surprise: "😱"
        }
    }
    public static func received(_ value: String) -> Self? {
        switch value {
        case "CLAP": .applause; case "JOY": .smile; case "OPEN_MOUTH": .surprise
        default: Self(rawValue: value)
        }
    }
}

public struct GuestMeetingPermissions: Equatable, Sendable {
    public var canViewParticipants = false
    public var canViewChat = false
    public var canSendChat = false
    public var canSendReaction = false
    public var canViewTranscript = false
    public var canManageTranscript = false
    public var canShareScreen = false
    public init(canViewParticipants: Bool = false, canViewChat: Bool = false, canSendChat: Bool = false,
                canSendReaction: Bool = false, canViewTranscript: Bool = false, canManageTranscript: Bool = false,
                canShareScreen: Bool = false) {
        self.canViewParticipants = canViewParticipants; self.canViewChat = canViewChat
        self.canSendChat = canSendChat; self.canSendReaction = canSendReaction
        self.canViewTranscript = canViewTranscript; self.canManageTranscript = canManageTranscript
        self.canShareScreen = canShareScreen
    }
}

public struct GuestMeetingParticipant: Identifiable, Equatable, Sendable {
    public let id: String
    public var name: String
    public var role: String?
    public var isLocal: Bool
    public var microphoneMuted = true
    public var cameraMuted = true
    public var sharingScreen = false
    public var isSpeaking = false
    public var audioLevel: Double = 0
    public init(id: String, name: String, role: String? = nil, isLocal: Bool,
                microphoneMuted: Bool = true, cameraMuted: Bool = true, sharingScreen: Bool = false,
                isSpeaking: Bool = false, audioLevel: Double = 0) {
        self.id = id; self.name = name; self.role = role; self.isLocal = isLocal
        self.microphoneMuted = microphoneMuted; self.cameraMuted = cameraMuted
        self.sharingScreen = sharingScreen; self.isSpeaking = isSpeaking; self.audioLevel = audioLevel
    }
}

public struct GuestMeetingMessage: Identifiable, Equatable, Sendable {
    public enum Delivery: String, Sendable { case pending, sent, failed }
    public let id: String
    public let participantID: String
    public var participantName: String
    public var text: String
    public var sentAt: Date?
    public var isOwn: Bool
    public var delivery: Delivery = .sent
    /// When a live event first delivered this message here; nil for history pages.
    /// It places live text in time when the provider's own timestamp is absent.
    public var receivedAt: Date? = nil
    /// Local acknowledgement carries less evidence than a server chat row.
    public var locallyAcknowledged = false
    public init(id: String, participantID: String, participantName: String, text: String,
                sentAt: Date? = nil, isOwn: Bool, delivery: Delivery = .sent,
                receivedAt: Date? = nil, locallyAcknowledged: Bool = false) {
        self.id = id; self.participantID = participantID; self.participantName = participantName
        self.text = text; self.sentAt = sentAt; self.isOwn = isOwn; self.delivery = delivery
        self.receivedAt = receivedAt; self.locallyAcknowledged = locallyAcknowledged
    }
}

public struct GuestMeetingReactionEvent: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let participantID: String
    public let participantName: String
    public let reaction: GuestMeetingReaction
    public let receivedAt: Date
    public init(id: UUID, participantID: String, participantName: String, reaction: GuestMeetingReaction, receivedAt: Date) {
        self.id = id; self.participantID = participantID; self.participantName = participantName
        self.reaction = reaction; self.receivedAt = receivedAt
    }
}

public struct GuestMeetingSnapshot: Equatable, Sendable {
    public enum TranscriptionStatus: String, Sendable { case unknown, active, stopped, failed }
    public var connected = false
    public var title = ""
    public var localParticipantID: String?
    public var permissions = GuestMeetingPermissions()
    public var participants: [GuestMeetingParticipant] = []
    public var messages: [GuestMeetingMessage] = []
    public var chatHistoryLoaded = false
    public var chatHasMore = false
    public var reactions: [GuestMeetingReactionEvent] = []
    public var transcript: [GuestMeetingMessage] = []
    public var transcriptHistoryLoaded = false
    public var transcriptHasMore = false
    public var transcriptNetworkRestricted = false
    public var transcriptionStatus: TranscriptionStatus = .unknown
    public var screenSharing = false
    public init(connected: Bool = false, title: String = "", localParticipantID: String? = nil,
                permissions: GuestMeetingPermissions = GuestMeetingPermissions(),
                participants: [GuestMeetingParticipant] = [], messages: [GuestMeetingMessage] = [],
                chatHistoryLoaded: Bool = false, chatHasMore: Bool = false,
                reactions: [GuestMeetingReactionEvent] = [], transcript: [GuestMeetingMessage] = [],
                transcriptHistoryLoaded: Bool = false, transcriptHasMore: Bool = false,
                transcriptNetworkRestricted: Bool = false, transcriptionStatus: TranscriptionStatus = .unknown,
                screenSharing: Bool = false) {
        self.connected = connected; self.title = title; self.localParticipantID = localParticipantID
        self.permissions = permissions; self.participants = participants; self.messages = messages
        self.chatHistoryLoaded = chatHistoryLoaded; self.chatHasMore = chatHasMore
        self.reactions = reactions; self.transcript = transcript
        self.transcriptHistoryLoaded = transcriptHistoryLoaded; self.transcriptHasMore = transcriptHasMore
        self.transcriptNetworkRestricted = transcriptNetworkRestricted
        self.transcriptionStatus = transcriptionStatus; self.screenSharing = screenSharing
    }
}

/// A per-connection reducer. Room membership owns identities/names; versioned RTC
/// snapshots only enrich media state. Permission loss erases protected content and
/// advances an epoch so an in-flight history response cannot restore it.
struct GuestMeetingFeatures {
    private(set) var snapshot = GuestMeetingSnapshot()
    private(set) var roomID: String?
    private(set) var groupID: String?
    private(set) var epoch: UInt64 = 0
    private(set) var chatPage: Any?
    private(set) var transcriptPage: Any?
    private var members: [String: GuestMeetingParticipant] = [:]
    private var rtc: [String: (identity: String, tracks: [[String: Any]])] = [:]
    private var rtcVersions: [String: Int] = [:]
    private var speakers: [String: Double] = [:]
    private var localMute: [Bool: Bool] = [:]
    private var permissions: [String: Bool] = [:]
    private var stopped = false

    @discardableResult
    mutating func receive(_ envelope: [String: Any]) -> (message: GuestMeetingMessage, transcript: Bool)? {
        guard !stopped, let event = envelope["event"] as? String else { return nil }
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        var captured: (message: GuestMeetingMessage, transcript: Bool)?
        if event == "joined" {
            guard let participant = payload["participant"] as? [String: Any],
                  let id = Self.identifier(participant["participantId"]),
                  let group = payload["participantGroup"] as? [String: Any],
                  let groupID = Self.identifier(group["groupId"]),
                  let roomID = Self.identifier(payload["roomId"]) else { return nil }
            if self.roomID != nil, self.roomID != roomID || self.groupID != groupID {
                let nextEpoch = epoch &+ 1
                self = GuestMeetingFeatures(); epoch = nextEpoch
            }
            self.roomID = roomID; self.groupID = groupID
            snapshot.localParticipantID = id
            snapshot.transcriptNetworkRestricted = GuestPermissionValues.extract(participant)["isNetworkRestrictTranscription"] == true
            snapshot.title = (group["name"] as? String) ?? (payload["settings"] as? [String: Any])?["title"] as? String ?? ""
            members.removeAll()
            for value in group["participants"] as? [[String: Any]] ?? [] { addMember(value) }
            if members[id] == nil { addMember(participant) }
            permissions.removeAll()
            updatePermissions(GuestPermissionValues.extract(participant["permissions"]))
        } else if event == "lobby-joined" || event == "lobby-settings-updated" {
            let settings = (payload["settings"] as? [String: Any]) ?? payload
            if let title = settings["title"] as? String, !title.isEmpty {
                snapshot.title = String(title.prefix(512))
            }
        } else {
            guard roomID != nil, acceptsScope(envelope) else { return nil }
            switch event {
            case "participant-joined": addMember(payload)
            case "participant-left":
                if let id = payload["participantId"] as? String {
                    members.removeValue(forKey: id)
                    rtc = rtc.filter { $0.value.identity != id }
                }
            case "participant-name-updated":
                if let id = payload["participantId"] as? String, let name = payload["participantName"] as? String {
                    members[id]?.name = String(name.prefix(256))
                }
            case "participant-role-updated":
                if let id = payload["participantId"] as? String {
                    members[id]?.role = payload["role"] as? String; updatePermissions([:])
                }
            case "permissions-updated": updatePermissions(GuestPermissionValues.extract(payload))
            case "settings-updated":
                if let title = payload["title"] as? String { snapshot.title = String(title.prefix(512)) }
            case "chat-message":
                if snapshot.permissions.canViewChat, let message = decodeMessage(payload["message"], fallbackID: envelope["requestId"], receivedAt: Date()) {
                    captured = (archiveMessage(message, raw: payload["message"]), false)
                    upsert(message, transcript: false)
                }
            case "reaction":
                if let id = Self.identifier(payload["participantId"]), let value = payload["reaction"] as? String,
                   let reaction = GuestMeetingReaction.received(value) {
                    snapshot.reactions.append(.init(id: UUID(), participantID: id, participantName: members[id]?.name ?? "Participant",
                                                    reaction: reaction, receivedAt: Date()))
                    snapshot.reactions = Array(snapshot.reactions.suffix(100))
                }
            case "transcription-message":
                if snapshot.permissions.canViewTranscript, let message = decodeMessage(payload["message"], receivedAt: Date()) {
                    if !loggedTranscriptShape, let fields = payload["message"] as? [String: Any] {
                        // Field names only, never content: which timestamp the provider sends.
                        loggedTranscriptShape = true
                        probeLog("transcript-message-shape", ["keys": fields.keys.sorted(), "dated": message.sentAt != nil])
                    }
                    captured = (archiveMessage(message, raw: payload["message"]), true)
                    upsert(message, transcript: true)
                }
            case "transcription-started": snapshot.transcriptionStatus = .active
            case "transcription-stopped": snapshot.transcriptionStatus = .stopped
            case "transcription-error": snapshot.transcriptionStatus = .failed
            default: break
            }
        }
        rebuildRoster()
        return captured
    }

    func acceptsScope(_ envelope: [String: Any]) -> Bool {
        if let room = envelope["roomId"] as? String, room != roomID { return false }
        if let group = envelope["groupId"] as? String, group != groupID { return false }
        return true
    }

    mutating func updateRTC(_ values: [[String: Any]]) {
        guard !stopped else { return }
        for value in values {
            guard let sid = Self.identifier(value["sid"]), let identity = Self.identifier(value["identity"]) else { continue }
            let version = value["version"] as? Int ?? 0
            guard version > (rtcVersions[sid] ?? -1) else { continue }
            rtcVersions[sid] = version
            // A resumed room identity can get a new SID before the old one leaves.
            if value["state"] as? String == "DISCONNECTED" { rtc.removeValue(forKey: sid); speakers.removeValue(forKey: sid) }
            else {
                rtc = rtc.filter { $0.key == sid || $0.value.identity != identity }
                rtc[sid] = (identity, value["tracks"] as? [[String: Any]] ?? [])
            }
        }
        rebuildRoster()
    }

    mutating func updateSpeakers(_ values: [[String: Any]]) {
        guard !stopped else { return }
        speakers.removeAll()
        for value in values {
            guard let sid = Self.identifier(value["sid"]), rtc[sid] != nil,
                  value["active"] as? Bool != false else { continue }
            let level = (value["level"] as? NSNumber)?.doubleValue ?? 1
            guard level.isFinite else { continue }
            speakers[sid] = min(1, max(0, level))
        }
        rebuildRoster()
    }

    mutating func setConnected(_ value: Bool) { snapshot.connected = value && !stopped }
    mutating func setScreenSharing(_ value: Bool) { snapshot.screenSharing = value && !stopped; rebuildRoster() }
    mutating func setLocalMute(_ muted: Bool, video: Bool) { localMute[video] = muted; rebuildRoster() }
    mutating func setTranscriptionStatus(_ value: GuestMeetingSnapshot.TranscriptionStatus) { snapshot.transcriptionStatus = value }

    mutating func addOutgoing(id: String, text: String) {
        guard !stopped, snapshot.permissions.canViewChat, let own = snapshot.localParticipantID else { return }
        upsert(.init(id: id, participantID: own, participantName: members[own]?.name ?? "You", text: text,
                     sentAt: Date(), isOwn: true, delivery: .pending), transcript: false)
    }
    mutating func finishOutgoing(id: String, succeeded: Bool) {
        guard let index = snapshot.messages.firstIndex(where: { $0.id == id }) else { return }
        snapshot.messages[index].delivery = succeeded ? .sent : .failed
    }

    @discardableResult
    mutating func acceptHistory(_ payload: [String: Any], transcript: Bool, epoch: UInt64) throws -> [GuestMeetingMessage] {
        guard !stopped, epoch == self.epoch,
              transcript ? snapshot.permissions.canViewTranscript : snapshot.permissions.canViewChat else { return [] }
        guard let values = payload["messages"] as? [[String: Any]], values.count <= 1_000 else { throw GuestEngineError.malformed }
        // The server pages newest first. Upsert sorts by timestamp and identity,
        // so live events received during the request remain present.
        var captured: [GuestMeetingMessage] = []
        for value in values.reversed() {
            if let message = decodeMessage(value) {
                captured.append(archiveMessage(message, raw: value))
                upsert(message, transcript: transcript)
            }
        }
        let page = payload["nextPageKey"]
        let next: Any? = (page is String || page is NSNumber) ? page : nil
        if transcript { transcriptPage = next; snapshot.transcriptHasMore = next != nil; snapshot.transcriptHistoryLoaded = true }
        else { chatPage = next; snapshot.chatHasMore = next != nil; snapshot.chatHistoryLoaded = true }
        // Shape and counts only: never record transcript text or identifiers.
        probeLog("guest-history-page", ["kind": transcript ? "transcript" : "chat",
            "rows": values.count, "decoded": captured.count, "hasMore": next != nil])
        return captured
    }

    mutating func stop() {
        stopped = true; epoch &+= 1
        snapshot = GuestMeetingSnapshot(); members.removeAll(); rtc.removeAll(); rtcVersions.removeAll(); speakers.removeAll()
        roomID = nil; groupID = nil; chatPage = nil; transcriptPage = nil
    }

    private mutating func addMember(_ value: [String: Any]) {
        guard let id = Self.identifier(value["participantId"]) else { return }
        members[id] = .init(id: id, name: String((value["name"] as? String ?? "Participant").prefix(256)),
                            role: value["role"] as? String, isLocal: id == snapshot.localParticipantID)
    }
    private mutating func updatePermissions(_ values: [String: Bool]) {
        let old = snapshot.permissions
        permissions.merge(values) { _, new in new }
        snapshot.permissions.canViewParticipants = permissions["canViewParticipants"] == true
        snapshot.permissions.canViewChat = permissions["canViewChat"] == true
        snapshot.permissions.canSendChat = permissions["canSendChatMessage"] == true
        snapshot.permissions.canSendReaction = permissions["canSendReaction"] == true
        // The official transcription plugin grants owner/moderator access in
        // addition to the explicit room permission flags.
        let localRole = snapshot.localParticipantID.flatMap { members[$0]?.role }
        let privileged = localRole == "OWNER" || localRole == "MODERATOR"
        snapshot.permissions.canViewTranscript = permissions["canViewTranscription"] == true || privileged
        snapshot.permissions.canManageTranscript = permissions["canStartTranscription"] == true || privileged
        snapshot.permissions.canShareScreen = permissions["canShareScreen"] == true
        if old.canViewChat && !snapshot.permissions.canViewChat {
            snapshot.messages.removeAll(); chatPage = nil; snapshot.chatHistoryLoaded = false; snapshot.chatHasMore = false; epoch &+= 1
        }
        if old.canViewTranscript && !snapshot.permissions.canViewTranscript {
            snapshot.transcript.removeAll(); transcriptPage = nil; snapshot.transcriptHistoryLoaded = false; snapshot.transcriptHasMore = false; epoch &+= 1
        }
    }
    private mutating func rebuildRoster() {
        snapshot.participants = members.values.filter { snapshot.permissions.canViewParticipants || $0.isLocal }.map { member in
            var member = member
            for (sid, value) in rtc where value.identity == member.id {
                member.isSpeaking = speakers[sid] != nil; member.audioLevel = speakers[sid] ?? 0
                for track in value.tracks {
                    let muted = track["muted"] as? Bool ?? true
                    switch track["source"] as? String {
                    case "MICROPHONE": member.microphoneMuted = muted
                    case "CAMERA": member.cameraMuted = muted
                    case "SCREEN_SHARE": member.sharingScreen = !muted
                    default: break
                    }
                }
            }
            if member.isLocal {
                if localMute[false] == true { member.microphoneMuted = true; member.isSpeaking = false; member.audioLevel = 0 }
                if localMute[true] == true { member.cameraMuted = true }
                member.sharingScreen = snapshot.screenSharing
            }
            return member
        }.sorted { $0.isLocal != $1.isLocal ? $0.isLocal : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private var loggedTranscriptShape = false
    private func archiveMessage(_ message: GuestMeetingMessage, raw: Any?) -> GuestMeetingMessage {
        var message = message
        message.text = (raw as? [String: Any])?["text"] as? String ?? message.text
        return message
    }
    private func decodeMessage(_ raw: Any?, fallbackID: Any? = nil, receivedAt: Date? = nil) -> GuestMeetingMessage? {
        guard let value = raw as? [String: Any], let id = Self.identifier(value["id"] ?? fallbackID),
              let participant = Self.identifier(value["participantId"]), let text = value["text"] as? String,
              !text.isEmpty, text.utf8.count <= 64 * 1024 else { return nil }
        return .init(id: id, participantID: participant,
                     participantName: String((value["participantName"] as? String ?? members[participant]?.name ?? "Participant").prefix(256)),
                     text: String(text.prefix(4_096)),
                     sentAt: ["createdAt", "timestamp", "startTime", "startedAt", "time"].lazy.compactMap { Self.date(value[$0]) }.first,
                     isOwn: participant == snapshot.localParticipantID, receivedAt: receivedAt)
    }
    private mutating func upsert(_ message: GuestMeetingMessage, transcript: Bool) {
        var values = transcript ? snapshot.transcript : snapshot.messages
        if let index = values.firstIndex(where: { $0.id == message.id }) {
            var updated = message; updated.receivedAt = values[index].receivedAt ?? message.receivedAt
            values[index] = updated
        }
        else { values.append(message) }
        values.sort {
            if $0.sentAt != $1.sentAt { return ($0.sentAt ?? .distantPast) < ($1.sentAt ?? .distantPast) }
            return $0.id < $1.id
        }
        values = Array(values.suffix(transcript ? 1_000 : 200))
        if transcript { snapshot.transcript = values } else { snapshot.messages = values }
    }
    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 1_024 else { return nil }
        return value
    }
    private static func date(_ value: Any?) -> Date? {
        if let number = value as? NSNumber {
            // Milliseconds or seconds since 1970; anything before 2020 is not a wall-clock time.
            let raw = number.doubleValue
            guard raw.isFinite else { return nil }
            let date = Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
            return date > Date(timeIntervalSince1970: 1_577_836_800) ? date : nil
        }
        if let value = value as? String {
            let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}
