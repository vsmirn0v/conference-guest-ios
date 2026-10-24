import Foundation

/// An HTTPS invitation; no account, cookies, or vendor runtime is required.
public struct GuestInvitation: Equatable, Sendable {
    public let invitationURL: URL
    public let origin: URL
    public let roomID: String
    public let password: String

    public init(url: URL) throws { self = try Self.parse(url) }

    private init(invitationURL: URL, origin: URL, roomID: String, password: String) {
        self.invitationURL = invitationURL; self.origin = origin
        self.roomID = roomID; self.password = password
    }

    public static func parse(_ text: String) throws -> GuestInvitation {
        try parse(URLString: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func parse(_ url: URL) throws -> GuestInvitation {
        try parse(URLString: url.absoluteString)
    }

    private static func parse(URLString text: String) throws -> GuestInvitation {
        guard text.utf8.count <= 4096,
              let parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url,
              let segment = parts.percentEncodedPath.split(separator: "/").last,
              let roomID = String(segment).removingPercentEncoding,
              !roomID.isEmpty, roomID != ".", roomID != "..",
              !roomID.contains("/"), !roomID.contains("\\"),
              !roomID.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw GuestBootstrapError.invalidInvitation }
        let passwords = (parts.queryItems ?? []).filter { $0.name == "psw" }
        guard passwords.count <= 1,
              passwords.isEmpty || passwords[0].value != nil
        else { throw GuestBootstrapError.invalidInvitation }
        var origin = URLComponents()
        origin.scheme = "https"
        origin.host = host.lowercased()
        origin.port = parts.port
        guard let originURL = origin.url else { throw GuestBootstrapError.invalidInvitation }
        let password = try decodeInvitationPassword(passwords.first?.value ?? "")
        return GuestInvitation(invitationURL: url, origin: originURL,
                               roomID: roomID, password: password)
    }

    /// JazzSDK arm64 SHA256 023ad74a3a6cf7cc6ac6fa9b6f675cce13b9a9f29e854bc1ba41082c717d1193:
    /// JazzServices.PasswordCoderImpl.decode at 0x7c216c; constructor at
    /// 0x7c299c builds SDSoup.R.devices + "-prefix". The URL psw is unpadded
    /// Base64 containing one ASCII decimal length byte followed by XOR bytes.
    /// This is the invitation wire format, not the API's decoded password.
    private static func decodeInvitationPassword(_ encoded: String) throws -> String {
        if encoded.isEmpty { return "" }
        let padding = String(repeating: "=", count: (4 - encoded.utf8.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded + padding),
              let first = data.first, (48...57).contains(first) else {
            throw GuestBootstrapError.invalidInvitation
        }
        let length = Int(first - 48)
        let mask = Array("sberdevices-prefix".utf8)
        guard data.count >= length + 1, length <= mask.count else {
            throw GuestBootstrapError.invalidInvitation
        }
        let bytes = Array(data.dropFirst().prefix(length))
        let scalars = bytes.enumerated().map { UnicodeScalar($0.element ^ mask[$0.offset]) }
        return String(String.UnicodeScalarView(scalars))
    }
}

public enum GuestBootstrapError: Error, LocalizedError {
    case invalidInvitation, invalidServiceDiscovery, invalidPreconnect, unsupportedLegacyRoom
    case httpStatus(Int)

    public var errorDescription: String? {
        switch self {
        case .invalidInvitation: return "Invalid HTTPS guest invitation."
        case .invalidServiceDiscovery: return "Service discovery did not return an HTTPS server URL."
        case .invalidPreconnect: return "Preconnect returned an invalid connector URL."
        case .unsupportedLegacyRoom: return "This room does not provide native WebSocket signaling."
        case .httpStatus(let status): return "Guest bootstrap HTTP status \(status)."
        }
    }
}

public struct GuestPreparedRoom {
    public let invitation: GuestInvitation
    public let serverURL: URL
    public let connectorURL: URL
    public let roomID: String
    public let password: String
    public let joinPayload: [String: Any]
    public let roomTitle: String?
    public let roomType: String?
}

public typealias GuestPrepared = GuestPreparedRoom

/// Protocol source: official web SDK createServiceLocatorController,
/// getRoomPreconnect, createConnectionService and createRoom (web-readable.js).
public struct GuestBootstrap {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            self.session = URLSession(configuration: configuration)
        }
    }

    public static func prepare(_ invitation: GuestInvitation, participantName: String,
                               supportedFeatures: [String: Any] = [:]) async throws -> GuestPrepared {
        try await GuestBootstrap().prepare(invitation, participantName: participantName,
                                           supportedFeatures: supportedFeatures)
    }

