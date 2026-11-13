import Foundation

enum ParticipationTranscriptSource: Equatable {
    case unavailable, service, localRoomAudio
}

/// A decoded line from the current Guest receive path. A missing RTP
/// identity stays unknown. It never inherits a name from the display timeline.
struct ParticipationLocalTranscriptLine {
    let id: String
    let participantID: String?
    let text: String
    let start: Date
    let end: Date

    init?(line: MeetingTranscriber.Line, receiver: [String: ParticipationRemoteAudioBinding]) {
        guard line.trackID != MeetingTranscriber.localTrackID,
              let source = receiver[line.trackID], line.start >= source.since, line.end >= line.start else { return nil }
        id = line.id; participantID = source.participantID; text = line.text
        start = line.start; end = line.end
    }
}

/// Bound to a receiving audio track and to the time its identity was resolved.
struct ParticipationRemoteAudioBinding {
    let participantID: String?
    let since: Date
}

struct ParticipationObservation {
    enum Source: String, Encodable, Sendable {
        case chat, serviceTranscript, localTranscript

        var namespace: String {
            switch self {
            case .chat: "chat"
            case .serviceTranscript: "transcript"
            case .localTranscript: "local-transcript"
            }
        }

        var channel: String { self == .chat ? "chat" : "transcript" }
    }

    let source: Source
    let id: String
    let participantID: String?
    let text: String
    let spokenAt: Date?
    let receivedAt: Date?
    let own: Bool
    let delivery: GuestMeetingMessage.Delivery

    init(_ message: GuestMeetingMessage, source: Source) {
        self.source = source; id = source.namespace + ":" + message.id
        participantID = message.participantID; text = message.text; spokenAt = message.sentAt
        receivedAt = message.receivedAt; own = message.isOwn; delivery = message.delivery
    }

    init(_ line: ParticipationLocalTranscriptLine) {
        source = .localTranscript; id = source.namespace + ":" + line.id
        participantID = line.participantID; text = line.text; spokenAt = line.start
        receivedAt = line.end; own = false; delivery = .sent
    }

    func line(members: [String: String], localParticipant: String) -> ParticipationLine? {
        if let participantID, let name = members[participantID] {
            let isOwn = own || participantID == localParticipant
            guard source != .localTranscript || !isOwn else { return nil }
            return .init(id: id, channel: source.channel, speaker: String(name.prefix(80)),
                         text: String(text.prefix(600)), own: isOwn)
        }
        guard source == .localTranscript, participantID == nil, !own else { return nil }
        return .init(id: id, channel: source.channel, speaker: L("Unidentified room speaker"),
                     text: String(text.prefix(600)), own: false, speakerVerified: false)
    }

    func isFresh(enteredAt: Date, now: Date, own: Bool) -> Date? {
        let pendingOwn = own && delivery == .pending
        guard delivery == .sent || pendingOwn,
              let timestamp = receivedAt ?? (pendingOwn ? spokenAt : nil),
              timestamp > enteredAt, now.timeIntervalSince(timestamp) < 45,
              timestamp <= now,
              spokenAt.map({ abs(timestamp.timeIntervalSince($0)) < 120 }) ?? true else { return nil }
        if source == .localTranscript, (spokenAt ?? .distantPast) < enteredAt { return nil }
        return timestamp
    }

    func overlapsVoice(start: Date, end: Date) -> Bool {
        guard source != .chat, let receivedAt else { return false }
        let spoken = spokenAt ?? receivedAt
        return spoken <= end.addingTimeInterval(4) && (source == .localTranscript ? receivedAt : spoken) >= start.addingTimeInterval(-1)
    }

    func duplicatesTranscript(_ prior: ParticipationObservation) -> Bool {
        guard source != .chat, prior.source != .chat, source != prior.source,
              let time = spokenAt ?? receivedAt, let previous = prior.spokenAt ?? prior.receivedAt,
              abs(time.timeIntervalSince(previous)) <= 12,
              participantID == nil || prior.participantID == nil || participantID == prior.participantID else { return false }
        return text == prior.text
    }
}
