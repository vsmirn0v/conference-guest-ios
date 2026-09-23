import Foundation

/// Converts the saved website's native-app handoff into a complete HTTPS invitation.
/// The website origin is an app preference; service discovery still comes from that invitation.
enum GuestSiteLinkAdapter {
    static let scheme = "jcp"

    static func invitation(from url: URL, websiteOrigin: String) throws -> URL {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              link.scheme?.lowercased() == scheme,
              link.host?.lowercased() == "jazz",
              link.user == nil, link.password == nil,
              link.path.isEmpty || link.path == "/",
              link.fragment == nil,
              let code = singleValue("code", in: link),
              let password = singleValue("psw", in: link),
              let origin = URLComponents(string: websiteOrigin),
              origin.scheme?.lowercased() == "https",
              origin.host != nil, origin.user == nil, origin.password == nil,
              origin.port == nil, origin.path.isEmpty || origin.path == "/",
              origin.query == nil, origin.fragment == nil else {
            throw GuestSiteLinkError.invalidLink
        }
        var invitation = origin
        invitation.path = "/calls/\(code)"
        invitation.queryItems = [URLQueryItem(name: "psw", value: password)]
        guard let result = invitation.url else { throw GuestSiteLinkError.invalidLink }
        return result
    }

    private static func singleValue(_ key: String, in link: URLComponents) -> String? {
        let values = link.queryItems?.filter { $0.name == key }
        guard values?.count == 1, let value = values?.first?.value,
              (1...128).contains(value.count) else { return nil }
        return value
    }
}

enum GuestSiteLinkError: LocalizedError {
    case invalidLink
    var errorDescription: String? {
        "This app link needs a valid HTTPS meeting website in Settings."
    }
}
