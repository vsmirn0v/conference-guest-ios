import Foundation

enum GuestICEPolicyError: LocalizedError {
    case noTCPRelay, noUDPRelay

    var errorDescription: String? {
        switch self {
        case .noTCPRelay: return "This meeting did not provide a TCP/TLS relay."
        case .noUDPRelay: return "This meeting did not provide a UDP relay."
        }
    }
}

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

/// One automatic switch per peer for the lifetime of a meeting. Unverified
/// attempts fall back to the regular recovery path on the next engine rebuild.
struct GuestRelayRecovery {
    private var tried: Set<GuestPeerTarget> = []
    private var next: Set<GuestPeerTarget> = []
    private(set) var verifying: Set<GuestPeerTarget> = []
    private(set) var confirmed: Set<GuestPeerTarget> = []

    mutating func schedule(_ target: GuestPeerTarget) -> Bool {
        guard tried.insert(target).inserted else { return false }
        next.insert(target)
        return true
    }

    mutating func beginAttempt() -> Set<GuestPeerTarget> {
        verifying = next
        next.removeAll()
        return confirmed.union(verifying)
    }

    mutating func verify(_ target: GuestPeerTarget) -> Bool {
        guard verifying.remove(target) != nil else { return false }
        confirmed.insert(target)
        return true
    }
}

struct GuestRelayVerificationError: GuestRecoverableError, LocalizedError {
    var errorDescription: String? { "The TCP/TLS relay could not carry meeting media." }
}

/// A sample from a single peer's RTCStatisticsReport. Candidate `protocol`
/// describes the relayed path to the SFU and can be UDP even for TURN/TLS.
struct GuestICETransportSample {
    enum Route: String { case udp, tcp, tls, other }
    enum MediaKind: String { case audio, video }
    struct Stream {
        let kind: MediaKind
        let track: String
        let progress: Double
        let loss: Double?
        let feedbackTime: Double?
        let fractionLost: Double?
    }
    let route: Route
    let reportedTracks: Set<String>
    private let target: GuestPeerTarget
    private let sampledAt: Double
    private let nativeTime: Double
    private let transportID: String
    private let pairID: String
    private let localCandidateID: String
    private let remoteCandidateID: String
    private let requests: Double?
    private let responses: Double?
    private let streams: [String: Stream]

    init?(_ rows: [[String: Any]], target: GuestPeerTarget, demandedTracks: Set<String>) {
        let transports = rows.filter { $0["type"] as? String == "transport" && $0["selectedCandidatePairId"] != nil }
        guard transports.count == 1, let transport = transports.first,
              transport["dtlsState"] as? String == "connected",
              let sampledAt = Self.count(transport["sampleUptime"]),
              let nativeTime = Self.count(transport["nativeTimestampUS"]),
              let transportID = transport["id"] as? String,
              let pairID = transport["selectedCandidatePairId"] as? String,
              let pair = rows.first(where: { $0["id"] as? String == pairID && $0["type"] as? String == "candidate-pair" }),
              pair["state"] as? String == "succeeded",
              let localCandidateID = pair["localCandidateId"] as? String,
              let remoteCandidateID = pair["remoteCandidateId"] as? String,
              let local = rows.first(where: { $0["id"] as? String == localCandidateID && $0["type"] as? String == "local-candidate" }) else { return nil }
        self.target = target; self.sampledAt = sampledAt; self.nativeTime = nativeTime
        self.transportID = transportID; self.pairID = pairID
        self.localCandidateID = localCandidateID; self.remoteCandidateID = remoteCandidateID
        self.requests = Self.count(pair["requestsSent"])
        self.responses = Self.count(pair["responsesReceived"])
        let relay = local["candidateType"] as? String == "relay"
        let proto = local[relay ? "relayProtocol" : "protocol"] as? String
        switch (relay, proto) {
        case (_, "udp"): route = .udp
        case (true, "tcp"): route = .tcp
        case (true, "tls"): route = .tls
        default: route = .other
        }
        let outbound = target == .publisher
        let sources = rows.filter { $0["type"] as? String == "media-source" }
        var streams: [String: Stream] = [:]
        var reportedTracks: Set<String> = []
        for row in rows where row["type"] as? String == (outbound ? "outbound-rtp" : "inbound-rtp") {
            guard row["transportId"] as? String == transportID,
                  let id = row["id"] as? String, let kind = (row["kind"] as? String).flatMap(MediaKind.init(rawValue:)) else { continue }
            let track: String?
            if outbound, let sourceID = row["mediaSourceId"] as? String {
                track = sources.first { $0["id"] as? String == sourceID }?["trackIdentifier"] as? String
            } else {
                track = row["trackIdentifier"] as? String
            }
            guard let track, demandedTracks.contains(track) else { continue }
            let counter = kind == .video ? (outbound ? "framesSent" : "framesDecoded") : (outbound ? "packetsSent" : "packetsReceived")
            guard let progress = Self.count(row[counter]) else { continue }
            let feedback = outbound ? rows.first {
                $0["type"] as? String == "remote-inbound-rtp" && $0["localId"] as? String == id &&
                    $0["transportId"] as? String == transportID && $0["kind"] as? String == kind.rawValue
            } : nil
            reportedTracks.insert(track)
            streams[id] = Stream(kind: kind, track: track, progress: progress,
                                 loss: Self.count(outbound ? feedback?["packetsLost"] : row["packetsLost"]),
                                 feedbackTime: Self.count(feedback?["nativeTimestampUS"]),
                                 fractionLost: Self.count(feedback?["fractionLost"]))
        }
        self.streams = streams; self.reportedTracks = reportedTracks
    }

