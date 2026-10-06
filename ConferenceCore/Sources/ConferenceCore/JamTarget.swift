import Foundation

public struct JamTarget: Equatable, Sendable {
    public let invitationURL: URL
    public let originURL: URL
    public let jamID: String

    public static func parse(_ text: String) throws -> JamTarget {
        let target = try parseCompatibleInvitation(text)
        guard target.originURL.host?.lowercased() == "rock.glowsoft.ru", target.jamID == "test",
              target.originURL.port == nil else { throw JamTargetError.invalidLink }
        return target
    }

    /// A syntactic candidate only. Use on another origin after verifying its API contract.
    public static func parseCompatibleInvitation(_ text: String) throws -> JamTarget {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              let invitationURL = components.url else {
            throw JamTargetError.invalidLink
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2, path[0] == "jams", components.path == "/jams/\(path[1])",
              path[1].utf8.count <= 128,
              path[1].utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || $0 == 45 || $0 == 95 }) else {
            throw JamTargetError.invalidLink
        }
        var origin = URLComponents()
        origin.scheme = components.scheme
        origin.host = components.host
        origin.port = components.port
        guard let originURL = origin.url else { throw JamTargetError.invalidLink }
        return JamTarget(invitationURL: invitationURL,
                         originURL: originURL,
                         jamID: String(path[1]))
    }
}

public enum JamTargetError: LocalizedError {
    case invalidLink
    public var errorDescription: String? { CoreL("Enter a valid Rock’n’Roll jam link.") }
}
