import Foundation
import CoreMedia
import CoreVideo
import LiveKitWebRTC

private final class GraphFixture {}
private final class WeakGraphFixture {
    weak var value: GraphFixture?
    init(_ value: GraphFixture?) { self.value = value }
}
private final class FormatFixture {
    let description: CMVideoFormatDescription
    let ranges: [GuestCameraDurationRange]
    init(_ description: CMVideoFormatDescription, _ ranges: [GuestCameraDurationRange]) {
        self.description = description; self.ranges = ranges
    }
}

@main struct CameraReuseTests {
    static func main() async {
        precondition(GuestCameraSessionReuse.experiment(environment: [:]) == nil)
        precondition(GuestCameraSessionReuse.experiment(environment: ["NATIVE_GUEST_CAMERA_SESSION_REUSE": "0"]) == nil)
        let cache = GuestCameraSessionReuse.experiment(environment: ["NATIVE_GUEST_CAMERA_SESSION_REUSE": "1"])!
        precondition(cache.snapshotForTesting()["parkedCount"] as? Int == 0)
        precondition(cache.snapshotForTesting()["borrowedCount"] as? Int == 0)
        let closed = await cache.close()
        precondition(closed)
        let closedAgain = await cache.close()
        precondition(closedAgain, "Meeting cleanup must be idempotent")
        precondition(cache.snapshotForTesting()["closed"] as? Bool == true)
        precondition(cache.snapshotForTesting()["stopFailed"] as? Bool == false)

        var captureClock: CMTimebase?
        precondition(CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(), timebaseOut: &captureClock) == noErr)
        let clock = captureClock!
        let cutoff = CMTime(value: 12, timescale: 1)
        precondition(CMTimebaseSetTime(clock, time: cutoff) == noErr)
        let freshness = GuestCameraFrameFreshness(required: true, clock: clock)
        precondition(freshness.ready && freshness.accepts(CMTime(value: 13, timescale: 1)),
                     "Fresh capture PTS must be accepted despite a large offset from the host clock")
        precondition(!freshness.accepts(CMTime(value: 11, timescale: 1)), "Buffered frames before the capture-clock cutoff are stale")
        precondition(freshness.accepts(cutoff), "The exact rational capture-clock boundary is valid")
        precondition(!freshness.accepts(.invalid))
        let unavailableClock = GuestCameraFrameFreshness(required: true)
        precondition(!unavailableClock.ready && !unavailableClock.accepts(CMTime(value: 13, timescale: 1)),
                     "An absent capture synchronization clock must fail closed")
        precondition(GuestCameraFrameFreshness().accepts(CMTime(value: 1, timescale: 1)), "The default lifecycle keeps its prior timestamp policy")

        var cadence = GuestCameraCadence()
        precondition(cadence.measuredFPS == nil && cadence.spanSeconds == nil && cadence.maximumGapSeconds == nil)
        let timestamps: [Int64] = [0, 33_333_333, 66_666_666, 100_000_000]
        for timestamp in timestamps { cadence.observe(timestamp) }
        precondition(cadence.measuredFPS == nil, "A short sample window must not claim an established cadence")
        cadence.observe(133_333_333)
        precondition(abs(cadence.measuredFPS! - 30) < 0.00001)
        precondition(cadence.firstPTS == 0 && cadence.lastPTS == 133_333_333 && cadence.spanSeconds == 0.133333333)
        cadence.observe(133_333_333); cadence.observe(-1); cadence.observe(100_000_000)
        precondition(cadence.frames == 5, "Duplicate, invalid and regressing PTS cannot inflate measured FPS")
        cadence.observe(333_333_333)
        precondition(abs(cadence.measuredFPS! - 15) < 0.00001 && cadence.maximumGapSeconds == 0.2,
                     "A delivery gap must lower measured cadence and remain visible independently of the configured format")
        precondition(GuestCameraCadence().frames == 0 && GuestCameraCadence().firstPTS == nil,
                     "Each activation starts with fresh sample cadence")

