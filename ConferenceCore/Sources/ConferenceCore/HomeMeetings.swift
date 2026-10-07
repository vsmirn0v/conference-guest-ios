import Foundation

public struct HomeMeeting: Identifiable, Equatable, Sendable {
    public let id: MeetingRoomIdentity
    public let invitation: URL
    public let calendar: CalendarMeeting?
    public let handoff: ActiveJam?
}

/// Room identity, time and connection freshness determine suggestions.
/// Calendar timing never implies that a room has live participants.
public enum HomeMeetingPolicy {
    public static let soonInterval: TimeInterval = 600
    public static let previewLimit = 2

    public static func candidates(meetings: [CalendarMeeting], handoffs: [ActiveJam], at now: Date) -> [HomeMeeting] {
        let scheduled = meetings.filter {
            $0.hasResolvedInvitation && !$0.allDay && $0.end > now &&
                $0.start <= now.addingTimeInterval(soonInterval)
        }.sorted {
            let left = abs($0.start.timeIntervalSince(now)), right = abs($1.start.timeIntervalSince(now))
            return left == right ? ($0.start, $0.id) < ($1.start, $1.id) : left < right
        }
        var byRoom: [MeetingRoomIdentity: CalendarMeeting] = [:]
        for meeting in scheduled {
            if let key = meeting.roomIdentity, byRoom[key] == nil { byRoom[key] = meeting }
        }
        let fresh = handoffs.filter { $0.isRecent(at: now) }.sorted {
            if ($0.audioPaused == true) != ($1.audioPaused == true) { return $0.audioPaused != true }
            if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
            return $0.deviceID < $1.deviceID
        }
        var result: [HomeMeeting] = []
        var seen: Set<MeetingRoomIdentity> = []
        for handoff in fresh {
            guard let key = MeetingRoomIdentity(handoff.invitation), seen.insert(key).inserted else { continue }
            result.append(HomeMeeting(id: key, invitation: handoff.invitation, calendar: byRoom[key], handoff: handoff))
        }
        for meeting in scheduled {
            guard let key = meeting.roomIdentity, let invitation = meeting.invitation,
                  seen.insert(key).inserted else { continue }
            result.append(HomeMeeting(id: key, invitation: invitation, calendar: meeting, handoff: nil))
        }
        return result
    }

    public static func today(meetings: [CalendarMeeting], at now: Date,
                             excluding: Set<String> = [], calendar: Calendar = .current) -> [CalendarMeeting] {
        meetings.filter {
            $0.hasResolvedInvitation && $0.end > now && !excluding.contains($0.id) &&
                (calendar.isDate($0.start, inSameDayAs: now) || $0.isScheduledNow(now))
        }.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}

/// Defer changes above the user's current position until interaction ends or
/// the user returns to the top. The underlying calendar remains authoritative.
public struct HomeMeetingSnapshot: Equatable, Sendable {
    public private(set) var items: [HomeMeeting] = []
    public init() {}
    public mutating func update(_ candidates: [HomeMeeting], allowChanges: Bool) {
        guard allowChanges else { return }
        items = Array(candidates.prefix(HomeMeetingPolicy.previewLimit))
    }
}
