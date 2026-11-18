import AVFoundation
import Foundation
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

/// No fixture opens a socket or physical capture/playout device. A blocked
/// camera-stop task exercises real peer.close(), not a replacement close path.
@MainActor final class ExternalRecoveryTests: XCTestCase {
    func testRecoveryDiagnosticsTrackEpochWithoutTransportData() throws {
        let engine = TelemostAdapter()
        let first = engine.ownershipDiagnostics
        XCTAssertEqual(first["executor"] as? String, RecoveryExecutorKind.nativeAdapterSupervisor.rawValue)
        engine.supervisor.advanceGeneration()
        let second = engine.ownershipDiagnostics
        XCTAssertNotEqual(first["connectionGeneration"] as? String, second["connectionGeneration"] as? String)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(second))
        XCTAssertNil(second["invitation"])
        XCTAssertNil(second["credentials"])
        XCTAssertNil(second["sdp"])
    }
    private final class BlockedCameraStop {
        var continuation: CheckedContinuation<Bool, Never>?
        var result: Bool?
        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ clean: Bool) {
            result = clean; continuation?.resume(returning: clean); continuation = nil
        }
    }
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
    private func blockedPeer(_ stop: BlockedCameraStop) async throws -> NativeDesktopRTCPeer {
        _ = LKRTCInitializeSSL()
        // No system-audio owner, send tracks, permission request or camera start.
        let peer = try await NativeDesktopRTCPeer(target: "SUBSCRIBER", factory: LKRTCPeerConnectionFactory(), ice: [])
        peer.installCameraStopForTesting(Task { await stop.wait() })
        return peer
    }
    func testLeaveDrainsBlockedRealPeerRetirementDespiteRecoveryCancellation() async throws {
        let stop = BlockedCameraStop(); defer { stop.finish(true) }
        let engine = TelemostAdapter(), peer = try await blockedPeer(stop)
        engine.publisher = peer; engine.snapshot.phase = .connected
        var audioShutdownReached = false
        engine.beforeAudioShutdownForTesting = { audioShutdownReached = true }
        engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)))
        let recovery = engine.supervisor.recoveryTask
        let closing = await eventually { peer.closed && engine.publisher == nil && engine.supervisor.connectionRetirementTask != nil }
        XCTAssertTrue(closing, "The actual peer.close must be suspended on its camera-stop drain")
        let barrier = engine.supervisor.connectionRetirementTask
        var concurrentCloseFinished = false, leaveFinished = false
        let concurrentClose = Task { let clean = await engine.closeConnections(); concurrentCloseFinished = true; return clean }
        let leave = Task { let clean = await engine.leave(); leaveFinished = true; return clean }
        let leaving = await eventually {
            (engine.snapshot.phase == .leaving && engine.supervisor.connectionRetirementWaitersForTesting == 2) || leaveFinished
        }
        XCTAssertTrue(leaving); XCTAssertEqual(engine.snapshot.phase, .leaving)
        XCTAssertEqual(engine.supervisor.connectionRetirementWaitersForTesting, 2, "Both callers actually joined the blocked retirement")
        XCTAssertFalse(leaveFinished); XCTAssertFalse(concurrentCloseFinished)
        XCTAssertFalse(audioShutdownReached, "Session audio shutdown must wait for the same real peer retirement")
        XCTAssertTrue(recovery?.isCancelled == true)
        concurrentClose.cancel()
        XCTAssertFalse(barrier?.isCancelled ?? true, "Cancelling either waiter must not cancel retirement ownership")
        stop.finish(true)
        let left = await leave.value, closed = await concurrentClose.value
        XCTAssertTrue(left); XCTAssertTrue(closed); XCTAssertTrue(audioShutdownReached)
        XCTAssertEqual(engine.snapshot.phase, .left); XCTAssertTrue(engine.supervisor.cleanupSucceeded)
        XCTAssertNil(engine.supervisor.connectionRetirementTask)
        // Post-Leave state stability: observing the cancelled recovery's result
        // cannot clear or fail a synthetic newer generation. It may already be done.
        let replacement = try await NativeDesktopRTCPeer(target: "SUBSCRIBER", factory: peer.factory, ice: [])
        engine.supervisor.advanceGeneration(); engine.snapshot.phase = .connected; engine.snapshot.lastError = nil
        engine.publisher = replacement
        await recovery?.value
        XCTAssertEqual(engine.snapshot.phase, .connected); XCTAssertNil(engine.snapshot.lastError)
        XCTAssertTrue(engine.publisher === replacement); XCTAssertEqual(engine.supervisor.retries, 1)
        let replacementStopped = await replacement.close(); XCTAssertTrue(replacementStopped)
        engine.publisher = nil
    }
    func testFailedBlockedRetirementStaysFailedForAllClosersAndReplacement() async throws {
        let stop = BlockedCameraStop(); defer { stop.finish(false) }
        let engine = TrueConfAdapter(), peer = try await blockedPeer(stop)
        engine.publisher = peer; engine.snapshot.phase = .connected
        var audioShutdownReached = false, leaveFinished = false
        engine.beforeAudioShutdownForTesting = { audioShutdownReached = true }
        engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNRESET.rawValue)))
        let recovery = engine.supervisor.recoveryTask
        let closing = await eventually { peer.closed && engine.supervisor.connectionRetirementTask != nil }
        XCTAssertTrue(closing)
        let leave = Task { let clean = await engine.leave(); leaveFinished = true; return clean }
        let leaving = await eventually {
            (engine.snapshot.phase == .leaving && engine.supervisor.connectionRetirementWaitersForTesting == 1) || leaveFinished
        }
        XCTAssertTrue(leaving); XCTAssertEqual(engine.snapshot.phase, .leaving)
        XCTAssertEqual(engine.supervisor.connectionRetirementWaitersForTesting, 1)
        XCTAssertFalse(leaveFinished); XCTAssertFalse(audioShutdownReached)
        // Even an invalidly advanced phase cannot bypass an in-flight barrier.
        engine.snapshot.phase = .failed
        do {
            try await engine.connect(invitation: URL(string: "https://tc.example.test/c/0100110011")!, name: "Fixture", quiet: false, sessionID: UUID())
            XCTFail("A new owner cannot be admitted while retirement is blocked")
        } catch { XCTAssertEqual(error as? NativeDesktopRTCError, .cleanupFailed) }
        engine.snapshot.phase = .leaving
        stop.finish(false)
        let left = await leave.value
        XCTAssertFalse(left); XCTAssertTrue(audioShutdownReached)
        XCTAssertFalse(engine.supervisor.cleanupSucceeded); XCTAssertEqual(engine.snapshot.phase, .failed)
        XCTAssertNotNil(engine.supervisor.connectionRetirementTask, "Failed retirement remains owned and sticky")
        let generation = engine.supervisor.generation, failure = engine.snapshot.lastError
        await recovery?.value
        XCTAssertEqual(engine.supervisor.generation, generation); XCTAssertEqual(engine.snapshot.lastError, failure)
        let closedAgain = await engine.closeConnections(), leftAgain = await engine.leave()
        XCTAssertFalse(closedAgain); XCTAssertFalse(leftAgain); XCTAssertFalse(engine.supervisor.cleanupSucceeded)
        do {
            try await engine.connect(invitation: URL(string: "https://tc.example.test/c/0100110011")!, name: "Fixture", quiet: false, sessionID: UUID())
            XCTFail("An unconfirmed camera stop cannot be cleared by another Leave")
        } catch { XCTAssertEqual(error as? NativeDesktopRTCError, .cleanupFailed) }
        XCTAssertEqual(engine.supervisor.retries, 1); XCTAssertNil(engine.publisher)
    }
    func testQueuedTerminalRecoveryCannotFailANewerGeneration() async {
        let engine = TelemostAdapter()
        engine.snapshot.phase = .connected
        engine.recover(TelemostError.ended)
        let obsolete = engine.supervisor.recoveryTask
        engine.supervisor.advanceGeneration(); engine.snapshot.phase = .connected
        await obsolete?.value
        XCTAssertEqual(engine.snapshot.phase, .connected)
        XCTAssertNil(engine.snapshot.lastError); XCTAssertNil(engine.supervisor.failureDuringShutdown)
        engine.supervisor.cancelRecovery()
    }
    func testPOSIXDisconnectRecoveryAndLeaveRepeatedly() async {
        for code in [POSIXErrorCode.ENOTCONN, .ECONNRESET, .EPIPE] {
            let engine = TelemostAdapter()
            engine.snapshot.phase = .connected
            engine.snapshot.microphoneOn = true; engine.snapshot.cameraOn = true; engine.snapshot.sharing = true
            let generation = engine.supervisor.generation
            engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue)))
            XCTAssertEqual(engine.snapshot.phase, .reconnecting)
            XCTAssertEqual(engine.supervisor.retries, 1)
            XCTAssertNotEqual(engine.supervisor.generation, generation)
            XCTAssertFalse(engine.snapshot.microphoneOn); XCTAssertFalse(engine.snapshot.cameraOn); XCTAssertFalse(engine.snapshot.sharing)
            let clean = await engine.leave()
            XCTAssertTrue(clean); XCTAssertEqual(engine.snapshot.phase, .left)
            XCTAssertNil(engine.supervisor.recoveryTask); XCTAssertNil(engine.audio)
            XCTAssertNil(engine.publisher); XCTAssertNil(engine.subscriber)
            // A late callback from the retired generation must stay harmless.
            engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue)))
            XCTAssertEqual(engine.snapshot.phase, .left); XCTAssertNil(engine.supervisor.recoveryTask)
        }
    }

    func testNetworkRecoveryRemainsBoundedAndTerminalFailuresStayTerminal() async {
        let terminal: [Error] = [TelemostError.removed, TelemostError.ended, TelemostError.rejected("4003"),
            TelemostError.admissionRequired, TelemostError.incompatibleProtocol, TelemostError.invalidResponse,
            TrueConfError.ended, TrueConfError.rejected, NativeDesktopRTCError.cleanupFailed,
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EINVAL.rawValue)),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)]
        for error in terminal {
            XCTAssertFalse(NativeAdapterRecoveryPolicy.isRetryableTransportFailure(error), "\(error)")
        }
        let engine = TelemostAdapter()
        engine.snapshot.phase = .connected
        for _ in 0..<3 {
            engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)))
            engine.supervisor.cancelRecovery()
        }
        engine.snapshot.phase = .connected
        engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)))
        let cleanup = engine.supervisor.recoveryTask
        await cleanup?.value
        XCTAssertEqual(engine.snapshot.phase, .failed)
        XCTAssertEqual(engine.supervisor.retries, 3, "A fourth disconnect cannot extend the retry budget")
        XCTAssertNil(engine.supervisor.recoveryTask); XCTAssertNil(engine.audio)
        XCTAssertNil(engine.publisher); XCTAssertNil(engine.subscriber)
    }

    func testSubscriberAcceptsIncrementingPcSeqAndRejectsStaleSeq() async throws {
        _ = LKRTCInitializeSSL()
        let audio = GuestSyntheticAudio()
        defer { XCTAssertTrue(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: audio
        )
        let peer = try await NativeDesktopRTCPeer(target: "SUBSCRIBER", factory: factory, ice: [])
        let offerSDP = [
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

        let first = try await peer.answer(["sdp": offerSDP, "pcSeq": 1])
        XCTAssertEqual(first["pcSeq"] as? Int, 1)
        let second = try await peer.answer(["sdp": offerSDP, "pcSeq": 2])
        XCTAssertEqual(second["pcSeq"] as? Int, 2, "Renegotiated subscriber offers with incrementing pcSeq must succeed")
        do {
            _ = try await peer.answer(["sdp": offerSDP, "pcSeq": 1])
            XCTFail("Stale pcSeq behind newer negotiated offer must be rejected")
        } catch {
            XCTAssertEqual(error as? NativeDesktopRTCError, .invalidResponse)
        }
        let closed = await peer.close()
        XCTAssertTrue(closed)
    }

    func testTrueConfSDPOfferGlareRollsBackLocalOfferAndReoffersWithoutFailing() async throws {
        _ = LKRTCInitializeSSL()
        let audio = GuestSyntheticAudio()
        defer { XCTAssertTrue(audio.terminateDevice()) }
        let serverFactory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: audio
        )
        let serverConfig = LKRTCConfiguration()
        serverConfig.sdpSemantics = .unifiedPlan
        let serverPeer = try XCTUnwrap(serverFactory.peerConnection(
            with: serverConfig,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        ))
        defer { serverPeer.close() }
        let sendOnly = LKRTCRtpTransceiverInit(); sendOnly.direction = .sendOnly
        _ = serverPeer.addTransceiver(of: .audio, init: sendOnly)
        _ = serverPeer.addTransceiver(of: .video, init: sendOnly)
        let initialOffer = try await createSDP(on: serverPeer, offer: true)
        try await setSDP(on: serverPeer, description: initialOffer, local: true)

        let transport = MockTrueConfTransport()
        let stubAudio = StubGuestAudio(factory: serverFactory)
        let adapter = TrueConfAdapter(
            makeTransport: { _, _ in transport },
            loadBootstrap: { _, _, _ in
                TrueConfBootstrap(login: "guest", credential: "cred",
                                  socketURL: URL(string: "wss://tc.example.test/websocket/")!)
            }
        )
        let attempt = adapter.supervisor.resetForNewConnect()
        adapter.audio = stubAudio
        adapter.transport = transport
        adapter.snapshot = .init(phase: .connecting, playoutOn: false)
        adapter.name = "Tester"
        adapter.publisher = try await NativeDesktopRTCPeer(target: "COMPOSITE", factory: serverFactory, ice: [], topology: .composite)

        try await adapter.receiveTrueConf(["method": "conferenceStateChange", "conference": ["message": "joinResponse", "streamConferenceId": "stream-1"]], attempt: attempt)
        try await adapter.receiveTrueConf(["method": "connectMedia", "result": true], attempt: attempt)
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "offer", "sdp": initialOffer.sdp], attempt: attempt)

        let clientAnswerIndex = try await transport.waitForIndex { ($0["method"] as? String) == "webrtc" && ($0["type"] as? String) == "answer" }
        let clientAnswerSDP = try XCTUnwrap(transport.sent[clientAnswerIndex]["sdp"] as? String)
        try await setSDP(on: serverPeer, description: LKRTCSessionDescription(type: .answer, sdp: clientAnswerSDP), local: false)

        let offer1Index = try await transport.waitForIndex { ($0["method"] as? String) == "webrtc" && ($0["type"] as? String) == "offer" }
        let glareOffer = try await createSDP(on: serverPeer, offer: true)
        try await setSDP(on: serverPeer, description: glareOffer, local: true)

        // Inject server offer while client local offer is awaiting answer (SDP glare).
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "offer", "sdp": glareOffer.sdp], attempt: adapter.supervisor.generation)

        let answer2Index = try await transport.waitForIndex(after: offer1Index) {
            ($0["method"] as? String) == "webrtc" && ($0["type"] as? String) == "answer"
        }
        let glareAnswerSDP = try XCTUnwrap(transport.sent[answer2Index]["sdp"] as? String)
        try await setSDP(on: serverPeer, description: LKRTCSessionDescription(type: .answer, sdp: glareAnswerSDP), local: false)

        let offer2Index = try await transport.waitForIndex(after: answer2Index) {
            ($0["method"] as? String) == "webrtc" && ($0["type"] as? String) == "offer"
        }
        let offer2SDP = try XCTUnwrap(transport.sent[offer2Index]["sdp"] as? String)
        try await setSDP(on: serverPeer, description: LKRTCSessionDescription(type: .offer, sdp: offer2SDP), local: false)
        let serverAnswer2 = try await createSDP(on: serverPeer, offer: false)
        try await setSDP(on: serverPeer, description: serverAnswer2, local: true)

        try await adapter.receiveTrueConf(["method": "webrtc", "type": "answer", "sdp": serverAnswer2.sdp], attempt: adapter.supervisor.generation)
        _ = try await transport.waitForIndex(after: offer2Index) { ($0["method"] as? String) == "DeviceStatus" }
        XCTAssertNotEqual(adapter.snapshot.phase, .failed)
        XCTAssertNotEqual(adapter.snapshot.phase, .reconnecting)

        let clean = await adapter.leave()
        XCTAssertTrue(clean)
    }

    func testFailedTrueConfCameraNegotiationThrowsAndReleasesCameraLease() async throws {
        _ = LKRTCInitializeSSL()
        let audio = GuestSyntheticAudio()
        defer { XCTAssertTrue(audio.terminateDevice()) }
        let serverFactory = LKRTCPeerConnectionFactory(
            encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioDevice: audio
        )
        let serverConfig = LKRTCConfiguration()
        serverConfig.sdpSemantics = .unifiedPlan
        let serverPeer = try XCTUnwrap(serverFactory.peerConnection(
            with: serverConfig,
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil
        ))
        defer { serverPeer.close() }
        let sendOnly = LKRTCRtpTransceiverInit(); sendOnly.direction = .sendOnly
        _ = serverPeer.addTransceiver(of: .audio, init: sendOnly)
        _ = serverPeer.addTransceiver(of: .video, init: sendOnly)
        let initialOffer = try await createSDP(on: serverPeer, offer: true)
        try await setSDP(on: serverPeer, description: initialOffer, local: true)

        let transport = MockTrueConfTransport()
        let stubAudio = StubGuestAudio(factory: serverFactory)
        let adapter = TrueConfAdapter(
            makeTransport: { _, _ in transport },
            loadBootstrap: { _, _, _ in
                TrueConfBootstrap(login: "guest", credential: "cred",
                                  socketURL: URL(string: "wss://tc.example.test/websocket/")!)
            }
        )
        let attempt = adapter.supervisor.resetForNewConnect()
        adapter.audio = stubAudio
        adapter.transport = transport
        adapter.snapshot = .init(phase: .connecting, playoutOn: false)
        adapter.name = "Tester"
        adapter.publisher = try await NativeDesktopRTCPeer(target: "COMPOSITE", factory: serverFactory, ice: [], topology: .composite)
        try await adapter.receiveTrueConf(["method": "conferenceStateChange", "conference": ["message": "joinResponse", "streamConferenceId": "stream-1"]], attempt: attempt)
        try await adapter.receiveTrueConf(["method": "connectMedia", "result": true], attempt: attempt)
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "offer", "sdp": initialOffer.sdp], attempt: attempt)

        let clientAnswerIdx = try await transport.waitForIndex { ($0["method"] as? String) == "webrtc" && ($0["type"] as? String) == "answer" }
        try await setSDP(on: serverPeer, description: LKRTCSessionDescription(type: .answer, sdp: try XCTUnwrap(transport.sent[clientAnswerIdx]["sdp"] as? String)), local: false)
        let offerIdx = try await transport.waitForIndex { ($0["method"] as? String) == "webrtc" && ($0["type"] as? String) == "offer" }
        try await setSDP(on: serverPeer, description: LKRTCSessionDescription(type: .offer, sdp: try XCTUnwrap(transport.sent[offerIdx]["sdp"] as? String)), local: false)
        let answer1 = try await createSDP(on: serverPeer, offer: false)
        try await setSDP(on: serverPeer, description: answer1, local: true)
        try await adapter.receiveTrueConf(["method": "webrtc", "type": "answer", "sdp": answer1.sdp], attempt: adapter.supervisor.generation)
        _ = try await transport.waitForIndex(after: offerIdx) { ($0["method"] as? String) == "DeviceStatus" }

        GuestCamera.defaultFactory = { _ in FailingGuestCameraStub() }
        defer { GuestCamera.defaultFactory = nil }
        let coordinator = MeetingCaptureCoordinator()
        do {
            try await coordinator.applyCameraEnabled(true, sessionID: UUID(), isValid: { true }) { enabled in
                try await adapter.setCamera(enabled)
            }
            XCTFail("Camera failure must throw so coordinator releases its camera lease")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("NativeDesktopRTCError"))
        }
        XCTAssertFalse(coordinator.hasActiveCameraLease, "Camera lease must be released when camera enable fails")
        XCTAssertEqual(NativeDesktopCameraLease.shared.ownershipDiagnostics["cleanupFailed"] as? Bool, false)
        XCTAssertEqual(NativeDesktopCameraLease.shared.ownershipDiagnostics["reservation"] as? String, "none")
        XCTAssertFalse(adapter.snapshot.cameraOn)

        let clean = await adapter.leave()
        XCTAssertTrue(clean)
    }

    private func createSDP(on peer: LKRTCPeerConnection, offer: Bool) async throws -> LKRTCSessionDescription {
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return try await withCheckedThrowingContinuation { continuation in
            let handler: @Sendable (LKRTCSessionDescription?, Error?) -> Void = { sdp, error in
                if let error { continuation.resume(throwing: error) }
                else if let sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: NativeDesktopRTCError.invalidResponse) }
            }
            if offer { peer.offer(for: constraints, completionHandler: handler) }
            else { peer.answer(for: constraints, completionHandler: handler) }
        }
    }

    private func setSDP(on peer: LKRTCPeerConnection, description: LKRTCSessionDescription, local: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let handler: @Sendable (Error?) -> Void = { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
            if local { peer.setLocalDescription(description, completionHandler: handler) }
            else { peer.setRemoteDescription(description, completionHandler: handler) }
        }
    }
}

