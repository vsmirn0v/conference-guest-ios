import Foundation
import LiveKitWebRTC

@main struct CameraMetadataTests {
    static func main() async throws {
        LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory()
        let cancelled = GuestCamera(source: factory.videoSource())
        let cancelBarrier = DispatchSemaphore(value: 0)
        try cancelled.prepareMetadataQueueFixtureForTesting(blockedBy: cancelBarrier)
        let observation = Task { await cancelled.captureDevice() }
        await Task.yield()
        observation.cancel()
        let cancelledDevice = await observation.value
        precondition(cancelledDevice == nil)
        precondition(cancelled.captureRequestedForTesting,
                     "Cancelling a pending device observation must not retire live capture")
        cancelBarrier.signal()
        await cancelled.drainCaptureQueueForTesting()
        precondition(cancelled.captureRequestedForTesting,
                     "A late observation must not change capture ownership")
        cancelled.cancel()
        precondition(!cancelled.captureRequestedForTesting,
                     "Explicit cancellation must retain its immediate capture barrier")
        try await cancelled.stop()

        let timedOut = GuestCamera(source: factory.videoSource())
        let timeoutBarrier = DispatchSemaphore(value: 0)
        try timedOut.prepareMetadataQueueFixtureForTesting(blockedBy: timeoutBarrier)
        async let device = timedOut.captureDevice()
        async let identity = timedOut.selectedDeviceIDForTesting()
        let observed = await (device, identity)
        precondition(observed.0 == nil && observed.1 == nil)
        precondition(timedOut.captureRequestedForTesting,
                     "Metadata deadlines must not stop a capture whose queue is busy")
        timeoutBarrier.signal()
        await timedOut.drainCaptureQueueForTesting()
        precondition(timedOut.captureRequestedForTesting,
                     "Timed-out metadata work must remain harmless when the queue resumes")
        try await timedOut.stop()
        precondition(!timedOut.captureRequestedForTesting)
        print("PASS: cancelled/timed-out camera observations preserve capture; late reads drain; explicit stop retires it (no hardware)")
    }
}
