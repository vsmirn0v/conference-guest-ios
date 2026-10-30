import Foundation

enum GuestICEPolicyError: Error { case noTCPRelay, noUDPRelay }

/// Diagnostic transport selection; no endpoint invention, rewriting or OS changes.
enum GuestICEPolicy: String {
    case automatic = "auto"
    case tcpRelay = "tcp-relay"
    case udpRelay = "udp-relay"
    case udpReceive = "udp-receive"
    case udpPublish = "udp-publish"

    func forTarget(_ target: GuestPeerTarget) -> GuestICEPolicy {
        switch self {
        case .udpReceive: return target == .subscriber ? .udpRelay : .tcpRelay
        case .udpPublish: return target == .publisher ? .udpRelay : .tcpRelay
        default: return self
        }
    }

    func servers(_ advertised: [[String: Any]]) throws -> [[String: Any]] {
        guard self != .automatic else { return advertised }
        let selected = advertised.compactMap { server -> [String: Any]? in
            let urls = server["urls"] as? [String] ?? (server["urls"] as? String).map { [$0] } ?? []
            let eligible = urls.filter { Self.isExplicitRelay($0, transport: self == .tcpRelay ? "tcp" : "udp") }
            guard !eligible.isEmpty else { return nil }
            var copy = server; copy["urls"] = eligible
            return copy
        }
        guard !selected.isEmpty else { throw self == .tcpRelay ? GuestICEPolicyError.noTCPRelay : GuestICEPolicyError.noUDPRelay }
        return selected
    }

    /// TURN is an opaque URI (RFC 7065). This deliberately supports only explicit
    /// transport=tcp endpoints; native WebRTC still validates host/port/address.
    static func isExplicitTCPRelay(_ text: String) -> Bool {
        isExplicitRelay(text, transport: "tcp")
    }

    static func isExplicitRelay(_ text: String, transport: String) -> Bool {
        guard transport == "tcp" || transport == "udp" else { return false }
        guard !text.contains(where: { $0.isWhitespace }), let colon = text.firstIndex(of: ":") else { return false }
        let scheme = text[..<colon].lowercased()
        guard scheme == "turn" || (scheme == "turns" && transport == "tcp") else { return false }
        let rest = text[text.index(after: colon)...].split(separator: "?", omittingEmptySubsequences: false)
        guard rest.count == 2, rest[1] == "transport=\(transport)", !rest[0].isEmpty,
              !rest[0].contains(where: { "/@#".contains($0) }) else { return false }
        return true
    }
#if DEBUG
    /// Diagnostic metadata only. Never return raw URLs, userinfo or credentials.
    static func diagnosticTurnServer(_ text: String) -> [String: Any]? {
        guard let transport = ["tcp", "udp"].first(where: { isExplicitRelay(text, transport: $0) }),
              let colon = text.firstIndex(of: ":") else { return nil }
        let scheme = text[..<colon].lowercased()
        let authority = text[text.index(after: colon)...].split(separator: "?", maxSplits: 1,
            omittingEmptySubsequences: false)[0]
        guard !authority.contains("%"), !authority.hasSuffix(":"),
              let components = URLComponents(string: "\(scheme)://\(authority)"),
              components.user == nil, components.password == nil, components.path.isEmpty,
              components.query == nil, components.fragment == nil,
              let parsedHost = components.host, !parsedHost.isEmpty else { return nil }
        let host = parsedHost.hasPrefix("[") && parsedHost.hasSuffix("]") ? String(parsedHost.dropFirst().dropLast()) : parsedHost
        guard !host.contains("@"), components.port.map({ (1...65_535).contains($0) }) ?? true else { return nil }
        return ["scheme": scheme, "host": host.lowercased(), "port": components.port.map { $0 as Any } ?? NSNull(),
                "transport": transport]
    }
#endif
}
