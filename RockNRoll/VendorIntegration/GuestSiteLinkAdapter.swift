import ConferenceCore
import Foundation

/// Converts a native-app handoff into an HTTPS invitation without guessing its website.
enum GuestSiteLinkAdapter {
    static func handles(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "jcp" || scheme == "jazz"
    }

    static func invitation(from url: URL, websiteOrigin: String,
                           recentInvitations: [URL] = [], selectedWebsite: String? = nil) throws -> URL {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = link.scheme?.lowercased(),
              let linkType = link.host?.lowercased(),
              link.user == nil, link.password == nil,
              link.path.isEmpty || link.path == "/",
              link.fragment == nil else { throw GuestSiteLinkError.invalidLink }

        if link.queryItems?.contains(where: { $0.name == "url" }) == true {
            guard let embedded = singleValue("url", in: link) else {
                throw GuestSiteLinkError.invalidLink
            }
            guard let target = try? JoinTarget.parse(embedded) else {
                throw GuestSiteLinkError.invalidLink
            }
            return target.invitationURL
        }

        let keys: (room: String, password: String)
        switch (scheme, linkType) {
        case ("jcp", "jazz"), ("jazz", "jazz"):
            keys = ("code", "psw")
        case ("jazz", "join"):
            keys = ("id", "password")
        default:
            throw GuestSiteLinkError.invalidLink
        }
        guard let rawCode = singleValue(keys.room, in: link),
              let password = singleValue(keys.password, in: link) else {
            throw GuestSiteLinkError.invalidLink
        }
        let parts = rawCode.split(separator: "@", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count),
              let first = parts.first, !first.isEmpty,
              !first.contains("/"), !first.contains("?") else {
            throw GuestSiteLinkError.invalidLink
        }
        let code = String(first)
        let qualifiedOrigin = parts.count == 2 ? try origin(String(parts[1])) : nil
        if link.queryItems?.contains(where: { $0.name == "host" }) == true,
           singleValue("host", in: link) == nil {
            throw GuestSiteLinkError.invalidLink
        }
        let hostOrigin = try singleValue("host", in: link).map(origin)
        if let qualifiedOrigin, let hostOrigin, qualifiedOrigin != hostOrigin {
            throw GuestSiteLinkError.conflictingHosts
        }
        if let explicit = hostOrigin ?? qualifiedOrigin {
            return try makeInvitation(code: code, password: password, origin: explicit)
        }

        let matches = recentInvitations.compactMap(guestTarget)
            .filter { $0.roomID == code && $0.password == password }
        // Keep the original path for sites whose invitation is not /calls/{id}.
        if let selectedWebsite {
            let selected = try origin(selectedWebsite)
            if let match = matches.first(where: { $0.originURL == selected }) {
                return match.invitationURL
            }
            return try makeInvitation(code: code, password: password, origin: selected)
        }
        let origins = Array(Set(matches.map(\.originURL)))
            .sorted { $0.absoluteString < $1.absoluteString }
        if origins.count > 1 { throw GuestSiteLinkError.ambiguousWebsites(origins) }
        if let match = matches.first { return match.invitationURL }

        guard let savedOrigin = try? origin(websiteOrigin) else {
            throw GuestSiteLinkError.websiteNeeded
        }
        return try makeInvitation(code: code, password: password, origin: savedOrigin)
    }

    static func rememberedOrigins(from invitations: [URL]) -> [URL] {
        Array(Set(invitations.compactMap { guestTarget($0)?.originURL }))
            .sorted { $0.absoluteString < $1.absoluteString }
    }

    private static func guestTarget(_ invitation: URL) -> JoinTarget? {
        guard case .guest(let target) = try? JoinDestination.parse(invitation.absoluteString) else {
            return nil
        }
        return target
    }

    private static func makeInvitation(code: String, password: String, origin: URL) throws -> URL {
        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.path = "/calls/\(code)"
        components.queryItems = [URLQueryItem(name: "psw", value: password)]
        guard let result = components.url else { throw GuestSiteLinkError.invalidLink }
        return result
    }

    private static func origin(_ value: String) throws -> URL {
        let candidate = value.hasPrefix("https://") ? value : "https://\(value)"
        guard !value.isEmpty, !value.contains("@"),
              let components = URLComponents(string: candidate),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port == nil,
              components.path.isEmpty || components.path == "/",
              components.query == nil, components.fragment == nil else {
            throw GuestSiteLinkError.invalidLink
        }
        var result = URLComponents()
        result.scheme = "https"
        result.host = host.lowercased()
        guard let url = result.url else { throw GuestSiteLinkError.invalidLink }
        return url
    }

    private static func singleValue(_ key: String, in link: URLComponents) -> String? {
        let values = link.queryItems?.filter { $0.name == key }
        guard values?.count == 1, let value = values?.first?.value,
              (1...4096).contains(value.utf8.count) else { return nil }
        return value
    }
}

enum GuestSiteLinkError: LocalizedError, Equatable {
    case invalidLink, conflictingHosts, websiteNeeded
    case ambiguousWebsites([URL])

    var requiresWebsite: Bool {
        switch self {
        case .websiteNeeded, .ambiguousWebsites: true
        default: false
        }
    }

    var candidateOrigins: [URL]? {
        if case .ambiguousWebsites(let origins) = self { return origins }
        return nil
    }

    var errorDescription: String? {
        switch self {
        case .invalidLink: L("This meeting app link is incomplete or invalid.")
        case .conflictingHosts: L("This meeting link names two different websites.")
        case .websiteNeeded: L("Choose the meeting website to open this link.")
        case .ambiguousWebsites: L("This room is saved on more than one website. Choose where to join.")
        }
    }
}
