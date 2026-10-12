import AVFoundation
import CallKit
import ConferenceCore
import XCTest
import UIKit
@testable import RockNRoll

@MainActor
final class AudioSessionWorkerTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock(); private var count = 0
        func increment() { lock.lock(); count += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    }
    func testSessionWorkDoesNotBlockMainActor() async throws {
        let worker = AudioSessionWorker(), entered = expectation(description: "worker entered")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        worker.enqueue(operation: {
            XCTAssertFalse(Thread.isMainThread); entered.fulfill()
            _ = release.wait(timeout: .now() + 2)
        })
        await fulfillment(of: [entered], timeout: 1)
        let tick = expectation(description: "main actor remains available")
        Task { @MainActor in tick.fulfill() }
        await fulfillment(of: [tick], timeout: 0.2)
        release.signal()
        try await worker.perform(lease: AudioSessionLease(), operation: {})
    }
    func testRetiredQueuedRequestNeverTouchesSession() async throws {
        let queue = DispatchQueue(label: "test.audio-session.retirement")
        let worker = AudioSessionWorker(queue: queue), lease = AudioSessionLease(), changes = Counter()
        let finished = expectation(description: "retired request completed")
        queue.suspend()
        worker.enqueue(lease: lease, operation: { changes.increment() }) { result in
            if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
            else { XCTFail("Retired request was admitted") }
            finished.fulfill()
        }
        lease.invalidate(); queue.resume()
        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(changes.value, 0)
    }
    func testLeaveRejectsDelayedActivationAndNextMeetingGetsFreshGrant() async throws {
        let queue = DispatchQueue(label: "test.audio-session.call")
        let activations = Counter(), worker = AudioSessionWorker(queue: queue, activate: { activations.increment() })
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false, sessionWorker: worker)
        let granted = expectation(description: "replacement activated")
        queue.suspend()
        owner.start(); owner.end()
        owner.onActivated = { granted.fulfill() }
        owner.start(); queue.resume()
        await fulfillment(of: [granted], timeout: 2)
        XCTAssertTrue(owner.canRestoreAudio)
        XCTAssertEqual(activations.value, 1)
        owner.end()
    }
    func testCompetingCallRetiresActivationBeforeWorkerRuns() async throws {
        let queue = DispatchQueue(label: "test.audio-session.competitor")
        let activations = Counter(), worker = AudioSessionWorker(queue: queue, activate: { activations.increment() })
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false, sessionWorker: worker)
        queue.suspend()
        owner.onActivated = { XCTFail("Audio must not resume across a competing call") }
        owner.start(); owner.audioSessionInterrupted(true); queue.resume()
        try await worker.perform(lease: AudioSessionLease(), operation: {})
        XCTAssertEqual(activations.value, 0); XCTAssertFalse(owner.canRestoreAudio)
        owner.end()
    }
    func testServiceResetReconfiguresBeforeRecoveryAndLeaveRejectsIt() async throws {
        let audio = AudioCoordinator(), ready = expectation(description: "session prepared")
        audio.start(ready: { ready.fulfill() }, failure: { XCTFail("\($0)") })
        await fulfillment(of: [ready], timeout: 3)
        var events: [Bool] = []
        let recovered = expectation(description: "reset ready")
        audio.onServicesChanged = { events.append($0); if $0 { recovered.fulfill() } }
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(events, [false, true])
        audio.endSession(); events = []
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(events.isEmpty)
    }
    func testMeterMailboxKeepsOnlyLatestAndRejectsRetiredSamples() {
        let levels = LatestMicrophoneLevel()
        levels.receive(1); XCTAssertNil(levels.take())
        levels.setEnabled(true)
        for i in 0..<10_000 { levels.receive(Float(i)) }
        XCTAssertEqual(levels.take(), 9999); XCTAssertNil(levels.take())
        levels.receive(0.5); levels.setEnabled(false)
        levels.receive(1); XCTAssertNil(levels.take())
        levels.setEnabled(true); XCTAssertNil(levels.take())
    }
    func testRoomMeterDetachesWhenHiddenButRemainsAvailableInPiP() {
        let activity = MicrophoneActivity(observeLifecycle: false), probe = RoomMicrophoneProbe(activity: activity)
        defer { probe.stop() }
        XCTAssertFalse(probe.isAttachedForTesting)
        activity.setStatus(.on); XCTAssertTrue(probe.isAttachedForTesting)
        activity.setForeground(false); XCTAssertFalse(probe.isAttachedForTesting)
        activity.setFloating(true); XCTAssertTrue(probe.isAttachedForTesting)
        activity.setStatus(.muted); XCTAssertFalse(probe.isAttachedForTesting)
        probe.stop(); activity.setStatus(.on); XCTAssertFalse(probe.isAttachedForTesting)
    }
    func testApplicationHandoffUnholdWaitsForAsynchronousGrant() async throws {
        let worker = AudioSessionWorker(activate: {}), ready = expectation(description: "activated")
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false, sessionWorker: worker)
        owner.onActivated = { ready.fulfill() }; owner.start()
        await fulfillment(of: [ready], timeout: 2)
        owner.onActivated = nil
        try await owner.setTransferHeld(true); XCTAssertFalse(owner.canRestoreAudio)
        try await owner.setTransferHeld(false); XCTAssertTrue(owner.canRestoreAudio)
        owner.end()
    }
    func testServiceResetDuringStartupDoesNotStrandJoin() async throws {
        let queue = DispatchQueue(label: "test.audio-session.startup-reset")
        let audio = AudioCoordinator(worker: AudioSessionWorker(queue: queue))
        let ready = expectation(description: "join remains admitted after reset")
        queue.suspend()
        audio.start(ready: { ready.fulfill() }, failure: { XCTFail("\($0)") })
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification, object: AVAudioSession.sharedInstance())
        queue.resume()
        await fulfillment(of: [ready], timeout: 3)
        audio.endSession()
    }
    func testStaleTransferHoldCannotOutliveLeaveAndReplacementGrant() async throws {
        let queue = DispatchQueue(label: "test.audio-session.transfer-retirement")
        let activations = Counter(), worker = AudioSessionWorker(queue: queue, activate: { activations.increment() })
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false, sessionWorker: worker)
        let first = expectation(description: "initial grant")
        owner.onActivated = { first.fulfill() }; owner.start()
        await fulfillment(of: [first], timeout: 2)
        let held = expectation(description: "hold admitted"), replacement = expectation(description: "replacement grant")
        owner.onHoldChanged = { if $0 { held.fulfill() } }
        queue.suspend()
        let hold = Task { try await owner.setTransferHeld(true) }
        await fulfillment(of: [held], timeout: 1)
        owner.end(); owner.onActivated = { replacement.fulfill() }; owner.start()
        queue.resume()
        do { try await hold.value; XCTFail("Retired transfer completed") } catch is CancellationError { }
        await fulfillment(of: [replacement], timeout: 2)
        XCTAssertEqual(activations.value, 2); XCTAssertTrue(owner.canRestoreAudio)
        owner.end()
    }
    func testCallKitEndRetiresActivationBeforeEndActionArrives() async throws {
        let queue = DispatchQueue(label: "test.audio-session.pending-callkit-end")
        let activations = Counter(), worker = AudioSessionWorker(queue: queue, activate: { activations.increment() })
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let owner = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
            callSnapshot: { snapshot }, systemCallRegistration: true, sessionWorker: worker)
        owner.start(); let id = try XCTUnwrap(owner.callID); owner.markConnected()
        snapshot = [.init(id: id, connected: true, held: false)]
        queue.suspend()
        owner.audioServicesChanged(false); owner.audioServicesChanged(true)
        owner.end(); queue.resume()
        try await worker.perform(lease: AudioSessionLease(), operation: {})
        XCTAssertEqual(activations.value, 0); XCTAssertFalse(owner.canRestoreAudio)
        owner.markEnded(reason: .remoteEnded)
    }
    func testCallKitServiceRecoveryRetriesTransientActivationFailure() async throws {
        let activations = Counter(), worker = AudioSessionWorker(activate: {
            activations.increment()
            if activations.value == 1 { throw NSError(domain: "TransientAudio", code: 1) }
        })
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let owner = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
            callSnapshot: { snapshot }, systemCallRegistration: true, sessionWorker: worker)
        let recovered = expectation(description: "transient reset activation recovered")
        owner.onActivated = { recovered.fulfill() }
        owner.start(); let id = try XCTUnwrap(owner.callID); owner.markConnected()
        snapshot = [.init(id: id, connected: true, held: false)]
        owner.audioServicesChanged(false); owner.audioServicesChanged(true)
        await fulfillment(of: [recovered], timeout: 3)
        XCTAssertEqual(activations.value, 2); XCTAssertTrue(owner.canRestoreAudio)
        owner.markEnded(reason: .remoteEnded)
    }
    func testHoldRetiresQueuedRouteChange() async throws {
        let queue = DispatchQueue(label: "test.audio-session.route-hold"), audio = AudioCoordinator(worker: AudioSessionWorker(queue: queue))
        audio.beginSession(); queue.suspend()
        let route = Task { try await audio.selectBuiltInOutput(speaker: true) }
        await Task.yield()
        audio.suspendConfiguration(); queue.resume()
        do { try await route.value; XCTFail("Held route was admitted") } catch is CancellationError { }
        audio.endSession()
    }
    func testDismissedSpeakerCheckCannotStartQueuedPlayback() async throws {
        let queue = DispatchQueue(label: "test.audio-session.speaker-dismiss"), worker = AudioSessionWorker(queue: queue)
        let speaker = SpeakerCheck(worker: worker)
        queue.suspend(); speaker.play(standalone: true)
        await Task.yield()
        speaker.stop(); queue.resume()
        try await worker.perform(lease: AudioSessionLease(), operation: {})
        XCTAssertFalse(speaker.playing); XCTAssertNil(speaker.error)
    }

    func testLeaveDuringRoomPreparationFinishesWithoutCallOwner() async throws {
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false, activateAudioSession: {})
        let engine = RockRoomEngine(catchUp: CatchUpStore(), chat: ChatStore(), systemCall: owner)
        let target = try JamTarget.parse("https://rock.glowsoft.ru/jams/test")
        let credentials = JamCredentials(serverURL: URL(string: "wss://example.invalid")!, participantToken: "unused",
            jam: JamDetails(id: "test", title: "Pending join", community: "Test", description: ""))
        let left = expectation(description: "early Leave finished")
        engine.onEvent = { if $0 == .left { left.fulfill() } }
        try engine.join(target: target, credentials: credentials, container: UIViewController())
        XCTAssertNil(owner.callID)
        engine.leave()
        XCTAssertFalse(engine.hasJoinStarted)
        await fulfillment(of: [left], timeout: 3)
        XCTAssertNil(owner.callID)
    }

    func testPersistentActivationFailureStopsAtEpisodeDeadline() async throws {
        let attempts = Counter(), worker = AudioSessionWorker(activate: {
            attempts.increment(); throw NSError(domain: "PersistentAudio", code: 1)
        })
        // The production worker seam is required for asynchronous failure.
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let systemOwner = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
            callSnapshot: { snapshot }, systemCallRegistration: true, sessionWorker: worker,
            recoveryWindow: .milliseconds(100), recoveryInterval: .milliseconds(10))
        systemOwner.start(); let id = try XCTUnwrap(systemOwner.callID); systemOwner.markConnected()
        snapshot = [.init(id: id, connected: true, held: false)]
        systemOwner.audioServicesChanged(false); systemOwner.audioServicesChanged(true)
        try await Task.sleep(for: .milliseconds(200))
        let exhausted = attempts.value
        XCTAssertGreaterThan(exhausted, 1); XCTAssertLessThan(exhausted, 20)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(attempts.value, exhausted, "Late failure must not restart an exhausted recovery episode")
        XCTAssertFalse(systemOwner.canRestoreAudio)
        systemOwner.markEnded(reason: .remoteEnded)
    }

    func testOverlappingTransferUnholdWaitsForReplacementGrant() async throws {
        let queue = DispatchQueue(label: "test.audio-session.overlapping-transfer")
        let owner = SystemCallCoordinator(callSnapshot: { [] }, systemCallRegistration: false,
            sessionWorker: AudioSessionWorker(queue: queue, activate: {}))
        let ready = expectation(description: "initial audio"), held = expectation(description: "hold entered")
        owner.onActivated = { ready.fulfill() }; owner.start()
        await fulfillment(of: [ready], timeout: 2)
        owner.onActivated = nil; owner.onHoldChanged = { if $0 { held.fulfill() } }
        queue.suspend()
        let hold = Task { try await owner.setTransferHeld(true) }
        await fulfillment(of: [held], timeout: 1)
        let unhold = Task { try await owner.setTransferHeld(false) }
        await Task.yield(); queue.resume()
        do { try await hold.value; XCTFail("Superseded hold completed") } catch is CancellationError { }
        try await unhold.value
        XCTAssertTrue(owner.canRestoreAudio); owner.end()
    }
    func testPendingCallKitEndDoesNotRequestAutomaticUnhold() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = [], unholds = 0
        let owner = SystemCallCoordinator(transactionRequester: { transaction, done in
            unholds += transaction.actions.filter { ($0 as? CXSetHeldCallAction)?.isOnHold == false }.count
            done(nil)
        }, callSnapshot: { snapshot }, systemCallRegistration: true, activateAudioSession: {})
        owner.start(); let id = try XCTUnwrap(owner.callID), competitor = UUID()
        owner.markConnected()
        snapshot = [.init(id: id, connected: true, held: true), .init(id: competitor, connected: true, held: false)]
        owner.provider(CXProvider(configuration: SystemCallCoordinator.providerConfiguration()),
            perform: CXSetHeldCallAction(call: id, onHold: true))
        owner.end()
        snapshot = [.init(id: id, connected: true, held: true)]
        owner.observedCallChanged(.init(id: competitor, connected: true, held: false, ended: true))
        XCTAssertEqual(unholds, 0)
        owner.markEnded(reason: .remoteEnded)
    }

    func testNewServiceResetGetsFreshRetryWindowNearOldDeadline() async throws {
        let attempts = Counter(), worker = AudioSessionWorker(activate: {
            attempts.increment(); throw NSError(domain: "RepeatedReset", code: 1)
        })
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let owner = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
            callSnapshot: { snapshot }, systemCallRegistration: true, sessionWorker: worker,
            recoveryWindow: .milliseconds(150), recoveryInterval: .milliseconds(10))
        owner.start(); let id = try XCTUnwrap(owner.callID); owner.markConnected()
        snapshot = [.init(id: id, connected: true, held: false)]
        owner.audioServicesChanged(false); owner.audioServicesChanged(true)
        try await Task.sleep(for: .milliseconds(120))
        let beforeSecond = attempts.value
        owner.audioServicesChanged(false); owner.audioServicesChanged(true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertGreaterThan(attempts.value, beforeSecond + 4, "New reset must outlive the retired episode's deadline")
        try await Task.sleep(for: .milliseconds(100))
        let exhausted = attempts.value
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(attempts.value, exhausted)
        owner.markEnded(reason: .remoteEnded)
    }

}
