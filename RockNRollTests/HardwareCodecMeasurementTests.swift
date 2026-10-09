#if DEBUG
import CoreImage
import LiveKitWebRTC
import ObjectiveC
import VideoToolbox
import WebRTC
import XCTest
@testable import RockNRoll

/// Explicitly opted-in physical qualification. Each paced measurement stays below a minute.
@MainActor final class HardwareCodecMeasurementTests: XCTestCase {
    func testVP9HardwareHDPixelOracle() throws {
        guard VP9HardwareDecoder.available else { throw XCTSkip("Physical hardware VP9 required") }
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "vp9-hd-measurement", withExtension: "json"))
        let fixture = try XCTUnwrap(JSONDecoder().decode([VP9Fixture].self, from: Data(contentsOf: url)).first)
        let decoder = VP9HardwareDecoder(), quality = MeasurementState()
        XCTAssertEqual(decoder.startDecode(withNumberOfCores: 2), 0)
        defer { _ = decoder.release() }
        decoder.setCallback { quality.hash(VP9Fixture.digest($0)) }
        for (index, frame) in fixture.frames.enumerated() {
            XCTAssertEqual(decoder.decode(frame.image(timestamp: UInt32(index * 3000)), missingFrames: false, codecSpecificInfo: nil, renderTimeMs: 0), 0)
        }
        XCTAssertEqual(quality.hashes, fixture.frames.map(\.sha256))
        XCTAssertEqual(decoder.evidenceForTesting["verifiedHardwareSession"] as? Bool, true)
        print("VP9_HD_ORACLE size=1280x720 exact=\(quality.hashes.count) hardware=true")
    }

    func testGuestAndNativePresenterEncodedColorOracle() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical VideoToolbox qualification required")
        #endif
        guard ProcessInfo.processInfo.environment["ROCKNROLL_MEASURE_COLOR"] == "1" else { throw XCTSkip("Opt-in independent color oracle") }
        _ = LKRTCInitializeSSL(); RTCInitializeSSL(); NativeH264ColorEncoder.prepare()
        var reports: [[String: Any]] = []
        for family in ["native", "guest"] {
            for bgra in [false, true] {
                for cropped in [false, true] {
                    reports.append(try await encodeColors(family: family, bgra: bgra, cropped: cropped))
                }
            }
        }
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codec-color-oracle.json")
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]).write(to: output)
        print("CODEC_COLOR_ORACLE exported=\(reports.count) path=\(output.lastPathComponent)")
    }

    func testAttachmentFreeBGRADefaultMatrixContract() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical VideoToolbox qualification required")
        #endif
        guard ProcessInfo.processInfo.environment["ROCKNROLL_MEASURE_COLOR"] == "1" else { throw XCTSkip("Opt-in independent color oracle") }
        _ = LKRTCInitializeSSL(); RTCInitializeSSL(); NativeH264ColorEncoder.prepare()
        var reports: [[String: Any]] = []
        for family in ["native", "guest"] {
            for size in [(320, 240), (1280, 720), (1920, 1080)] {
                for cropped in [false, true] {
                    reports.append(try await encodeColors(family: family, bgra: true, cropped: cropped,
                        width: size.0, height: size.1, qualified: false))
                }
            }
            reports.append(try await encodeColors(family: family, bgra: true, cropped: false,
                qualified: false, scaled: true))
        }
        let output = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("codec-untagged-color-oracle.json")
        try JSONSerialization.data(withJSONObject: reports, options: [.sortedKeys]).write(to: output)
        print("CODEC_UNTAGGED_COLOR_ORACLE exported=\(reports.count)")
    }

    private func encodeColors(family: String, bgra: Bool, cropped: Bool, width: Int = 320, height: Int = 240, qualified: Bool = true, scaled: Bool = false) async throws -> [String: Any] {
        let pixels = try pattern(bgra: bgra, cropped: cropped, width: scaled ? width * 2 : width, height: scaled ? height * 2 : height, qualified: qualified)
        let state = MeasurementState()
        let info = ["profile-level-id": "42e029", "packetization-mode": "1"]
        var send: (Int) -> Int, release: () -> Int, object: NSObject
        if family == "guest" {
            let base = try XCTUnwrap(RTCDefaultVideoEncoderFactory().createEncoder(RTCVideoCodecInfo(name: "H264", parameters: info)))
            let encoder = GuestH264ColorEncoder(base: base)
            encoder.setCallback { image, _ in state.packet(image.buffer, timestamp: image.timeStamp); return true }
            let settings = RTCVideoEncoderSettings(); settings.name = "H264"; settings.width = UInt16(width); settings.height = UInt16(height)
            settings.startBitrate = 2000; settings.maxBitrate = 2000; settings.minBitrate = 200; settings.maxFramerate = 30; settings.qpMax = 56
            XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
            let input = cropped || scaled ? RTCCVPixelBuffer(pixelBuffer: pixels, adaptedWidth: Int32(width), adaptedHeight: Int32(height),
                cropWidth: Int32(scaled ? width * 2 : width), cropHeight: Int32(scaled ? height * 2 : height), cropX: Int32(cropped ? width / 2 : 0), cropY: Int32(cropped ? height / 2 : 0)) : RTCCVPixelBuffer(pixelBuffer: pixels)
            send = { index in
                let frame = RTCVideoFrame(buffer: input, rotation: ._0, timeStampNs: Int64(index + 1) * 33_333_333)
                frame.timeStamp = Int32((index + 1) * 3000)
                return encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: index == 0 ? RTCFrameType.videoFrameKey.rawValue : RTCFrameType.videoFrameDelta.rawValue)])
            }
            release = { encoder.release() }; object = try XCTUnwrap(base as? NSObject)
        } else {
            let encoder = try XCTUnwrap(LKRTCDefaultVideoEncoderFactory().createEncoder(LKRTCVideoCodecInfo(name: "H264", parameters: info)))
            encoder.setCallback { image, _ in state.packet(image.buffer, timestamp: image.timeStamp); return true }
            let settings = LKRTCVideoEncoderSettings(); settings.name = "H264"; settings.width = UInt16(width); settings.height = UInt16(height)
            settings.startBitrate = 2000; settings.maxBitrate = 2000; settings.minBitrate = 200; settings.maxFramerate = 30; settings.qpMax = 56
            XCTAssertEqual(encoder.startEncode(with: settings, numberOfCores: 2), 0)
            let input = cropped || scaled ? LKRTCCVPixelBuffer(pixelBuffer: pixels, adaptedWidth: Int32(width), adaptedHeight: Int32(height),
                cropWidth: Int32(scaled ? width * 2 : width), cropHeight: Int32(scaled ? height * 2 : height), cropX: Int32(cropped ? width / 2 : 0), cropY: Int32(cropped ? height / 2 : 0)) : LKRTCCVPixelBuffer(pixelBuffer: pixels)
            send = { index in
                let frame = LKRTCVideoFrame(buffer: input, rotation: ._0, timeStampNs: Int64(index + 1) * 33_333_333)
                frame.timeStamp = Int32((index + 1) * 3000)
                return encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: index == 0 ? LKRTCFrameType.videoFrameKey.rawValue : LKRTCFrameType.videoFrameDelta.rawValue)])
            }
            release = { encoder.release() }
            object = try XCTUnwrap(((encoder as? NativeH264ColorEncoder)?.base ?? encoder) as? NSObject)
        }
        defer { _ = release() }
        for index in 0..<24 { XCTAssertEqual(send(index), 0); try await Task.sleep(for: .milliseconds(35)) }
        try await Task.sleep(for: .milliseconds(200))
        // Diagnostic-only session inspection while this fixed-size encoder is idle.
        let hardware = try hardwareEncoder(object)
        XCTAssertTrue(hardware)
        let context = CIContext(), image = CIImage(cvPixelBuffer: pixels).transformed(by: CGAffineTransform(scaleX: scaled ? 0.5 : 1, y: scaled ? 0.5 : 1))
        let bounds = CGRect(x: cropped ? width / 2 : 0, y: cropped ? height / 2 : 0, width: width, height: height)
        let reference = try XCTUnwrap(context.createCGImage(image, from: bounds, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!))
        let png = try XCTUnwrap(UIImage(cgImage: reference).pngData())
        XCTAssertGreaterThan(state.frames, 10)
        print("CODEC_COLOR family=\(family) bgra=\(bgra) cropped=\(cropped) hardware=\(hardware) frames=\(state.frames)")
        return ["family": family, "bgra": bgra, "cropped": cropped, "hardware": hardware,
            "qualified": qualified, "scaled": scaled, "reference_png": png.base64EncodedString(), "packets": state.packets]
    }

    private func hardwareEncoder(_ encoder: NSObject) throws -> Bool {
        guard #available(iOS 17.4, *) else { throw XCTSkip("Hardware session property requires iOS 17.4") }
        let field = try XCTUnwrap(class_getInstanceVariable(type(of: encoder), "_compressionSession"))
        XCTAssertTrue(String(cString: ivar_getTypeEncoding(field)!).hasPrefix("^"))
        let address = try XCTUnwrap(UnsafeRawPointer(Unmanaged.passUnretained(encoder).toOpaque())
            .advanced(by: ivar_getOffset(field)).load(as: UnsafeRawPointer?.self))
        let session = Unmanaged<VTCompressionSession>.fromOpaque(address).takeUnretainedValue()
        var value: Unmanaged<CFTypeRef>?
        XCTAssertEqual(VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
            allocator: nil, valueOut: &value), noErr)
        return (value?.takeRetainedValue() as? NSNumber)?.boolValue == true
    }

    private func pattern(bgra: Bool, cropped: Bool, width logicalWidth: Int, height logicalHeight: Int, qualified: Bool) throws -> CVPixelBuffer {
        let width = cropped ? logicalWidth * 2 : logicalWidth, height = cropped ? logicalHeight * 2 : logicalHeight
        var output: CVPixelBuffer?
        let format = bgra ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &output), kCVReturnSuccess)
        let pixels = try XCTUnwrap(output)
        CVPixelBufferLockBaseAddress(pixels, [])
        if bgra {
            let data = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(pixels)
            let colors: [(UInt8, UInt8, UInt8)] = [(230, 32, 32), (32, 230, 32), (32, 32, 230), (230, 230, 32), (32, 230, 230), (230, 32, 230), (0, 0, 0), (255, 255, 255)]
            for y in 0..<height { for x in 0..<width {
                let px = (x - (cropped ? logicalWidth / 2 : 0) + logicalWidth) % logicalWidth, py = (y - (cropped ? logicalHeight / 2 : 0) + logicalHeight) % logicalHeight
                let rgb = py < logicalHeight / 2 ? colors[min(7, px * 8 / logicalWidth)] : (UInt8(px * 255 / (logicalWidth - 1)), UInt8(px * 255 / (logicalWidth - 1)), UInt8(px * 255 / (logicalWidth - 1)))
                let offset = y * stride + x * 4
                data[offset] = rgb.2; data[offset + 1] = rgb.1; data[offset + 2] = rgb.0; data[offset + 3] = 255
            } }
        } else {
            memset(CVPixelBufferGetBaseAddressOfPlane(pixels, 0), 80, CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) * height)
            let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
            for y in 0..<height / 2 { for x in 0..<width / 2 { uv[y * stride + x * 2] = 90; uv[y * stride + x * 2 + 1] = 180 } }
            CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, bgra ? kCVImageBufferTransferFunction_sRGB : kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        if bgra { H264InputColorSignalling.tagPresenter(pixels) }
        if !qualified { CVBufferRemoveAllAttachments(pixels) }
        return pixels
    }


}

private final class MeasurementState: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0, encoded: [[String: Any]] = []
    private var digests: [String] = []
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    var packets: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return encoded }
    var hashes: [String] { lock.lock(); defer { lock.unlock() }; return digests }
    func hash(_ value: String) { lock.lock(); digests.append(value); lock.unlock() }
    func packet(_ data: Data, timestamp: UInt32) {
        lock.lock(); defer { lock.unlock() }
        count += 1; encoded.append(["data": data.base64EncodedString(), "timestamp": timestamp])
    }
}
#endif
