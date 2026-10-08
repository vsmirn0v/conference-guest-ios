import Foundation

public enum MeetingEngineKind: String, Codable, Sendable { case guest, community, telemost }

public extension MeetingEngineKind {
    /// Older clients must still decode the shared history/cloud schema. Formal
    /// Telemost invitations identify their engine without a persisted hint.
    var persistenceHint: Self? { self == .telemost ? nil : self }
}

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
        self.engine = engine ?? ((try? JoinDestination.parse(url.absoluteString))?.engineKind ?? .guest)
    }
}

/// Structured fields outrank links buried in descriptions or titles.
public struct CalendarLinkGroup: Equatable, Sendable {
    public enum Source: Int, Sendable { case eventURL, location, notes, title }
    public let source: Source
    public let links: [URL]
    public init(source: Source, links: [URL]) { self.source = source; self.links = links }
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
    public let linkGroups: [CalendarLinkGroup]
    public var links: [URL] { linkGroups.flatMap(\.links) }
    public var invitation: URL?
    public var engine: MeetingEngineKind?
    public var requiresChoice: Bool = false

    public init(id: String, seriesID: String, calendarID: String, calendarTitle: String,
                title: String, start: Date, end: Date, allDay: Bool = false, tentative: Bool = false,
                links: [URL] = [], linkGroups: [CalendarLinkGroup]? = nil) {
        self.id = id; self.seriesID = seriesID; self.calendarID = calendarID; self.calendarTitle = calendarTitle
        self.title = title; self.start = start; self.end = end; self.allDay = allDay; self.tentative = tentative
        self.linkGroups = (linkGroups ?? [.init(source: .notes, links: links)])
            .sorted { $0.source.rawValue < $1.source.rawValue }
    }

    public func isScheduledNow(_ now: Date) -> Bool { start <= now && end > now }
    public func isTimely(_ now: Date) -> Bool { !allDay && end > now && start <= now.addingTimeInterval(15 * 60) }
    public var roomIdentity: MeetingRoomIdentity? { invitation.flatMap { MeetingRoomIdentity($0, engine: engine) } }
    public var hasResolvedInvitation: Bool { invitation != nil && engine != nil && !requiresChoice }
}

public enum CalendarAutoJoinPolicy {
    public static func candidate(in meetings: [CalendarMeeting], at now: Date,
                                 suppressed: Set<String> = []) -> CalendarMeeting? {
        // An overlapping event with no working link still makes intent ambiguous.
        let overlapping = meetings.filter { !$0.allDay && !$0.tentative && $0.end > now &&
            $0.start <= now.addingTimeInterval(120) }
        guard overlapping.count == 1, let meeting = overlapping.first,
              meeting.start >= now.addingTimeInterval(-600), meeting.hasResolvedInvitation,
              !suppressed.contains(meeting.id) else { return nil }
        return meeting
    }
}

public enum CalendarLinkDiscovery {
    /// Formal URLs only; event-title words never identify a room.
    public static func links(url: URL?, location: String?, notes: String?,
                             knownOrigins: Set<String>, hintedHostFragments: [String],
                             aliases: [String: URL] = [:], title: String? = nil,
                             nativeSchemes: Set<String> = []) -> [URL] {
        groups(url: url, location: location, notes: notes, knownOrigins: knownOrigins,
               hintedHostFragments: hintedHostFragments, aliases: aliases, title: title,
               nativeSchemes: nativeSchemes).flatMap(\.links)
    }

    public static func groups(url: URL?, location: String?, notes: String?,
                              knownOrigins: Set<String>, hintedHostFragments: [String],
                              aliases: [String: URL] = [:], title: String? = nil,
                              nativeSchemes: Set<String> = []) -> [CalendarLinkGroup] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        func extract(_ field: String?) -> [URL] {
            guard let field else { return [] }
            let text = String(field.prefix(32_768))
            return (detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []).compactMap(\.url)
        }
        let fields: [(CalendarLinkGroup.Source, [URL])] = [
            (.eventURL, url.map { [$0] } ?? []), (.location, extract(location)),
            (.notes, extract(notes)), (.title, extract(title))]
        var seen: Set<URL> = []
        var resolved: Set<URL> = []
        func accept(_ candidate: URL) -> URL? {
            guard seen.insert(candidate).inserted else { return nil }
            if (try? TelemostTarget.parse(candidate.absoluteString)) != nil { return candidate }
            if let scheme = candidate.scheme?.lowercased(), nativeSchemes.contains(scheme) { return candidate }
            if let host = candidate.host?.lowercased(), let bound = aliases[host],
               candidate.path.isEmpty || candidate.path == "/", candidate.query == nil { return bound }
            if candidate == url { return candidate.scheme?.lowercased() == "https" ? candidate : nil }
            guard let target = try? JoinTarget.parse(candidate.absoluteString), let host = target.originURL.host?.lowercased() else { return nil }
            return knownOrigins.contains(target.originURL.absoluteString.lowercased()) ||
                hintedHostFragments.contains(where: { host.contains($0.lowercased()) }) ? candidate : nil
        }
        var result: [CalendarLinkGroup] = []
        for (source, candidates) in fields {
            let links = Array(candidates.compactMap(accept).filter { resolved.insert($0).inserted }
                .prefix(max(0, 8 - result.reduce(0) { $0 + $1.links.count })))
            if !links.isEmpty { result.append(.init(source: source, links: links)) }
        }
        return result
    }
}
