import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class TelemostFeatureTests: XCTestCase {
    func testNativeInputMeterFollowsDemandAndRejectsRetiredSamples() async throws {
        let activity = MicrophoneActivity(observeLifecycle: false)
        var calls = 0
        var pending: CheckedContinuation<Float?, Never>?
        let probe = TelemostMicrophoneProbe(activity: activity) {
            calls += 1
            if calls == 1 { return 0.05 }
            return await withCheckedContinuation { pending = $0 }
        }
        XCTAssertEqual(calls, 0)
        activity.setStatus(.on)
        try await wait { activity.hasSignal }
        XCTAssertGreaterThan(activity.level, 0)
        try await wait { pending != nil }
        activity.setForeground(false)
        XCTAssertFalse(activity.samplingNeeded); XCTAssertFalse(activity.hasSignal)
        pending?.resume(returning: 1); pending = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(activity.level, 0); XCTAssertFalse(activity.hasSignal)
        activity.setFloating(true)
        try await wait { pending != nil }
        activity.setStatus(.muted)
        pending?.resume(returning: 1); pending = nil
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(activity.level, 0); XCTAssertFalse(activity.hasSignal)
        withExtendedLifetime(probe) {}
    }
    func testStudioContractsExistAndPrivateCheckRejectsAnUnconnectedCall() async throws {
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        let studio = engine.studioForTesting
        XCTAssertTrue(studio.presenter.available)
        XCTAssertNotNil(studio.soundCheck.verifyMuted)
        do { try await studio.soundCheck.verifyMuted?(); XCTFail("No active audio session must not start private capture") }
        catch is CancellationError {}
        studio.end()
    }
    func testComposedScreenUsesTheSameSenderAndRetiresDelivery() async throws {
        var first = 0
        let preview = LocalSharePreview()
        let sender = TelemostScreenSender(factory: try TelemostPeer.makeFactory(), preview: preview, onFirstFrame: { first += 1 }, onEnd: { _ in })
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
    func testLivePresenterPublishesAndStopsAcrossHold() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable Telemost room required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .left, .failed: ended = true; default: break } }
        try engine.join(target: TelemostTarget.parse(invitation), name: "Native Presenter QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        let studio = engine.studioForTesting
        print("TELEMOST_PRESENTER connected")
        studio.presenter.selectCanvas(); studio.open(.presenter)
        try await wait { studio.presenter.hasPreview }
        await studio.presenter.start()
        try await wait { engine.isSharingScreen || ended }
        XCTAssertTrue(studio.presenter.running); XCTAssertFalse(ended)
        var sent = await engine.sentScreenFramesForTesting()
        let deadline = Date().addingTimeInterval(12)
        while sent < 3, Date() < deadline { try await Task.sleep(for: .milliseconds(200)); sent = await engine.sentScreenFramesForTesting() }
        XCTAssertGreaterThanOrEqual(sent, 3, "Presenter frames must enter the real conference encoder")
        print("TELEMOST_PRESENTER sent=\(sent)")
        #if targetEnvironment(simulator)
        // Direct simulator media bypasses CallKit. Exercise the shared Studio
        // hold teardown here; qualify the real CallKit action on the device.
        studio.held = true
        #else
        try await engine.setTransferHeld(true, restoreSending: true)
        #endif
        try await wait { !engine.isSharingScreen && !studio.presenter.running }
        #if targetEnvironment(simulator)
        studio.held = false
        #else
        try await engine.setTransferHeld(false, restoreSending: true)
        #endif
        XCTAssertFalse(studio.presenter.running, "Call resume must not restart capture without consent")
        engine.leave(); try await wait { ended }
        XCTAssertFalse(studio.presenter.available)
    }
    func testLiveMicrophoneMeterAndPrivateSoundCheck() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real microphone and shared audio session require a physical device")
        #endif
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable Telemost room required") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var active = false, ended = false
        engine.onEvent = { event in switch event { case .active: active = true; case .left, .failed: ended = true; default: break } }
        try engine.join(target: TelemostTarget.parse(invitation), name: "Native Microphone QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        let studio = engine.studioForTesting
        studio.open(.sound); studio.testMicrophone()
        try await wait { studio.soundCheck.state == .listening || studio.soundCheck.state == .failed }
        XCTAssertEqual(studio.soundCheck.state, .listening, studio.soundCheck.error ?? "")
        try await wait { studio.soundCheck.activity.hasSignal }
        XCTAssertFalse(engine.microphoneSendingForTesting, "Private preview must never publish microphone input")
        print("TELEMOST_PRIVATE_METER level=\(studio.soundCheck.activity.level)")
        studio.close(); XCTAssertEqual(studio.soundCheck.state, .idle)
        engine.setSendingForTesting(microphone: true, camera: false)
        try await wait { studio.microphoneActivity.status == .on && studio.microphoneActivity.hasSignal }
        XCTAssertTrue(engine.microphoneSendingForTesting)
        // The first report can precede actual microphone capture. Observe a
        // full window rather than asserting a single startup/silence sample.
        var peak = studio.microphoneActivity.level
        for _ in 0..<32 {
            try await Task.sleep(for: .milliseconds(250))
            peak = max(peak, studio.microphoneActivity.level)
        }
        XCTAssertGreaterThan(peak, 0, "Requires an audible sound near the test device")
        print("TELEMOST_LIVE_METER level=\(studio.microphoneActivity.level)")
        print("TELEMOST_LIVE_METER peak=\(peak)")
        studio.microphoneActivity.setFloating(true); studio.microphoneActivity.setForeground(false)
        studio.microphoneActivity.clear()
        try await wait { studio.microphoneActivity.hasSignal }
        print("TELEMOST_FLOATING_METER level=\(studio.microphoneActivity.level)")
        studio.microphoneActivity.setForeground(true); studio.microphoneActivity.setFloating(false)
        engine.setSendingForTesting(microphone: false, camera: false)
        XCTAssertEqual(studio.microphoneActivity.status, .muted)
        XCTAssertFalse(studio.microphoneActivity.hasSignal)
        engine.leave(); try await wait { ended }
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
        let readOnly = L("Read-only chat. This meeting service requires sign-in to send messages.")
        try await wait { chat.unavailableReason == readOnly || ended }
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
