import Foundation

/// A complete invitation carries both the meeting credentials and the origin
/// from which this deployment publishes service discovery.
public struct JoinTarget: Equatable, Sendable {
    public let invitationURL: URL
    public let originURL: URL
    public let roomID: String
    public let password: String

    public static func parse(_ text: String, joinLinkHost: String? = nil) throws -> JoinTarget {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 4096,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased() else {
            throw JoinTargetError.invalidLink
        }

        if scheme == "conferenceguest" {
            guard components.host?.lowercased() == "join",
                  components.user == nil, components.password == nil,
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw JoinTargetError.invalidLink
            }
            return try parseInvitation(nested)
        }

        if let joinLinkHost,
           scheme == "https", components.host?.lowercased() == joinLinkHost.lowercased() {
            guard components.user == nil, components.password == nil,
                  components.port == nil, components.path == "/join",
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw JoinTargetError.invalidLink
            }
            return try parseInvitation(nested)
        }

        return try parseInvitation(candidate)
    }

    private static func parseInvitation(_ text: String) throws -> JoinTarget {
        guard text.utf8.count <= 4096,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              let invitationURL = components.url else {
            throw JoinTargetError.invalidLink
        }
        let path = components.path.split(separator: "/", omittingEmptySubsequences: true)
        guard path.count == 2, path[0] == "calls",
              (1...128).contains(path[1].count),
              path[1].unicodeScalars.allSatisfy({
                  CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
              }),
              let passwords = components.queryItems?.filter({ $0.name == "psw" }),
              passwords.count == 1,
              let password = passwords.first?.value,
              (1...128).contains(password.count) else {
            throw JoinTargetError.invalidLink
        }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host
        origin.port = components.port
        guard let originURL = origin.url else { throw JoinTargetError.invalidLink }
        return JoinTarget(
            invitationURL: invitationURL,
            originURL: originURL,
            roomID: String(path[1]),
            password: password
        )
    }
}

public enum JoinTargetError: LocalizedError, Equatable {
    case invalidLink

    public var errorDescription: String? {
        "Enter a complete HTTPS meeting invitation link."
    }
}
