import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNRoll

@MainActor
final class TelemostFeatureTests: XCTestCase {
    func testComposedScreenUsesTheSameSenderAndRetiresDelivery() async throws {
        var first = 0
        let preview = LocalSharePreview()
        let sender = NativeScreenSender(factory: LKRTCPeerConnectionFactory(), preview: preview, onFirstFrame: { first += 1 }, onEnd: { _ in })
        try sender.startComposed()
        XCTAssertTrue(sender.composed); XCTAssertTrue(preview.active)
        let sample = try XCTUnwrap(PresenterCompositor(size: CGSize(width: 160, height: 90)).render(scene: PresenterScene(), camera: nil, time: CMTime(seconds: 1, preferredTimescale: 600)))
        sender.send(sample)
        try await wait { first == 1 }
        await sender.stop()
        sender.send(sample)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(first, 1); XCTAssertFalse(preview.active)
        XCTAssertThrowsError(try sender.startComposed())
    }
    private let chatID = "0/22/test"
    private func message(chat: String = "0/22/test", timestamp: Double = 1_800_000_000_000_000, deleted: Bool = false) -> [String: Any] {
        ["ClientMessage": ["Plain": ["ChatId": chat, "PayloadId": "stable-id", "Text": ["MessageText": "Native QA"]]],
         "ServerMessageInfo": ["Timestamp": timestamp, "Deleted": deleted, "From": ["Guid": "guest", "DisplayName": "Browser QA"]]]
    }
    func testChatWireRoundtripAndTruncationBounds() throws {
        let request = try TelemostChatWire.request(id: 301, method: "history", body: ["ChatId": chatID])
        let decoded = try TelemostChatWire.decode(request)
        XCTAssertEqual(decoded.type, 1); XCTAssertEqual(decoded.requestID, 301); XCTAssertEqual(decoded.body["ChatId"] as? String, chatID)
        for count in 0..<request.count { XCTAssertThrowsError(try TelemostChatWire.decode(request.prefix(count))) }
        XCTAssertThrowsError(try TelemostChatWire.decode(Data(repeating: 0, count: 2_000_001)))
        XCTAssertThrowsError(try TelemostChatWire.request(id: 65536, method: "history", body: [:]))
    }
    func testChatHistoryScopesMessagesAndPreservesTimestampIdentity() throws {
        let wrapped: [String: Any] = ["ServerMessage": message(), "Meta": ["Origin": 39]]
        let body: [String: Any] = ["Chats": [["ChatId": chatID, "Messages": [wrapped, message(timestamp: 1_799_000_000_000_000)]],
                                                ["ChatId": "other", "Messages": [message(chat: "other")]]]]
        let entries = TelemostChatWire.entries(body, chatID: chatID, ownID: "guest")
        XCTAssertEqual(entries.count, 2); XCTAssertTrue(entries.allSatisfy(\.isOwn))
        XCTAssertLessThan(entries[0].sentAt, entries[1].sentAt)
        XCTAssertEqual(TelemostChatWire.messageChatID(wrapped), chatID)
        XCTAssertEqual(TelemostChatWire.messageChatID(message()), chatID)
        XCTAssertNil(TelemostChatWire.messageChatID(["Meta": [:]]))
        XCTAssertNil(TelemostChatWire.entry(message(chat: "other"), chatID: chatID, ownID: "guest"))
        XCTAssertNil(TelemostChatWire.entry(message(deleted: true), chatID: chatID, ownID: "guest"))
        let store = ChatStore(); store.replace(entries); let count = store.unreadCount
        store.replace(entries); XCTAssertEqual(store.unreadCount, count)
        store.unavailableReason = "Read only"; store.clear(); XCTAssertNil(store.unavailableReason)
    }
    func testScreenSenderRejectsFramesAfterStop() async throws {
        var first = 0
        let sender = NativeScreenSender(factory: LKRTCPeerConnectionFactory(), preview: LocalSharePreview(), onFirstFrame: { first += 1 }, onEnd: { _ in })
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixel)
        sender.receiveForTesting(pixels, timestamp: 1_000_000_000)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(first, 1)
        await sender.stop()
        sender.receiveForTesting(pixels, timestamp: 2_000_000_000)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(first, 1)
    }
    func testLiveChatStaysConnectedBeyondOneMinute() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable Telemost room required") }
        let target = try TelemostTarget.parse(invitation)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let bootstrap = try await TelemostBootstrap.load(target, name: "Native Chat Lifecycle QA", session: session)
        let store = ChatStore(), reader = TelemostChat(store: store)
        reader.start(invitation: target.invitationURL, roomID: bootstrap.roomID)
        defer { reader.stop() }
        let readOnly = L("Read-only chat. This meeting service requires sign-in to send messages.")
        try await wait { store.unavailableReason == readOnly }
        let deadline = Date().addingTimeInterval(75)
        while Date() < deadline {
            try await Task.sleep(for: .seconds(1))
            XCTAssertEqual(store.unavailableReason, readOnly)
        }
        if let expected = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CHAT_TEXT"] {
            XCTAssertTrue(store.items.contains { $0.text == expected })
        }
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition()); if !condition() { throw TelemostError.timedOut }
    }
}
