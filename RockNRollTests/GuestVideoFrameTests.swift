import AVFoundation
import JazzSDK
import UIKit
import WebRTC
import XCTest
@testable import RockNRoll

@MainActor
final class GuestVideoFrameTests: XCTestCase {
    func testHiddenGuestShareRemainsSelectedForBackgroundPiP() async {
        let streams = GuestStreamViews()
        let model = JazzParticipantViewModel(
            name: "Share", isAudioOn: false, isVideoOn: true, isPinned: false,
            isSharingScreen: true, isLocal: false, id: "share", isDominantSpeaker: false,
            shouldShowParticipantInfo: false, isZoomable: true,
            watermarkState: .hidden, displayMode: .speaker)
        let tile = streams.makeView(model: model, video: UIView())
        tile.frame = CGRect(x: 0, y: 0, width: 320, height: 180)
        tile.isHidden = true
        let selected = expectation(description: "Background share retained")
        var chosen: StreamViewport?
        streams.onPreferredVideo = { viewport, _, _ in
            chosen = viewport
            if viewport === tile { selected.fulfill() }
        }
        streams.setBackgrounded(true)
        await fulfillment(of: [selected], timeout: 2)
        XCTAssertTrue(chosen === tile)
        streams.reset()
        XCTAssertNil(chosen)
    }

    func testSelectedGuestTileStaysAliveUntilFloatingVideoClears() {
        let floating = GuestVideoPictureInPicture(sourceView: UIView())
        let renderer = RTCEAGLVideoView(frame: CGRect(x: 0, y: 0, width: 320, height: 180))
        var viewport: StreamViewport? = StreamViewport(
            video: renderer, state: StreamViewportState(), zoomable: true,
            name: "Share", showInfo: false, microphoneOn: false,
            pinned: false, watermark: nil)
        weak var retained = viewport
        floating.select(viewport: viewport, name: "Share", isScreenShare: true)
        viewport = nil
        XCTAssertNotNil(retained)
        floating.clear()
        XCTAssertNil(retained)
    }

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

#if DEBUG
    func testExperimentsKeepNativePassthroughAndBoundedPool() throws {
        let uncropped = try nativeFrame(width: 8, height: 8,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            crop: (0, 0, 8, 8), adapted: nil)
        let original = (uncropped.buffer as! RTCCVPixelBuffer).pixelBuffer
        let cropped = try nativeFrame(width: 8, height: 8,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            crop: (2, 2, 4, 4), adapted: nil)
        for technique in GuestVideoConversionExperiment.allCases {
            let processor = GuestVideoFrameProcessor(experiment: technique)
            XCTAssertTrue(try XCTUnwrap(processor.pixelBuffer(for: uncropped)) === original)
            var retained = try (0..<4).map { _ in try XCTUnwrap(processor.pixelBuffer(for: cropped)) }
            withExtendedLifetime(retained) {
                XCTAssertNil(processor.pixelBuffer(for: cropped), "\(technique) exceeded the pool limit")
            }
            retained.removeAll()
            XCTAssertNotNil(processor.pixelBuffer(for: cropped), "\(technique) failed to reuse released buffers")
        }
    }

