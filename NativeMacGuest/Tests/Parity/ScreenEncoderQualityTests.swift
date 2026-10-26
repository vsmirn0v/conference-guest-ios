import CoreVideo
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

final class ScreenEncoderQualityTests: XCTestCase {
    override func setUp() { super.setUp(); _ = LKRTCInitializeSSL(); NativeScreenEncoderQuality.prepare() }
    func testFactoryPreservesCodecsCapabilitiesAndVP9Encoder() throws {
        let base: any LKRTCVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory()
        let factory: any LKRTCVideoEncoderFactory = LKRTCDefaultVideoEncoderFactory()
        XCTAssertEqual(factory.supportedCodecs(), base.supportedCodecs())
        XCTAssertEqual(factory.implementations?(), base.implementations?())
        for codec in base.supportedCodecs() {
            let encoder = try XCTUnwrap(factory.createEncoder(codec))
            XCTAssertEqual(encoder is NativeScreenH264Encoder, codec.name == "H264")
            let support = factory.queryCodecSupport?(codec, scalabilityMode: nil)
            let original = base.queryCodecSupport?(codec, scalabilityMode: nil)
            XCTAssertEqual(support?.isSupported, original?.isSupported)
            XCTAssertEqual(support?.isPowerEfficient, original?.isPowerEfficient)
        }
    }