    var isTCPRelay: Bool { route == .tcp || route == .tls }

    struct MediaDelta {
        var progressing: Set<MediaKind> = []
        var progressingVideoTracks: Set<String> = []
        var stalledStreams: Set<String> = []

        func confirmsMedia(_ kinds: Set<MediaKind>, videoTracks: Set<String>) -> Bool {
            kinds.isSubset(of: progressing) && videoTracks.isSubset(of: progressingVideoTracks)
        }
    }

    func samePath(as previous: Self) -> Bool {
        target == previous.target && transportID == previous.transportID && pairID == previous.pairID &&
            localCandidateID == previous.localCandidateID && remoteCandidateID == previous.remoteCandidateID &&
            route == previous.route
    }

    func mediaDelta(since previous: Self) -> MediaDelta {
        var delta = MediaDelta()
        guard samePath(as: previous), sampledAt > previous.sampledAt, sampledAt - previous.sampledAt <= 6,
              nativeTime > previous.nativeTime, !streams.isEmpty,
              Set(streams.keys) == Set(previous.streams.keys) else { return delta }
        let missedProbes = Self.increased(requests, since: previous.requests) && responses != nil && responses == previous.responses
        for (id, current) in streams {
            guard let old = previous.streams[id], current.kind == old.kind, current.track == old.track else { continue }
            let freshFeedback = current.feedbackTime.map {
                $0 > (old.feedbackTime ?? 0) && $0 <= nativeTime && nativeTime - $0 <= 6_000_000
            } == true
            let severeLoss = freshFeedback && (current.fractionLost ?? 0) >= 0.95
            if current.progress > old.progress,
               target == .subscriber || (freshFeedback && current.fractionLost.map { $0 < 0.95 } == true) {
                delta.progressing.insert(current.kind)
                if current.kind == .video { delta.progressingVideoTracks.insert(current.track) }
            }
            // Outbound RTP counters alone measure local sends. Only a fresh
            // receiver report on that stream can show downstream packet loss.
            if old.progress > 0, current.progress >= old.progress,
               severeLoss || (current.progress == old.progress &&
                    (missedProbes || (target == .subscriber && Self.increased(current.loss, since: old.loss)))) {
                delta.stalledStreams.insert(id)
            }
        }
        return delta
    }

    private static func increased(_ current: Double?, since previous: Double?) -> Bool {
        guard let current, let previous else { return false }
        return current > previous
    }

    private static func count(_ value: Any?) -> Double? {
        guard let number = (value as? NSNumber)?.doubleValue, number.isFinite, number >= 0 else { return nil }
        return number
    }
}
