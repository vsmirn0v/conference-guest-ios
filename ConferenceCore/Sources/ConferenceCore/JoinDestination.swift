import Foundation

public enum JoinDestination: Equatable, Sendable {
    case jam(JamTarget)
    case guest(JoinTarget)
    case telemost(TelemostTarget)
    case trueconf(TrueConfTarget)

    public var invitationURL: URL {
        switch self {
        case .jam(let target): target.invitationURL
        case .guest(let target): target.invitationURL
        case .telemost(let target): target.invitationURL
        case .trueconf(let target): target.invitationURL
        }
    }

    public static func parse(_ text: String, joinLinkHost: String? = nil) throws -> JoinDestination {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 4_096,
              let components = URLComponents(string: candidate) else {
            throw JoinDestinationError.invalidLink
        }
        if components.scheme?.lowercased() == "conferenceguest" {
            guard components.host?.lowercased() == "join",
                  components.user == nil, components.password == nil,
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw JoinDestinationError.invalidLink
            }
            return try parse(nested, joinLinkHost: joinLinkHost)
        }
        if let joinLinkHost,
           components.scheme?.lowercased() == "https",
           components.host?.lowercased() == joinLinkHost.lowercased(),
           components.path == "/join" {
            guard components.user == nil, components.password == nil,
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw JoinDestinationError.invalidLink
            }
            return try parse(nested, joinLinkHost: nil)
        }
        if let host = components.host?.lowercased(), TelemostTarget.hosts.contains(host) {
            return .telemost(try TelemostTarget.parse(candidate))
        }
        if components.host?.lowercased() == "rock.glowsoft.ru" {
            return .jam(try JamTarget.parse(candidate))
        }
        return .guest(try JoinTarget.parse(candidate, joinLinkHost: joinLinkHost))
    }

    /// Use only engine evidence already verified by discovery or a prior join.
    /// The provider's formal invitation parser still validates the destination.
    public static func verified(_ invitation: URL, engine: MeetingEngineKind) throws -> JoinDestination {
        switch engine {
        case .guest: return .guest(try JoinTarget.parse(invitation.absoluteString))
        case .community: return .jam(try JamTarget.parseCompatibleInvitation(invitation.absoluteString))
        case .telemost: return .telemost(try TelemostTarget.parse(invitation.absoluteString))
        case .trueconf: return .trueconf(try TrueConfTarget.parse(invitation.absoluteString))
        }
    }

    /// Fresh positive evidence wins. Missing evidence can reuse a verified kind;
    /// ambiguous evidence without a known kind requires an explicit choice (nil).
    public static func resolve(_ invitation: URL, detection: MeetingEngineDetection,
                               knownEngine: MeetingEngineKind?) throws -> JoinDestination? {
        switch detection {
        case .verified(.guest): return try verified(invitation, engine: .guest)
        case .verified(.community): return try verified(invitation, engine: .community)
        case .verified(.telemost): return try verified(invitation, engine: .telemost)
        case .verified(.trueconf): return try verified(invitation, engine: .trueconf)
        case .ambiguous:
            return try knownEngine.map { try verified(invitation, engine: $0) }
        case .unknown:
            return try knownEngine.map { try verified(invitation, engine: $0) } ?? parse(invitation.absoluteString)
        }
    }

    public static func guestInvitations(in rooms: [RecentRoom]) -> [URL] {
        rooms.filter { ($0.engine == nil || $0.engine == .guest) &&
            (try? TelemostTarget.parse($0.joinURL.absoluteString)) == nil }.map(\.joinURL)
    }
}

public extension JoinDestination {
    var engineKind: MeetingEngineKind {
        switch self { case .jam: .community; case .guest: .guest; case .telemost: .telemost; case .trueconf: .trueconf }
    }
    var roomIdentifier: String {
        switch self { case .jam(let target): target.jamID; case .guest(let target): target.roomID; case .telemost(let target): target.roomID; case .trueconf(let target): target.roomID }
    }
}

public enum JoinDestinationError: LocalizedError {
    case invalidLink
    public var errorDescription: String? { CoreL("Enter a complete jam invitation link.") }
}
