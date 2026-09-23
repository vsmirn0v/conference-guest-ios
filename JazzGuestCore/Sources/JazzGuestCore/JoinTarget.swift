import Foundation

public struct MeetingRoom: Equatable, Sendable {
    public let code: String
    public let password: String

    public init(code: String, password: String) throws {
        let normalizedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(normalizedCode.count),
              (1...128).contains(normalizedPassword.count) else {
            throw JoinTargetError.invalidRoom
        }
        self.code = normalizedCode
        self.password = normalizedPassword
    }
}

public enum JoinTarget: Equatable, Sendable {
    case room(MeetingRoom)
    case jazzInvite(URL)

    public func webGuestURL() throws -> URL {
        switch self {
        case .jazzInvite(let url):
            return url
        case .room(let room):
            guard room.code.unicodeScalars.allSatisfy({
                CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0)
            }) else {
                throw JoinTargetError.invalidRoom
            }
            var components = URLComponents()
            components.scheme = "https"
            components.host = "salutejazz.ru"
            components.path = "/calls/\(room.code)"
            components.queryItems = [URLQueryItem(name: "psw", value: room.password)]
            guard let url = components.url else { throw JoinTargetError.invalidRoom }
            return url
        }
    }

    public static func parse(_ text: String, joinLinkHost: String? = nil) throws -> JoinTarget {
        let candidate = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty, candidate.utf8.count <= 4096,
              let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased() else {
            throw JoinTargetError.invalidLink
        }

        if scheme == "jazzguest" {
            guard components.host?.lowercased() == "join",
                  components.user == nil, components.password == nil,
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw JoinTargetError.invalidLink
            }
            return try parseJazzURL(nested)
        }

        if let joinLinkHost,
           scheme == "https", components.host?.lowercased() == joinLinkHost.lowercased() {
            guard components.user == nil, components.password == nil,
                  components.port == nil, components.path == "/join",
                  components.queryItems?.filter({ $0.name == "url" }).count == 1,
                  let nested = components.queryItems?.first(where: { $0.name == "url" })?.value else {
                throw JoinTargetError.invalidLink
            }
            return try parseJazzURL(nested)
        }

        return try parseJazzURL(candidate)
    }

    private static func parseJazzURL(_ text: String) throws -> JoinTarget {
        guard text.utf8.count <= 4096,
              let components = URLComponents(string: text),
              components.scheme?.lowercased() == "https",
              let host = components.host?.lowercased(),
              ["salutejazz.ru", "jazz.sber.ru"].contains(host),
              components.user == nil, components.password == nil,
              components.port == nil,
              let url = components.url else {
            throw JoinTargetError.invalidLink
        }
        return .jazzInvite(url)
    }
}

public enum JoinTargetError: LocalizedError, Equatable {
    case invalidRoom
    case invalidLink

    public var errorDescription: String? {
        switch self {
        case .invalidRoom: return "Enter a meeting code and password."
        case .invalidLink: return "Enter a valid SaluteJazz meeting link."
        }
    }
}
