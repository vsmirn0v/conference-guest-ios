import Foundation

public enum MeetingEngineEvidence: Equatable, Sendable {
    case guest(endpoint: URL)
    case community
    case telemost
}

public enum MeetingEngineDetection: Equatable, Sendable {
    case verified(MeetingEngineEvidence)
    case ambiguous
    case unknown
}

/// Read-only protocol discovery. Hostname and page text are never proof of an engine.
/// Responses are bounded, HTTPS redirects stay on the origin, and credentials/name
/// are never included in probes. Only positive, unambiguous evidence is cached.
public actor MeetingEngineDetector {
    private let serviceName: String
    private let session: URLSession
    private let timeout: TimeInterval
    private let lifetime: TimeInterval
    private let now: @Sendable () -> Date
    private struct Cached {
        let evidence: MeetingEngineDetection
        let expires: Date
    }
    private var cache: [URL: Cached] = [:]

    public init(serviceName: String, session: URLSession? = nil, timeout: TimeInterval = 3,
                cacheLifetime: TimeInterval = 300, now: @escaping @Sendable () -> Date = { Date() }) {
        self.serviceName = serviceName
        self.timeout = min(10, max(0.05, timeout))
        self.lifetime = max(0, cacheLifetime)
        self.now = now
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForResource = self.timeout
        self.session = session ?? URLSession(configuration: config)
    }

    public func detect(_ invitation: URL) async throws -> MeetingEngineDetection {
        try Task.checkCancellation()
        if (try? TelemostTarget.parse(invitation.absoluteString)) != nil { return .verified(.telemost) }
        let guest = try JoinTarget.parse(invitation.absoluteString)
        let community = try? JamTarget.parseCompatibleInvitation(invitation.absoluteString)
        // Community evidence is room-specific; guest-only results are origin-specific.
        let key = community?.invitationURL ?? guest.originURL
        if let cached = cache[key], cached.expires > now() { return cached.evidence }

        let session = self.session, timeout = self.timeout, serviceName = self.serviceName
        async let guestEvidence: MeetingEngineEvidence? = Self.probeGuest(guest, serviceName: serviceName,
                                                                          session: session, timeout: timeout)
        async let communityEvidence: MeetingEngineEvidence? = Self.probeCommunity(community,
                                                                    session: session, timeout: timeout)
        let proofs = await [guestEvidence, communityEvidence].compactMap { $0 }
        try Task.checkCancellation()
        let result: MeetingEngineDetection
        switch proofs.count {
        case 1: result = .verified(proofs[0])
        case 2: result = .ambiguous
        default: result = .unknown
        }
        if case .verified = result, lifetime > 0 {
            cache = cache.filter { $0.value.expires > now() }
            if cache.count >= 32, let oldest = cache.min(by: { $0.value.expires < $1.value.expires })?.key {
                cache.removeValue(forKey: oldest)
            }
            cache[key] = Cached(evidence: result, expires: now().addingTimeInterval(lifetime))
        }
        return result
    }

    public func invalidate(_ invitation: URL) {
        guard let target = try? JoinTarget.parse(invitation.absoluteString) else { return }
        cache.removeValue(forKey: target.originURL)
        cache.removeValue(forKey: invitation)
    }

    private static func probeGuest(_ target: JoinTarget, serviceName: String,
                                   session: URLSession, timeout: TimeInterval) async -> MeetingEngineEvidence? {
        var components = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)!
        components.path = "/.well-known/s2b-services.json"
        do {
            let (data, response) = try await load(components.url!, session: session,
                                                timeout: timeout, maximumBytes: 65_536)
            let endpoint = try ConferenceEndpointResolver.endpoint(in: data, response: response,
                                                       origin: target.originURL, serviceName: serviceName)
            return .guest(endpoint: endpoint)
        } catch { return nil }
    }

    private struct CommunityDescription: Decodable {
        let id: String
        let title: String
        let community: String
        let description: String
        let engine: String
        let joinProtocol: String
        enum CodingKeys: String, CodingKey {
            case id, title, community, description, engine
            case joinProtocol = "join_protocol"
        }
    }

    private static func probeCommunity(_ target: JamTarget?, session: URLSession,
                                       timeout: TimeInterval) async -> MeetingEngineEvidence? {
        guard let target else { return nil }
        var components = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)!
        components.path = "/api/jams/\(target.jamID)"
        do {
            let (data, response) = try await load(components.url!, session: session,
                                                timeout: timeout, maximumBytes: 16_384)
            guard response.statusCode == 200,
                  let metadata = try? JSONDecoder().decode(CommunityDescription.self, from: data),
                  metadata.id == target.jamID, metadata.engine == "livekit",
                  metadata.joinProtocol == "rocknroll-v1",
                  !metadata.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  metadata.title.utf8.count <= 1_024 else { return nil }
            return .community
        } catch { return nil }
    }

    private static func load(_ url: URL, session: URLSession, timeout: TimeInterval,
                             maximumBytes: Int) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return try await withThrowingTaskGroup(of: (Data, HTTPURLResponse).self) { group in
            group.addTask { try await BoundedHTTP.load(request, session: session, maximumBytes: maximumBytes) }
            group.addTask {
                try await Task.sleep(for: .seconds(timeout))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw CancellationError() }
            guard result.1.mimeType?.lowercased() == "application/json" else {
                throw EndpointDiscoveryError.invalidDiscovery
            }
            return result
        }
    }
}
