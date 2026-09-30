import Foundation

public struct RoomChatPacket: Codable, Sendable {
    public static let topic = "rock.chat.v1"
    public static let maximumScalars = 2_000
    public static let maximumBytes = 16_384
    public let id: String
    public let text: String
    public init(id: String, text: String) { self.id = id; self.text = text }
    public func encoded() throws -> Data {
        guard !id.isEmpty, id.utf8.count <= 64, !text.isEmpty,
              text.unicodeScalars.count <= Self.maximumScalars else { throw RoomChatError.tooLarge }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumBytes else { throw RoomChatError.tooLarge }
        return data
    }
    public static func decode(_ data: Data) throws -> Self {
        guard data.count <= maximumBytes else { throw RoomChatError.tooLarge }
        let packet = try JSONDecoder().decode(Self.self, from: data)
        _ = try packet.encoded()
        return packet
    }
    public static func accepts(text: String) -> Bool {
        (try? Self(id: String(repeating: "0", count: 36), text: text).encoded()) != nil
    }
}

public enum RoomChatError: LocalizedError {
    case tooLarge
    public var errorDescription: String? { CoreL("This message is too long to send. Shorten it and try again.") }
}
