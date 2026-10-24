import Foundation

/// Values and envelopes below follow the preserved official Jazz Web SDK 26.11.23
/// and its transcription/chat plugins, not the legacy XMPP message format.
enum GuestMeetingReaction: String, CaseIterable, Sendable {
    case heart = "RED_HEART", like = "THUMBS_UP", smile = "FACE_WITH_TEARS_OF_JOY"
    case applause = "PARTY_POPPER", fire = "FIRE", wave = "WAVING_HAND", handshake = "HANDSHAKE"
    case thanks = "FOLDED_HANDS", thinking = "THINKING_FACE", sad = "CRYING_FACE"
    case dislike = "THUMBS_DOWN", surprise = "FACE_SCREAMING_IN_FEAR"
    var symbol: String {
        switch self {
        case .heart: "❤️"; case .like: "👍"; case .smile: "😂"; case .applause: "🎉"
        case .fire: "🔥"; case .wave: "👋"; case .handshake: "🤝"; case .thanks: "🙏"
        case .thinking: "🤔"; case .sad: "😢"; case .dislike: "👎"; case .surprise: "😱"
        }
    }
    static func received(_ value: String) -> Self? {
        switch value {
        case "CLAP": .applause; case "JOY": .smile; case "OPEN_MOUTH": .surprise
        default: Self(rawValue: value)
        }
    }
}

struct GuestMeetingPermissions: Equatable, Sendable {
    var canViewParticipants = false
    var canViewChat = false
    var canSendChat = false
    var canSendReaction = false
    var canViewTranscript = false
    var canManageTranscript = false
    var canShareScreen = false
}

struct GuestMeetingParticipant: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var role: String?
    var isLocal: Bool
    var microphoneMuted = true
    var cameraMuted = true
    var sharingScreen = false
    var isSpeaking = false
    var audioLevel: Double = 0
}

struct GuestMeetingMessage: Identifiable, Equatable, Sendable {
    enum Delivery: String, Sendable { case pending, sent, failed }
    let id: String
    let participantID: String
    var participantName: String
    var text: String
    var sentAt: Date?
    var isOwn: Bool
    var delivery: Delivery = .sent
}

struct GuestMeetingReactionEvent: Identifiable, Equatable, Sendable {
    let id: UUID
    let participantID: String
    let participantName: String
    let reaction: GuestMeetingReaction
    let receivedAt: Date
}

struct GuestMeetingSnapshot: Equatable, Sendable {
    enum TranscriptionStatus: String, Sendable { case unknown, active, stopped, failed }
    var connected = false
    var title = ""
    var localParticipantID: String?
    var permissions = GuestMeetingPermissions()
    var participants: [GuestMeetingParticipant] = []
    var messages: [GuestMeetingMessage] = []
    var chatHistoryLoaded = false
    var chatHasMore = false
    var reactions: [GuestMeetingReactionEvent] = []
    var transcript: [GuestMeetingMessage] = []
    var transcriptHistoryLoaded = false
    var transcriptHasMore = false
    var transcriptionStatus: TranscriptionStatus = .unknown
    var screenSharing = false
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

    mutating func receive(_ envelope: [String: Any]) {
        guard !stopped, let event = envelope["event"] as? String else { return }
        let payload = envelope["payload"] as? [String: Any] ?? [:]
        if event == "joined" {
            guard let participant = payload["participant"] as? [String: Any],
                  let id = Self.identifier(participant["participantId"]),
                  let group = payload["participantGroup"] as? [String: Any],
                  let groupID = Self.identifier(group["groupId"]),
                  let roomID = Self.identifier(payload["roomId"]) else { return }
            if self.roomID != nil, self.roomID != roomID || self.groupID != groupID {
                let nextEpoch = epoch &+ 1
                self = GuestMeetingFeatures(); epoch = nextEpoch
            }
            self.roomID = roomID; self.groupID = groupID
            snapshot.localParticipantID = id
            snapshot.title = (group["name"] as? String) ?? (payload["settings"] as? [String: Any])?["title"] as? String ?? ""
            members.removeAll()
            for value in group["participants"] as? [[String: Any]] ?? [] { addMember(value) }
            if members[id] == nil { addMember(participant) }
            permissions.removeAll()
            updatePermissions(participant["permissions"] as? [String: Bool] ?? [:])
        } else {
            guard roomID != nil, acceptsScope(envelope) else { return }
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
            case "permissions-updated": updatePermissions(payload as? [String: Bool] ?? [:])
            case "settings-updated":
                if let title = payload["title"] as? String { snapshot.title = String(title.prefix(512)) }
            case "chat-message":
                if snapshot.permissions.canViewChat, let message = decodeMessage(payload["message"], fallbackID: envelope["requestId"]) {
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
                if snapshot.permissions.canViewTranscript, let message = decodeMessage(payload["message"]) { upsert(message, transcript: true) }
            case "transcription-started": snapshot.transcriptionStatus = .active
            case "transcription-stopped": snapshot.transcriptionStatus = .stopped
            case "transcription-error": snapshot.transcriptionStatus = .failed
            default: break
            }
        }
        rebuildRoster()
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

    mutating func acceptHistory(_ payload: [String: Any], transcript: Bool, epoch: UInt64) throws {
        guard !stopped, epoch == self.epoch,
              transcript ? snapshot.permissions.canViewTranscript : snapshot.permissions.canViewChat else { return }
        guard let values = payload["messages"] as? [[String: Any]], values.count <= 1_000 else { throw GuestEngineError.malformed }
        // The server pages newest first. Upsert sorts by timestamp and identity,
        // so live events received during the request remain present.
        for value in values.reversed() {
            if let message = decodeMessage(value) { upsert(message, transcript: transcript) }
        }
        let page = payload["nextPageKey"]
        let next: Any? = (page is String || page is NSNumber) ? page : nil
        if transcript { transcriptPage = next; snapshot.transcriptHasMore = next != nil; snapshot.transcriptHistoryLoaded = true }
        else { chatPage = next; snapshot.chatHasMore = next != nil; snapshot.chatHistoryLoaded = true }
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
    private func decodeMessage(_ raw: Any?, fallbackID: Any? = nil) -> GuestMeetingMessage? {
        guard let value = raw as? [String: Any], let id = Self.identifier(value["id"] ?? fallbackID),
              let participant = Self.identifier(value["participantId"]), let text = value["text"] as? String,
              !text.isEmpty, text.utf8.count <= 64 * 1024 else { return nil }
        return .init(id: id, participantID: participant,
                     participantName: String((value["participantName"] as? String ?? members[participant]?.name ?? "Participant").prefix(256)),
                     text: String(text.prefix(4_096)), sentAt: Self.date(value["createdAt"]),
                     isOwn: participant == snapshot.localParticipantID)
    }
    private mutating func upsert(_ message: GuestMeetingMessage, transcript: Bool) {
        var values = transcript ? snapshot.transcript : snapshot.messages
        if let index = values.firstIndex(where: { $0.id == message.id }) { values[index] = message }
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
            let milliseconds = number.doubleValue
            guard milliseconds.isFinite else { return nil }
            return Date(timeIntervalSince1970: milliseconds / 1_000)
        }
        if let value = value as? String {
            let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        }
        return nil
    }
}
