import Foundation

/// Xiva's small MessagePack header followed by the provider's JSON envelope.
/// Parse only the documented-in-client frame types; reject oversized/truncated input.
enum TelemostChatWire {
    struct Packet { let type: Int; let requestID: Int?; let body: [String: Any] }
    static func request(id: Int, method: String, body: [String: Any]) throws -> Data {
        guard (1...Int(UInt16.max)).contains(id), method.utf8.count <= 31 else { throw TelemostError.invalidResponse }
        var bytes: [UInt8] = [1, 0x93, 0]
        if id < 128 { bytes.append(UInt8(id)) }
        else { bytes += [0xcd, UInt8(id >> 8), UInt8(id & 255)] }
        bytes += [0xa0 | UInt8(method.utf8.count)] + Array(method.utf8)
        bytes += [5] + Array(repeating: 0, count: 11)
        var data = Data(bytes); data.append(try JSONSerialization.data(withJSONObject: body))
        guard data.count <= 1_000_000 else { throw TelemostError.invalidResponse }; return data
    }
    static func decode(_ data: Data) throws -> Packet {
        guard data.count <= 2_000_000 else { throw TelemostError.invalidResponse }
        var cursor = Cursor(data: Array(data))
        let type = try cursor.integer(), array = try cursor.byte()
        let headerCount = type == 1 ? 3 : type == 2 ? 2 : type == 3 ? 4 : 0
        guard headerCount != 0, array == 0x90 | headerCount else { throw TelemostError.invalidResponse }
        var requestID: Int?
        if type == 1 { _ = try cursor.integer(); requestID = try cursor.integer(); _ = try cursor.string() }
        else if type == 2 {
            requestID = try cursor.integer(); _ = try cursor.integer()
            return Packet(type: type, requestID: requestID, body: [:])
        } else { for _ in 0..<4 { _ = try cursor.string() } }
        guard try cursor.byte() == 5 else { throw TelemostError.invalidResponse }
        for _ in 0..<11 { _ = try cursor.byte() }
        guard let object = try JSONSerialization.jsonObject(with: Data(cursor.data.dropFirst(cursor.offset))) as? [String: Any] else { throw TelemostError.invalidResponse }
        return Packet(type: type, requestID: requestID, body: object)
    }
    private struct Cursor {
        let data: [UInt8]; var offset = 0
        mutating func byte() throws -> Int {
            guard offset < data.count else { throw TelemostError.invalidResponse }
            defer { offset += 1 }; return Int(data[offset])
        }
        mutating func integer() throws -> Int {
            let tag = try byte()
            if tag < 128 { return tag }
            let count: Int
            switch tag { case 0xcc: count = 1; case 0xcd: count = 2; case 0xce: count = 4; default: throw TelemostError.invalidResponse }
            var value = 0; for _ in 0..<count { value = (value << 8) | (try byte()) }; return value
        }
        mutating func string() throws -> String {
            let tag = try byte(), count: Int
            if tag & 0xe0 == 0xa0 { count = tag & 31 }
            else if tag == 0xd9 { count = try byte() }
            else if tag == 0xda { count = (try byte()) << 8 | (try byte()) }
            else { throw TelemostError.invalidResponse }
            guard count <= 2048, offset + count <= data.count,
                let value = String(bytes: data[offset..<offset + count], encoding: .utf8) else { throw TelemostError.invalidResponse }
            offset += count; return value
        }
    }
    static func entries(_ body: [String: Any], chatID: String, ownID: String) -> [ChatEntry] {
        (body["Chats"] as? [[String: Any]] ?? []).filter { $0["ChatId"] as? String == chatID }
            .flatMap { $0["Messages"] as? [[String: Any]] ?? [] }.prefix(200).compactMap { entry($0, chatID: chatID, ownID: ownID) }
            .sorted { $0.sentAt < $1.sentAt }
    }
    static func entry(_ body: [String: Any], chatID: String, ownID: String) -> ChatEntry? {
        guard let client = body["ClientMessage"] as? [String: Any], let plain = client["Plain"] as? [String: Any],
            plain["ChatId"] as? String == chatID,
            let text = (plain["Text"] as? [String: Any])?["MessageText"] as? String, !text.isEmpty, text.utf8.count <= 64_000,
            let info = body["ServerMessageInfo"] as? [String: Any], info["Deleted"] as? Bool != true,
            let timestamp = info["Timestamp"] as? NSNumber, timestamp.doubleValue > 0 else { return nil }
        let sender = info["CustomFrom"] as? [String: Any] ?? info["From"] as? [String: Any] ?? [:]
        let guid = (info["From"] as? [String: Any])?["Guid"] as? String ?? ""
        return .init(id: String(timestamp.int64Value), sender: String((sender["DisplayName"] as? String ?? L("Participant")).prefix(256)),
            text: text, sentAt: Date(timeIntervalSince1970: timestamp.doubleValue / 1_000_000), isOwn: guid == ownID)
    }
}