    func testPlanarExperimentsMatchReferenceWithPaddingAndOddSizes() throws {
        for (width, height) in [(4, 2), (5, 3), (17, 9)] {
            let buffer = RTCMutableI420Buffer(width: Int32(width), height: Int32(height),
                strideY: Int32(width + 11), strideU: Int32((width + 1) / 2 + 7),
                strideV: Int32((width + 1) / 2 + 13))
            for row in 0..<height {
                for col in 0..<width { buffer.mutableDataY[row * Int(buffer.strideY) + col] = UInt8(truncatingIfNeeded: row * 19 + col * 13) }
            }
            for row in 0..<((height + 1) / 2) {
                for col in 0..<((width + 1) / 2) {
                    buffer.mutableDataU[row * Int(buffer.strideU) + col] = UInt8(truncatingIfNeeded: 43 + row * 3 + col * 7)
                    buffer.mutableDataV[row * Int(buffer.strideV) + col] = UInt8(truncatingIfNeeded: 127 + row * 11 + col * 5)
                }
            }
            let frame = RTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1)
            let reference = GuestVideoFrameProcessor()
            let expected = try pixels(XCTUnwrap(reference.pixelBuffer(for: frame)))
            for technique in [GuestVideoConversionExperiment.cachedPlanes, .accelerate] {
                let candidate = GuestVideoFrameProcessor(experiment: technique)
                XCTAssertEqual(try pixels(XCTUnwrap(candidate.pixelBuffer(for: frame))), expected,
                               "\(technique), \(width)x\(height)")
            }
        }
    }

    func testNativeCropExperimentsMatchPixelsRangeTagsAndLeaveSourceUnchanged() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            for (x, y, width, height) in [(2, 2, 4, 4), (2, 2, 3, 3), (1, 1, 4, 4)] {
                let source = try nativeFrame(width: 8, height: 8, format: format,
                                             crop: (x, y, width, height), adapted: nil)
                let native = source.buffer as! RTCCVPixelBuffer
                let before = try pixels(native.pixelBuffer)
                let reference = GuestVideoFrameProcessor()
                let expected = try XCTUnwrap(reference.pixelBuffer(for: source))
                for technique in [GuestVideoConversionExperiment.nativeCopy, .nativeTransfer] {
                    let candidate = GuestVideoFrameProcessor(experiment: technique)
                    let actual = try XCTUnwrap(candidate.pixelBuffer(for: source))
                    XCTAssertEqual(try pixels(actual), try pixels(expected), "\(technique), crop \(x),\(y),\(width),\(height)")
                    XCTAssertEqual(CVPixelBufferGetPixelFormatType(actual), format)
                    let matrix = try XCTUnwrap(CVBufferGetAttachment(actual, kCVImageBufferYCbCrMatrixKey, nil))
                    XCTAssertTrue(CFEqual(matrix.takeUnretainedValue(), kCVImageBufferYCbCrMatrix_ITU_R_709_2))
                }
                XCTAssertEqual(try pixels(native.pixelBuffer), before)
            }
        }
    }

    func testNativeTransferScalingPreservesConstantPlanesAndColorMetadata() throws {
        for format in [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange] {
            let frame = try nativeFrame(width: 16, height: 12, format: format,
                                        crop: (2, 2, 12, 8), adapted: (6, 4))
            let input = (frame.buffer as! RTCCVPixelBuffer).pixelBuffer
            XCTAssertEqual(CVPixelBufferLockBaseAddress(input, []), kCVReturnSuccess)
            let y = CVPixelBufferGetBaseAddressOfPlane(input, 0)!
            memset(y, 92, CVPixelBufferGetBytesPerRowOfPlane(input, 0) * 12)
            let uv = CVPixelBufferGetBaseAddressOfPlane(input, 1)!.assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(input, 1)
            for row in 0..<6 {
                for column in 0..<8 { uv[row * stride + column * 2] = 73; uv[row * stride + column * 2 + 1] = 193 }
            }
            CVPixelBufferUnlockBaseAddress(input, [])
            let before = try pixels(input)
            let reference = GuestVideoFrameProcessor()
            let candidate = GuestVideoFrameProcessor(experiment: .nativeTransfer)
            let expected = try XCTUnwrap(reference.pixelBuffer(for: frame))
            let actual = try XCTUnwrap(candidate.pixelBuffer(for: frame))
            XCTAssertEqual(CVPixelBufferGetWidth(actual), 6)
            XCTAssertEqual(CVPixelBufferGetHeight(actual), 4)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(actual), format)
            XCTAssertEqual(try pixels(actual), try pixels(expected))
            XCTAssertEqual(try pixels(input), before)
            let matrix = try XCTUnwrap(CVBufferGetAttachment(actual, kCVImageBufferYCbCrMatrixKey, nil))
            XCTAssertTrue(CFEqual(matrix.takeUnretainedValue(), kCVImageBufferYCbCrMatrix_ITU_R_709_2))
        }
    }

    func testVideoConversionExperimentBenchmark() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CONVERSION_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in optimized conversion benchmark")
        }
        for (width, height) in [(1280, 720), (1920, 1080), (3840, 2160)] {
            let planar = RTCMutableI420Buffer(width: Int32(width), height: Int32(height))
            memset(planar.mutableDataY, 120, Int(planar.strideY) * height)
            memset(planar.mutableDataU, 73, Int(planar.strideU) * ((height + 1) / 2))
            memset(planar.mutableDataV, 193, Int(planar.strideV) * ((height + 1) / 2))
            let frames: [(String, RTCVideoFrame)] = [
                ("I420", RTCVideoFrame(buffer: planar, rotation: ._0, timeStampNs: 1)),
                ("NV12-crop", try nativeFrame(width: width + 16, height: height + 16,
                    format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    crop: (8, 8, width, height), adapted: nil)),
                ("NV12-scale", try nativeFrame(width: width + 16, height: height + 16,
                    format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    crop: (8, 8, width, height), adapted: (width / 2, height / 2)))
            ]
            for (kind, frame) in frames {
                let techniques = GuestVideoConversionExperiment.allCases
                let processors = Dictionary(uniqueKeysWithValues: techniques.map {
                    ($0, GuestVideoFrameProcessor(experiment: $0))
                })
                for technique in techniques {
                    let processor = processors[technique]!
                    for _ in 0..<10 { _ = try XCTUnwrap(processor.pixelBuffer(for: frame)) }
                }
                var elapsed: [GuestVideoConversionExperiment: [Double]] = [:]
                var cpu: [GuestVideoConversionExperiment: Double] = [:]
                // Balance order to reduce warm-up and CPU frequency bias between techniques.
                for round in 0..<4 {
                    for technique in round % 2 == 0 ? techniques : Array(techniques.reversed()) {
                        let processor = processors[technique]!
                        var milliseconds: [Double] = []
                        let beforeCPU = processCPUTimeMilliseconds()
                        for _ in 0..<30 {
                            let start = CACurrentMediaTime()
                            _ = try XCTUnwrap(processor.pixelBuffer(for: frame))
                            milliseconds.append((CACurrentMediaTime() - start) * 1000)
                        }
                        cpu[technique, default: 0] += processCPUTimeMilliseconds() - beforeCPU
                        elapsed[technique, default: []].append(contentsOf: milliseconds)
                    }
                }
                for technique in techniques {
                    let milliseconds = elapsed[technique]!.sorted()
                    print("CONVERSION,\(width)x\(height),\(kind),\(technique.rawValue),p50_ms=\(milliseconds[60]),p95_ms=\(milliseconds[114]),cpu_ms_per_frame=\(cpu[technique]! / 120)")
                }
            }
        }
    }

    private func processCPUTimeMilliseconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) * 1000 +
            Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1000
    }

    private func pixels(_ buffer: CVPixelBuffer) throws -> [[UInt8]] {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw NSError(domain: "Pixels", code: 1) }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        return (0..<CVPixelBufferGetPlaneCount(buffer)).map { plane in
            let width = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 1 ? 2 : 1)
            let height = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            let data = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt8.self)
            return (0..<height).flatMap { row in Array(UnsafeBufferPointer(start: data.advanced(by: row * stride), count: width)) }
        }
    }

    private func nativeFrame(width: Int, height: Int, format: OSType,
                             crop: (Int, Int, Int, Int), adapted: (Int, Int)?) throws -> RTCVideoFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let input = try XCTUnwrap(buffer)
        CVBufferSetAttachment(input, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        CVPixelBufferLockBaseAddress(input, [])
        for plane in 0..<2 {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(input, plane)
            let data = CVPixelBufferGetBaseAddressOfPlane(input, plane)!.assumingMemoryBound(to: UInt8.self)
            for row in 0..<CVPixelBufferGetHeightOfPlane(input, plane) {
                for col in 0..<CVPixelBufferGetWidthOfPlane(input, plane) * (plane == 1 ? 2 : 1) {
                    data[row * stride + col] = UInt8(truncatingIfNeeded: 31 + row * 17 + col * 29)
                }
            }
        }
        CVPixelBufferUnlockBaseAddress(input, [])
        let source = RTCCVPixelBuffer(pixelBuffer: input, adaptedWidth: Int32(adapted?.0 ?? crop.2),
            adaptedHeight: Int32(adapted?.1 ?? crop.3), cropWidth: Int32(crop.2), cropHeight: Int32(crop.3),
            cropX: Int32(crop.0), cropY: Int32(crop.1))
        return RTCVideoFrame(buffer: source, rotation: ._0, timeStampNs: 1)
    }
#endif
}
