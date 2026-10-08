import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class TelemostTests: XCTestCase {
    func testPhysicalCameraMicrophoneAndRoutes() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical capture and audio routes")
        #else
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable room required") }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized,
              AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw XCTSkip("Physical camera/microphone permission must already be granted") }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController, idle = UIApplication.shared.isIdleTimerDisabled
        UIApplication.shared.isIdleTimerDisabled = true
        let container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous; UIApplication.shared.isIdleTimerDisabled = idle }
        let engine = TelemostCallEngine(systemCall: SystemCallCoordinator(), catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var active = false, ended = false, readyCount = 0
        engine.onEvent = { event in switch event { case .active: active = true; readyCount += 1; case .left, .failed: ended = true; default: break } }
        try engine.join(target: TelemostTarget.parse(invitation), name: "Native Physical Camera QA", container: container, quiet: false)
        defer { engine.leave() }
        try await wait { active || ended }; XCTAssertFalse(ended)
        engine.setSendingForTesting(microphone: true, camera: true)
        let deadline = Date().addingTimeInterval(20)
        var sent = await engine.sentScreenFramesForTesting()
        while sent < 15, Date() < deadline {
            try await Task.sleep(for: .milliseconds(200)); sent = await engine.sentScreenFramesForTesting()
        }
        XCTAssertGreaterThanOrEqual(sent, 15, "Physical camera must encode real frames")
        engine.flipCameraForTesting(); try await Task.sleep(for: .seconds(4))
        let afterFlip = await engine.sentScreenFramesForTesting()
        XCTAssertGreaterThan(afterFlip, sent, "Camera must continue after lens switch")
        let session = AVAudioSession.sharedInstance()
        try engine.selectSpeakerForTesting(false); try await Task.sleep(for: .seconds(2))
        print("Physical native route after receiver selection: \(session.currentRoute.outputs.map { $0.portType.rawValue })")
        XCTAssertEqual(session.currentRoute.outputs.first?.portType, .builtInReceiver)
        try engine.selectSpeakerForTesting(true); try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(session.currentRoute.outputs.first?.portType, .builtInSpeaker)
        XCTAssertFalse(ended)
        let position = try XCTUnwrap(engine.cameraPositionForTesting)
        XCTAssertEqual(position, .back)
        let beforeHold = readyCount
        try await engine.setTransferHeld(true, restoreSending: true)
        try await Task.sleep(for: .seconds(4))
        try await engine.setTransferHeld(false, restoreSending: true)
        try await wait { readyCount > beforeHold || ended }; XCTAssertFalse(ended)
        let media = await waitForMedia(engine)
        XCTAssertGreaterThan(media.audioEnergy, 0)
        XCTAssertGreaterThanOrEqual(media.videoFrames, 10)
        try await wait { engine.cameraPositionForTesting != nil || ended }
        XCTAssertEqual(engine.cameraPositionForTesting, position, "Recovery must preserve the selected lens")
        let beforeRecovery = readyCount
        engine.interruptForTesting()
        try await wait { readyCount > beforeRecovery || ended }; XCTAssertFalse(ended)
        let recovered = await waitForMedia(engine)
        XCTAssertGreaterThanOrEqual(recovered.videoFrames, 10)
        XCTAssertGreaterThan(recovered.audioEnergy, 0)
        try await wait { engine.cameraPositionForTesting != nil || ended }
        XCTAssertEqual(engine.cameraPositionForTesting, position, "Transport recovery must preserve the selected lens")
        engine.setSendingForTesting(microphone: false, camera: false)
        engine.leave(); try await wait { ended }
        #endif
    }
    func testLiveNativeMediaAndRecovery() async throws {
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else {
            throw XCTSkip("Opt-in live Telemost media check requires a disposable room and synthetic source.")
        }
        let window = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.windows.first { $0.isKeyWindow })
        let previous = window.rootViewController
        let container = UIViewController(); window.rootViewController = container
        defer { window.rootViewController = previous }
        let call = SystemCallCoordinator()
        let rtcAudio = LKRTCAudioSession.sharedInstance()
        let previousManual = rtcAudio.useManualAudio, previousEnabled = rtcAudio.isAudioEnabled
        let engine = TelemostCallEngine(systemCall: call, catchUp: CatchUpStore(storageURL: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)), chat: ChatStore())
        var readyCount = 0, ended = false
        engine.onEvent = { event in switch event { case .active: readyCount += 1; case .left, .failed: ended = true; default: break } }
        try engine.join(target: TelemostTarget.parse(invitation), name: "Telemost Native QA", container: container, quiet: false)
        do {
            try await wait { readyCount >= 1 || ended }
            XCTAssertFalse(ended)
            var evidence = await waitForMedia(engine)
            XCTAssertGreaterThan(evidence.videoFrames, 0)
            XCTAssertGreaterThan(evidence.audioDuration, 0)
            XCTAssertGreaterThan(evidence.audioEnergy, 0)
            // The former resource deadline silently killed healthy sockets at 20s.
            try await Task.sleep(for: .seconds(23))
            XCTAssertEqual(readyCount, 1, "A healthy established socket must not reconnect on a resource timer")
            let sustained = await engine.receiveEvidenceForTesting()
            XCTAssertGreaterThan(sustained.videoFrames, evidence.videoFrames)
            XCTAssertGreaterThan(sustained.audioDuration, evidence.audioDuration)
            #if !targetEnvironment(simulator)
            let readyBeforeHold = readyCount
            try await engine.setTransferHeld(true, restoreSending: true)
            try await wait { !rtcAudio.isAudioEnabled && !call.canRestoreAudio }
            XCTAssertFalse(ended, "System hold must keep the meeting alive")
            try await Task.sleep(for: .seconds(4))
            try await engine.setTransferHeld(false, restoreSending: true)
            try await wait { call.canRestoreAudio && readyCount > readyBeforeHold || ended }
            XCTAssertFalse(ended)
            evidence = await waitForMedia(engine)
            XCTAssertGreaterThanOrEqual(evidence.videoFrames, 10, "Presentation must resume after CallKit hold")
            XCTAssertGreaterThan(evidence.audioEnergy, 0, "Decoded audio must resume after CallKit hold")
            print("Physical native media: CallKit hold/resume restored audio and video")
            #endif
            let readyBeforeRecovery = readyCount
            engine.interruptForTesting()
            try await wait { readyCount > readyBeforeRecovery || ended }
            XCTAssertFalse(ended)
            evidence = await waitForMedia(engine)
            XCTAssertGreaterThan(evidence.videoFrames, 0)
            XCTAssertGreaterThan(evidence.audioEnergy, 0)
        } catch { engine.leave(); throw error }
        engine.leave(); try await wait { ended }
        XCTAssertFalse(engine.hasJoinStarted)
        XCTAssertEqual(rtcAudio.useManualAudio, previousManual)
        XCTAssertEqual(rtcAudio.isAudioEnabled, previousEnabled)
    }
    private func waitForMedia(_ engine: TelemostCallEngine) async -> TelemostCallEngine.ReceiveEvidence {
        let deadline = Date().addingTimeInterval(12)
        var evidence = await engine.receiveEvidenceForTesting()
        while Date() < deadline, evidence.videoFrames < 10 || evidence.audioDuration == 0 || evidence.audioEnergy == 0 {
            try? await Task.sleep(for: .milliseconds(200))
            evidence = await engine.receiveEvidenceForTesting()
        }
        return evidence
    }
    private func wait(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(25)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(condition(), "Live connection did not reach its required state")
        if !condition() { throw TelemostError.timedOut }
    }
    private func bootstrap(_ changes: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["connection_type": "CONFERENCE", "media_platform": "GOLOOM",
            "room_id": "room", "peer_id": "peer", "credentials": "test-credential",
            "client_configuration": ["media_server_url": "wss://goloom.strm.yandex.net/join", "service_name": "telemost"]]
        value.merge(changes) { _, new in new }
        return try JSONSerialization.data(withJSONObject: value)
    }
    func testBootstrapKeepsAdmissionAndUnsupportedProtocolDistinct() throws {
        let value = try TelemostBootstrap.decode(bootstrap())
        XCTAssertEqual(value.participantID, "peer")
        XCTAssertThrowsError(try TelemostBootstrap.decode(bootstrap(["connection_type": "WAITING_ROOM"]))) {
            guard case TelemostError.admissionRequired = $0 else { return XCTFail("Admission must not be retried as a network outage") }
        }
        XCTAssertThrowsError(try TelemostBootstrap.decode(bootstrap(["media_platform": "OTHER"]))) {
            guard case TelemostError.incompatibleProtocol = $0 else { return XCTFail("Unsupported transport") }
        }
    }
    func testBootstrapRejectsCredentialExposureAndMalformedResponse() throws {
        for server in ["ws://goloom.strm.yandex.net/join", "wss://goloom.strm.yandex.net.attacker.test/join", "wss://user:password@goloom.strm.yandex.net/join"] {
            XCTAssertThrowsError(try TelemostBootstrap.decode(bootstrap(["client_configuration": ["media_server_url": server, "service_name": "telemost"]])))
        }
        XCTAssertThrowsError(try TelemostBootstrap.decode(bootstrap(["credentials": ""])))
        XCTAssertThrowsError(try TelemostBootstrap.decode(Data("[]".utf8)))
    }
    func testHostRemovalAndMeetingEndDoNotTriggerRejoin() {
        for code in [4004, 4009, 4000, 4002, 4003, 4005] {
            let value = TelemostError.socketFailure(code: code, underlying: URLError(.networkConnectionLost)) as? TelemostError
            XCTAssertEqual(value?.isRetryable, false)
        }
        XCTAssertTrue(TelemostError.disconnected.isRetryable)
        XCTAssertTrue(TelemostError.requestFailed(503).isRetryable)
        XCTAssertFalse(TelemostError.requestFailed(403).isRetryable)
    }
    func testRealSDPMapsReceivedTrackToItsMid() async throws {
        let factory = try TelemostPeer.makeFactory()
        let config = LKRTCConfiguration(); config.sdpSemantics = .unifiedPlan
        let sender = try XCTUnwrap(factory.peerConnection(with: config, constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        defer { sender.close() }
        let track = factory.videoTrack(with: factory.videoSource(), trackId: "test-camera")
        let settings = LKRTCRtpTransceiverInit(); settings.direction = .sendOnly
        sender.addTransceiver(with: track, init: settings)
        let offer: LKRTCSessionDescription = try await withCheckedThrowingContinuation { completion in
            sender.offer(for: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)) { value, error in
                if let value { completion.resume(returning: value) } else { completion.resume(throwing: error ?? TelemostError.invalidResponse) }
            }
        }
        let received = expectation(description: "MID available after remote SDP")
        received.assertForOverFulfill = false
        let receiver = TelemostPeer(target: "SUBSCRIBER", factory: factory, ice: [])
        receiver.onTrack = { mid, video in
            XCTAssertFalse(mid.isEmpty); XCTAssertEqual(video.kind, "video"); received.fulfill()
        }
        _ = try await receiver.answer(["sdp": offer.sdp, "pcSeq": 1])
        await fulfillment(of: [received], timeout: 2)
        await receiver.close()
    }
    private func pixels(width: Int = 8, height: Int = 8) throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &result), kCVReturnSuccess)
        let value = try XCTUnwrap(result)
        CVPixelBufferLockBaseAddress(value, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(value, plane), plane == 0 ? 64 : 128,
                CVPixelBufferGetBytesPerRowOfPlane(value, plane) * CVPixelBufferGetHeightOfPlane(value, plane))
        }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
    func testNativeFrameIsZeroCopyAndCroppedFrameIsNotFullSized() throws {
        let original = try pixels()
        let converter = NativeVideoPixelBuffer()
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: original), rotation: ._0, timeStampNs: 0)
        XCTAssertTrue(try XCTUnwrap(converter.convert(frame)) === original)
        let crop = LKRTCCVPixelBuffer(pixelBuffer: original, adaptedWidth: 4, adaptedHeight: 4, cropWidth: 4, cropHeight: 4, cropX: 2, cropY: 2)
        let result = try XCTUnwrap(converter.convert(.init(buffer: crop, rotation: ._0, timeStampNs: 1)))
        XCTAssertEqual(CVPixelBufferGetWidth(result), 4); XCTAssertEqual(CVPixelBufferGetHeight(result), 4)
        CVPixelBufferLockBaseAddress(result, .readOnly); defer { CVPixelBufferUnlockBaseAddress(result, .readOnly) }
        XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(result, 0)?.assumingMemoryBound(to: UInt8.self).pointee, 64)
        XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(result, 1)?.assumingMemoryBound(to: UInt8.self).pointee, 128)
    }
    func testRetiredNativeRendererRejectsLateFrame() async throws {
        let delivered = expectation(description: "First native frame")
        let forbidden = expectation(description: "No late frame"); forbidden.isInverted = true
        var ended = false
        let sink = RoomFloatingVideoSink { sample, _ in
            XCTAssertNotNil(CMSampleBufferGetImageBuffer(sample))
            if ended { forbidden.fulfill() } else { delivered.fulfill() }
        }
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: try pixels()), rotation: ._0, timeStampNs: 0)
        sink.renderFrame(frame)
        await fulfillment(of: [delivered], timeout: 2)
        ended = true; sink.retire(); sink.renderFrame(frame)
        await fulfillment(of: [forbidden], timeout: 0.2)
    }
}
