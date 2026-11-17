import ConferenceCore
import Foundation
import Network
import XCTest
@testable import RockNativeDesktop

@MainActor final class TelemostVerticalSliceTests: XCTestCase {
    func testUniversalTelemostSessionConnectsHandlesPushBehindPendingAckAndDrainsCleanly() async throws {
        let server = try LoopbackGoloomServer()
        defer { server.stop() }
        let port = try await server.start()

        let engine = UniversalMeetingEngine(sharedAudio: SharedAudioEngine.live(manualRenderingForTesting: true))
        let chat = ChatStore()
        let invitation = try XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/01234567890123456789"))
        let destination = try JoinDestination.verified(invitation, engine: .telemost)

        let session = engine.makeSession(destination: destination, chat: chat, adapter: nil)
        XCTAssertEqual(engine.activeSessionCount, 1)
        XCTAssertEqual(session.capabilities, .telemost)
        XCTAssertEqual(session.ownershipDiagnostics["configuredRecoveryExecutor"] as? String, "native-adapter-supervisor")
        XCTAssertTrue(chat.onSend == nil && (session.chatService?.canSend == false))

        let loopbackAdapter = TelemostAdapter(
            chat: chat,
            sharedAudio: engine.sharedAudio,
            makeTransport: { _, urlSession in TelemostTransport(server: URL(string: "ws://127.0.0.1:\(port)/ws")!, session: urlSession) },
            loadBootstrap: { _, _, _ in
                TelemostBootstrap(
                    roomID: "telemost-room-1",
                    participantID: "self-peer",
                    credentials: "cred",
                    serverURL: URL(string: "ws://127.0.0.1:\(port)/ws")!,
                    serviceName: "telemost",
                    iceServers: [],
                    chatAllowed: false
                )
            }
        )
        let loopbackSession = UniversalMeetingEngine(sharedAudio: engine.sharedAudio)
            .makeSession(destination: destination, chat: chat, adapter: loopbackAdapter)

        _ = await session.leave()
        try await loopbackSession.connect(invitation: invitation, name: "Vitalii", quiet: true)
        XCTAssertFalse(loopbackSession.snapshot.playoutOn)
        XCTAssertFalse(loopbackSession.snapshot.microphoneOn)

        // Drive serverHello -> subscriberSdpOffer; withhold subscriberSdpAnswer ack while slotsConfig and
        // updateDescription arrive on the socket behind it, then release the ack and verify both apply.
        await server.waitForClientMessage(kind: "hello")
        await server.sendServerHello()

        await server.sendSubscriberOffer(sdp: FakeLoopbackSDP.offer)
        let answerUID = await server.waitForClientMessage(kind: "subscriberSdpAnswer")
        XCTAssertNotNil(answerUID)

        await server.sendSlotsConfig(slots: [["vad": true, "participant": ["participantId": "alice"]]])
        await server.sendUpdateDescription(participants: [["id": "alice", "meta": ["name": "Alice", "sendAudio": true, "sendVideo": false]]])
        try await Task.sleep(for: .milliseconds(30))
        if let answerUID {
            await server.sendAck(uid: answerUID)
        }

        let deadline = ContinuousClock.now + .seconds(3)
        while !loopbackSession.snapshot.participants.contains(where: { $0.id == "alice" && $0.speaking == true }),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let alice = loopbackSession.snapshot.participants.first { $0.id == "alice" }
        XCTAssertEqual(alice?.name, "Alice")
        XCTAssertEqual(alice?.speaking, true)

        try await loopbackSession.setVisibleParticipantIDs(["alice"], focusedParticipantID: nil)
        let left = await loopbackSession.leave()
        XCTAssertTrue(left)
        XCTAssertEqual(loopbackAdapter.snapshot.phase, .left)
        XCTAssertEqual(loopbackAdapter.activeTaskCountForTesting, 0)
        XCTAssertEqual(loopbackAdapter.remoteAudioSourceCountForTesting, 0)
    }