        func videoDescription(width: Int32 = 1280, subtype: FourCharCode = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) -> CMVideoFormatDescription {
            var value: CMVideoFormatDescription?
            precondition(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: subtype,
                width: width, height: 720, extensions: nil, formatDescriptionOut: &value) == noErr)
            return value!
        }
        let oldDescription = videoDescription(), newDescription = videoDescription()
        precondition(oldDescription !== newDescription && CMFormatDescriptionEqual(oldDescription, otherFormatDescription: newDescription),
                     "The regression fixture needs distinct but structurally equivalent descriptions")
        let thirty = CMTime(value: 1, timescale: 30), fifteen = CMTime(value: 1, timescale: 15)
        let supported = [GuestCameraDurationRange(shortest: thirty, longest: fifteen)]
        let cached = FormatFixture(oldDescription, supported), current = FormatFixture(newDescription, supported)
        func match(_ formats: [FormatFixture], duration: CMTime = thirty) -> FormatFixture? {
            GuestCameraFormatMatching.current(matching: cached.description, duration: duration, in: formats,
                description: { $0.description }, ranges: { $0.ranges })
        }
        precondition(match([current]) === current && current !== cached,
                     "Reuse must reapply the current catalog wrapper, even when the cached wrapper disappeared")
        precondition(match([FormatFixture(videoDescription(width: 1920), supported)]) == nil,
                     "A different resolution must recreate the graph")
        precondition(match([FormatFixture(videoDescription(subtype: kCVPixelFormatType_32BGRA), supported)]) == nil,
                     "A different media subtype must recreate the graph")
        precondition(match([FormatFixture(newDescription, [.init(shortest: fifteen, longest: fifteen)])]) == nil,
                     "Equivalent media descriptions cannot substitute a format that no longer supports 30 fps")
        precondition(match([current], duration: CMTime(value: 1, timescale: 60)) == nil)
        precondition(GuestCameraFormatMatching.current(matching: cached.description, duration: thirty,
            maximumDuration: fifteen, in: [current], description: { $0.description }, ranges: { $0.ranges }) === current)
        precondition(GuestCameraFormatMatching.current(matching: cached.description, duration: thirty,
            maximumDuration: CMTime(value: 1, timescale: 10), in: [current], description: { $0.description },
            ranges: { $0.ranges }) == nil, "Both actual duration bounds must remain supported")
        precondition(match([FormatFixture(newDescription, [.init(shortest: .invalid, longest: fifteen)])]) == nil)
        precondition(match([]) == nil)

        var slot = GuestCameraReuseSlot<GraphFixture>()
        let firstOwner = UUID(), secondOwner = UUID()
        let (firstGeneration, empty) = slot.checkout(owner: firstOwner)
        precondition(empty == nil)
        var graph: GraphFixture? = GraphFixture()
        let reference = WeakGraphFixture(graph)
        precondition(slot.park(graph!, generation: firstGeneration))
        graph = nil
        precondition(reference.value != nil, "A stopped graph is retained between activations")
        let (secondGeneration, reused) = slot.checkout(owner: secondOwner)
        precondition(reused === reference.value && slot.value == nil, "Checkout transfers sole cache ownership")
        precondition(!slot.park(reused!, generation: firstGeneration), "Old activation cannot return a graph to a newer borrower")
        precondition(slot.park(reused!, generation: secondGeneration))
        precondition(!slot.park(GraphFixture(), generation: secondGeneration), "One activation cannot replace a parked graph")
        precondition(slot.invalidate(owner: firstOwner) == nil && slot.generation == secondGeneration && slot.value === reused,
                     "A late cancelled start/deadline must not invalidate the replacement activation")

        var discarded = slot.invalidate()
        precondition(discarded === reused && slot.value == nil)
        precondition(!slot.park(reused!, generation: secondGeneration), "Route/device/permission invalidation revokes outstanding loans")
        discarded = nil

        let (lateGeneration, _) = slot.checkout()
        precondition(slot.invalidate(closing: true) == nil)
        precondition(slot.closed)
        precondition(!slot.park(reused!, generation: lateGeneration), "Leave rejects an asynchronous stop completing later")
        let (afterClose, _) = slot.checkout()
        precondition(!slot.park(reused!, generation: afterClose), "A closed meeting cannot be reopened by a new activation")

        var releaseSlot = GuestCameraReuseSlot<GraphFixture>()
        let (releaseGeneration, _) = releaseSlot.checkout()
        var onlyOwner: GraphFixture? = GraphFixture()
        let released = WeakGraphFixture(onlyOwner)
        precondition(releaseSlot.park(onlyOwner!, generation: releaseGeneration)); onlyOwner = nil
        precondition(released.value != nil)
        var releasedGraph = releaseSlot.invalidate(closing: true)
        precondition(releasedGraph != nil && released.value != nil)
        releasedGraph = nil
        precondition(released.value == nil, "Leave disposal releases the last retained graph")

        LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory(), blockedCache = GuestCameraSessionReuse()
        let expectedProfile = GuestCameraSampleProfile(width: 1920, height: 1080, pixelFormat: kCVPixelFormatType_32BGRA)
        precondition(expectedProfile != GuestCameraSampleProfile(width: 1280, height: 720, pixelFormat: kCVPixelFormatType_32BGRA))
        precondition(expectedProfile != GuestCameraSampleProfile(width: 1920, height: 1080,
            pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange))
        var pixels: CVPixelBuffer?
        precondition(CVPixelBufferCreate(kCFAllocatorDefault, 1280, 720, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess)
        var bufferDescription: CMVideoFormatDescription?
        precondition(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels!,
            formatDescriptionOut: &bufferDescription) == noErr)
        var timing = CMSampleTimingInfo(duration: thirty, presentationTimeStamp: CMTime(value: 1, timescale: 1), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        precondition(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels!,
            formatDescription: bufferDescription!, sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let qualityGuard = GuestCamera(source: factory.videoSource())
        try! qualityGuard.prepareFrameProfileForTesting(expectedProfile)
        qualityGuard.forwardSampleForTesting(sample!)
        do {
            try await qualityGuard.waitForFirstFrameForTesting(timeout: 0)
            preconditionFailure("A lower-resolution sample must fail before WebRTC delivery or startup readiness")
        } catch GuestCameraError.unsupportedFormat {} catch { preconditionFailure("Unexpected profile mismatch error: \(error)") }
        precondition(qualityGuard.snapshot().frames == 0 && qualityGuard.snapshot().sampleProfileMismatch)
        precondition(!qualityGuard.captureRequestedForTesting, "Profile mismatch must revoke capture and queue physical cleanup")
        try! await qualityGuard.stop()

        let capture = GuestCamera(source: factory.videoSource(), sessionReuse: blockedCache)
        let barrier = DispatchSemaphore(value: 0)
        try! capture.prepareMetadataQueueFixtureForTesting(blockedBy: barrier)
        let blockedClose = await blockedCache.close()
        precondition(!blockedClose, "Leave must report a blocked session queue within its deadline")
        capture.cancel(); barrier.signal()
        await capture.drainCaptureQueueForTesting()
        try! await capture.stop()
        let lateClose = await blockedCache.close()
        precondition(lateClose && !capture.captureRequestedForTesting, "Queued cleanup finishes safely after a bounded Leave failure")
        print("PASS: semantic format/current-wrapper/rational-cadence matching, clock-domain freshness, DEBUG opt-in/default, idempotent/bounded close, ownership transfer, stale/duplicate return, stale cancellation, route invalidation, Leave/late stop, closed reactivation and final release; no camera hardware")
    }
}
