import Foundation
import LiveKitWebRTC

private func wait(_ semaphore: DispatchSemaphore) async {
    await withCheckedContinuation { continuation in
        DispatchQueue.global().async { semaphore.wait(); continuation.resume() }
    }
}

@main @MainActor struct CameraReadinessTests {
    static func main() async throws {
        let watchdog = DispatchWorkItem { fatalError("Camera readiness tests exceeded 15 seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel() }
        LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory()
        precondition(GuestCameraStopBudget.timeout(hasForwardedFrame: false) == 15)
        precondition(GuestCameraStopBudget.timeout(hasForwardedFrame: true) == 3)
        func camera() throws -> GuestCamera {
            let value = GuestCamera(source: factory.videoSource())
            try value.prepareFrameReadinessForTesting()
            return value
        }

        let blocked = try camera(), entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let forwarding = Task.detached { blocked.forwardFrameForTesting { entered.signal(); release.wait() } }
        await wait(entered)
        let waiting = DispatchSemaphore(value: 0)
        var ready = false
        let startup = Task { waiting.signal(); try await blocked.waitForFirstFrameForTesting(); ready = true }
        await wait(waiting)
        precondition(!ready, "Startup must not complete while the RTC frame-delivery call is blocked")
        precondition(blocked.stopTimeoutForTesting == 15, "A pending first delivery still owns the cold-start stop allowance")
        release.signal(); await forwarding.value; try await startup.value
        precondition(ready && blocked.captureRequestedForTesting)
        precondition(blocked.stopTimeoutForTesting == 3, "A returned first delivery restores the established-capture stop deadline")
        try await blocked.stop()

        let early = try camera()
        early.forwardFrameForTesting {}
        try await early.waitForFirstFrameForTesting(timeout: 0)
        precondition(early.captureRequestedForTesting, "A frame returned before waiter installation must remain ready")
        try await early.stop()

        let cancelled = try camera(), enteredCancelled = DispatchSemaphore(value: 0), releaseCancelled = DispatchSemaphore(value: 0)
        let lateForward = Task.detached { cancelled.forwardFrameForTesting { enteredCancelled.signal(); releaseCancelled.wait() } }
        await wait(enteredCancelled)
        let cancelWaiting = DispatchSemaphore(value: 0)
        let cancelledStartup = Task { cancelWaiting.signal(); try await cancelled.waitForFirstFrameForTesting() }
        await wait(cancelWaiting); cancelledStartup.cancel()
        do { try await cancelledStartup.value; preconditionFailure("Cancelled startup became ready") }
        catch is CancellationError {}
        precondition(!cancelled.captureRequestedForTesting, "Cancellation must retire capture without waiting for RTC delivery")
        precondition(cancelled.stopTimeoutForTesting == 15, "Cancelling during first delivery must retain the cold-start cleanup allowance")
        releaseCancelled.signal(); await lateForward.value
        do { try await cancelled.waitForFirstFrameForTesting(); preconditionFailure("Late delivery revived cancelled capture") }
        catch is CancellationError {}
        try await cancelled.stop()

        let preCancelled = try camera()
        let neverStarted = Task { try await preCancelled.waitForFirstFrameForTesting() }
        neverStarted.cancel()
        do { try await neverStarted.value; preconditionFailure("Pre-cancelled readiness wait succeeded") }
        catch is CancellationError {}
        precondition(!preCancelled.captureRequestedForTesting)
        try await preCancelled.stop()

        let timedOut = try camera()
        do { try await timedOut.waitForFirstFrameForTesting(timeout: 0); preconditionFailure("Missing frames never timed out") }
        catch GuestCameraError.timedOut {}
        precondition(!timedOut.captureRequestedForTesting, "Warmup timeout must revoke frame delivery")
        timedOut.forwardFrameForTesting {}
        do { try await timedOut.waitForFirstFrameForTesting(); preconditionFailure("Late frame replaced terminal timeout") }
        catch GuestCameraError.timedOut {}
        try await timedOut.stop()

        let stopped = try camera(), stopWaiting = DispatchSemaphore(value: 0)
        let stoppedStartup = Task { stopWaiting.signal(); try await stopped.waitForFirstFrameForTesting() }
        await wait(stopWaiting); stopped.cancel()
        do { try await stoppedStartup.value; preconditionFailure("Explicit capture cancellation left startup ready") }
        catch is CancellationError {}
        try await stopped.stop()

        let retiredReady = try camera()
        retiredReady.forwardFrameForTesting {}; retiredReady.cancel()
        precondition(retiredReady.stopTimeoutForTesting == 3, "Cancelling established capture must not extend its stop deadline")
        do { try await retiredReady.waitForFirstFrameForTesting(); preconditionFailure("Cached readiness survived capture retirement") }
        catch is CancellationError {}
        try await retiredReady.stop()
        print("PASS: 7 camera readiness scenarios and 6 stop-budget assertions: RTC return barrier, early frame, cancellation during forwarding, pre-cancellation, timeout/late frame, explicit stop and retired readiness; no hardware")
    }
}
