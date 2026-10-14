import Foundation

public struct HomeMeeting: Identifiable, Equatable, Sendable {
    public let id: MeetingRoomIdentity
    public let invitation: URL
    public let calendar: CalendarMeeting?
    public let handoff: ActiveJam?
    public func currentCalendar(in meetings: [CalendarMeeting]) -> CalendarMeeting? {
        calendar.flatMap { original in meetings.first { $0.id == original.id && $0.roomIdentity == id } }
    }
    public func currentHandoff(in handoffs: [ActiveJam], at now: Date) -> ActiveJam? {
        handoff.flatMap { original in handoffs.first {
            $0.deviceID == original.deviceID && $0.sessionID == original.sessionID &&
            $0.isRecent(at: now) && MeetingRoomIdentity($0.invitation) == id
        } }
    }
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

/// Keep suggestions in place for the visible home session. Late discoveries
/// are applied explicitly, so an approaching tap cannot land on another room.
public struct HomeMeetingSnapshot: Equatable, Sendable {
    public private(set) var items: [HomeMeeting] = []
    public private(set) var pending: [HomeMeeting] = []
    private struct Key: Equatable {
        let room: MeetingRoomIdentity; let calendar: CalendarMeeting?; let device: String?; let session: UUID?
        let title: String?; let deviceLabel: String?; let sharing: Bool?; let companion: Bool?
        init(_ item: HomeMeeting) {
            room = item.id; calendar = item.calendar; device = item.handoff?.deviceID; session = item.handoff?.sessionID
            title = item.handoff?.title; deviceLabel = item.handoff?.deviceLabel
            sharing = item.handoff?.isSharingScreen; companion = item.handoff?.supportsCompanion
        }
    }
    public var hasUpdates: Bool { pending.map(Key.init) != items.map(Key.init) }
    public init() {}
    public mutating func update(_ candidates: [HomeMeeting], allowChanges: Bool) {
        pending = Array(candidates.prefix(HomeMeetingPolicy.previewLimit))
        if allowChanges { acceptUpdates() }
    }
    public mutating func acceptUpdates() { items = pending }
}
