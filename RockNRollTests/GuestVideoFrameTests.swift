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

    func testEarlyFramesWaitForNextSlotAndUseNewestFrame() async {
        let processor = GuestVideoFrameProcessor()
        processor.setFrameRate(5)
        let delivered = expectation(description: "Newest frame delivered in next slot")
        var values: [UInt8] = []
        var firstTime: CFTimeInterval = 0
        processor.onSample = { sample, _, _ in
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else {
                XCTFail("Missing frame"); delivered.fulfill(); return
            }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let value = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
                .assumingMemoryBound(to: UInt8.self).pointee
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            values.append(value)
            if values.count == 1 {
                firstTime = CACurrentMediaTime()
                processor.submit(self.makeFrame(firstY: 22))
                processor.submit(self.makeFrame(firstY: 33))
            } else if values.count == 2 {
                XCTAssertEqual(values, [11, 33])
                XCTAssertGreaterThanOrEqual(CACurrentMediaTime() - firstTime, 0.17)
                delivered.fulfill()
            }
        }
        processor.setEnabled(true)
        processor.submit(makeFrame())
        await fulfillment(of: [delivered], timeout: 3)
        processor.setEnabled(false)
        processor.onSample = nil
    }

    func testPendingFrameDoesNotCrossMeetingSwitch() async {
        let processor = GuestVideoFrameProcessor()
        processor.setFrameRate(5)
        let first = expectation(description: "First meeting frame")
        let next = expectation(description: "Next meeting frame")
        let stale = expectation(description: "No pending frame from old meeting")
        stale.isInverted = true
        processor.onSample = { sample, _, _ in
            guard let buffer = CMSampleBufferGetImageBuffer(sample) else { XCTFail("Missing frame"); return }
            CVPixelBufferLockBaseAddress(buffer, .readOnly)
            let value = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!
                .assumingMemoryBound(to: UInt8.self).pointee
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
            switch value {
            case 11: first.fulfill()
            case 22: stale.fulfill()
            case 44: next.fulfill()
            default: XCTFail("Unexpected frame \(value)")
            }
        }
        let previousSource = processor.replaceSource()
        processor.setEnabled(true)
        processor.submit(makeFrame(), source: previousSource)
        await fulfillment(of: [first], timeout: 3)
        processor.submit(makeFrame(firstY: 22), source: previousSource)
        let currentSource = processor.replaceSource()
        processor.setEnabled(true)
        processor.submit(makeFrame(firstY: 44), source: currentSource)
        await fulfillment(of: [next], timeout: 3)
        await fulfillment(of: [stale], timeout: 0.3)
        processor.setEnabled(false)
    }

    func testPlanarFormatChangesWithFrameSize() async {
        let processor = GuestVideoFrameProcessor()
        let delivered = expectation(description: "Both frame sizes")
        delivered.expectedFulfillmentCount = 2
        var widths = [Int32]()
        processor.onSample = { sample, _, _ in
            guard let format = CMSampleBufferGetFormatDescription(sample) else {
                XCTFail("Missing format"); delivered.fulfill(); return
            }
            widths.append(CMVideoFormatDescriptionGetDimensions(format).width)
            if widths.count == 1 {
                let buffer = RTCMutableI420Buffer(width: 8, height: 4)
                for index in 0..<(Int(buffer.strideY) * 4) { buffer.mutableDataY[index] = 128 }
                for index in 0..<(Int(buffer.strideU) * 2) { buffer.mutableDataU[index] = 128 }
                for index in 0..<(Int(buffer.strideV) * 2) { buffer.mutableDataV[index] = 128 }
                processor.submit(RTCVideoFrame(buffer: buffer,
                    rotation: RTCVideoRotation(rawValue: 0)!, timeStampNs: 2))
            }
            delivered.fulfill()
        }
        processor.setEnabled(true)
        processor.submit(makeFrame())
        await fulfillment(of: [delivered], timeout: 3)
        XCTAssertEqual(widths, [4, 8])
        processor.setEnabled(false)
        processor.onSample = nil
    }

    private func makeFrame(firstY: UInt8 = 11) -> RTCVideoFrame {
        let buffer = RTCMutableI420Buffer(width: 4, height: 2, strideY: 8, strideU: 4, strideV: 4)
        for row in 0..<2 {
            for column in 0..<4 { buffer.mutableDataY[row * 8 + column] = firstY + UInt8(row * 10 + column) }
        }
        buffer.mutableDataU[0] = 31; buffer.mutableDataU[1] = 32
        buffer.mutableDataV[0] = 41; buffer.mutableDataV[1] = 42
        return RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation(rawValue: 90)!, timeStampNs: 1)
    }
}
