import CryptoKit
import Foundation

public struct JoinableMeetingCandidate: Identifiable, Equatable, Sendable {
    public enum Source: String, Codable, Equatable, Sendable {
        case ongoingCalendar
        case upcomingCalendar
        case handoff
        case favoriteRoom
        case recentRoom
    }

    public var id: UUID
    public var title: String
    public var invitation: URL
    public var source: Source
    public var start: Date?
    public var end: Date?
    public var activeSessionID: UUID?

    public init(
        id: UUID,
        title: String,
        invitation: URL,
        source: Source,
        start: Date? = nil,
        end: Date? = nil,
        activeSessionID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.invitation = invitation
        self.source = source
        self.start = start
        self.end = end
        self.activeSessionID = activeSessionID
    }
}

public enum CurrentMeetingTargetResolver {
    public static func stableID(namespace: String, key: String) -> UUID {
        var hasher = SHA256()
        hasher.update(data: Data(namespace.utf8))
        hasher.update(data: Data([0]))
        hasher.update(data: Data(key.utf8))
        let digest = Array(hasher.finalize())
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    public static func rankedCandidates(
        now: Date,
        calendarMeetings: [CalendarMeeting],
        handoffs: [ActiveJam] = [],
        rooms: [RecentRoom] = [],
        activeRooms: [String: UUID] = [:],
        calendar: Calendar = .current
    ) -> [JoinableMeetingCandidate] {
        var seenKeys = Set<String>()
        var result: [JoinableMeetingCandidate] = []

        func roomKey(for url: URL, engine: MeetingEngineKind? = nil) -> String {
            MeetingRoomIdentity(url, engine: engine)?.workspaceKey ?? url.absoluteString.lowercased()
        }

        // 1. Ongoing calendar meetings (started <= now, ends > now)
        let ongoing = calendarMeetings
            .filter { !$0.allDay && !$0.tentative && $0.invitation != nil && $0.start <= now && $0.end > now }
            .sorted { $0.start > $1.start }

        for meeting in ongoing {
            guard let url = meeting.invitation else { continue }
            let rKey = roomKey(for: url, engine: meeting.engine)
            guard seenKeys.insert(rKey).inserted else { continue }
            result.append(JoinableMeetingCandidate(
                id: stableID(namespace: "calendar", key: meeting.id),
                title: meeting.title,
                invitation: url,
                source: .ongoingCalendar,
                start: meeting.start,
                end: meeting.end,
                activeSessionID: activeRooms[rKey]
            ))
        }

        // 2. Imminent upcoming calendar meetings (starting within 45 min)
        let upcomingSoonCutoff = now.addingTimeInterval(45 * 60)
        let upcomingSoon = calendarMeetings
            .filter { !$0.allDay && !$0.tentative && $0.invitation != nil && $0.start > now && $0.start <= upcomingSoonCutoff }
            .sorted { $0.start < $1.start }

        for meeting in upcomingSoon {
            guard let url = meeting.invitation else { continue }
            let rKey = roomKey(for: url, engine: meeting.engine)
            guard seenKeys.insert(rKey).inserted else { continue }
            result.append(JoinableMeetingCandidate(
                id: stableID(namespace: "calendar", key: meeting.id),
                title: meeting.title,
                invitation: url,
                source: .upcomingCalendar,
                start: meeting.start,
                end: meeting.end,
                activeSessionID: activeRooms[rKey]
            ))
        }

        // 3. Handoff / ActiveJams from other devices
        for jam in handoffs where jam.isVisible(at: now) {
            let rKey = roomKey(for: jam.invitation, engine: jam.engine)
            guard seenKeys.insert(rKey).inserted else { continue }
            result.append(JoinableMeetingCandidate(
                id: jam.sessionID,
                title: jam.title,
                invitation: jam.invitation,
                source: .handoff,
                start: jam.updatedAt,
                end: nil,
                activeSessionID: activeRooms[rKey]
            ))
        }

        // 4. Later same-day calendar meetings
        let laterToday = calendarMeetings
            .filter {
                !$0.allDay && !$0.tentative && $0.invitation != nil &&
                $0.start > upcomingSoonCutoff && calendar.isDate($0.start, inSameDayAs: now)
            }
            .sorted { $0.start < $1.start }

        for meeting in laterToday {
            guard let url = meeting.invitation else { continue }
            let rKey = roomKey(for: url, engine: meeting.engine)
            guard seenKeys.insert(rKey).inserted else { continue }
            result.append(JoinableMeetingCandidate(
                id: stableID(namespace: "calendar", key: meeting.id),
                title: meeting.title,
                invitation: url,
                source: .upcomingCalendar,
                start: meeting.start,
                end: meeting.end,
                activeSessionID: activeRooms[rKey]
            ))
        }

        // 5. Starred & recent rooms
        let sortedRooms = rooms.sorted { lhs, rhs in
            if lhs.isStarred != rhs.isStarred { return lhs.isStarred }
            return lhs.lastJoined > rhs.lastJoined
        }
        for room in sortedRooms.prefix(12) {
            let rKey = roomKey(for: room.joinURL, engine: room.engine)
            guard seenKeys.insert(rKey).inserted else { continue }
            result.append(JoinableMeetingCandidate(
                id: stableID(namespace: "room", key: rKey),
                title: room.displayTitle,
                invitation: room.joinURL,
                source: room.isStarred ? .favoriteRoom : .recentRoom,
                start: nil,
                end: nil,
                activeSessionID: activeRooms[rKey]
            ))
        }

        return result
    }

    public static func bestCurrentMeeting(
        from candidates: [JoinableMeetingCandidate],
        now: Date
    ) -> JoinableMeetingCandidate? {
        if let ongoing = candidates.first(where: { $0.source == .ongoingCalendar }) {
            return ongoing
        }
        if let imminent = candidates.first(where: { candidate in
            guard candidate.source == .upcomingCalendar, let start = candidate.start else { return false }
            let delta = start.timeIntervalSince(now)
            return delta >= 0 && delta <= 45 * 60
        }) {
            return imminent
        }
        if let handoff = candidates.first(where: { $0.source == .handoff }) {
            return handoff
        }
        return candidates.first
    }
}
