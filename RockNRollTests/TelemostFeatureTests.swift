import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class TelemostFeatureTests: XCTestCase {
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
    func testSeparatePresentationTransceiverAndStop() async throws {
        let factory = try TelemostPeer.makeFactory()
        let publisher = TelemostPeer(target: "PUBLISHER", factory: factory, ice: [])
        let receiver = TelemostPeer(target: "SUBSCRIBER", factory: factory, ice: [])
        let track = factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: "screen")
        publisher.setSharing(track)
        let offer = try await publisher.offer()
        let tracks = try XCTUnwrap(offer["tracks"] as? [[String: Any]])
        XCTAssertEqual(tracks.map { $0["kind"] as? String }, ["DISPLAY_VIDEO"])
        try await publisher.accept(try await receiver.answer(offer))
        publisher.setSharing(nil)
        let stopped = try await publisher.offer()
        XCTAssertTrue((stopped["tracks"] as? [[String: Any]] ?? []).isEmpty)
        await publisher.close(); await receiver.close()
    }
    func testScreenSenderRejectsFramesAfterStop() async throws {
        var first = 0
        let sender = TelemostScreenSender(factory: try TelemostPeer.makeFactory(), preview: LocalSharePreview(), onFirstFrame: { first += 1 }, onEnd: { _ in })
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        let pixels = try XCTUnwrap(pixel)
        sender.receiveForTesting(pixels, timestamp: 1_000_000_000)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(first, 1)
        await sender.stop()
        sender.receiveForTesting(pixels, timestamp: 2_000_000_000)
        try await Task.sleep(for: .milliseconds(100)); XCTAssertEqual(first, 1)
    }
    func testLiveChatAndOutgoingPresentation() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable Telemost room required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let chat = ChatStore()
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: chat)
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .left, .failed: ended = true; default: break } }
        try engine.join(target: TelemostTarget.parse(invitation), name: "Native Presentation QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        print("Native chat QA: media connected")
        try await wait { chat.unavailableReason?.hasPrefix("Read-only") == true || ended }
        XCTAssertFalse(chat.canSend); XCTAssertFalse(ended)
        print("Native chat QA: reader ready, messages \(chat.items.count)")
        if let expected = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CHAT_TEXT"] {
            try await wait { chat.items.contains { $0.text == expected } }
            XCTAssertFalse(chat.items.first { $0.text == expected }?.isOwn ?? true)
        }
        try engine.startSharingForTesting()
        var pixel: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel), kCVReturnSuccess)
        _ = try XCTUnwrap(pixel)
        for n in 1...70 {
            var next: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &next), kCVReturnSuccess)
            let pixels = try XCTUnwrap(next)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), n % 2 == 0 ? 64 : 200, CVPixelBufferGetBytesPerRow(pixels) * 360)
            CVPixelBufferUnlockBaseAddress(pixels, [])
            engine.sendScreenForTesting(pixels, timestamp: Int64(n) * 100_000_000)
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(engine.isSharingScreen)
        let frames = await engine.sentScreenFramesForTesting(); XCTAssertGreaterThan(frames, 10)
        await engine.stopSharingForTesting(); XCTAssertFalse(engine.isSharingScreen)
        engine.leave(); try await wait { ended }; XCTAssertFalse(engine.hasJoinStarted)
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(30)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition()); if !condition() { throw TelemostError.timedOut }
    }
}
