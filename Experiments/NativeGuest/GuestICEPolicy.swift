import Foundation

enum GuestICEPolicyError: Error { case noTCPRelay, noUDPRelay }

/// Diagnostic transport selection; no endpoint invention, rewriting or OS changes.
enum GuestICEPolicy: String {
    case automatic = "auto"
    case tcpRelay = "tcp-relay"
    case udpRelay = "udp-relay"
    case udpReceive = "udp-receive"
    case udpPublish = "udp-publish"
    /// Recovery after the receive path stalled: only the subscriber goes through the
    /// server's TURN relay (UDP, else TCP); without an advertised relay it stays automatic.
    case subscriberRelay = "subscriber-relay"

    func forTarget(_ target: GuestPeerTarget) -> GuestICEPolicy {
        switch self {
        case .udpReceive: return target == .subscriber ? .udpRelay : .tcpRelay
        case .udpPublish: return target == .publisher ? .udpRelay : .tcpRelay
        case .subscriberRelay: return target == .subscriber ? .subscriberRelay : .automatic
        default: return self
        }
    }

    /// Whether candidates are limited to relays for these advertised servers.
    func relayOnly(_ advertised: [[String: Any]]) -> Bool {
        switch self {
        case .automatic: return false
        case .subscriberRelay: return !Self.relays(advertised, transport: "udp").isEmpty || !Self.relays(advertised, transport: "tcp").isEmpty
        default: return true
        }
    }

    private static func relays(_ advertised: [[String: Any]], transport: String) -> [[String: Any]] {
        advertised.compactMap { server -> [String: Any]? in
            let urls = server["urls"] as? [String] ?? (server["urls"] as? String).map { [$0] } ?? []
            let eligible = urls.filter { isExplicitRelay($0, transport: transport) }
            guard !eligible.isEmpty else { return nil }
            var copy = server; copy["urls"] = eligible
            return copy
        }
    }

    /// Counts of advertised server kinds for diagnostics (no hosts, ports or credentials).
    static func serverKinds(_ advertised: [[String: Any]]) -> [String: Int] {
        var kinds: [String: Int] = [:]
        for server in advertised {
            let urls = server["urls"] as? [String] ?? (server["urls"] as? String).map { [$0] } ?? []
            for url in urls {
                let kind: String
                if isExplicitRelay(url, transport: "udp") { kind = "turn-udp" }
                else if isExplicitRelay(url, transport: "tcp") { kind = url.lowercased().hasPrefix("turns:") ? "turns-tcp" : "turn-tcp" }
                else if url.lowercased().hasPrefix("turn") { kind = "turn-unspecified" }
                else if url.lowercased().hasPrefix("stun") { kind = "stun" }
                else { kind = "other" }
                kinds[kind, default: 0] += 1
            }
        }
        return kinds
    }

    func servers(_ advertised: [[String: Any]]) throws -> [[String: Any]] {
        guard self != .automatic else { return advertised }
        if self == .subscriberRelay {
            let udp = Self.relays(advertised, transport: "udp")
            if !udp.isEmpty { return udp }
            let tcp = Self.relays(advertised, transport: "tcp")
            return tcp.isEmpty ? advertised : tcp
        }
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
