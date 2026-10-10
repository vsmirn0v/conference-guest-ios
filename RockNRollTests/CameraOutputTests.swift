import AVFoundation
import LiveKit
import XCTest
@testable import RockNRoll

final class CameraOutputTests: XCTestCase {
    func testEncoderAndPreviewRetentionsDoNotStarveTheBoundedCameraPool() throws {
        let scaler = CameraPixelScaler()
        let source = try pixels()
        let maximum = CameraQualityPolicy.Profile(tier: .high, fps: 24).maximum
        var retained: [CVPixelBuffer] = []
        for _ in 0..<CameraPixelScaler.maximumRetainedBuffers {
            let next = try autoreleasepool { try XCTUnwrap(scaler.scale(source, maximum: maximum)) }
            retained.append(next)
        }
        XCTAssertGreaterThan(retained.count, 3, "Hardware encoding plus preview must not starve a triple-buffer pool")
        XCTAssertNil(scaler.scale(source, maximum: maximum), "Retained native camera memory must remain bounded")
        retained.removeAll()
        XCTAssertNotNil(scaler.scale(source, maximum: maximum), "Releasing downstream references must restore progress")
    }

    private func pixels(width: Int = 1920, height: Int = 1080) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value), kCVReturnSuccess)
        let result = try XCTUnwrap(value)
        CVPixelBufferLockBaseAddress(result, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(result, plane), plane == 0 ? 32 : 128,
                CVPixelBufferGetBytesPerRowOfPlane(result, plane) * CVPixelBufferGetHeightOfPlane(result, plane))
        }
        CVPixelBufferUnlockBaseAddress(result, [])
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return result
    }
    func testAllTiersProduceProportionalNativeBuffersAndKeepRotationColorAndTimestamp() throws {
        let input = try pixels(width: 1080, height: 1920)
        for (tier, width, height) in [(CameraQualityPolicy.Tier.high, 720, 1280), (.balance, 540, 960), (.constrained, 360, 640)] {
            let processor = CameraOutputProcessor(); processor.setProfile(.init(tier: tier, fps: 24))
            let frame = VideoFrame(dimensions: .init(width: 1080, height: 1920), rotation: ._90,
                timeStampNs: 123, buffer: CVPixelVideoBuffer(pixelBuffer: input))
            let output = try XCTUnwrap(processor.process(frame: frame))
            let pixels = try XCTUnwrap(output.toCVPixelBuffer())
            XCTAssertEqual(CVPixelBufferGetWidth(pixels), width); XCTAssertEqual(CVPixelBufferGetHeight(pixels), height)
            XCTAssertEqual(output.rotation, ._90); XCTAssertEqual(output.timeStampNs, 123)
            XCTAssertEqual(CVPixelBufferGetPixelFormatType(pixels), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            XCTAssertEqual(CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self).pointee, 32)
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            XCTAssertNotNil(CVBufferCopyAttachment(pixels, kCVImageBufferYCbCrMatrixKey, nil))
        }
    }
    func testThirtyFpsInputAchievesTwentyFourFpsWithoutIntervalDrift() throws {
        let processor = CameraOutputProcessor(); processor.setProfile(.init(tier: .high, fps: 24))
        let input = try pixels(width: 320, height: 180)
        var frames = 0
        for index in 0..<300 {
            let frame = VideoFrame(dimensions: .init(width: 320, height: 180), rotation: ._0,
                timeStampNs: Int64(index) * 1_000_000_000 / 30, buffer: CVPixelVideoBuffer(pixelBuffer: input))
            if processor.process(frame: frame) != nil { frames += 1 }
        }
        XCTAssertGreaterThanOrEqual(frames, 239); XCTAssertLessThanOrEqual(frames, 241)
    }
    func testCameraProcessorPreservesFullNativeAspectInsteadOfSDKLogicalCenterCrop() throws {
        let processor = CameraOutputProcessor()
        let input = try pixels(width: 1280, height: 960)
        let frame = VideoFrame(dimensions: .init(width: 1280, height: 720), rotation: ._0,
            timeStampNs: 1, buffer: CVPixelVideoBuffer(pixelBuffer: input))
        let output = try XCTUnwrap(processor.process(frame: frame))
        XCTAssertEqual(output.dimensions.width, 720); XCTAssertEqual(output.dimensions.height, 540)
        XCTAssertEqual(CVPixelBufferGetWidth(try XCTUnwrap(output.toCVPixelBuffer())), 720)
    }
    func testUncertainTransportDoesNotBecomeExcellentAndRestrictionsOverrideGoodRtt() {
        XCTAssertEqual(CameraUplinkSample.classify(limited: false, roundTrip: nil, availableBitrate: nil, loss: nil), .unknown)
        XCTAssertEqual(CameraUplinkSample.classify(limited: false, roundTrip: .nan, availableBitrate: .infinity, loss: -1), .unknown)
        XCTAssertEqual(CameraUplinkSample.classify(limited: false, roundTrip: 0.1, availableBitrate: 3_000_000, loss: 0), .excellent)
        XCTAssertEqual(CameraUplinkSample.classify(limited: true, roundTrip: 0.1, availableBitrate: 3_000_000, loss: 0), .poor)
        XCTAssertEqual(CameraUplinkSample.classify(limited: false, roundTrip: 0.5, availableBitrate: 3_000_000, loss: 0), .poor)
    }
    func testCameraTransportEvidenceExcludesSharingAndUnselectedIcePairs() throws {
        let records: [CameraUplinkStatistics.Record] = [
            .init(id: "camera", type: "outbound-rtp", timestamp: 12, values: ["kind": "video" as NSString,
                "mid": "0" as NSString, "framesEncoded": 30 as NSNumber, "transportId": "transport" as NSString]),
            .init(id: "share", type: "outbound-rtp", timestamp: 12, values: ["kind": "video" as NSString,
                "mid": "1" as NSString, "framesEncoded": 30 as NSNumber, "qualityLimitationReason": "bandwidth" as NSString]),
            .init(id: "transport", type: "transport", timestamp: 12, values: ["selectedCandidatePairId": "active" as NSString]),
            .init(id: "active", type: "candidate-pair", timestamp: 12, values: ["currentRoundTripTime": 0.1 as NSNumber,
                "availableOutgoingBitrate": 3_000_000 as NSNumber]),
            .init(id: "old", type: "candidate-pair", timestamp: 2, values: ["currentRoundTripTime": 1 as NSNumber,
                "availableOutgoingBitrate": 20_000 as NSNumber])]
        XCTAssertEqual(try XCTUnwrap(CameraUplinkStatistics.sample(records: records, cameraMID: "0")).network, .excellent)
        XCTAssertEqual(try XCTUnwrap(CameraUplinkStatistics.sample(records: records, cameraMID: "1")).network, .poor)
        XCTAssertNil(CameraUplinkStatistics.sample(records: records, cameraMID: "missing"))
    }
    @MainActor func testPlatformCameraAccessUsesRuntimeSupport() {
        let session = AVCaptureSession()
        let supported = CameraBackgroundAccess.configure(session)
        XCTAssertEqual(supported, session.isMultitaskingCameraAccessSupported)
        XCTAssertEqual(session.isMultitaskingCameraAccessEnabled, supported)
        XCTAssertFalse(session.isRunning)
        if ProcessInfo.processInfo.isiOSAppOnMac {
            XCTAssertNotEqual(MacExternalPower.current, .unknown, "Qualify the public power-source bridge on this Mac")
        } else { XCTAssertEqual(MacExternalPower.current, .unknown) }
    }
}
