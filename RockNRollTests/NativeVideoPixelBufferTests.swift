import CoreImage
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

final class NativeVideoPixelBufferTests: XCTestCase {
    func testCropPreservesRangeAndColorWithoutLeakingPooledAttachments() throws {
        let converter = NativeVideoPixelBuffer()
        let context = CIContext(options: [.useSoftwareRenderer: false])
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let cases: [(OSType, CFString, CFString, CFString)] = [
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
             kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVImageBufferYCbCrMatrix_ITU_R_601_4,
             kCVImageBufferColorPrimaries_ITU_R_709_2, kCVImageBufferTransferFunction_ITU_R_709_2),
            (kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVImageBufferYCbCrMatrix_ITU_R_709_2,
             kCVImageBufferColorPrimaries_P3_D65, kCVImageBufferTransferFunction_sRGB)
        ]
        for (format, matrix, primaries, transfer) in cases {
            let source = try pixels(format)
            let keys = [kCVImageBufferYCbCrMatrixKey, kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey]
            let values = [matrix, primaries, transfer]
            for (key, value) in zip(keys, values) { CVBufferSetAttachment(source, key, value, .shouldPropagate) }
            CVBufferSetAttachment(source, kCVImageBufferCleanApertureKey, ["invalid": 1] as CFDictionary, .shouldPropagate)
            let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: source), rotation: ._0, timeStampNs: 1)
            let cropped = try XCTUnwrap(converter.convert(frame, region: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)))
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(cropped), format)
            for (key, value) in zip(keys, values) {
                XCTAssertEqual(CVBufferCopyAttachment(cropped, key, nil) as? String, value as String)
            }
            XCTAssertNil(CVBufferCopyAttachment(cropped, kCVImageBufferCleanApertureKey, nil))
            CVPixelBufferLockBaseAddress(cropped, .readOnly)
            XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(cropped, 0)!.assumingMemoryBound(to: UInt8.self).pointee, 80)
            CVPixelBufferUnlockBaseAddress(cropped, .readOnly)
            func rgb(_ buffer: CVPixelBuffer) -> [UInt8] {
                var output = [UInt8](repeating: 0, count: 4)
                context.render(CIImage(cvPixelBuffer: buffer), toBitmap: &output, rowBytes: 4,
                    bounds: CGRect(x: 2, y: 2, width: 1, height: 1), format: .RGBA8, colorSpace: colorSpace)
                return output
            }
            XCTAssertEqual(rgb(source), rgb(cropped), "Cropping must not change the displayed color")
        }
        let untagged = try pixels(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: untagged), rotation: ._0, timeStampNs: 1)
        let output = try XCTUnwrap(converter.convert(frame, region: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)))
        XCTAssertNil(CVBufferCopyAttachment(output, kCVImageBufferYCbCrMatrixKey, nil), "Do not invent metadata or retain the preceding frame's tags")
    }

    private func pixels(_ format: OSType) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, 16, 16, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let value = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(value, [])
        memset(CVPixelBufferGetBaseAddressOfPlane(value, 0), 80, CVPixelBufferGetBytesPerRowOfPlane(value, 0) * 16)
        let uv = CVPixelBufferGetBaseAddressOfPlane(value, 1)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(value, 1)
        for y in 0..<8 { for x in 0..<8 { uv[y * stride + x * 2] = 90; uv[y * stride + x * 2 + 1] = 180 } }
        CVPixelBufferUnlockBaseAddress(value, [])
        return value
    }
}