@MainActor private final class MockTrueConfTransport: TrueConfSignalingTransport {
    var cid = ""
    var onMessage: (([String: Any]) async throws -> Void)?
    var onFailure: ((Error) -> Void)?
    private(set) var sent: [[String: Any]] = []

    func start() {}
    func send(_ fields: [String: Any]) async throws { sent.append(fields) }
    func close(room: String?) async { onMessage = nil; onFailure = nil }

    func waitForIndex(after startAfter: Int = -1, matching predicate: ([String: Any]) -> Bool) async throws -> Int {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let index = sent.indices.first(where: { $0 > startAfter && predicate(sent[$0]) }) {
                return index
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw NativeDesktopRTCError.invalidResponse
    }
}

private final class FailingGuestCameraStub: GuestCameraCapture {
    func start() async throws -> GuestCameraInfo { throw GuestCameraError.unavailable }
    func cancel() {}
    func stop() async throws {}
    func snapshot() -> GuestCameraSnapshot {
        GuestCameraSnapshot(frames: 0, advancingPTS: 0, dropped: 0, width: 0, height: 0,
                            pixelFormat: nil, systemBackgroundSelected: nil,
                            systemBackgroundActive: nil, observedReaction: false)
    }
    func performReaction() async -> Bool { false }
}

@MainActor private final class StubGuestAudio: GuestMeetingAudio {
    let factory: LKRTCPeerConnectionFactory
    let profile: GuestAudioProfile = .speech
    var snapshot: [String: Any] = ["microphoneMuted": true]
    var playoutEpoch: UUID?
    var startupAudioObservation = GuestStartupAudioObservation(snapshot: [:], inputCallbacks: 0, outputCallbacks: 0)
    var canUnmuteMicrophone = true
    var privateInputLevel: Float?
    var privateInputMeterEvidence: [String: Any] = [:]
    var playoutMeterEvidence: [String: Any] = [:]
    var meetingLevel: Double = 1
    #if DEBUG
    var sharedPlayoutGateForTesting = GuestSharedPlayoutGate(enabled: false)
    var startupCallbackEvidence: [String: Any] = [:]
    #endif

