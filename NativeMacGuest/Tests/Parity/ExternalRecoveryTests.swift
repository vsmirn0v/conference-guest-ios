import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// No fixture opens a socket or physical capture/playout device. A blocked
/// camera-stop task exercises real peer.close(), not a replacement close path.
@MainActor final class ExternalRecoveryTests: XCTestCase {
    func testRecoveryDiagnosticsTrackEpochWithoutTransportData() throws {
        let engine = TelemostAdapter()
        let first = engine.ownershipDiagnostics
        XCTAssertEqual(first["executor"] as? String, RecoveryExecutorKind.nativeAdapterSupervisor.rawValue)
        engine.supervisor.advanceGeneration()
        let second = engine.ownershipDiagnostics
        XCTAssertNotEqual(first["connectionGeneration"] as? String, second["connectionGeneration"] as? String)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(second))
        XCTAssertNil(second["invitation"])
        XCTAssertNil(second["credentials"])
        XCTAssertNil(second["sdp"])
    }
    private final class BlockedCameraStop {
        var continuation: CheckedContinuation<Bool, Never>?
        var result: Bool?
        func wait() async -> Bool {
            if let result { return result }
            return await withCheckedContinuation { continuation = $0 }
        }
        func finish(_ clean: Bool) {
            result = clean; continuation?.resume(returning: clean); continuation = nil
        }
    }
    private func eventually(_ predicate: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !predicate(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return predicate()
    }
    private func blockedPeer(_ stop: BlockedCameraStop) async throws -> NativeDesktopRTCPeer {
        _ = LKRTCInitializeSSL()
        // No system-audio owner, send tracks, permission request or camera start.
        let peer = try await NativeDesktopRTCPeer(target: "SUBSCRIBER", factory: LKRTCPeerConnectionFactory(), ice: [])
        peer.installCameraStopForTesting(Task { await stop.wait() })
        return peer
    }
    func testLeaveDrainsBlockedRealPeerRetirementDespiteRecoveryCancellation() async throws {
        let stop = BlockedCameraStop(); defer { stop.finish(true) }
        let engine = TelemostAdapter(), peer = try await blockedPeer(stop)
        engine.publisher = peer; engine.snapshot.phase = .connected
        var audioShutdownReached = false
        engine.beforeAudioShutdownForTesting = { audioShutdownReached = true }
        engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)))
        let recovery = engine.supervisor.recoveryTask
        let closing = await eventually { peer.closed && engine.publisher == nil && engine.supervisor.connectionRetirementTask != nil }
        XCTAssertTrue(closing, "The actual peer.close must be suspended on its camera-stop drain")
        let barrier = engine.supervisor.connectionRetirementTask
        var concurrentCloseFinished = false, leaveFinished = false
        let concurrentClose = Task { let clean = await engine.closeConnections(); concurrentCloseFinished = true; return clean }
        let leave = Task { let clean = await engine.leave(); leaveFinished = true; return clean }
        let leaving = await eventually {
            (engine.snapshot.phase == .leaving && engine.supervisor.connectionRetirementWaitersForTesting == 2) || leaveFinished
        }
        XCTAssertTrue(leaving); XCTAssertEqual(engine.snapshot.phase, .leaving)
        XCTAssertEqual(engine.supervisor.connectionRetirementWaitersForTesting, 2, "Both callers actually joined the blocked retirement")
        XCTAssertFalse(leaveFinished); XCTAssertFalse(concurrentCloseFinished)
        XCTAssertFalse(audioShutdownReached, "Session audio shutdown must wait for the same real peer retirement")
        XCTAssertTrue(recovery?.isCancelled == true)
        concurrentClose.cancel()
        XCTAssertFalse(barrier?.isCancelled ?? true, "Cancelling either waiter must not cancel retirement ownership")
        stop.finish(true)
        let left = await leave.value, closed = await concurrentClose.value
        XCTAssertTrue(left); XCTAssertTrue(closed); XCTAssertTrue(audioShutdownReached)
        XCTAssertEqual(engine.snapshot.phase, .left); XCTAssertTrue(engine.supervisor.cleanupSucceeded)
        XCTAssertNil(engine.supervisor.connectionRetirementTask)
        // Post-Leave state stability: observing the cancelled recovery's result
        // cannot clear or fail a synthetic newer generation. It may already be done.
        let replacement = try await NativeDesktopRTCPeer(target: "SUBSCRIBER", factory: peer.factory, ice: [])
        engine.supervisor.advanceGeneration(); engine.snapshot.phase = .connected; engine.snapshot.lastError = nil
        engine.publisher = replacement
        await recovery?.value
        XCTAssertEqual(engine.snapshot.phase, .connected); XCTAssertNil(engine.snapshot.lastError)
        XCTAssertTrue(engine.publisher === replacement); XCTAssertEqual(engine.supervisor.retries, 1)
        let replacementStopped = await replacement.close(); XCTAssertTrue(replacementStopped)
        engine.publisher = nil
    }
    func testFailedBlockedRetirementStaysFailedForAllClosersAndReplacement() async throws {
        let stop = BlockedCameraStop(); defer { stop.finish(false) }
        let engine = TrueConfAdapter(), peer = try await blockedPeer(stop)
        engine.publisher = peer; engine.snapshot.phase = .connected
        var audioShutdownReached = false, leaveFinished = false
        engine.beforeAudioShutdownForTesting = { audioShutdownReached = true }
        engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ECONNRESET.rawValue)))
        let recovery = engine.supervisor.recoveryTask
        let closing = await eventually { peer.closed && engine.supervisor.connectionRetirementTask != nil }
        XCTAssertTrue(closing)
        let leave = Task { let clean = await engine.leave(); leaveFinished = true; return clean }
        let leaving = await eventually {
            (engine.snapshot.phase == .leaving && engine.supervisor.connectionRetirementWaitersForTesting == 1) || leaveFinished
        }
        XCTAssertTrue(leaving); XCTAssertEqual(engine.snapshot.phase, .leaving)
        XCTAssertEqual(engine.supervisor.connectionRetirementWaitersForTesting, 1)
        XCTAssertFalse(leaveFinished); XCTAssertFalse(audioShutdownReached)
        // Even an invalidly advanced phase cannot bypass an in-flight barrier.
        engine.snapshot.phase = .failed
        do {
            try await engine.connect(invitation: URL(string: "https://tc.example.test/c/0100110011")!, name: "Fixture", quiet: false, sessionID: UUID())
            XCTFail("A new owner cannot be admitted while retirement is blocked")
        } catch { XCTAssertEqual(error as? NativeDesktopRTCError, .cleanupFailed) }
        engine.snapshot.phase = .leaving
        stop.finish(false)
        let left = await leave.value
        XCTAssertFalse(left); XCTAssertTrue(audioShutdownReached)
        XCTAssertFalse(engine.supervisor.cleanupSucceeded); XCTAssertEqual(engine.snapshot.phase, .failed)
        XCTAssertNotNil(engine.supervisor.connectionRetirementTask, "Failed retirement remains owned and sticky")
        let generation = engine.supervisor.generation, failure = engine.snapshot.lastError
        await recovery?.value
        XCTAssertEqual(engine.supervisor.generation, generation); XCTAssertEqual(engine.snapshot.lastError, failure)
        let closedAgain = await engine.closeConnections(), leftAgain = await engine.leave()
        XCTAssertFalse(closedAgain); XCTAssertFalse(leftAgain); XCTAssertFalse(engine.supervisor.cleanupSucceeded)
        do {
            try await engine.connect(invitation: URL(string: "https://tc.example.test/c/0100110011")!, name: "Fixture", quiet: false, sessionID: UUID())
            XCTFail("An unconfirmed camera stop cannot be cleared by another Leave")
        } catch { XCTAssertEqual(error as? NativeDesktopRTCError, .cleanupFailed) }
        XCTAssertEqual(engine.supervisor.retries, 1); XCTAssertNil(engine.publisher)
    }
    func testQueuedTerminalRecoveryCannotFailANewerGeneration() async {
        let engine = TelemostAdapter()
        engine.snapshot.phase = .connected
        engine.recover(TelemostError.ended)
        let obsolete = engine.supervisor.recoveryTask
        engine.supervisor.advanceGeneration(); engine.snapshot.phase = .connected
        await obsolete?.value
        XCTAssertEqual(engine.snapshot.phase, .connected)
        XCTAssertNil(engine.snapshot.lastError); XCTAssertNil(engine.supervisor.failureDuringShutdown)
        engine.supervisor.cancelRecovery()
    }
    func testPOSIXDisconnectRecoveryAndLeaveRepeatedly() async {
        for code in [POSIXErrorCode.ENOTCONN, .ECONNRESET, .EPIPE] {
            let engine = TelemostAdapter()
            engine.snapshot.phase = .connected
            engine.snapshot.microphoneOn = true; engine.snapshot.cameraOn = true; engine.snapshot.sharing = true
            let generation = engine.supervisor.generation
            engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue)))
            XCTAssertEqual(engine.snapshot.phase, .reconnecting)
            XCTAssertEqual(engine.supervisor.retries, 1)
            XCTAssertNotEqual(engine.supervisor.generation, generation)
            XCTAssertFalse(engine.snapshot.microphoneOn); XCTAssertFalse(engine.snapshot.cameraOn); XCTAssertFalse(engine.snapshot.sharing)
            let clean = await engine.leave()
            XCTAssertTrue(clean); XCTAssertEqual(engine.snapshot.phase, .left)
            XCTAssertNil(engine.supervisor.recoveryTask); XCTAssertNil(engine.audio)
            XCTAssertNil(engine.publisher); XCTAssertNil(engine.subscriber)
            // A late callback from the retired generation must stay harmless.
            engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(code.rawValue)))
            XCTAssertEqual(engine.snapshot.phase, .left); XCTAssertNil(engine.supervisor.recoveryTask)
        }
    }

    func testNetworkRecoveryRemainsBoundedAndTerminalFailuresStayTerminal() async {
        let terminal: [Error] = [TelemostError.removed, TelemostError.ended, TelemostError.rejected("4003"),
            TelemostError.admissionRequired, TelemostError.incompatibleProtocol, TelemostError.invalidResponse,
            TrueConfError.ended, TrueConfError.rejected, NativeDesktopRTCError.cleanupFailed,
            NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.EINVAL.rawValue)),
            NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue)]
        for error in terminal {
            XCTAssertFalse(NativeAdapterRecoveryPolicy.isRetryableTransportFailure(error), "\(error)")
        }
        let engine = TelemostAdapter()
        engine.snapshot.phase = .connected
        for _ in 0..<3 {
            engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)))
            engine.supervisor.cancelRecovery()
        }
        engine.snapshot.phase = .connected
        engine.recover(NSError(domain: NSPOSIXErrorDomain, code: Int(POSIXErrorCode.ENOTCONN.rawValue)))
        let cleanup = engine.supervisor.recoveryTask
        await cleanup?.value
        XCTAssertEqual(engine.snapshot.phase, .failed)
        XCTAssertEqual(engine.supervisor.retries, 3, "A fourth disconnect cannot extend the retry budget")
        XCTAssertNil(engine.supervisor.recoveryTask); XCTAssertNil(engine.audio)
        XCTAssertNil(engine.publisher); XCTAssertNil(engine.subscriber)
    }
}
