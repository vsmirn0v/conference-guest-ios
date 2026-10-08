import Foundation

/// Server invitations have a formal path; engine identity still requires a
/// structured capability response. Any HTTPS origin can host this server.
public struct TrueConfTarget: Equatable, Sendable {
    public let invitationURL: URL
    public let originURL: URL
    public let roomID: String
    public static func parse(_ text: String) throws -> Self {
        let target = try JoinTarget.parse(text)
        let parts = target.invitationURL.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, parts[0] == "c", !parts[1].isEmpty,
              parts[1].utf8.count <= 256, !parts[1].contains("/"),
              !parts[1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw JoinDestinationError.invalidLink
        }
        return .init(invitationURL: target.invitationURL, originURL: target.originURL, roomID: parts[1])
    }
    public var descriptionURL: URL {
        var url = URLComponents(url: originURL, resolvingAgainstBaseURL: false)!
        url.path = "/api/v4/conferences/" + roomID
        url.queryItems = [.init(name: "url_type", value: "fixed")]
        return url.url!
    }
    public func supportsBrowser(in data: Data) -> Bool {
        struct Envelope: Decodable {
            struct Conference: Decodable { let id: String; let web_client_url: String; let allow_guests: Bool }
            let conference: Conference
        }
        guard let value = try? JSONDecoder().decode(Envelope.self, from: data),
              value.conference.id == roomID, value.conference.allow_guests,
              let browser = URL(string: value.conference.web_client_url, relativeTo: originURL)?.absoluteURL,
              browser.scheme?.lowercased() == "https", browser.host?.lowercased() == originURL.host?.lowercased(),
              (browser.port ?? 443) == (originURL.port ?? 443), browser.user == nil, browser.password == nil,
              browser.path == "/webrtc/" + roomID else { return false }
        return true
    }
}
