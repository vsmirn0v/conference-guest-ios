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
            $0.isRecent(at: now) && MeetingRoomIdentity($0.invitation, engine: $0.engine) == id
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
            if $0.isScheduledNow(now) != $1.isScheduledNow(now) { return $0.isScheduledNow(now) }
            return ($0.start, $0.id) < ($1.start, $1.id)
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
            guard let key = MeetingRoomIdentity(handoff.invitation, engine: handoff.engine), seen.insert(key).inserted else { continue }
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

    /// Expansion hides only later events; concurrent and soon-starting rooms
    /// remain discoverable even when both promoted slots are occupied.
    public static func todayPreview(_ meetings: [CalendarMeeting], at now: Date, expanded: Bool) -> [CalendarMeeting] {
        guard !expanded else { return meetings }
        let boundary = now.addingTimeInterval(soonInterval)
        return meetings.filter { $0.start <= boundary } + meetings.filter { $0.start > boundary }.prefix(2)
    }
}

/// Presentation state is frozen with the rows it controls. Live permission is
/// still revalidated by each action, so revocation never enables a stale join.
public struct HomeCalendarState: Equatable, Sendable {
    public let enabled: Bool
    public let available: Bool
    public let hasSelection: Bool
    public let loading: Bool
    public let error: String?
    public init(enabled: Bool = false, available: Bool = false, hasSelection: Bool = false,
                loading: Bool = false, error: String? = nil) {
        self.enabled = enabled; self.available = available; self.hasSelection = hasSelection
        self.loading = loading; self.error = error
    }
}

/// Apply discoveries automatically when safe. During interaction, update only
/// existing same-room metadata; insertion/removal/reordering waits for release.
public struct HomeMeetingSnapshot: Equatable, Sendable {
    public private(set) var items: [HomeMeeting] = []
    public private(set) var pending: [HomeMeeting] = []
    public private(set) var calendarItems: [CalendarMeeting] = []
    public private(set) var calendarState = HomeCalendarState()
    private var pendingCalendarItems: [CalendarMeeting] = []
    private var pendingCalendarState = HomeCalendarState()
    private struct Key: Equatable {
        let room: MeetingRoomIdentity; let calendar: CalendarMeeting?; let device: String?; let session: UUID?
        let title: String?; let deviceLabel: String?; let sharing: Bool?; let companion: Bool?
        init(_ item: HomeMeeting) {
            room = item.id; calendar = item.calendar; device = item.handoff?.deviceID; session = item.handoff?.sessionID
            title = item.handoff?.title; deviceLabel = item.handoff?.deviceLabel
            sharing = item.handoff?.isSharingScreen; companion = item.handoff?.supportsCompanion
        }
    }
    public var hasUpdates: Bool {
        pending.map(Key.init) != items.map(Key.init) || pendingCalendarItems != calendarItems || pendingCalendarState != calendarState
    }
    public init() {}
    public mutating func update(_ candidates: [HomeMeeting], calendarMeetings: [CalendarMeeting] = [],
                                calendarState: HomeCalendarState = .init(), allowChanges: Bool) {
        pending = Array(candidates.prefix(HomeMeetingPolicy.previewLimit))
        pendingCalendarItems = calendarMeetings
        pendingCalendarState = calendarState
        if allowChanges { acceptUpdates(); return }
        items = items.map { original in
            pending.first { updated in
                updated.id == original.id && updated.calendar?.id == original.calendar?.id &&
                    updated.handoff?.deviceID == original.handoff?.deviceID &&
                    updated.handoff?.sessionID == original.handoff?.sessionID
            } ?? original
        }
        calendarItems = calendarItems.map { original in
            calendarMeetings.first {
                $0.id == original.id && $0.roomIdentity == original.roomIdentity &&
                    $0.start == original.start && $0.end == original.end && $0.allDay == original.allDay
            } ?? original
        }
    }
    public mutating func acceptUpdates() {
        items = pending; calendarItems = pendingCalendarItems; calendarState = pendingCalendarState
    }
}
