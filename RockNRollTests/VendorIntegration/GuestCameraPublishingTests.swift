import AVFoundation
import WebRTC
import XCTest
@testable import RockNRoll

final class GuestCameraPublishingTests: XCTestCase {
    func testPartialColorDescriptionCompletesOnlyAgreeingFields() {
        let source = Data(base64Encoded: "AAAAASdCAB+rQKD8gA==")!
        let color = H264ColorDescription(primaries: 1, transfer: 13, matrix: 1)
        let partial = H264ColorSignalling.applying(.init(primaries: 1, transfer: 2, matrix: 2), to: source)
        let complete = H264ColorSignalling.applying(color, to: source)
        XCTAssertNotEqual(partial, source)
        XCTAssertEqual(H264ColorSignalling.applying(color, to: partial), complete)
        XCTAssertEqual(H264ColorSignalling.applying(.init(primaries: 2, transfer: 2, matrix: 1), to: partial),
                       H264ColorSignalling.applying(.init(primaries: 1, transfer: 2, matrix: 1), to: source))
        let conflicting = H264ColorSignalling.applying(.init(primaries: 9, transfer: 2, matrix: 2), to: source)
        XCTAssertEqual(H264ColorSignalling.applying(color, to: conflicting), conflicting)
    }
    func testOnlyExplicitlyQualifiedPresenterRGBGetsH264ColorTags() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        XCTAssertNil(H264InputColorSignalling.color(pixels), "An external RGB frame must not inherit the Presenter conversion contract")
        H264InputColorSignalling.tagPresenter(pixels)
        XCTAssertEqual(H264InputColorSignalling.color(pixels), .init(primaries: 1, transfer: 13, matrix: 1))
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        XCTAssertNil(H264InputColorSignalling.color(pixels))
    }
    func testDefaultBGRAAssertsOnlyQualifiedEncoderMatrix() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        XCTAssertNil(H264InputColorSignalling.color(pixels), "Camera qualification must not broaden")
        XCTAssertEqual(H264InputColorSignalling.defaultBGRAMatrix(pixels), .init(primaries: 2, transfer: 2, matrix: 1))
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_P3_D65, .shouldPropagate)
        XCTAssertNil(H264InputColorSignalling.defaultBGRAMatrix(pixels), "Unknown ICC/P3/HDR content must not inherit the default")
    }

    func testIndependentBaselineMainHighFixturesPreservePayloadAndExplicitColor() throws {
        struct Fixture: Decodable { let name: String; let original: Data; let expected: Data }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "h264-color-signalling", withExtension: "json"))
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: file))
        for fixture in fixtures {
            let result = H264ColorSignalling.applying(.init(primaries: 1, transfer: 1, matrix: 1), to: fixture.original)
            XCTAssertEqual(result, fixture.expected, fixture.name)
            XCTAssertEqual(H264ColorSignalling.applying(.init(primaries: 1, transfer: 1, matrix: 1), to: result), result)
        }
    }
    func testTruncatedUnsupportedAndNonParameterSetBytesPassThrough() {
        let original = Data(base64Encoded: "AAAAASdCAB+rQKD8gA==")!
        for count in 0..<original.count {
            let data = Data(original.prefix(count))
            XCTAssertEqual(H264ColorSignalling.applying(.init(primaries: 1, transfer: 1, matrix: 1), to: data), data)
        }
        for data in [Data([0,0,0,1,0x65,1,2,3]), Data([0,0,0,1,0x27,0xff,0,0,3,0xff]), Data([1,2,3])] {
            XCTAssertEqual(H264ColorSignalling.applying(.init(primaries: 1, transfer: 1, matrix: 1), to: data), data)
        }
    }
    func testEncoderRetriesDroppedKeyframesAndKeepsAsynchronousFrameColor() throws {
        let base = TestEncoder(), encoder = GuestH264ColorEncoder(base: base)
        var accept = false
        var received: [Data] = []
        encoder.setCallback { frame, _ in received.append(frame.buffer); return accept }
        let first = try frame(stamp: 100, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let second = try frame(stamp: 200, matrix: kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let delta = [NSNumber(value: RTCFrameType.videoFrameDelta.rawValue)]
        XCTAssertEqual(encoder.encode(first, codecSpecificInfo: nil, frameTypes: delta), 0)
        base.complete(stamp: 100)
        XCTAssertEqual(encoder.encode(first, codecSpecificInfo: nil, frameTypes: delta), 0)
        XCTAssertEqual(base.types.last?.first?.uintValue, RTCFrameType.videoFrameKey.rawValue)
        accept = true; base.complete(stamp: 100)
        _ = encoder.encode(first, codecSpecificInfo: nil, frameTypes: delta)
        XCTAssertEqual(base.types.last, delta)
        _ = encoder.encode(second, codecSpecificInfo: nil, frameTypes: delta)
        // Older asynchronous output must use its own tuple, not the latest input.
        base.complete(stamp: 100); base.complete(stamp: 200)
        let source = Data(base64Encoded: "AAAAASdCAB+rQKD8gA==")!
        XCTAssertEqual(received.suffix(2).first, H264ColorSignalling.applying(.init(primaries: 1, transfer: 1, matrix: 1), to: source))
        XCTAssertEqual(received.last, H264ColorSignalling.applying(.init(primaries: 1, transfer: 1, matrix: 6), to: source))
        _ = encoder.release(); base.complete(stamp: 200)
        XCTAssertEqual(received.count, 4)
    }
    func testCameraDelegatePreservesOriginalMetadataWhenNativeBakeIsUnsupported() throws {
        let receiver = FrameReceiver(), camera = RTCCameraVideoCapturer(delegate: receiver)
        let adapter = GuestCameraFrameDelegate(camera: camera, device: nil, downstream: receiver)
        let source = try frame(stamp: 345, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               ns: 345_000, format: kCVPixelFormatType_32BGRA, width: 32, height: 16)
        XCTAssertNil(GuestH264ColorEncoder.nativeColor(for: source))
        for rotation in [RTCVideoRotation._0, ._90, ._180, ._270] {
            let input = RTCVideoFrame(buffer: source.buffer, rotation: rotation, timeStampNs: source.timeStampNs)
            input.timeStamp = source.timeStamp
            adapter.capturer(camera, didCapture: input)
            let output = try XCTUnwrap(receiver.lastFrame)
            XCTAssertTrue(output === input)
            XCTAssertTrue(output.buffer === input.buffer)
            XCTAssertEqual(output.rotation, rotation)
            XCTAssertEqual(output.width, 32); XCTAssertEqual(output.height, 16)
            XCTAssertEqual(output.timeStampNs, input.timeStampNs)
            XCTAssertEqual(output.timeStamp, input.timeStamp)
        }
    }
    func testNativeRotationPreservesPixelRangeAndMatchesSoftwareReference() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            let source = try frame(stamp: 400, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, format: format, width: 32, height: 16)
            let pixels = try XCTUnwrap((source.buffer as? RTCCVPixelBuffer)?.pixelBuffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
            let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<16 { for column in 0..<32 { y[row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + column] = UInt8((row * 32 + column) % 256) } }
            for row in 0..<8 { for column in 0..<16 {
                uv[row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) + column * 2] = UInt8(row * 16 + column)
                uv[row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 1) + column * 2 + 1] = UInt8(180 + row + column)
            } }
            CVPixelBufferUnlockBaseAddress(pixels, [])
            let adapter = GuestCameraOrientation()
            for rotation in [RTCVideoRotation._90, ._180, ._270] {
                let input = RTCVideoFrame(buffer: source.buffer, rotation: rotation, timeStampNs: source.timeStampNs)
                input.timeStamp = source.timeStamp
                guard case .frame(let output) = adapter.orient(input) else { return XCTFail("Native rotation unavailable") }
                XCTAssertEqual(output.width, rotation == ._180 ? 32 : 16)
                XCTAssertEqual(output.height, rotation == ._180 ? 16 : 32)
                XCTAssertEqual(output.rotation, ._0); XCTAssertEqual(output.timeStampNs, input.timeStampNs)
                XCTAssertEqual(output.timeStamp, input.timeStamp)
                XCTAssertEqual(CVPixelBufferGetPixelFormatType((output.buffer as! RTCCVPixelBuffer).pixelBuffer), format)
                XCTAssertEqual(GuestH264ColorEncoder.nativeColor(for: output), GuestH264ColorEncoder.nativeColor(for: input))
                let original = source.buffer.toI420(), result = output.buffer.toI420()
                for row in 0..<16 { for column in 0..<32 {
                    let (x, yy) = rotated(x: column, y: row, width: 32, height: 16, rotation: rotation)
                    XCTAssertEqual(result.dataY[yy * Int(result.strideY) + x], original.dataY[row * Int(original.strideY) + column])
                } }
                for row in 0..<8 { for column in 0..<16 {
                    let (x, yy) = rotated(x: column, y: row, width: 16, height: 8, rotation: rotation)
                    XCTAssertEqual(result.dataU[yy * Int(result.strideU) + x], original.dataU[row * Int(original.strideU) + column])
                    XCTAssertEqual(result.dataV[yy * Int(result.strideV) + x], original.dataV[row * Int(original.strideV) + column])
                } }
            }
            let input = RTCVideoFrame(buffer: source.buffer, rotation: ._90, timeStampNs: 1000)
            var held = (0..<8).compactMap { _ -> RTCVideoFrame? in if case .frame(let output) = adapter.orient(input) { return output }; return nil }
            XCTAssertEqual(held.count, 8)
            guard case .backpressure = adapter.orient(input) else { return XCTFail("Never exceed eight in-flight buffers") }
            held.removeLast()
            guard case .frame = adapter.orient(input) else { return XCTFail("Recover when retained frames are released") }
        }
    }
    func testCameraDelegateBakesOriginalSDKRotationIntoNV12() throws {
        let receiver = FrameReceiver(), camera = RTCCameraVideoCapturer(delegate: receiver)
        let adapter = GuestCameraFrameDelegate(camera: camera, device: nil, downstream: receiver)
        let source = try frame(stamp: 456, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                               ns: 456_000, width: 32, height: 16)
        let pixels = try XCTUnwrap((source.buffer as? RTCCVPixelBuffer)?.pixelBuffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<16 { for column in 0..<32 {
            y[row * CVPixelBufferGetBytesPerRowOfPlane(pixels, 0) + column] = UInt8((row * 32 + column) % 256)
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        let original = source.buffer.toI420()
        for rotation in [RTCVideoRotation._0, ._90, ._180, ._270] {
            let input = RTCVideoFrame(buffer: source.buffer, rotation: rotation, timeStampNs: source.timeStampNs)
            input.timeStamp = source.timeStamp
            adapter.capturer(camera, didCapture: input)
            let output = try XCTUnwrap(receiver.lastFrame)
            let turns = rotation == ._90 || rotation == ._270
            XCTAssertEqual(output.width, turns ? 16 : 32)
            XCTAssertEqual(output.height, turns ? 32 : 16)
            XCTAssertEqual(output.rotation, ._0)
            XCTAssertEqual(input.rotation, rotation)
            XCTAssertEqual(output.timeStampNs, input.timeStampNs)
            XCTAssertEqual(output.timeStamp, input.timeStamp)
            if rotation == ._0 { XCTAssertTrue(output === input) }
            let actual = output.buffer.toI420()
            for row in 0..<16 { for column in 0..<32 {
                let (x, yy) = rotation == ._0 ? (column, row) : rotated(x: column, y: row, width: 32, height: 16, rotation: rotation)
                XCTAssertEqual(actual.dataY[yy * Int(actual.strideY) + x], original.dataY[row * Int(original.strideY) + column])
            } }
        }
    }
    private func rotated(x: Int, y: Int, width: Int, height: Int, rotation: RTCVideoRotation) -> (Int, Int) {
        switch rotation {
        case ._90: return (height - 1 - y, x)
        case ._180: return (width - 1 - x, height - 1 - y)
        default: return (y, width - 1 - x)
        }
    }
    func testRapidCaptureRestartUnwrapsInactiveDelegate() throws {
        let downstream = FrameReceiver(), camera = RTCCameraVideoCapturer(delegate: downstream)
        let first = GuestCameraFrameDelegate(camera: camera, device: nil, downstream: downstream)
        camera.delegate = first
        let source = try frame(stamp: 500, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2, ns: 500_000)
        first.capturer(camera, didCapture: source)
        first.deactivate()
        let second = GuestCameraFrameDelegate(camera: camera, device: nil, downstream: try XCTUnwrap(first.originalDelegate))
        camera.delegate = second
        first.restore() // Completion from the old asynchronous stop.
        XCTAssertTrue(camera.delegate === second)
        second.capturer(camera, didCapture: source)
        XCTAssertEqual(downstream.frames, 2)
        second.deactivate()
        second.restore(); XCTAssertTrue(camera.delegate === downstream)
    }
    @MainActor
    func testLongLivedCameraSourceKeepsNewestTrackBindings() {
        GuestCameraTrackBinding.prepare()
        let factory = RTCPeerConnectionFactory(), source = factory.videoSource()
        for index in 0..<80 { _ = factory.videoTrack(with: source, trackId: "replacement-\(index)") }
        XCTAssertTrue(GuestCameraTrackBinding.source(source, owns: "replacement-79"))
        XCTAssertFalse(GuestCameraTrackBinding.source(source, owns: "replacement-0"))
    }
    @MainActor
    func testRawCaptureAdvancesThroughPoolStarvationAndCannotBindAnotherSource() throws {
        GuestCameraTrackBinding.prepare()
        let factory = RTCPeerConnectionFactory(), source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: UUID().uuidString)
        let other = factory.videoTrack(with: factory.videoSource(), trackId: UUID().uuidString)
        let camera = RTCCameraVideoCapturer(delegate: source)
        let proxy = GuestCameraFrameDelegate(camera: camera, device: nil, downstream: source)
        var retained: [RTCVideoFrame] = []
        GuestCameraOrientation.observeForTesting { _, output in retained.append(output) }
        defer { GuestCameraOrientation.observeForTesting(nil); proxy.retire() }
        let sourceFrame = try frame(stamp: 600, matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        let input = RTCVideoFrame(buffer: sourceFrame.buffer, rotation: ._90, timeStampNs: sourceFrame.timeStampNs)
        for _ in 0..<8 { proxy.capturer(camera, didCapture: input) }
        XCTAssertEqual(retained.count, 8)
        let initial = try XCTUnwrap(proxy.progress(trackID: track.trackId))
        XCTAssertEqual(initial.frames, 8)
        XCTAssertNil(proxy.progress(trackID: other.trackId), "A sharing source cannot borrow camera counters")
        var health = VideoPublicationHealth()
        func sample(_ frames: Int64) -> VideoPublicationHealth.Sample {
            .init(stream: initial.generation.uuidString, captured: frames, encoded: 8, bandwidthLimited: false)
        }
        XCTAssertFalse(health.stalled(sample(initial.frames), at: 0))
        for step in 1...3 {
            proxy.capturer(camera, didCapture: input)
            let progress = try XCTUnwrap(proxy.progress(trackID: track.trackId))
            XCTAssertEqual(retained.count, 8, "No more output while all buffers are retained")
            XCTAssertEqual(progress.frames, 8 + Int64(step))
            XCTAssertEqual(health.stalled(sample(progress.frames), at: Double(step * 4)), step == 3)
        }
        retained.removeFirst(); proxy.capturer(camera, didCapture: input)
        XCTAssertEqual(retained.count, 8, "Delivery resumes after a buffer is released")
        proxy.deactivate(); XCTAssertNil(proxy.progress(trackID: track.trackId))
        let replacement = GuestCameraFrameDelegate(camera: camera, device: nil, downstream: source)
        let restarted = try XCTUnwrap(replacement.progress(trackID: track.trackId))
        XCTAssertNotEqual(restarted.generation, initial.generation)
        XCTAssertEqual(restarted.frames, 0)
        XCTAssertFalse(health.stalled(.init(stream: restarted.generation.uuidString, captured: 0, encoded: 8, bandwidthLimited: false), at: 16))
    }
    func testPublicationStallRequiresContinuousInputAndResetsAcrossPausesAndReplacement() {
        var health = VideoPublicationHealth()
        func sample(_ captured: Int64, _ encoded: Int64 = 10, stream: String = "one", limited: Bool = false) -> VideoPublicationHealth.Sample {
            .init(stream: stream, captured: captured, encoded: encoded, bandwidthLimited: limited)
        }
        XCTAssertFalse(health.stalled(sample(10), at: 0))
        XCTAssertFalse(health.stalled(sample(20), at: 4))
        XCTAssertFalse(health.stalled(sample(30), at: 8))
        XCTAssertTrue(health.stalled(sample(40), at: 12))
        XCTAssertFalse(health.stalled(sample(40), at: 16), "Static capture is not encoder failure")
        XCTAssertFalse(health.stalled(sample(50, limited: true), at: 20))
        XCTAssertFalse(health.stalled(sample(60), at: 24))
        XCTAssertFalse(health.stalled(sample(70, stream: "replacement"), at: 28))
        health.reset()
        XCTAssertFalse(health.stalled(sample(80), at: 100))
        XCTAssertFalse(health.stalled(sample(90, 20), at: 104), "Advancing output clears a stall")
    }
    private func frame(stamp: Int32, matrix: CFString, ns: Int64 = 1000,
                       format: OSType = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, width: Int = 16, height: Int = 16) throws -> RTCVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: ns)
        frame.timeStamp = stamp; return frame
    }
}

private final class FrameReceiver: NSObject, RTCVideoCapturerDelegate {
    var frames = 0
    var lastFrame: RTCVideoFrame?
    func capturer(_ capturer: RTCVideoCapturer, didCapture frame: RTCVideoFrame) { frames += 1; lastFrame = frame }
}

private final class TestEncoder: NSObject, RTCVideoEncoder {
    var callback: RTCVideoEncoderCallback?
    var types: [[NSNumber]] = []
    func complete(stamp: UInt32) {
        let image = RTCEncodedImage(); image.timeStamp = stamp; image.frameType = .videoFrameKey
        image.buffer = Data(base64Encoded: "AAAAASdCAB+rQKD8gA==")!
        _ = callback?(image, RTCCodecSpecificInfoH264())
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) { self.callback = callback }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int { 0 }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int { types.append(frameTypes); return 0 }
    func release() -> Int { 0 }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { 0 }
    func implementationName() -> String { "Test" }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { nil }
    var resolutionAlignment: Int { 2 }
    var applyAlignmentToAllSimulcastLayers: Bool { false }
    var supportsNativeHandle: Bool { true }
}
