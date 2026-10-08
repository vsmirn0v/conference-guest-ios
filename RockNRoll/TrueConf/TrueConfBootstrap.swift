import ConferenceCore
import CryptoKit
import Foundation

enum TrueConfError: LocalizedError, Equatable {
    case invalidResponse, unavailable, rejected, ended, disconnected, timedOut
    var isRetryable: Bool { self == .disconnected || self == .timedOut }
    var errorDescription: String? {
        switch self {
        case .unavailable: L("This meeting requires host admission or signing in on its website.")
        case .rejected: L("The meeting service declined this connection.")
        case .ended: L("This meeting has ended.")
        case .timedOut: L("The meeting connection timed out. Check your network and try again.")
        case .invalidResponse, .disconnected: L("Could not connect to the meeting. Check the invitation and your network.")
        }
    }
}

struct TrueConfBootstrap {
    let login: String
    let credential: String
    let socketURL: URL
    static func load(_ target: TrueConfTarget, name: String, session: URLSession) async throws -> Self {
        var url = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)!
        url.path = "/api/v4/software/clients"
        url.queryItems = [.init(name: "lang", value: "en"), .init(name: "call_id", value: target.roomID),
                          .init(name: "case", value: "join_conference_button"), .init(name: "user", value: "$" + name)]
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await BoundedHTTP.load(request, session: session, maximumBytes: 256_000)
        guard response.statusCode == 200 else { throw TrueConfError.unavailable }
        return try decode(data, target: target)
    }
    static func decode(_ data: Data, target: TrueConfTarget) throws -> Self {
        struct Envelope: Decodable {
            struct Client: Decodable { let type: String?; let platform: String?; let web_url: String? }
            let clients: [Client]
        }
        let response = try JSONDecoder().decode(Envelope.self, from: data)
        let advertised = response.clients.compactMap { client -> URLComponents? in
            guard client.type == "web", client.platform == "webrtc", let text = client.web_url,
                  let url = URLComponents(string: text), url.scheme?.lowercased() == "https",
                  url.host?.lowercased() == target.originURL.host?.lowercased(),
                  (url.port ?? 443) == (target.originURL.port ?? 443), url.user == nil, url.password == nil,
                  url.path == "/webrtc/" + target.roomID else { return nil }
            return url
        }
        guard let url = advertised.first else { throw TrueConfError.unavailable }
        guard let fragment = url.percentEncodedFragment,
              let fields = URLComponents(string: "https://localhost/?" + fragment)?.queryItems,
              fields.filter({ $0.name == "login" }).count == 1, fields.filter({ $0.name == "token" }).count == 1,
              let login = fields.first(where: { $0.name == "login" })?.value,
              let credential = fields.first(where: { $0.name == "token" })?.value,
              !login.isEmpty, !credential.isEmpty, login.utf8.count <= 512, credential.utf8.count <= 4096 else {
            throw TrueConfError.invalidResponse
        }
        var socket = URLComponents(url: target.originURL, resolvingAgainstBaseURL: false)!
        socket.scheme = "wss"; socket.path = "/websocket/"
        return .init(login: login, credential: credential, socketURL: socket.url!)
    }
}

enum TrueConfICE {
    /// Credentials are encrypted for our current browser-protocol session.
    /// Never persist or log the CID, key, token or decoded TURN password.
    static func decode(_ values: [[String: Any]], cid: String, stream: String) throws -> [[String: Any]] {
        guard values.count <= 16, cid.utf8.count >= 12, cid.utf8.count <= 512, stream.utf8.count <= 1024 else { throw TrueConfError.invalidResponse }
        return try values.map { value in
            guard let address = value["address"] as? String, !address.isEmpty, address.utf8.count <= 256,
                  !address.contains(where: { $0.isWhitespace || "/?#@".contains($0) }),
                  let port = value["port"] as? Int, (1...65535).contains(port),
                  let service = value["serviceType"] as? Int, [0, 1].contains(service),
                  let transport = value["transport"] as? Int, [0, 1].contains(transport) else { throw TrueConfError.invalidResponse }
            let host = address.contains(":") ? "[\(address)]" : address
            let url = "\(service == 0 ? "stun" : "turn"):\(host):\(port)" + (transport == 1 ? "?transport=tcp" : "")
            var result: [String: Any] = ["urls": [url]]
            if service == 1 {
                guard let hex = value["credential"] as? String, (32...8192).contains(hex.count), hex.count.isMultiple(of: 2),
                      let username = value["userName"] as? String, !username.isEmpty, username.utf8.count <= 1024 else { throw TrueConfError.invalidResponse }
                var encrypted = Data(); var cursor = hex.startIndex
                while cursor < hex.endIndex {
                    let next = hex.index(cursor, offsetBy: 2)
                    guard let byte = UInt8(hex[cursor..<next], radix: 16) else { throw TrueConfError.invalidResponse }
                    encrypted.append(byte); cursor = next
                }
                let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(cid.utf8)),
                    salt: Data(stream.utf8), info: Data("app=bridge;module=conference;dir=s2c;".utf8), outputByteCount: 32)
                let sealed = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Data(cid.utf8).prefix(12)),
                    ciphertext: encrypted.dropLast(16), tag: encrypted.suffix(16))
                let plaintext = try AES.GCM.open(sealed, using: key)
                guard let password = String(data: plaintext, encoding: .utf8), !password.isEmpty else { throw TrueConfError.invalidResponse }
                result["username"] = username; result["credential"] = password
            }
            return result
        }
    }
}
