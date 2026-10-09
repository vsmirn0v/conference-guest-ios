import CoreVideo
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

final class H264InputColorSignallingTests: XCTestCase {
    func testLayersOwnIndependentBoundedAssociationsAndDoNotRollBackColor() throws {
        let first = H264InputColorSignalling(), second = H264InputColorSignalling()
        let video = try pixels(kCVImageBufferYCbCrMatrix_ITU_R_709_2), other = try pixels(kCVImageBufferYCbCrMatrix_ITU_R_601_4)
        let source = Data(base64Encoded: "AAAAASdCAB+rQKD8gA==")!
        XCTAssertTrue(first.prepare(100, pixels: video)); XCTAssertTrue(second.prepare(100, pixels: other))
        let output1 = first.output(100, data: source, keyframe: true), output2 = second.output(100, data: source, keyframe: true)
        XCTAssertNotEqual(output1.data, output2.data)
        first.accepted(output1); second.accepted(output2)
        XCTAssertFalse(first.prepare(200, pixels: video)); XCTAssertFalse(second.prepare(200, pixels: other))
        XCTAssertTrue(first.prepare(300, pixels: other))
        let newer = first.output(300, data: source, keyframe: true), older = first.output(200, data: source, keyframe: true)
        first.accepted(newer); first.accepted(older)
        XCTAssertFalse(first.prepare(400, pixels: other), "Late callbacks must not roll back the announced color")
        first.reset()
        for stamp in 0..<65 { _ = first.prepare(UInt32(stamp), pixels: video) }
        XCTAssertEqual(first.output(0, data: source, keyframe: true).data, source, "Retired inputs must not borrow another frame's color")
        XCTAssertNotEqual(first.output(64, data: source, keyframe: true).data, source)
        first.reset(); XCTAssertTrue(first.prepare(100, pixels: video))
    }
    func testDefaultFactoriesWrapH264LeavesOnceAndPreserveOtherCodecs() throws {
        NativeH264ColorEncoder.prepare()
        let factory = LKRTCDefaultVideoEncoderFactory()
        let codecs = factory.supportedCodecs()
        for codec in codecs {
            let encoder = try XCTUnwrap(factory.createEncoder(codec))
            XCTAssertEqual(encoder is NativeH264ColorEncoder, codec.name == "H264")
            if let adapter = encoder as? NativeH264ColorEncoder {
                XCTAssertFalse(adapter.base is NativeH264ColorEncoder)
                XCTAssertEqual(adapter.implementationName(), adapter.base.implementationName())
                XCTAssertEqual(adapter.supportsNativeHandle, adapter.base.supportsNativeHandle)
            }
        }
        XCTAssertEqual(factory.supportedCodecs().map(\.parameters), codecs.map(\.parameters))
    }
    private func pixels(_ matrix: CFString) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 32, 16, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, &buffer), kCVReturnSuccess)
        let value = try XCTUnwrap(buffer)
        for (key, entry) in [(kCVImageBufferYCbCrMatrixKey, matrix), (kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2),
                             (kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2)] {
            CVBufferSetAttachment(value, key, entry, .shouldPropagate)
        }
        return value
    }
}