    func testLeaveWhileSubscriberAckInFlightCancelsCleanlyWithoutHang() async throws {
        let server = try LoopbackGoloomServer()
        defer { server.stop() }
        let port = try await server.start()

        let shared = SharedAudioEngine.live(manualRenderingForTesting: true)
        let adapter = TelemostAdapter(
            chat: ChatStore(),
            sharedAudio: shared,
            makeTransport: { _, urlSession in TelemostTransport(server: URL(string: "ws://127.0.0.1:\(port)/ws")!, session: urlSession) },
            loadBootstrap: { _, _, _ in
                TelemostBootstrap(
                    roomID: "telemost-room-2",
                    participantID: "self-peer",
                    credentials: "cred",
                    serverURL: URL(string: "ws://127.0.0.1:\(port)/ws")!,
                    serviceName: "telemost",
                    iceServers: [],
                    chatAllowed: false
                )
            }
        )
        let invitation = try XCTUnwrap(URL(string: "https://telemost.yandex.ru/j/01234567890123456789"))
        let session = UniversalMeetingEngine(sharedAudio: shared).makeSession(
            destination: try JoinDestination.verified(invitation, engine: .telemost),
            adapter: adapter
        )
        try await session.connect(invitation: invitation, name: "Vitalii", quiet: true)
        await server.waitForClientMessage(kind: "hello")
        await server.sendServerHello()
        await server.sendSubscriberOffer(sdp: FakeLoopbackSDP.offer)
        _ = await server.waitForClientMessage(kind: "subscriberSdpAnswer")

        // Leave before the server ever acknowledges subscriberSdpAnswer.
        let started = ContinuousClock.now
        let clean = await session.leave()
        XCTAssertTrue(clean)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(3))
        XCTAssertEqual(adapter.snapshot.phase, .left)
        XCTAssertEqual(adapter.activeTaskCountForTesting, 0)
    }
}

private enum FakeLoopbackSDP {
    static let offer = [
        "v=0",
        "o=- 1 2 IN IP4 127.0.0.1",
        "s=-",
        "t=0 0",
        "a=group:BUNDLE 0",
        "a=msid-semantic: WMS",
        "m=audio 9 UDP/TLS/RTP/SAVPF 111",
        "c=IN IP4 0.0.0.0",
        "a=rtcp:9 IN IP4 0.0.0.0",
        "a=ice-ufrag:ufrag0001",
        "a=ice-pwd:passwordpasswordpassword01",
        "a=fingerprint:sha-256 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00",
        "a=setup:actpass",
        "a=mid:0",
        "a=sendonly",
        "a=rtcp-mux",
        "a=rtpmap:111 opus/48000/2",
        ""
    ].joined(separator: "\r\n")
}

private final class LoopbackGoloomServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.goloom.ws")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var received: [(kind: String, uid: String)] = []

    func start() async throws -> UInt16 {
        let wsOptions = NWProtocolWebSocket.Options()
        let params = NWParameters.tcp
        params.defaultProtocolStack.applicationProtocols.insert(wsOptions, at: 0)
        let listener = try NWListener(using: params, on: .any)
        self.listener = listener
        return try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if !resumed, let port = listener.port?.rawValue {
                        resumed = true
                        continuation.resume(returning: port)
                    }
                case .failed(let error):
                    if !resumed {
                        resumed = true
                        continuation.resume(throwing: error)
                    }
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
        }
    }

    private func accept(_ conn: NWConnection) {
        connection = conn
        conn.start(queue: queue)
        receiveNext(conn)
    }

    private func receiveNext(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil else { return }
            if let data, let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let uid = envelope["uid"] as? String {
                for key in envelope.keys where key != "uid" {
                    received.append((key, uid))
                    if key == "hello" || key == "setSlots" {
                        sendJSON(["uid": uid, "ack": ["status": ["code": "OK"]]])
                    }
                }
            }
            receiveNext(conn)
        }
    }

    @discardableResult func waitForClientMessage(kind: String) async -> String? {
        for _ in 0..<200 {
            if let uid = queue.sync(execute: { received.first { $0.kind == kind }?.uid }) {
                return uid
            }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return nil
    }

    func sendServerHello() async {
        sendJSON(["uid": UUID().uuidString, "serverHello": [:]])
    }

    func sendSubscriberOffer(sdp: String) async {
        sendJSON(["uid": UUID().uuidString, "subscriberSdpOffer": ["sdp": sdp, "pcSeq": 1]])
    }

    func sendSlotsConfig(slots: [[String: Any]]) async {
        sendJSON(["uid": UUID().uuidString, "slotsConfig": ["key": 0, "slots": slots]])
    }

    func sendUpdateDescription(participants: [[String: Any]]) async {
        sendJSON(["uid": UUID().uuidString, "updateDescription": ["description": participants]])
    }

    func sendAck(uid: String) async {
        sendJSON(["uid": uid, "ack": ["status": ["code": "OK"]]])
    }

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let context = NWConnection.ContentContext(identifier: "ws", metadata: [meta])
        queue.async { [weak self] in
            self?.connection?.send(content: data, contentContext: context, isComplete: true, completion: .idempotent)
        }
    }

    func stop() {
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.listener?.cancel()
        }
    }
}
