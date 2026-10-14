import XCTest
import Darwin
import CoreVideo
import WebRTC
@testable import RockNRoll

final class GuestScreenSharePolicyTests: XCTestCase {
    func testAtomicBindingBeforeSDPRejectsReplacedTrack() throws {
        let factory = RTCPeerConnectionFactory()
        let peer = try XCTUnwrap(factory.peerConnection(with: RTCConfiguration(),
            constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil))
        defer { peer.close() }
        let firstID = "early-" + UUID().uuidString, secondID = "replacement-" + UUID().uuidString
        let source = factory.videoSource(forScreenCast: true)
        let sender = try XCTUnwrap(peer.add(factory.videoTrack(with: source, trackId: firstID), streamIds: ["detail"]))
        XCTAssertTrue(GuestScreenSharePolicy.applyNative(to: sender, trackID: firstID))
        sender.track = factory.videoTrack(with: source, trackId: secondID)
        XCTAssertFalse(GuestScreenSharePolicy.applyNative(to: sender, trackID: firstID))
        XCTAssertTrue(GuestScreenSharePolicy.applyNative(to: sender, trackID: secondID))
    }
    func testNativeBindingPreservesOutstandingSDKTransactionAndEncodingEdits() async throws {
        guard dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCSetScreenShareSenderResolution") != nil else {
            XCTFail("The selected native component must support atomic sender binding"); return
        }
        GuestPeerRegistry.prepare(); GuestScreenSharePolicy.prepare()
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = RTCPeerConnectionFactory()
        let peer = try XCTUnwrap(factory.peerConnection(with: RTCConfiguration(), constraints: constraints, delegate: nil))
        defer { peer.close() }
        let id = "transaction-" + UUID().uuidString, generation = UUID()
        let sender = try XCTUnwrap(peer.add(factory.videoTrack(with: factory.videoSource(forScreenCast: true), trackId: id), streamIds: ["detail"]))
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
        let policy = GuestScreenSharePolicy.shared
        policy.begin(generation); defer { policy.end(generation) }
        policy.register(id, generation: generation)
        let sdkSnapshot = sender.parameters
        XCTAssertTrue(GuestScreenSharePolicy.applyNative(to: sender, trackID: id))
        XCTAssertTrue(GuestScreenSharePolicy.applyNative(to: sender, trackID: id), "Repeated binding cannot invalidate the SDK snapshot")
        XCTAssertFalse(GuestScreenSharePolicy.applyNative(to: sender, trackID: "replaced"))
        // No public getter between SDK get and set: it would invalidate this
        // very transaction and conceal the behavior being qualified.
        let layer = try XCTUnwrap(sdkSnapshot.encodings.first)
        layer.maxBitrateBps = 533_000; layer.maxFramerate = 7; layer.isActive = false
        sdkSnapshot.degradationPreference = NSNumber(value: RTCDegradationPreference.balanced.rawValue)
        sender.parameters = sdkSnapshot
        let actual = sender.parameters
        XCTAssertEqual(actual.encodings.first?.maxBitrateBps, 533_000)
        XCTAssertEqual(actual.encodings.first?.maxFramerate, 7)
        XCTAssertEqual(actual.encodings.first?.isActive, false)
        XCTAssertEqual(actual.degradationPreference?.intValue, RTCDegradationPreference.maintainResolution.rawValue)
        let audio = try XCTUnwrap(peer.add(factory.audioTrack(withTrackId: "audio-" + UUID().uuidString), streamIds: ["detail"]))
        XCTAssertFalse(GuestScreenSharePolicy.applyNative(to: audio, trackID: audio.track!.trackId))
        peer.close()
        XCTAssertFalse(GuestScreenSharePolicy.applyNative(to: sender, trackID: id))
    }
    func testRecreatedHardwareSessionRetainsActualBitrateAndFrameRateControls() throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              let configureSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCConfigureScreenShareEncoderQuality"),
              let ratesSymbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCGetScreenShareEncoderRates") else {
            throw XCTSkip("Mac hardware-session rate qualification")
        }
        let configure = unsafeBitCast(configureSymbol, to: GuestScreenEncoderQuality.Configure.self)
        typealias Rates = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>, Int32) -> Int32
        let read = unsafeBitCast(ratesSymbol, to: Rates.self)
        let encoder = RTCVideoEncoderH264(codecInfo: RTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "42e034", "packetization-mode": "1"]))
        encoder.setCallback { _, _ in true }; defer { _ = encoder.release() }
        let settings = RTCVideoEncoderSettings()
        settings.name = "H264"; settings.qpMax = 51; settings.mode = .screensharing
        settings.width = 1280; settings.height = 720; settings.maxFramerate = 5
        settings.startBitrate = 1_500; settings.maxBitrate = 2_500; settings.minBitrate = 1
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
        let pointer = Unmanaged.passUnretained(encoder).toOpaque()
        XCTAssertEqual(configure(pointer, 24, 0), 1)
        func rates() -> [UInt32] {
            var values = [UInt32](repeating: 0, count: 8)
            let written = values.withUnsafeMutableBufferPointer { read(pointer, $0.baseAddress!, 8) }
            XCTAssertGreaterThanOrEqual(written, 4)
            return Array(values.prefix(Int(max(0, written))))
        }
        let initial = rates()
        guard initial.count == 6, initial[3] > 0, initial[5] > 0 else { XCTFail("VBR must expose peak and long-term rate limit pairs"); return }
        XCTAssertEqual(initial[0], 1_500_000); XCTAssertEqual(initial[1], 5); XCTAssertGreaterThan(initial[2], 0)
        XCTAssertEqual(initial[4] * 8 / initial[5], initial[0], "The long-term data limit must match the requested average rate")
        var stamp: Int64 = 0
        func encode() throws {
            var pixels: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
            stamp += 200_000_000
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: try XCTUnwrap(pixels)), rotation: ._0, timeStampNs: stamp)
            XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: []), 0)
        }
        try encode()  // NV12 -> BGRA recreates the hardware session at the same rate.
        XCTAssertEqual(rates(), initial)
        XCTAssertEqual(encoder.setBitrate(20, framerate: 5), 0)
        try encode(); try encode()  // Cross the budget threshold and recreate.
        let constrained = rates()
        guard constrained.count == 6, constrained[3] > 0, constrained[5] > 0 else { XCTFail("Recreated VBR rate properties are missing"); return }
        XCTAssertEqual(constrained[0], 20_000); XCTAssertEqual(constrained[1], 5)
        XCTAssertEqual(constrained[4] * 8 / constrained[5], constrained[0])
        XCTAssertGreaterThan(constrained[2], 0); XCTAssertLessThan(constrained[2], initial[2])
        XCTAssertEqual(encoder.setBitrate(1_500, framerate: 5), 0)
        try encode(); try encode()
        XCTAssertEqual(rates(), initial, "Restored session must apply the same requested rate before its first frame")
    }
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
