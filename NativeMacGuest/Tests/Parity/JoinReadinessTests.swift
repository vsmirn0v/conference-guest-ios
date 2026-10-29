import AVFoundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

@MainActor func joinTestPower(pluggedIn: Bool = true, lowPowerMode: Bool = false) -> NativeDesktopPowerMonitor {
    NativeDesktopPowerMonitor(read: { .init(pluggedIn: pluggedIn, lowPowerMode: lowPowerMode) }, observe: { _ in {} })
}

@MainActor func joinTestCameraMetadata() -> NativeDesktopCameraMetadataPreparation {
    .init(authorized: { true }, read: { _ in })
}

@MainActor final class JoinPrimeCapture: GuestCameraCapture {
    var starts = 0, stops = 0, cancellations = 0
    var starting: (() async throws -> Void)?
    var stopping: (() async throws -> Void)?
    var frameReady = false
    func start() async throws -> GuestCameraInfo {
        starts += 1
        try await starting?()
        try Task.checkCancellation()
        guard cancellations == 0 else { throw CancellationError() }
        frameReady = true
        return .init(deviceName: "fixture", width: 1280, height: 720, fps: 30,
            requestedWidth: 1280, requestedHeight: 720, requestedFPS: 30,
            sessionPreset: "fixture", minimumFrameDuration: CMTime(value: 1, timescale: 30),
            maximumFrameDuration: CMTime(value: 1, timescale: 30), pixelFormat: 0, mirrored: false, rotationDegrees: 0)
    }
    func cancel() { cancellations += 1 }
    func stop() async throws { stops += 1; try await stopping?(); frameReady = false }
    func snapshot() -> GuestCameraSnapshot {
        .init(frames: frameReady ? 1 : 0, advancingPTS: frameReady ? 1 : 0, dropped: 0,
            width: 1280, height: 720, pixelFormat: nil, systemBackgroundSelected: nil,
            systemBackgroundActive: nil, observedReaction: false)
    }
    func performReaction() async -> Bool { false }
}

