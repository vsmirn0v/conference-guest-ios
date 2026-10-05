#if DEBUG
import AVFoundation
import LiveKit
import ReplayKit
import XCTest
@testable import RockNRoll

@MainActor
final class OutgoingMediaExperimentTests: XCTestCase {
    func testSixtyFpsInputIsCappedWithoutDelayingFirstFrame() throws {
        let sample = try makeSample()
        for (profile, expected) in [(OutgoingShareExperiment.Profile.reference, 120), (.cap30, 60), (.cap15, 30)] {
            let candidate = OutgoingShareExperiment(profile: profile)
            var sends = 0, previews = 0
            for frame in 0..<120 {
                let accepted = candidate.deliver(sample, time: Double(frame) / 60,
                    send: { sends += 1 }, preview: { previews += 1 })
                if frame == 0 { XCTAssertTrue(accepted) }
            }
            XCTAssertEqual(candidate.received, 120)
            XCTAssertEqual(candidate.forwarded, expected)
            XCTAssertEqual(sends, expected); XCTAssertEqual(previews, expected)
        }
    }

    func testFormatClockAndSessionChangesAlwaysDeliverFreshFrames() throws {
        let candidate = OutgoingShareExperiment(profile: .cap30)
        let first = try makeSample(), changed = try makeSample(width: 16, height: 8)
        func send(_ sample: CMSampleBuffer, _ time: Double) -> Bool {
            candidate.deliver(sample, time: time, send: {}, preview: {})
        }
        XCTAssertTrue(send(first, 10)); XCTAssertFalse(send(first, 10.001))
        XCTAssertTrue(send(changed, 10.002)); XCTAssertTrue(send(changed, 0))
        CMSetAttachment(changed, key: RPVideoSampleOrientationKey as CFString,
                        value: NSNumber(value: 6), attachmentMode: kCMAttachmentMode_ShouldPropagate)
        XCTAssertTrue(send(changed, 0.001), "An orientation change must pass immediately")
        candidate.reset()
        XCTAssertTrue(send(changed, 0.001))
        XCTAssertEqual(candidate.received, 1)
        XCTAssertTrue(send(changed, .nan)); XCTAssertTrue(send(changed, .infinity))
    }

    func testPreviewOrderAndBoundedTimingStorage() throws {
        let sample = try makeSample()
        for after in [false, true] {
            let candidate = OutgoingShareExperiment(profile: .reference, previewAfterSend: after)
            var order: [String] = []
            candidate.deliver(sample, send: { order.append("send") }, preview: { order.append("preview") })
            XCTAssertEqual(order, after ? ["send", "preview"] : ["preview", "send"])
            for frame in 1..<5_000 { candidate.deliver(sample, time: Double(frame), send: {}, preview: {}) }
            XCTAssertTrue(candidate.summary.contains("timingSamples=904,"))
            candidate.deliver(sample, send: { candidate.reset() }, preview: {})
            XCTAssertTrue(candidate.summary.contains("timingSamples=0,"), "Discard timings completed after a reset")
        }
        XCTAssertNil(OutgoingShareExperiment.configured(environment: [:]))
        XCTAssertNil(OutgoingShareExperiment.configured(environment: ["ROCKNROLL_OUTGOING_SHARE": "unsupported"]))
    }

    func testRoomProfilesPreserveAudioResolutionAndBackgroundPolicy() {
        let baseline = RoomOptions()
        for profile in OutgoingRoomExperiment.allCases {
            let options = profile.options
            XCTAssertEqual(options.defaultCameraCaptureOptions, baseline.defaultCameraCaptureOptions)
            XCTAssertEqual(options.defaultAudioCaptureOptions, baseline.defaultAudioCaptureOptions)
            XCTAssertEqual(options.defaultAudioPublishOptions, baseline.defaultAudioPublishOptions)
            XCTAssertEqual(options.defaultScreenShareCaptureOptions, baseline.defaultScreenShareCaptureOptions)
            XCTAssertEqual(options.suspendLocalVideoTracksInBackground, baseline.suspendLocalVideoTracksInBackground)
            XCTAssertFalse(options.adaptiveStream)
            XCTAssertEqual(options.defaultVideoPublishOptions.simulcast, profile != .h264SingleLayer)
            XCTAssertEqual(options.dynacast, profile != .reference)
            XCTAssertEqual(options.defaultVideoPublishOptions.preferredCodec,
                [.h264Dynacast, .h264TwoLayers, .h264SingleLayer].contains(profile) ? .h264 : nil)
            XCTAssertEqual(options.defaultVideoPublishOptions.simulcastLayers.count, profile == .h264TwoLayers ? 1 : 0)
        }
    }

    func testBroadcastConfigurationIsExplicitBoundedAndClearedForAnOrdinaryRun() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        OutgoingShareExperiment.prepareBroadcastConfiguration(environment: ["ROCKNROLL_OUTGOING_SHARE": "cap30",
            "ROCKNROLL_OUTGOING_PREVIEW_AFTER_SEND": "1"], url: url)
        let candidate = try XCTUnwrap(OutgoingShareExperiment.configuredForBroadcast(environment: [:], url: url))
        XCTAssertTrue(candidate.summary.contains("profile=cap30,previewAfter=true,"))
        OutgoingShareExperiment.prepareBroadcastConfiguration(environment: [:], url: url)
        XCTAssertNil(OutgoingShareExperiment.configuredForBroadcast(environment: [:], url: url))
        try Data(repeating: 0, count: 1_025).write(to: url)
        XCTAssertNil(OutgoingShareExperiment.configuredForBroadcast(environment: [:], url: url))
    }

    func testPreviewHandoffBenchmark() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_OUTGOING_BENCHMARK"] == "1" else {
            throw XCTSkip("Opt-in outgoing preview benchmark")
        }
        let sample = try makeSample(width: 1920, height: 1080)
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(sample))
        for after in [false, true] {
            let preview = LocalSharePreview(isMac: true, observeLifecycle: false)
            preview.begin()
            let candidate = OutgoingShareExperiment(profile: .reference, previewAfterSend: after)
            for frame in 0..<200 {
                candidate.deliver(sample, time: Double(frame) * 0.6,
                    send: {}, preview: { preview.accept(pixels, time: Double(frame) * 0.6) })
            }
            XCTAssertNotNil(preview.image)
            XCTAssertEqual(preview.image?.size, CGSize(width: 640, height: 360))
            print(candidate.summary)
        }
    }

    private func makeSample(width: Int = 8, height: Int = 4) throws -> CMSampleBuffer {
        var pixels: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels), kCVReturnSuccess)
        let buffer = try XCTUnwrap(pixels)
        CVPixelBufferLockBaseAddress(buffer, [])
        for plane in 0..<2 {
            memset(CVPixelBufferGetBaseAddressOfPlane(buffer, plane), plane == 0 ? 92 : 128,
                   CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) * CVPixelBufferGetHeightOfPlane(buffer, plane))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        var format: CMVideoFormatDescription?
        XCTAssertEqual(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &format), noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: try XCTUnwrap(format), sampleTiming: &timing, sampleBufferOut: &sample), noErr)
        return try XCTUnwrap(sample)
    }
}
#endif
