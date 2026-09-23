import Foundation

public struct JamTarget: Equatable, Sendable {
    public let invitationURL: URL
    public let originURL: URL
    public let jamID: String

    public static func parse(_ text: String) throws -> JamTarget {
        guard let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "rock.glowsoft.ru",
              components.user == nil, components.password == nil,
              components.port == nil, components.query == nil, components.fragment == nil,
              let invitationURL = components.url else {
            throw JamTargetError.invalidLink
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2, path[0] == "jams", path[1] == "test" else {
            throw JamTargetError.invalidLink
        }
        var origin = URLComponents()
        origin.scheme = components.scheme
        origin.host = components.host
        guard let originURL = origin.url else { throw JamTargetError.invalidLink }
        return JamTarget(invitationURL: invitationURL,
                         originURL: originURL,
                         jamID: String(path[1]))
    }
}

public enum JamTargetError: LocalizedError {
    case invalidLink
    public var errorDescription: String? { "Enter a valid Rock’n’Roll jam link." }
}
