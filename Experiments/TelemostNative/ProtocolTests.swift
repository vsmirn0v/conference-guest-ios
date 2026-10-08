import Foundation

@main
struct ProtocolTests {
    static func main() throws {
        var passed = 0
        func rejects(_ operation: () throws -> Void) {
            do { try operation(); fatalError("Expected rejection") } catch { passed += 1 }
        }
        for url in ["http://telemost.yandex.ru/j/123", "https://telemost.yandex.ru.attacker.test/j/123",
                    "https://telemost.yandex.ru/j/", "https://telemost.yandex.ru/j/123/extra",
                    "https://user:password@telemost.yandex.ru/j/123", "https://telemost.yandex.ru:8080/j/123"] {
            rejects { _ = try TelemostConnection.request(invitation: URL(string: url)!, name: "QA") }
        }
        let invitation = URL(string: "https://telemost.yandex.ru/j/123?value=a%26b")!
        let request = try TelemostConnection.request(invitation: invitation, name: "QA & Name")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        precondition(components.queryItems?.first(where: { $0.name == "display_name" })?.value == "QA & Name")
        precondition(components.path.contains(invitation.absoluteString))
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.value(forHTTPHeaderField: "Client-Instance-Id") != nil)
        passed += 1
        let fixture: [String: Any] = ["connection_type": "CONFERENCE", "media_platform": "GOLOOM",
            "room_id": "test-room", "peer_id": "test-peer", "credentials": "not-a-real-credential",
            "client_configuration": ["media_server_url": "wss://goloom.strm.yandex.net/join", "service_name": "telemost"]]
        func decode(_ value: [String: Any]) throws -> TelemostConnection {
            try TelemostConnection.decode(JSONSerialization.data(withJSONObject: value))
        }
        let result = try decode(fixture)
        precondition(result.peerID == "test-peer" && result.ice.isEmpty); passed += 1
        var waiting = fixture; waiting["connection_type"] = "WAITING_ROOM"
        rejects { _ = try decode(waiting) }
        var otherEngine = fixture; otherEngine["media_platform"] = "UNKNOWN"
        rejects { _ = try decode(otherEngine) }
        var missing = fixture; missing.removeValue(forKey: "credentials")
        rejects { _ = try decode(missing) }
        for endpoint in ["ws://goloom.strm.yandex.net/join", "wss://attacker.test/join", "wss://user:password@goloom.strm.yandex.net/join"] {
            var unsafe = fixture
            unsafe["client_configuration"] = ["media_server_url": endpoint, "service_name": "telemost"]
            rejects { _ = try decode(unsafe) }
        }
        rejects { _ = try TelemostConnection.decode(Data("not JSON".utf8)) }
        rejects { _ = try TelemostConnection.decode(Data(repeating: 32, count: 256_001)) }
        print("Passed \(passed) protocol boundary checks")
    }
}
