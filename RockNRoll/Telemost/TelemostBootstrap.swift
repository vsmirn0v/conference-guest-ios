import ConferenceCore
import Foundation

enum TelemostError: LocalizedError {
    case invalidResponse, requestFailed(Int), admissionRequired, incompatibleProtocol, disconnected, timedOut, rejected(String), removed, ended, cameraUnavailable
    var isRetryable: Bool {
        switch self {
        case .disconnected, .timedOut: true
        case .requestFailed(let code): code == 408 || code == 429 || code >= 500
        default: false
        }
    }
    static func socketFailure(code: Int, underlying: Error) -> Error {
        switch code {
        case 4004: TelemostError.removed
        case 4009: TelemostError.ended
        case 4000, 4002, 4003, 4005: TelemostError.rejected(String(code))
        default: underlying
        }
    }
    var errorDescription: String? {
        switch self {
        case .admissionRequired: L("This meeting requires host admission or signing in on its website.")
        case .requestFailed(let code): L("The meeting service could not connect (%ld).", code)
        case .incompatibleProtocol: L("This meeting uses a connection protocol this app does not support yet.")
        case .timedOut: L("The meeting connection timed out. Check your network and try again.")
        case .rejected: L("The meeting service declined this connection.")
        case .removed: L("The host removed you from this meeting.")
        case .ended: L("This meeting has ended.")
        case .cameraUnavailable: L("The camera is unavailable. Audio can continue.")
        case .invalidResponse, .disconnected: L("Could not connect to the meeting. Check the invitation and your network.")
        }
    }
}

struct TelemostBootstrap {
    let roomID: String
    let participantID: String
    let credentials: String
    let serverURL: URL
    let serviceName: String
    let iceServers: [[String: Any]]
    static func load(_ target: TelemostTarget, name: String, session: URLSession) async throws -> Self {
        let invitation = target.invitationURL.absoluteString.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        var components = URLComponents(string: "https://cloud-api.yandex.ru/telemost_front/v2/telemost/conferences/\(invitation)/connection")!
        components.queryItems = [URLQueryItem(name: "next_gen_media_platform_allowed", value: "true"),
            URLQueryItem(name: "display_name", value: name), URLQueryItem(name: "waiting_room_supported", value: "false"),
            URLQueryItem(name: "breakoutRoomsSupported", value: "false")]
        var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        for (key, value) in ["Accept": "application/json", "Content-Type": "application/json", "Origin": "https://telemost.yandex.ru",
            "Referer": target.invitationURL.absoluteString, "X-Telemost-Client-Version": "212.6.0",
            "Client-Instance-Id": UUID().uuidString, "idempotency-key": UUID().uuidString] { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await BoundedHTTP.load(request, session: session, maximumBytes: 256_000)
        guard response.statusCode == 200 else { throw TelemostError.requestFailed(response.statusCode) }
        return try decode(data)
    }
    static func decode(_ data: Data) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TelemostError.invalidResponse }
        guard object["connection_type"] as? String == "CONFERENCE" else { throw TelemostError.admissionRequired }
        guard object["media_platform"] as? String == "GOLOOM" else { throw TelemostError.incompatibleProtocol }
        guard let room = object["room_id"] as? String, !room.isEmpty,
            let peer = object["peer_id"] as? String, !peer.isEmpty,
            let credentials = object["credentials"] as? String, !credentials.isEmpty,
            let config = object["client_configuration"] as? [String: Any],
            let endpoint = config["media_server_url"] as? String, let url = URL(string: endpoint),
            url.scheme == "wss", url.host?.hasSuffix(".yandex.net") == true, url.user == nil, url.password == nil,
            let service = config["service_name"] as? String, !service.isEmpty else { throw TelemostError.invalidResponse }
        return .init(roomID: room, participantID: peer, credentials: credentials, serverURL: url,
                     serviceName: service, iceServers: config["ice_servers"] as? [[String: Any]] ?? [])
    }
}