@MainActor final class JoinReadinessTests: XCTestCase {
    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 { if predicate() { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("Join camera fixture did not advance")
    }
    func testMetadataTimeoutAndCancellationRetainTheNativeReadBarrier() async throws {
        for cancel in [false, true] {
            var release: CheckedContinuation<Void, Never>?, reads = 0
            let metadata = NativeDesktopCameraMetadataPreparation(timeout: 0.05, authorized: { true }, read: { _ in
                reads += 1; await withCheckedContinuation { release = $0 }
            })
            let first = Task { try await metadata.prepare(eligible: { true }, deviceID: nil) }
            try await spin { release != nil }
            if cancel { first.cancel() }
            do { _ = try await first.value; XCTFail("An interrupted metadata caller succeeded") } catch {}
            var secondCompleted = false
            let second = Task { let outcome = try await metadata.prepare(eligible: { false }, deviceID: nil); secondCompleted = true; return outcome }
            await Task.yield(); await Task.yield()
            XCTAssertFalse(secondCompleted, "Camera-Off must not bypass an entered native read after cancellation/timeout")
            release?.resume(); release = nil
            let outcome = try await second.value
            XCTAssertEqual(outcome, .drained); XCTAssertEqual(reads, 1)
        }
    }
    func testReadinessDefaultsToPluggedInWithoutWritingPreferences() {
        let defaults = UserDefaults(suiteName: "join-readiness-\(UUID())")!
        let policy = NativeDesktopJoinReadinessPolicy.current(defaults: defaults)
        XCTAssertEqual(policy.microphone, .whenPluggedIn); XCTAssertEqual(policy.camera, .whenPluggedIn)
        XCTAssertNil(defaults.object(forKey: NativeDesktopJoinReadinessPolicy.microphoneKey))
        XCTAssertNil(defaults.object(forKey: NativeDesktopJoinReadinessPolicy.cameraKey))
    }
    func testUnauthorizedJoinCannotCreateSourceOrAcquireCamera() async throws {
        let lease = NativeDesktopCameraLease()
        let prime = NativeDesktopJoinCameraPrime(lease: lease, authorized: { false }, makeCapture: { _ in
            XCTFail("Unauthorized prime constructed capture"); return JoinPrimeCapture()
        })
        try await prime.run(source: { XCTFail("Unauthorized prime constructed source"); return nil })
        XCTAssertEqual(prime.report["reason"] as? String, "authorization")
        let live = try await lease.acquireLive(owner: UUID(), revoke: {})
        XCTAssertTrue(lease.isCurrent(live)); lease.release(live)
    }
    func testSpeculativePrimeNeverRevokesAnExistingPreview() async throws {
        let lease = NativeDesktopCameraLease()
        var revoked = false
        let acquired = try await lease.acquirePrivate(owner: UUID(), revoke: { revoked = true })
        guard case .owned(let preview) = acquired else { return XCTFail("Preview reservation missing") }
        let prime = NativeDesktopJoinCameraPrime(lease: lease, authorized: { true })
        try await prime.run(source: { XCTFail("Busy camera constructed source"); return nil })
        XCTAssertFalse(revoked); XCTAssertTrue(lease.isCurrent(preview))
        XCTAssertEqual(prime.report["reason"] as? String, "cameraOwned")
        lease.release(preview)
    }
    func testStopBeforeRunCannotInstallALateReservation() async throws {
        let lease = NativeDesktopCameraLease()
        let prime = NativeDesktopJoinCameraPrime(lease: lease, authorized: { true })
        try await prime.stop()
        do { try await prime.run(source: { XCTFail("Stopped prime constructed source"); return nil }); XCTFail("Stopped prime ran") }
        catch is CancellationError {}
        let live = try await lease.acquireLive(owner: UUID(), revoke: {})
        XCTAssertTrue(lease.isCurrent(live)); lease.release(live)
    }
    func testValidPrivateFrameIsStoppedBeforeLeaseReleaseAndNeverCreatesTrack() async throws {
        let lease = NativeDesktopCameraLease(), capture = JoinPrimeCapture()
        let prime = NativeDesktopJoinCameraPrime(lease: lease, authorized: { true }, makeCapture: { _ in capture })
        let factory = LKRTCPeerConnectionFactory()
        try await prime.run(source: { factory.videoSource() })
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        XCTAssertFalse(capture.frameReady); XCTAssertNil(lease.liveTrack)
        XCTAssertEqual(prime.report["state"] as? String, "completed")
        XCTAssertEqual(prime.report["frames"] as? Int, 1)
        XCTAssertEqual(prime.report["stopped"] as? Bool, true)
        let live = try await lease.acquireLive(owner: UUID(), revoke: {})
        XCTAssertTrue(lease.isCurrent(live)); lease.release(live)
    }
    func testLiveClickWaitsForConfirmedPrivateStop() async throws {
        let lease = NativeDesktopCameraLease(), capture = JoinPrimeCapture()
        var allowFrame = false, allowStop = false, liveAcquired = false
        capture.starting = { while !allowFrame { try await Task.sleep(for: .milliseconds(10)) } }
        capture.stopping = { while !allowStop { try await Task.sleep(for: .milliseconds(10)) } }
        let prime = NativeDesktopJoinCameraPrime(lease: lease, authorized: { true }, makeCapture: { _ in capture })
        let factory = LKRTCPeerConnectionFactory()
        let pending = Task { try await prime.run(source: { factory.videoSource() }) }
        try await spin { capture.starts == 1 }
        let live = Task {
            let token = try await lease.acquireLive(owner: UUID(), revoke: {})
            liveAcquired = true; return token
        }
        try await spin { capture.stops == 1 }
        XCTAssertFalse(liveAcquired)
        allowFrame = true; allowStop = true
        _ = try? await pending.value
        let token = try await live.value
        XCTAssertTrue(lease.isCurrent(token)); XCTAssertTrue(prime.cleanupSucceeded)
        lease.release(token)
    }
    func testFailedStopQuarantinesCameraInsteadOfAllowingCompetingOwner() async throws {
        let lease = NativeDesktopCameraLease(), capture = JoinPrimeCapture()
        capture.stopping = { throw GuestCameraError.timedOut }
        let prime = NativeDesktopJoinCameraPrime(lease: lease, authorized: { true }, makeCapture: { _ in capture })
        let factory = LKRTCPeerConnectionFactory()
        do { try await prime.run(source: { factory.videoSource() }); XCTFail("Failed stop was accepted") }
        catch {}
        XCTAssertFalse(prime.cleanupSucceeded)
        XCTAssertEqual(prime.report["stopped"] as? Bool, false)
        do { _ = try await lease.acquireLive(owner: UUID(), revoke: {}); XCTFail("Camera quarantine was bypassed") }
        catch {}
    }
    func testFailedHandoverRetainsUnresolvedCaptureAfterPrimeIsDropped() async throws {
        let lease = NativeDesktopCameraLease(), factory = LKRTCPeerConnectionFactory()
        var capture: JoinPrimeCapture? = JoinPrimeCapture()
        weak var unresolvedCapture = capture
        capture?.starting = { [weak capture] in
            while capture?.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        capture?.stopping = { throw GuestCameraError.timedOut }
        var prime: NativeDesktopJoinCameraPrime? = NativeDesktopJoinCameraPrime(lease: lease,
            authorized: { true }, makeCapture: { [weak capture] _ in capture! })
        weak var releasedPrime = prime
        var running: Task<Void, Error>? = Task { [prime] in try await prime!.run(source: { factory.videoSource() }) }
        try await spin { capture?.starts == 1 }
        // acquireLive installs the replacement token before revoking the prime.
        // The old token must still quarantine its unresolved capture on failure.
        do { _ = try await lease.acquireLive(owner: UUID(), revoke: {}); XCTFail("Failed handover was accepted") }
        catch {}
        _ = try? await running?.value
        running = nil; prime = nil; capture = nil
        await Task.yield()
        XCTAssertNil(releasedPrime, "The lease should retain the capture, not depend on the prime/model lifetime")
        XCTAssertNotNil(unresolvedCapture, "Dropping the model must not release a capturer without confirmed stop")
        do { _ = try await lease.acquireLive(owner: UUID(), revoke: {}); XCTFail("Retired-token quarantine was bypassed") }
        catch {}
    }
    func testBudgetCancelsStartupAndStillRequiresStop() async throws {
        let lease = NativeDesktopCameraLease(), capture = JoinPrimeCapture()
        capture.starting = {
            while capture.cancellations == 0 { try await Task.sleep(for: .milliseconds(10)) }
            throw CancellationError()
        }
        let prime = NativeDesktopJoinCameraPrime(lease: lease, budget: .milliseconds(20), authorized: { true }, makeCapture: { _ in capture })
        let factory = LKRTCPeerConnectionFactory()
        do { try await prime.run(source: { factory.videoSource() }); XCTFail("Budget failed to cancel capture") }
        catch is CancellationError {}
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        XCTAssertTrue(prime.cleanupSucceeded)
        XCTAssertEqual(prime.report["stopped"] as? Bool, true)
    }
    func testSuccessfulSlowStopCannotExpireTheCompletedStartupBudget() async throws {
        let lease = NativeDesktopCameraLease(), capture = JoinPrimeCapture()
        capture.stopping = { try await Task.sleep(for: .milliseconds(80)) }
        let prime = NativeDesktopJoinCameraPrime(lease: lease, budget: .milliseconds(20), authorized: { true }, makeCapture: { _ in capture })
        let factory = LKRTCPeerConnectionFactory()
        try await prime.run(source: { factory.videoSource() })
        XCTAssertEqual(capture.starts, 1); XCTAssertEqual(capture.stops, 1)
        XCTAssertEqual(prime.report["state"] as? String, "completed")
        XCTAssertEqual(prime.report["stopped"] as? Bool, true)
        XCTAssertNil(prime.report["budgetExpired"], "Startup budget must be disarmed before confirmed stop is awaited")
    }
}