    /// Official SDK create contract: CreateMeetingRequest plus withAnonymousCreateRoom.
    /// The caller explicitly opts into creating a separate disposable meeting.
    public static func createDisposable(origin: URL) async throws -> GuestInvitation {
        let bootstrap = GuestBootstrap()
        let server = try await bootstrap.discoverServer(origin: origin)
        let result = try await bootstrap.json(url: server.appendingPathComponent("room/create-meeting"), body: [
            "title": "Rock native guest prototype disposable", "roomType": "ANONYMOUS",
            "guestEnabled": true, "lobbyEnabled": false
        ], headers: ["X-Jazz-Token": ""])
        guard let rawURL = result["url"] as? String,
              let roomID = result["roomId"] as? String,
              let password = result["password"] as? String else { throw GuestBootstrapError.invalidPreconnect }
        let invitation = try GuestInvitation.parse(rawURL)
        guard invitation.roomID == roomID, invitation.password == password else {
            throw GuestBootstrapError.invalidPreconnect
        }
        return invitation
    }

    /// Advertise only features the native implementation actually implements.
    /// No join is performed; the returned payload is sent by the caller.
    public func prepare(_ invitation: GuestInvitation, participantName: String,
                        supportedFeatures: [String: Any] = [:],
                        sessionID: String? = nil, jazzToken: String? = nil) async throws -> GuestPreparedRoom {
        let serverURL = try await discoverServer(origin: invitation.origin)
        let endpoint = serverURL.appendingPathComponent("room")
            .appendingPathComponent(invitation.roomID).appendingPathComponent("preconnect")
        // Observed SDK defaults; these select the signaling protocol, not user permissions.
        let migration: [String: Any] = [
            "b2bBaseRoomSupport": true, "demoRoomBaseSupport": true,
            "demoRoomVersionSupport": 2, "mediaWithoutAutoSubscribeSupport": true,
            "webinarSpeakerSupport": false, "webinarViewerSupport": false,
            "sdkRoomSupport": true, "sberclassRoomSupport": false
        ]
        let response = try await json(url: endpoint, body: [
            "password": invitation.password, "jazzNextMigration": migration
        ])
        guard let rawConnector = response["connectorUrl"] as? String, !rawConnector.isEmpty else {
            throw GuestBootstrapError.unsupportedLegacyRoom
        }
        guard let connector = URLComponents(string: rawConnector),
              connector.scheme?.lowercased() == "wss", connector.host?.isEmpty == false,
              connector.user == nil, connector.password == nil, connector.fragment == nil,
              let connectorURL = connector.url else { throw GuestBootstrapError.invalidPreconnect }
        var join: [String: Any] = [
            "password": invitation.password, "participantName": participantName,
            "supportedFeatures": supportedFeatures, "isSilent": false
        ]
        if let sessionID { join["sessionId"] = sessionID }
        if let jazzToken { join["jazzToken"] = jazzToken }
        return GuestPreparedRoom(invitation: invitation, serverURL: serverURL,
                                 connectorURL: connectorURL, roomID: invitation.roomID,
                                 password: invitation.password, joinPayload: join,
                                 roomTitle: response["roomTitle"] as? String,
                                 roomType: response["roomType"] as? String)
    }

    public func discoverServer(origin: URL) async throws -> URL {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", parts.host?.isEmpty == false,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/" else { throw GuestBootstrapError.invalidServiceDiscovery }
        var services: [String: Any]
        do {
            services = try await json(url: origin.appendingPathComponent(".well-known/jazz-services.json"))
        } catch {
            try Task.checkCancellation()
            services = try await json(url: origin.appendingPathComponent(".well-known/s2b-services.json"))
        }
        guard let jazz = services["jazz"] as? [String: Any],
              let raw = jazz["serverUrl"] as? String,
              let parts = URLComponents(string: raw), parts.scheme?.lowercased() == "https",
              parts.host?.isEmpty == false, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, let server = parts.url else {
            throw GuestBootstrapError.invalidServiceDiscovery
        }
        return server
    }

    private func json(url: URL, body: [String: Any]? = nil,
                      headers: [String: String] = [:]) async throws -> [String: Any] {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GuestBootstrapError.invalidPreconnect }
        guard (200..<300).contains(http.statusCode) else { throw GuestBootstrapError.httpStatus(http.statusCode) }
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GuestBootstrapError.invalidPreconnect
        }
        return object
    }
}