    func testCameraAndFailedStartKeepOriginalEncoderBehavior() throws {
        let base = EncoderSpy(), encoder = NativeScreenH264Encoder(base: base)
        let settings = settings(mode: .realtimeVideo)
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 3), 0)
        XCTAssertTrue(base.settings === settings)
        XCTAssertEqual(base.cores, 3)
        XCTAssertFalse(encoder.screenQualityConfigured)
        XCTAssertEqual(encoder.setBitrate(750, framerate: 15), 17)
        XCTAssertEqual(base.rate, [750, 15])
        XCTAssertEqual(encoder.implementationName(), base.implementationName())
        XCTAssertEqual(encoder.resolutionAlignment, base.resolutionAlignment)
        XCTAssertEqual(encoder.applyAlignmentToAllSimulcastLayers, base.applyAlignmentToAllSimulcastLayers)
        XCTAssertEqual(encoder.supportsNativeHandle, base.supportsNativeHandle)
        let frame = try frame()
        XCTAssertEqual(encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [0]), 19)
        XCTAssertTrue(base.frame === frame)
        XCTAssertEqual(encoder.release(), 23)
        settings.mode = .screensharing; base.startResult = -7
        XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 1), -7)
        XCTAssertFalse(encoder.screenQualityConfigured)
    }

    func testHardwareScreenPresetSurvivesRestartAndBudgetChanges() async throws {
        let factory = LKRTCDefaultVideoEncoderFactory()
        let codec = LKRTCVideoCodecInfo(name: "H264", parameters: ["profile-level-id": "42e034", "packetization-mode": "1"])
        let encoder = try XCTUnwrap(factory.createEncoder(codec) as? NativeScreenH264Encoder)
        defer { _ = encoder.release() }
        for cycle in 0..<2 {
            XCTAssertEqual(encoder.startEncode(with: settings(mode: .screensharing), numberOfCores: 2), 0)
            XCTAssertTrue(encoder.screenQualityConfigured, "Real H264 screen encoders must accept the detail preset")
            for (step, rate) in [(1500, 15), (20, 5), (1500, 15)].enumerated() {
                XCTAssertEqual(encoder.setBitrate(UInt32(rate.0), framerate: UInt32(rate.1)), 0)
                let delivered = expectation(description: "Screen callback \(cycle)/\(step)")
                delivered.assertForOverFulfill = false
                encoder.setCallback { _, _ in delivered.fulfill(); return true }
                let stamp = Int64(cycle * 3 + step + 1) * 1_000_000_000
                XCTAssertEqual(encoder.encode(try frame(stamp: stamp), codecSpecificInfo: nil,
                    frameTypes: [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue)]), 0)
                await fulfillment(of: [delivered], timeout: 5)
                // Encode first: low-budget transitions recreate the VT session lazily.
                let current = try rates(encoder.base)
                XCTAssertEqual(current[0], UInt32(rate.0 * 1000))
                XCTAssertEqual(current[1], UInt32(rate.1))
                XCTAssertEqual(current[2] * 8, current[0] * 3 / 2)
                XCTAssertEqual(current[3], 1)
            }
            XCTAssertEqual(encoder.release(), 0)
            XCTAssertFalse(encoder.screenQualityConfigured)
        }
        XCTAssertEqual(encoder.startEncode(with: settings(mode: .realtimeVideo), numberOfCores: 2), 0)
        XCTAssertFalse(encoder.screenQualityConfigured, "A reused H264 leaf must not apply screen settings to camera video")
    }

    @MainActor func testOnlyH264ScreenSenderPreservesResolutionAcrossUpdates() throws {
        let audio = GuestSyntheticAudio(); defer { XCTAssertTrue(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        for codec in ["h264", "vp9"] {
            let peer = try GuestPeer(target: .publisher, factory: factory); defer { peer.close() }
            let track = peer.prepareScreenVideo(cid: UUID().uuidString, profile: .init(width: 1920, height: 1080, fps: 30, maximumBitrate: 18_000_000))
            try peer.attachScreenVideo(track, codec: codec)
            let sender = try XCTUnwrap(peer.connection.senders.first { $0.track?.trackId == track.trackId })
            let expected: NSNumber? = codec == "h264" ? NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue) : nil
            XCTAssertEqual(sender.parameters.degradationPreference, expected)
            peer.updateScreenProfile(.init(width: 2560, height: 1440, fps: 30, maximumBitrate: 18_000_000))
            try peer.setScreenMuted(false); try peer.setScreenMuted(true)
            XCTAssertEqual(sender.parameters.degradationPreference, expected)
            XCTAssertEqual(sender.parameters.encodings.first?.scaleResolutionDownBy, 1)
        }
    }

    @MainActor func testExternalScreenSendersPreserveResolutionInBothTopologies() async throws {
        let audio = GuestSyntheticAudio(); defer { XCTAssertTrue(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        for topology in [NativeDesktopRTCPeer.Topology.split, .composite] {
            let peer = try NativeDesktopRTCPeer(target: "PUBLISHER", factory: factory, ice: [], topology: topology)
            let source = factory.videoSource(forScreenCast: true)
            let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
            try peer.setScreenTrack(track)
            let sender = try XCTUnwrap(peer.connection.senders.first { $0.track?.trackId == track.trackId })
            XCTAssertEqual(sender.parameters.degradationPreference, NSNumber(value: LKRTCDegradationPreference.maintainResolution.rawValue))
            XCTAssertEqual(sender.parameters.encodings.first?.maxBitrateBps, 18_000_000)
            try peer.setScreenTrack(nil)
            let closed = await peer.close(); XCTAssertTrue(closed)
        }
    }

    private func settings(mode: LKRTCVideoCodecMode) -> LKRTCVideoEncoderSettings {
        let value = LKRTCVideoEncoderSettings()
        value.name = "H264"; value.mode = mode; value.qpMax = 51
        value.width = 1280; value.height = 720; value.maxFramerate = 15
        value.startBitrate = 1_500; value.maxBitrate = 2_500; value.minBitrate = 1
        return value
    }
    private func frame(stamp: Int64 = 1_000_000_000) throws -> LKRTCVideoFrame {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        memset(CVPixelBufferGetBaseAddress(buffer), 127, CVPixelBufferGetDataSize(buffer))
        return LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: ._0, timeStampNs: stamp)
    }
    private func rates(_ encoder: any LKRTCVideoEncoder) throws -> [UInt32] {
        var values = [UInt32](repeating: 0, count: 8)
        let count = values.withUnsafeMutableBufferPointer {
            LKRTCGetScreenShareEncoderRates(Unmanaged.passUnretained(encoder as AnyObject).toOpaque(), $0.baseAddress!, 8)
        }
        guard count >= 4, count <= 8, count % 2 == 0 else { throw NSError(domain: "Screen rates", code: 1) }
        for index in stride(from: 2, to: Int(count), by: 2) {
            XCTAssertGreaterThan(values[index], 0); XCTAssertGreaterThan(values[index + 1], 0)
        }
        return Array(values.prefix(Int(count)))
    }
}

private final class EncoderSpy: NSObject, LKRTCVideoEncoder {
    var startResult = 0, cores: Int32 = 0
    var settings: LKRTCVideoEncoderSettings?, frame: LKRTCVideoFrame?
    var rate: [UInt32] = []
    func setCallback(_ callback: LKRTCVideoEncoderCallback?) {}
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        self.settings = settings; cores = numberOfCores; return startResult
    }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int { self.frame = frame; return 19 }
    func release() -> Int { 23 }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { rate = [bitrateKbit, framerate]; return 17 }
    func implementationName() -> String { "Spy" }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 16 }
    var applyAlignmentToAllSimulcastLayers: Bool { true }
    var supportsNativeHandle: Bool { false }
}
