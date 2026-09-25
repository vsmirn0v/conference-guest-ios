import AVFoundation
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class GuestVideoFrameTests: XCTestCase {
    func testRendererTapReceivesFramesAndDetaches() {
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 32, height: 32))
        var frames = 0
        var tap = GuestVideoFrameTap(view: renderer) { _ in frames += 1 }
        XCTAssertNotNil(tap)
        XCTAssertTrue(tap?.matches(renderer) == true)
        let frame = makeFrame()
        renderer.renderFrame(frame)
        XCTAssertEqual(frames, 1)
        tap?.invalidate()
        tap = nil
        renderer.renderFrame(frame)
        XCTAssertEqual(frames, 1)
        XCTAssertNil(GuestVideoFrameTap(view: UIView()) { _ in XCTFail("Unsupported renderer") })
    }

    func testPlanarFrameConvertsStrideAndChromaAndPreservesRotation() async {
        let processor = GuestVideoFrameProcessor()
        let delivered = expectation(description: "Converted frame")
        processor.onSample = { sample, size, rotation in
            XCTAssertEqual(size, CGSize(width: 4, height: 2))
            XCTAssertEqual(rotation, 90)
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                XCTFail("Missing pixels"); delivered.fulfill(); return
            }
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(buffer), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            let matrix = CVBufferGetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil)
            XCTAssertTrue(matrix.map { CFEqual($0.takeUnretainedValue(), kCVImageBufferYCbCrMatrix_ITU_R_601_4) } ?? false)
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
            let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!.assumingMemoryBound(to: UInt8.self)
            let uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            XCTAssertEqual(Array(UnsafeBufferPointer(start: y, count: 4)), [11, 12, 13, 14])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: y.advanced(by: stride), count: 4)), [21, 22, 23, 24])
            XCTAssertEqual(Array(UnsafeBufferPointer(start: uv, count: 4)), [31, 41, 32, 42])
            delivered.fulfill()
        }
        processor.setEnabled(true)
        processor.submit(makeFrame())
        await fulfillment(of: [delivered], timeout: 3)
        processor.setEnabled(false)
    }

    func testCroppedFullRangeFrameKeepsItsRangeAndColorTags() async throws {
        var pixelBuffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 4, 4,
            kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, attributes, &pixelBuffer), kCVReturnSuccess)
        let source = try XCTUnwrap(pixelBuffer)
        CVBufferSetAttachment(source, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(source, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(source, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(source, 1)!.assumingMemoryBound(to: UInt8.self)
        for row in 0..<4 {
            for column in 0..<4 {
                y[row * CVPixelBufferGetBytesPerRowOfPlane(source, 0) + column] = column < 2 ? 0 : 255
            }
        }
        for row in 0..<2 {
            for column in 0..<4 { uv[row * CVPixelBufferGetBytesPerRowOfPlane(source, 1) + column] = 128 }
        }
        CVPixelBufferUnlockBaseAddress(source, [])
        let cropped = RTCCVPixelBuffer(pixelBuffer: source, adaptedWidth: 2, adaptedHeight: 2,
                                       cropWidth: 2, cropHeight: 2, cropX: 2, cropY: 0)
        let frame = RTCVideoFrame(buffer: cropped, rotation: RTCVideoRotation(rawValue: 0)!, timeStampNs: 1)
        let processor = GuestVideoFrameProcessor()
        let delivered = expectation(description: "Cropped full-range frame")
        processor.onSample = { sample, _, _ in
            guard let output = CMSampleBufferGetImageBuffer(sample) else {
                XCTFail("Missing converted pixels"); delivered.fulfill(); return
            }
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(output),
                           kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            let matrix = CVBufferGetAttachment(output, kCVImageBufferYCbCrMatrixKey, nil)
            XCTAssertTrue(matrix.map { CFEqual($0.takeUnretainedValue(), kCVImageBufferYCbCrMatrix_ITU_R_709_2) } ?? false)
            delivered.fulfill()
        }
        processor.setEnabled(true)
        processor.submit(frame)
        await fulfillment(of: [delivered], timeout: 3)
    }

    func testResetDropsQueuedFramesFromPreviousMeeting() async {
        let processor = GuestVideoFrameProcessor()
        let oldFrame = expectation(description: "No stale room frame")
        oldFrame.isInverted = true
        processor.onSample = { _, _, _ in oldFrame.fulfill() }
        processor.setEnabled(true)
        processor.submit(makeFrame())
        processor.setEnabled(false)
        await fulfillment(of: [oldFrame], timeout: 0.2)
        let currentFrame = expectation(description: "New room frame")
        let previousSource = processor.replaceSource()
        let nextSource = processor.replaceSource()
        let staleSource = expectation(description: "A detached renderer cannot submit into the new room")
        staleSource.isInverted = true
        processor.onSample = { _, _, _ in staleSource.fulfill() }
        processor.setEnabled(true)
        processor.submit(makeFrame(), source: previousSource)
        await fulfillment(of: [staleSource], timeout: 0.2)
        processor.onSample = { _, _, _ in currentFrame.fulfill() }
        processor.submit(makeFrame(), source: nextSource)
        await fulfillment(of: [currentFrame], timeout: 3)
    }

    private func makeFrame() -> RTCVideoFrame {
        let buffer = RTCMutableI420Buffer(width: 4, height: 2, strideY: 8, strideU: 4, strideV: 4)
        for row in 0..<2 {
            for column in 0..<4 { buffer.mutableDataY[row * 8 + column] = UInt8(11 + row * 10 + column) }
        }
        buffer.mutableDataU[0] = 31; buffer.mutableDataU[1] = 32
        buffer.mutableDataV[0] = 41; buffer.mutableDataV[1] = 42
        return RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation(rawValue: 90)!, timeStampNs: 1)
    }
}
