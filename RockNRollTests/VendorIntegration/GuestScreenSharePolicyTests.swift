import XCTest
import Darwin
import WebRTC
@testable import RockNRoll

final class GuestScreenSharePolicyTests: XCTestCase {
    func testLateSenderBindingAndLaterSDKWritesKeepScreenPolicy() async throws {
        GuestPeerRegistry.prepare(); GuestScreenSharePolicy.prepare()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = RTCPeerConnectionFactory()
        let peer = try XCTUnwrap(factory.peerConnection(with: RTCConfiguration(), constraints: constraints, delegate: nil))
        defer { peer.close() }
        let trackID = "screen-" + UUID().uuidString, generation = UUID()
        let policy = GuestScreenSharePolicy.shared
        policy.begin(generation); defer { policy.end(generation) }
        policy.register(trackID, generation: generation)
        // The signaling declaration deliberately precedes public AddTrack.
        try await Task.sleep(for: .milliseconds(250))
        let sender = try XCTUnwrap(peer.add(factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: trackID), streamIds: ["detail"]))
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { completion in
            peer.offer(for: constraints) { description, error in
                if let description { completion.resume(returning: description) }
                else { completion.resume(throwing: error ?? NSError(domain: "ScreenPolicyTest", code: 1)) }
            }
        }
        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { completion.resume(throwing: error) } else { completion.resume() }
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(sender.parameters.degradationPreference?.intValue, RTCDegradationPreference.maintainResolution.rawValue)
        let parameters = sender.parameters
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        sender.parameters = parameters
        XCTAssertEqual(sender.parameters.degradationPreference?.intValue, RTCDegradationPreference.maintainResolution.rawValue)
    }
    func testNativeDetailExtensionRejectsCamerasInvalidLimitsAndReleasedEncoder() throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCConfigureScreenShareEncoderQuality") else {
            throw XCTSkip("Qualified Mac hardware encoder with rebuilt native extension")
        }
        let configure = unsafeBitCast(symbol, to: GuestScreenEncoderQuality.Configure.self)
        let codec = RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "42e034", "level-asymmetry-allowed": "1", "packetization-mode": "1"])
        let encoder = RTCVideoEncoderH264(codecInfo: codec)
        encoder.setCallback { _, _ in true }
        defer { _ = encoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.qpMax = 51
        settings.width = 1280; settings.height = 720; settings.maxFramerate = 15
        settings.startBitrate = 1_500; settings.maxBitrate = 2_500; settings.minBitrate = 100
        settings.mode = .screensharing
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
        let pointer = Unmanaged.passUnretained(encoder as AnyObject).toOpaque()
        XCTAssertEqual(configure(pointer, 0, 0), 0)
        XCTAssertEqual(configure(pointer, 52, 0), 0)
        XCTAssertEqual(configure(pointer, 28, 0), 1)
        _ = encoder.release()
        XCTAssertEqual(configure(pointer, 28, 0), 0)
        settings.mode = .realtimeVideo
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
        XCTAssertEqual(configure(pointer, 28, 0), 0, "Native mode must reject a camera even if the caller asks for screen detail")
    }
    func testOnlyIdentifiedScreenTracksPreserveResolution() {
        let policy = GuestScreenSharePolicy(), generation = UUID()
        policy.begin(generation); policy.register("screen", generation: generation)
        let parameters = RTCRtpParameters()
        parameters.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        XCTAssertFalse(policy.apply(to: parameters, trackID: "camera"))
        XCTAssertEqual(parameters.degradationPreference?.intValue, RTCDegradationPreference.balanced.rawValue)
        XCTAssertTrue(policy.apply(to: parameters, trackID: "screen"))
        XCTAssertEqual(parameters.degradationPreference?.intValue, RTCDegradationPreference.maintainResolution.rawValue)
        XCTAssertFalse(policy.apply(to: parameters, trackID: "screen"), "Repeated writes must be idempotent")
    }
    func testPolicyDoesNotChangeBandwidthLayersOrNetworkPriority() {
        let policy = GuestScreenSharePolicy(), generation = UUID()
        policy.begin(generation); policy.register("screen", generation: generation)
        let parameters = RTCRtpParameters(), layer = RTCRtpEncodingParameters()
        layer.isActive = false; layer.rid = "high"; layer.maxBitrateBps = 1_750_000
        layer.maxFramerate = 5; layer.scaleResolutionDownBy = 2
        parameters.encodings = [layer]
        let transaction = parameters.transactionId
        XCTAssertTrue(policy.apply(to: parameters, trackID: "screen"))
        XCTAssertEqual(parameters.transactionId, transaction)
        XCTAssertEqual(parameters.encodings.count, 1); XCTAssertTrue(parameters.encodings[0] === layer)
        XCTAssertFalse(layer.isActive); XCTAssertEqual(layer.rid, "high")
        XCTAssertEqual(layer.maxBitrateBps, 1_750_000); XCTAssertEqual(layer.maxFramerate, 5)
        XCTAssertEqual(layer.scaleResolutionDownBy, 2)
    }
    func testLateRegistrationAndOldEndCannotAffectReplacement() {
        let policy = GuestScreenSharePolicy(), old = UUID(), next = UUID()
        policy.begin(old); policy.register("old", generation: old)
        policy.begin(next); policy.register("stale", generation: old); policy.register("new", generation: next)
        policy.end(old)
        XCTAssertFalse(policy.apply(to: RTCRtpParameters(), trackID: "old"))
        XCTAssertFalse(policy.apply(to: RTCRtpParameters(), trackID: "stale"))
        XCTAssertTrue(policy.apply(to: RTCRtpParameters(), trackID: "new"))
        policy.end(next)
        XCTAssertFalse(policy.apply(to: RTCRtpParameters(), trackID: "new"))
    }
    func testCameraModeAndOlderNativeComponentKeepWorkingEncoder() {
        let factory = RTCDefaultVideoEncoderFactory()
        for codec in factory.supportedCodecs() where codec.name == "H264" {
            guard let encoder = factory.createEncoder(codec) else { continue }
            XCTAssertFalse(GuestScreenEncoderQuality.apply(to: encoder, mode: .realtimeVideo))
        }
    }
    func testBoundedTrackIdentitiesRejectInvalidInput() {
        let policy = GuestScreenSharePolicy(), generation = UUID()
        policy.begin(generation)
        for id in ["", String(repeating: "x", count: 513)] { policy.register(id, generation: generation) }
        XCTAssertFalse(policy.apply(to: RTCRtpParameters(), trackID: ""))
        for i in 0..<129 { policy.register("screen-\(i)", generation: generation) }
        XCTAssertTrue(policy.apply(to: RTCRtpParameters(), trackID: "screen-127"))
        XCTAssertFalse(policy.apply(to: RTCRtpParameters(), trackID: "screen-128"))
    }
    func testOnlyCurrentJoinedPublisherCanIdentifyScreenTracksIncludingFallback() throws {
        let screens = GuestScreenSharePolicy(), codec = GuestPublishingCodecPolicy(hardwareH264: false, screenPolicy: screens)
        let generation = UUID(), socket = UUID()
        codec.begin(generation: generation, roomID: "room")
        func message(_ event: String, _ payload: [String: Any], room: String = "room") throws -> Data {
            try JSONSerialization.data(withJSONObject: ["event": event, "roomId": room, "payload": payload])
        }
        let publication: [String: Any] = ["addTrackRequest": ["type": "VIDEO", "source": "SCREEN_SHARE", "cid": "screen"]]
        _ = codec.outgoing(socket: socket, data: try message("media-in", publication))
        XCTAssertFalse(screens.apply(to: RTCRtpParameters(), trackID: "screen"))
        _ = codec.outgoing(socket: socket, data: try message("join", ["jazzToken": "", "participantName": "QA"]))
        _ = codec.outgoing(socket: socket, data: try message("media-in", publication, room: "wrong"))
        XCTAssertFalse(screens.apply(to: RTCRtpParameters(), trackID: "screen"))
        XCTAssertNil(codec.outgoing(socket: socket, data: try message("media-in", publication)))
        XCTAssertTrue(screens.apply(to: RTCRtpParameters(), trackID: "screen"))
        codec.disable(generation: generation)
        let replacement: [String: Any] = ["addTrackRequest": ["type": "VIDEO", "source": "SCREEN_SHARE", "cid": "fallback"]]
        XCTAssertNil(codec.outgoing(socket: socket, data: try message("media-in", replacement)))
        XCTAssertTrue(screens.apply(to: RTCRtpParameters(), trackID: "fallback"))
        codec.end(generation: generation)
        XCTAssertFalse(screens.apply(to: RTCRtpParameters(), trackID: "fallback"))
    }
}
