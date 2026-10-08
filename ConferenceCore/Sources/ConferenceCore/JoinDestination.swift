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
