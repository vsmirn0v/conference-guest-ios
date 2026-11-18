import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import VideoToolbox
import XCTest
@testable import RockNRoll

@MainActor
final class TelemostTests: XCTestCase {
    func testPhysicalVideoToolboxCapabilities() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Hardware capability query requires a physical device")
        #else
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] != nil else { throw XCTSkip("Opt-in hardware experiment") }
        if #available(iOS 26.2, *) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) }
        var list: CFArray?
        XCTAssertEqual(VTCopyVideoEncoderList(nil, &list), noErr)
        let encoders = (list as? [[String: Any]] ?? []).map { entry in
            entry.filter { ["CodecType", "CodecName", "EncoderName", "IsHardwareAccelerated"].contains($0.key) }
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "encoders": encoders,
            "h264HWDecode": VTIsHardwareDecodeSupported(kCMVideoCodecType_H264),
            "hevcHWDecode": VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC),
            "vp9HWDecode": VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        ], options: .sortedKeys)
        print("TELEMOST_VT_CAPABILITIES " + String(decoding: data, as: UTF8.self))
        #endif
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