    init(factory: LKRTCPeerConnectionFactory) { self.factory = factory }
    func registerMicrophoneTrack(_ track: LKRTCAudioTrack) {}
    func activateMicrophone(timeout: TimeInterval?) async -> Bool { true }
    func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval) async -> Bool {
        snapshot["microphoneMuted"] = muted
        return true
    }
    func suppressMicrophone() { snapshot["microphoneMuted"] = true }
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool, timeout: TimeInterval) async -> Bool { true }
    func prewarmInput(timeout: TimeInterval) async -> Bool { true }
    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval, expectedEpoch: UUID?) async -> Bool { true }
    func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval) async -> Bool { true }
    func openSharedPlayout(expected: UUID?) -> Bool { true }
    func setSharedSoundIntent(_ sound: Bool, expected: UUID?) -> Bool { true }
    func closeSharedPlayout(expected: UUID?) -> Bool { true }
    func sharedPlayoutIsOpen(expected: UUID?) -> Bool { false }
    func setMeetingVolume(_ volume: Double) -> Bool { true }
    func refreshSnapshot(timeout: TimeInterval) async -> Bool { true }
    func beginPrivateInputCheck(timeout: TimeInterval?) async -> Bool { true }
    func endPrivateInputCheck(timeout: TimeInterval) async -> Bool { true }
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {}
    func setPrivateInputMeterEnabled(_ enabled: Bool) {}
    func setMicrophoneGate(open: Bool) -> Bool { true }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { true }
    func shutdown(timeout: TimeInterval) async -> Bool { true }
}
