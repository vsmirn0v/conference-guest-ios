import Foundation
import CryptoKit

enum ProbeError: Error {
    case invalidPayload, invalidInvitation, response(Int), noWebClient
    case mediaNotConnected, rejected(Int), transportLost
}

struct ServerConnection {
    let room: String
    let login: String
    let credential: String
    let socket: URL

    static func fetch(_ invitation: URL, name: String) async throws -> ServerConnection {
        let path = invitation.pathComponents.filter { $0 != "/" }
        guard invitation.scheme == "https", invitation.host != nil,
              invitation.user == nil, invitation.password == nil,
              path.count == 2, path[0] == "c", !path[1].isEmpty else {
            throw ProbeError.invalidInvitation
        }
        var endpoint = URLComponents(url: invitation, resolvingAgainstBaseURL: false)!
        endpoint.path = "/api/v4/software/clients"
        endpoint.fragment = nil
        endpoint.queryItems = [
            .init(name: "lang", value: "en"), .init(name: "call_id", value: path[1]),
            .init(name: "case", value: "join_conference_button"), .init(name: "user", value: "$" + name)
        ]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(from: endpoint.url!)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw ProbeError.response((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard data.count < 1_048_576,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clients = root["clients"] as? [[String: Any]],
              let web = clients.first(where: { $0["type"] as? String == "web" && $0["platform"] as? String == "webrtc" }),
              let text = web["web_url"] as? String,
              let url = URLComponents(string: text), url.scheme == "https", url.host == invitation.host,
              let fragment = url.percentEncodedFragment,
              let fields = URLComponents(string: "https://localhost/?" + fragment)?.queryItems else {
            throw ProbeError.noWebClient
        }
        guard let login = fields.first(where: { $0.name == "login" })?.value,
              let credential = fields.first(where: { $0.name == "token" })?.value,
              !login.isEmpty, !credential.isEmpty else { throw ProbeError.invalidPayload }
        endpoint.scheme = "wss"
        endpoint.path = "/websocket/"
        endpoint.query = nil
        return ServerConnection(room: path[1], login: login, credential: credential, socket: endpoint.url!)
    }
}

// Current bridge protocol encrypts session-scoped TURN passwords. This is the
// same derivation performed by the public browser client, using our own CID.
func decodeIceServers(_ values: [[String: Any]], cid: String, stream: String) throws -> [[String: Any]] {
    try values.map { value in
        guard let address = value["address"] as? String,
              let port = value["port"] as? Int,
              let service = value["serviceType"] as? Int,
              let transport = value["transport"] as? Int,
              [0, 1].contains(service), [0, 1].contains(transport) else { throw ProbeError.invalidPayload }
        let host = address.contains(":") ? "[\(address)]" : address
        let url = "\(service == 0 ? "stun" : "turn"):\(host):\(port)" + (transport == 1 ? "?transport=tcp" : "")
        var result: [String: Any] = ["urls": [url]]
        if service == 1 {
            guard let hex = value["credential"] as? String, hex.count >= 32, hex.count.isMultiple(of: 2),
                  let username = value["userName"] as? String else { throw ProbeError.invalidPayload }
            var encrypted = Data()
            var index = hex.startIndex
            while index < hex.endIndex {
                let next = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<next], radix: 16) else { throw ProbeError.invalidPayload }
                encrypted.append(byte)
                index = next
            }
            let key = HKDF<SHA256>.deriveKey(
                inputKeyMaterial: SymmetricKey(data: Data(cid.utf8)),
                salt: Data(stream.utf8), info: Data("app=bridge;module=conference;dir=s2c;".utf8),
                outputByteCount: 32
            )
            let sealed = try AES.GCM.SealedBox(
                nonce: AES.GCM.Nonce(data: Data(cid.utf8).prefix(12)),
                ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16)
            )
            let plaintext = try AES.GCM.open(sealed, using: key)
            guard let credential = String(data: plaintext, encoding: .utf8), !credential.isEmpty else { throw ProbeError.invalidPayload }
            result["username"] = username
            result["credential"] = credential
        }
        return result
    }
}

func probeLog(_ event: String, _ fields: [String: Any] = [:]) {
    let result = fields.merging(["event": event, "time": ISO8601DateFormatter().string(from: Date())]) { _, new in new }
    if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) { print(text); fflush(stdout) }
}
