import AVFoundation
import XCTest
@testable import RockNRoll

@MainActor
final class AudioAcquisitionTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }

    func testJoinOptionsMixExistingAudioAndKeepHandsFreeRouting() {
        let options = AudioCoordinator.communicationOptions
        XCTAssertTrue(options.contains(.allowBluetoothHFP))
        XCTAssertTrue(options.contains(.mixWithOthers))
        XCTAssertTrue(options.contains(.allowBluetoothA2DP))
        XCTAssertFalse(options.contains(.duckOthers))
        XCTAssertFalse(options.contains(.interruptSpokenAudioAndMixWithOthers))
    }

    func testJoinAndMediaServiceResetUseTheSameMixingPolicy() async throws {
        let center = NotificationCenter(), preparations = Counter(), mixing = Counter()
        let audio = AudioCoordinator(prepareSession: { preparations.increment() },
            restoreMixingSession: { mixing.increment() }, notifications: center)
        let ready = expectation(description: "prepared")
        audio.start(ready: { ready.fulfill() }, failure: { XCTFail("\($0)") })
        defer { audio.endSession() }
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(preparations.value, 1)
        audio.callAudioDidActivate()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertGreaterThan(mixing.value, 0)
        let recovered = expectation(description: "reset prepared")
        audio.onServicesChanged = { if $0 { recovered.fulfill() } }
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        await fulfillment(of: [recovered], timeout: 2)
        XCTAssertEqual(preparations.value, 2)
    }

    func testBeganOnlyJoinTransitionCanRecoverOnceWithoutReportingCallHold() async throws {
        var attempts = 0, holds = 0
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: { attempts += 1 }, recoveryWindow: .seconds(1), recoveryInterval: .milliseconds(20))
        owner.onHoldChanged = { if $0 { holds += 1 } }
        owner.start(allowInitialActivationRetry: true); owner.markConnected()
        defer { owner.end() }
        owner.audioSessionInterrupted(true)
        XCTAssertFalse(owner.canRestoreAudio)
        await waitForAudio(owner)
        XCTAssertTrue(owner.canRestoreAudio)
        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(holds, 0, "A route interruption is not a confirmed competing call")
        owner.audioSessionInterrupted(true)
        XCTAssertFalse(try owner.reactivateAudioIfPossible(), "A fresh interruption cannot reuse startup permission")
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertEqual(attempts, 2)
    }

    func testResetRetiresQueuedPreparationAndRestartsOnce() async throws {
        let queue = DispatchQueue(label: "test.join.reset"), preparations = Counter()
        let center = NotificationCenter()
        let audio = AudioCoordinator(worker: AudioSessionWorker(queue: queue),
            prepareSession: { preparations.increment() }, restoreMixingSession: {}, notifications: center)
        let ready = expectation(description: "reset startup ready")
        queue.suspend()
        audio.start(ready: { ready.fulfill() }, failure: { XCTFail("\($0)") })
        try await Task.sleep(for: .milliseconds(20))
        center.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        queue.resume()
        await fulfillment(of: [ready], timeout: 2)
        XCTAssertEqual(preparations.value, 1)
        audio.endSession()
    }

    func testTransientInitialActivationFailureRetriesWithoutEndingMeeting() async throws {
        var attempts = 0, failures = 0
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: {
                attempts += 1
                if attempts == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: 561017449) }
            }, recoveryWindow: .seconds(1), recoveryInterval: .milliseconds(20))
        owner.onFailure = { _ in failures += 1 }
        owner.start(allowInitialActivationRetry: true)
        defer { owner.end() }
        await waitForAudio(owner)
        XCTAssertTrue(owner.canRestoreAudio)
        XCTAssertEqual(attempts, 2); XCTAssertEqual(failures, 0)
    }

    func testPersistentInitialActivationFailureRetiresOwnerAtBoundedDeadline() async throws {
        var failures = 0
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: { throw NSError(domain: "TransientActivation", code: 1) },
            recoveryWindow: .milliseconds(80), recoveryInterval: .milliseconds(20))
        let failed = expectation(description: "startup timed out")
        owner.onFailure = { _ in failures += 1; failed.fulfill() }
        owner.start(allowInitialActivationRetry: true)
        await fulfillment(of: [failed], timeout: 1)
        XCTAssertEqual(failures, 1); XCTAssertNil(owner.callID)
        XCTAssertFalse(owner.canRestoreAudio)
        owner.end()
    }

    func testJoinProbeRevokedWhenRingingConnectedOrHeldCompetitorAppears() async throws {
        for connected in [false, true] {
            for held in [false, true] {
                var snapshot: [SystemCallCoordinator.ObservedCall] = [], attempts = 0
                let owner = SystemCallCoordinator(callSnapshot: { snapshot }, systemCallRegistration: false,
                    activateAudioSession: { attempts += 1 }, recoveryWindow: .seconds(1), recoveryInterval: .milliseconds(20))
                owner.start(allowInitialActivationRetry: true); owner.markConnected()
                owner.audioSessionInterrupted(true)
                snapshot = [.init(id: UUID(), connected: connected, held: held)]
                owner.observedCallChanged(snapshot[0])
                try await Task.sleep(for: .milliseconds(60))
                XCTAssertFalse(owner.canRestoreAudio); XCTAssertEqual(attempts, 1)
                owner.end()
            }
        }
    }

    func testCompetitorDuringQueuedProbePreventsPublicationOfGrant() async throws {
        let queue = DispatchQueue(label: "test.join-focus.worker"), attempts = Counter()
        let worker = AudioSessionWorker(queue: queue, activate: { attempts.increment() }, deactivate: {})
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let owner = SystemCallCoordinator(callSnapshot: { snapshot }, systemCallRegistration: false, sessionWorker: worker,
            recoveryWindow: .seconds(1), recoveryInterval: .milliseconds(20))
        owner.start(allowInitialActivationRetry: true)
        defer { owner.end() }
        await waitForAudio(owner); XCTAssertTrue(owner.canRestoreAudio)
        queue.suspend()
        owner.audioSessionInterrupted(true)
        try await Task.sleep(for: .milliseconds(60))
        snapshot = [.init(id: UUID(), connected: false, held: false)]
        owner.observedCallChanged(snapshot[0])
        queue.resume()
        try await worker.perform(lease: AudioSessionLease(), operation: {})
        XCTAssertEqual(attempts.value, 1)
        XCTAssertFalse(owner.canRestoreAudio)
    }

    func testFocusProbeExpiresAndLeaveCancelsRetryBeforeReplacement() async throws {
        var attempts = 0, reject = false
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            activateAudioSession: {
                attempts += 1
                if reject { throw NSError(domain: "TransientActivation", code: 1) }
            }, recoveryWindow: .milliseconds(80), recoveryInterval: .milliseconds(20))
        owner.start(allowInitialActivationRetry: true); owner.markConnected()
        reject = true; owner.audioSessionInterrupted(true)
        try await Task.sleep(for: .milliseconds(120))
        let expiredAttempts = attempts
        reject = false
        XCTAssertFalse(try owner.reactivateAudioIfPossible())
        XCTAssertFalse(owner.canRestoreAudio); XCTAssertEqual(attempts, expiredAttempts)
        owner.end(); owner.start(allowInitialActivationRetry: true); owner.markConnected()
        owner.audioSessionInterrupted(true); owner.end()
        owner.start(); owner.markConnected(); owner.audioSessionInterrupted(true)
        let replacementAttempts = attempts
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertFalse(owner.canRestoreAudio); XCTAssertEqual(attempts, replacementAttempts)
        owner.end()
    }

    private func waitForAudio(_ owner: SystemCallCoordinator) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !owner.canRestoreAudio, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
