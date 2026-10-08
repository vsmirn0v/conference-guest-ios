import Foundation

/// Provider invitation grammar, independent of account state or room admission.
public struct TelemostTarget: Equatable, Sendable {
    public static let hosts: Set<String> = ["telemost.yandex.ru", "telemost.360.yandex.ru"]
    public let invitationURL: URL
    public let roomID: String
    public static func parse(_ text: String) throws -> TelemostTarget {
        guard let url = URL(string: text), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), hosts.contains(host),
              url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.count == 3, url.pathComponents[1] == "j",
              !url.pathComponents[2].isEmpty else { throw JoinDestinationError.invalidLink }
        return .init(invitationURL: url, roomID: url.pathComponents[2])
    }
}
