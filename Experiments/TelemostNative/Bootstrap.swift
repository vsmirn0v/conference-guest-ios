import Foundation

enum ProbeError: Error {
    case invalidInvitation, response(Int), unsupportedConnection(String), invalidPayload
    case transportLost, signalingRejected(String), mediaNotConnected, expectedMediaMissing
}

struct TelemostConnection {
    let roomID: String
    let peerID: String
    let credentials: String
    let server: URL
    let service: String
    let ice: [[String: Any]]

    static func fetch(invitation: URL, name: String) async throws -> TelemostConnection {
        let request = try request(invitation: invitation, name: name)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ProbeError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try decode(data)
    }

    static func request(invitation: URL, name: String) throws -> URLRequest {
        guard invitation.scheme == "https", ["telemost.yandex.ru", "telemost.360.yandex.ru"].contains(invitation.host),
              invitation.pathComponents.count == 3, invitation.pathComponents[1] == "j",
              !invitation.pathComponents[2].isEmpty, invitation.port == nil,
              invitation.user == nil, invitation.password == nil else {
            throw ProbeError.invalidInvitation
        }
        let encoded = invitation.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        var url = URLComponents(string: "https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences/\(encoded)/connection")!
        url.queryItems = [URLQueryItem(name: "next_gen_media_platform_allowed", value: "true"),
                         URLQueryItem(name: "display_name", value: name),
                         URLQueryItem(name: "waiting_room_supported", value: "true"),
                         URLQueryItem(name: "breakoutRoomsSupported", value: "true")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://telemost.yandex.ru", forHTTPHeaderField: "Origin")
        request.setValue(invitation.absoluteString, forHTTPHeaderField: "Referer")
        request.setValue("RockNRoll-NativeExperiment/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("212.6.0", forHTTPHeaderField: "X-Telemost-Client-Version")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "Client-Instance-Id")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "idempotency-key")
        return request
    }

    static func decode(_ data: Data) throws -> TelemostConnection {
        guard data.count < 256_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["connection_type"] as? String else { throw ProbeError.invalidPayload }
        guard type == "CONFERENCE" else { throw ProbeError.unsupportedConnection(type) }
        guard object["media_platform"] as? String == "GOLOOM",
              let roomID = object["room_id"] as? String, let peerID = object["peer_id"] as? String,
              let credentials = object["credentials"] as? String,
              let client = object["client_configuration"] as? [String: Any],
              let serverString = client["media_server_url"] as? String, let server = URL(string: serverString),
              server.scheme == "wss", server.host?.hasSuffix(".yandex.net") == true,
              server.user == nil, server.password == nil,
              let service = client["service_name"] as? String else { throw ProbeError.invalidPayload }
        return .init(roomID: roomID, peerID: peerID, credentials: credentials, server: server,
                     service: service, ice: client["ice_servers"] as? [[String: Any]] ?? [])
    }
}

func probeLog(_ event: String, _ fields: [String: Any] = [:]) {
    let object = fields.merging(["event": event, "time": ISO8601DateFormatter().string(from: Date())]) { _, new in new }
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
