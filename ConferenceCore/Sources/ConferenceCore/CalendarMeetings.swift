import Foundation

public enum MeetingEngineKind: String, Codable, Sendable { case guest, community }

/// Stable room matching independent of invitation passwords and guest path variants.
/// Existing history/cloud record IDs stay intact; matching never deletes records.
public struct MeetingRoomIdentity: Hashable, Codable, Sendable {
    public let origin: String
    public let room: String
    public let engine: MeetingEngineKind
    public init?(_ url: URL, engine: MeetingEngineKind? = nil) {
        guard let target = try? JoinTarget.parse(url.absoluteString) else { return nil }
        var origin = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)!
        origin.host = origin.host?.lowercased()
        if origin.port == 443 { origin.port = nil }
        self.origin = origin.string!
        self.room = target.roomID
        self.engine = engine ?? ((try? JamTarget.parseCompatibleInvitation(url.absoluteString)) != nil ? .community : .guest)
    }
}

public struct CalendarMeeting: Identifiable, Equatable, Sendable {
    public let id: String
    public let seriesID: String
    public let calendarID: String
    public let calendarTitle: String
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let tentative: Bool
    public let links: [URL]
    public var invitation: URL?
    public var engine: MeetingEngineKind?
    public var requiresChoice: Bool = false

    public init(id: String, seriesID: String, calendarID: String, calendarTitle: String,
                title: String, start: Date, end: Date, allDay: Bool = false, tentative: Bool = false,
                links: [URL] = []) {
        self.id = id; self.seriesID = seriesID; self.calendarID = calendarID; self.calendarTitle = calendarTitle
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.tentative = tentative
        self.links = links
    }

    public func isScheduledNow(_ now: Date) -> Bool { start <= now && end > now }
    public func isTimely(_ now: Date) -> Bool { !allDay && end > now && start <= now.addingTimeInterval(15 * 60) }
    public var roomIdentity: MeetingRoomIdentity? { invitation.flatMap { MeetingRoomIdentity($0, engine: engine) } }
}

public enum CalendarAutoJoinPolicy {
    public static func candidate(in meetings: [CalendarMeeting], at now: Date,
                                 suppressed: Set<String> = []) -> CalendarMeeting? {
        // An overlapping event with no working link still makes intent ambiguous.
        let overlapping = meetings.filter { !$0.allDay && !$0.tentative && $0.end > now &&
            $0.start <= now.addingTimeInterval(120) }
        guard overlapping.count == 1, let meeting = overlapping.first,
              meeting.start >= now.addingTimeInterval(-600), meeting.invitation != nil,
              meeting.engine != nil, !meeting.requiresChoice, !suppressed.contains(meeting.id) else { return nil }
        return meeting
    }
}

public enum CalendarLinkDiscovery {
    /// Formal URLs only; event-title words never identify a room.
    public static func links(url: URL?, location: String?, notes: String?,
                             knownOrigins: Set<String>, hintedHostFragments: [String],
                             aliases: [String: URL] = [:], title: String? = nil,
                             nativeSchemes: Set<String> = []) -> [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var candidates = url.map { [$0] } ?? []
        for field in [location, notes, title].compactMap({ $0 }) {
            let text = String(field.prefix(32_768))
            for match in detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? [] {
                if let link = match.url { candidates.append(link) }
            }
        }
        var seen: Set<URL> = []
        var resolved: Set<URL> = []
        return candidates.compactMap { candidate -> URL? in
            guard seen.insert(candidate).inserted else { return nil }
            if let scheme = candidate.scheme?.lowercased(), nativeSchemes.contains(scheme) { return candidate }
            if let host = candidate.host?.lowercased(), let bound = aliases[host],
               candidate.path.isEmpty || candidate.path == "/", candidate.query == nil { return bound }
            if candidate == url { return candidate.scheme?.lowercased() == "https" ? candidate : nil }
            guard let target = try? JoinTarget.parse(candidate.absoluteString), let host = target.originURL.host?.lowercased() else { return nil }
            return knownOrigins.contains(target.originURL.absoluteString.lowercased()) ||
                hintedHostFragments.contains(where: { host.contains($0.lowercased()) }) ? candidate : nil
        }.filter { resolved.insert($0).inserted }.prefix(8).map { $0 }
    }
}
