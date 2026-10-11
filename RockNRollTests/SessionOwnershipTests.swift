import AVFoundation
import CallKit
import JazzSDK
import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class SessionOwnershipTests: XCTestCase {
    func testFreshNativeInterruptionCannotReuseFailedCompetitorRecovery() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var reject = false
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("Unexpected CallKit transaction") },
            callSnapshot: { snapshot }, systemCallRegistration: false,
            activateAudioSession: { if reject { throw NSError(domain: "TransientActivation", code: 1) } })
        calls.start(); calls.markConnected()
        defer { calls.end() }
        let first = UUID()
        snapshot = [.init(id: first, connected: true, held: false)]
        calls.observedCallChanged(snapshot[0])
        snapshot = []; reject = true
        calls.observedCallChanged(.init(id: first, connected: true, held: false, ended: true))
        XCTAssertFalse(calls.canRestoreAudio)
        // A new interruption arrives before its competing call reaches CXCallObserver.
        calls.audioSessionInterrupted(true)
        reject = false
        XCTAssertFalse(try calls.reactivateAudioIfPossible(), "The previous call's completion must not release a fresh interruption")
        XCTAssertFalse(calls.canRestoreAudio)
        calls.audioSessionInterrupted(false)
        XCTAssertTrue(calls.canRestoreAudio, "A fresh ended notification still resumes the meeting")
    }

    func testNativeMeetingResumesAfterEndedNotificationWithoutMediaPlayerHint() {
        var activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { [] }, systemCallRegistration: false, activateAudioSession: { activations += 1 })
        calls.start(); calls.markConnected()
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        XCTAssertFalse(calls.canRestoreAudio)
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        XCTAssertTrue(calls.canRestoreAudio)
        XCTAssertEqual(activations, 2, "Continuous meeting policy differs from paused media playback")
        calls.end()
    }

    func testNativeHoldEventsCoalesceAndResumeOnlyAfterLastCompetitor() {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var events: [String] = []
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { snapshot }, systemCallRegistration: false, activateAudioSession: {})
        calls.onActivated = { events.append("activate") }
        calls.onDeactivated = { events.append("deactivate") }
        calls.onHoldChanged = { events.append($0 ? "hold" : "unhold") }
        calls.start(); calls.markConnected(); events.removeAll()
        let first = UUID(), second = UUID()
        snapshot = [.init(id: first, connected: false, held: false), .init(id: second, connected: true, held: true)]
        calls.observedCallChanged(snapshot[0])
        calls.audioSessionInterrupted(true)
        calls.observedCallChanged(snapshot[1])
        XCTAssertEqual(events, ["hold", "deactivate"])
        snapshot.removeFirst()
        calls.observedCallChanged(.init(id: first, connected: true, held: false, ended: true))
        calls.audioSessionInterrupted(false)
        XCTAssertEqual(events, ["hold", "deactivate"])
        snapshot = []
        calls.observedCallChanged(.init(id: second, connected: true, held: false, ended: true))
        XCTAssertEqual(events, ["hold", "deactivate", "unhold", "activate"])
        calls.end()
    }

    func testRetiredNativeRetryCannotActivateReplacementMeeting() async throws {
        var reject = false, attempts = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { [] }, systemCallRegistration: false, activateAudioSession: {
                attempts += 1
                if reject { throw NSError(domain: "test", code: 1) }
            })
        calls.start(); calls.markConnected()
        let old = calls.callID
        calls.audioSessionInterrupted(true); reject = true; calls.audioSessionInterrupted(false)
        calls.end(); reject = false; calls.start(); calls.markConnected()
        XCTAssertNotEqual(calls.callID, old)
        calls.audioSessionInterrupted(true)
        try await Task.sleep(for: .milliseconds(650))
        XCTAssertFalse(calls.canRestoreAudio)
        XCTAssertEqual(attempts, 3)
        calls.end()
    }

    func testApplicationAudioModeWaitsForExistingCallBeforeJoining() throws {
        let other = UUID()
        var snapshot: [SystemCallCoordinator.ObservedCall] = [.init(id: other, connected: true, held: false)]
        var activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("Must not register a system call") },
            callSnapshot: { snapshot }, systemCallRegistration: false, activateAudioSession: { activations += 1 })
        calls.start()
        let identity = try XCTUnwrap(calls.callID)
        XCTAssertEqual(activations, 0)
        XCTAssertFalse(calls.canRestoreAudio)
        snapshot = []
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        XCTAssertEqual(activations, 1)
        XCTAssertEqual(calls.callID, identity)
        XCTAssertTrue(calls.canRestoreAudio)
        calls.end()
    }

    func testApplicationAudioModeNeverActivatesDuringRingingOrHeldCompetitor() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { snapshot }, systemCallRegistration: false, activateAudioSession: { activations += 1 })
        calls.start(); calls.markConnected()
        let identity = try XCTUnwrap(calls.callID), other = UUID()
        calls.audioSessionInterrupted(true)
        for connected in [false, true] {
            snapshot = [.init(id: other, connected: connected, held: true)]
            calls.observedCallChanged(snapshot[0])
            calls.audioSessionInterrupted(false)
            XCTAssertFalse(try calls.reactivateAudioIfPossible())
            XCTAssertFalse(calls.canRestoreAudio)
            XCTAssertEqual(activations, 1)
        }
        snapshot = []
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        XCTAssertEqual(activations, 2)
        XCTAssertTrue(calls.canRestoreAudio)
        XCTAssertEqual(calls.callID, identity)
        calls.end()
    }

    func testApplicationAudioModeRequiresFreshReleaseAndRetainsFailedActivation() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var reject = false, activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { snapshot }, systemCallRegistration: false, activateAudioSession: {
                if reject { throw NSError(domain: "test", code: 1) }
                activations += 1
            })
        calls.start(); calls.markConnected()
        calls.audioSessionInterrupted(true)
        calls.observedCallChanged(.init(id: UUID(), connected: true, held: false, ended: true))
        XCTAssertEqual(activations, 1, "An unrelated ended call is not release evidence")
        XCTAssertFalse(try calls.reactivateAudioIfPossible())
        let other = UUID()
        snapshot = [.init(id: other, connected: false, held: false)]
        calls.observedCallChanged(snapshot[0])
        snapshot = []; reject = true
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        XCTAssertFalse(calls.canRestoreAudio)
        reject = false
        XCTAssertTrue(try calls.reactivateAudioIfPossible(), "Failed activation retains this episode's release")
        calls.audioSessionInterrupted(true)
        XCTAssertFalse(try calls.reactivateAudioIfPossible(), "A new interruption cannot reuse the preceding release")
        calls.end()
        calls.audioSessionInterrupted(false)
        XCTAssertNil(calls.callID)
        XCTAssertEqual(activations, 2)
    }

    func testApplicationTransferUnholdCannotTakeAudioFromCompetingCall() async throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { snapshot }, systemCallRegistration: false, activateAudioSession: { activations += 1 })
        calls.start(); calls.markConnected()
        try await calls.setTransferHeld(true)
        let other = UUID()
        snapshot = [.init(id: other, connected: true, held: false)]
        calls.observedCallChanged(snapshot[0])
        do { try await calls.setTransferHeld(false); XCTFail("A competitor still owns audio") }
        catch { XCTAssertEqual(activations, 1) }
        snapshot = []
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        XCTAssertTrue(calls.canRestoreAudio)
        XCTAssertEqual(activations, 2)
        calls.end()
    }

    func testApplicationAudioRetriesTransientActivationFailureAfterCallEnds() async throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var attempts = 0
        let calls = SystemCallCoordinator(transactionRequester: { _, _ in XCTFail("No system call transaction") },
            callSnapshot: { snapshot }, systemCallRegistration: false, activateAudioSession: {
                attempts += 1
                if attempts == 2 { throw NSError(domain: "test", code: 1) }
            })
        calls.start(); calls.markConnected()
        let other = UUID()
        snapshot = [.init(id: other, connected: true, held: false)]
        calls.observedCallChanged(snapshot[0])
        snapshot = []
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        XCTAssertFalse(calls.canRestoreAudio)
        let deadline = Date().addingTimeInterval(2)
        while !calls.canRestoreAudio && Date() < deadline { try await Task.sleep(for: .milliseconds(25)) }
        XCTAssertTrue(calls.canRestoreAudio)
        XCTAssertEqual(attempts, 3)
        calls.end()
    }

    // Record acknowledgments at the delegate boundary: these local actions
    // are not attached to a system transaction.
    private final class StartAction: CXStartCallAction {
        var fulfilled = false
        override func fulfill() { fulfilled = true }
    }
    private final class HoldAction: CXSetHeldCallAction {
        var fulfilled = false
        override func fulfill() { fulfilled = true }
    }

    func testTerminationBeforeQueuedHoldCallbackPreservesMeetingOwnership() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var deferredHold = false
        let calls = SystemCallCoordinator(transactionRequester: { _, done in done(nil) }, callSnapshot: { snapshot })
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID)
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: false)]
        calls.provider(provider, didActivate: .sharedInstance())
        XCTAssertFalse(calls.isAwaitingAudioRecovery)
        calls.onHoldChanged = { held in Task { @MainActor in deferredHold = held } }
        snapshot = [.init(id: id, connected: true, held: true),
                    .init(id: UUID(), connected: false, held: false)]
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        XCTAssertFalse(deferredHold, "The engine's deferred callback has not executed yet")
        XCTAssertTrue(calls.isAwaitingAudioRecovery)
        let context = GuestTerminationContext(established: true, leaving: false, rebuilding: false,
                                             recoveringNetwork: false, recoveringAudio: calls.isAwaitingAudioRecovery)
        for event in [CallEvent.inactive, .left, .canceled] { XCTAssertEqual(context.resolve(event), .recover) }
        XCTAssertEqual(calls.callID, id)
        calls.markEnded(reason: .remoteEnded)
    }

    func testDeactivationAndCompetingCallAreVisibleBeforeEngineCallbacks() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let calls = SystemCallCoordinator(transactionRequester: { _, done in done(nil) }, callSnapshot: { snapshot })
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID)
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: false)]
        calls.provider(provider, didActivate: .sharedInstance())
        XCTAssertFalse(calls.isAwaitingAudioRecovery)
        snapshot = [.init(id: id, connected: true, held: true)]
        XCTAssertTrue(calls.isAwaitingAudioRecovery, "Observer hold can precede the provider delegate")
        snapshot = [.init(id: id, connected: true, held: false)]
        snapshot.append(.init(id: UUID(), connected: false, held: false))
        XCTAssertTrue(calls.isAwaitingAudioRecovery, "Even a dialing competitor owns a competing call")
        snapshot.removeLast()
        calls.provider(provider, didDeactivate: .sharedInstance())
        XCTAssertTrue(calls.isAwaitingAudioRecovery)
        calls.markEnded(reason: .remoteEnded)
        XCTAssertFalse(calls.isAwaitingAudioRecovery, "An explicitly ended call cannot authorize rejoining")
    }

    func testTypedHostEndAndRejectionWinOverInterruptionOrRebuild() {
        for rebuilding in [false, true] {
            let context = GuestTerminationContext(established: true, leaving: false, rebuilding: rebuilding,
                                                 recoveringNetwork: true, recoveringAudio: true)
            XCTAssertEqual(context.resolve(.inactive, reason: .kickedFromConference(.callEnded)), .finish(.left))
            XCTAssertEqual(context.resolve(.left, reason: .network(.roomClosed)), .finish(.left))
            for reason in [JazzConferenceKickReason.beenKicked, .maxConferenceCapacityExceeded,
                           .maxConferenceViewersCapacityExceeded, .maxConferenceDurationExceeded,
                           .featureUnsupported, .unknowned] {
                XCTAssertEqual(context.resolve(.inactive, reason: .kickedFromConference(reason)), .finish(.evicted))
            }
            for reason in [JazzConferenceConnectionStage.TerminationReason.network(.unathorized),
                           .network(.roomNotFound(nil)), .rejectedByRecipient, .alreadyInCall,
                           .webinarUnsupported, .network(.unsupported)] {
                XCTAssertEqual(context.resolve(.left, reason: reason), .finish(.failed))
            }
        }
    }

    func testUnknownEndRecoversOnlyEstablishedInterruptionAndLocalTeardownIsIgnored() {
        var context = GuestTerminationContext(established: false, leaving: false, rebuilding: false,
                                             recoveringNetwork: false, recoveringAudio: true)
        XCTAssertEqual(context.resolve(.inactive), .finish(.inactive), "Initial join failures remain failures")
        context.established = true
        XCTAssertEqual(context.resolve(.left), .recover)
        XCTAssertEqual(context.resolve(.left, reason: .network(.rejectedDueToConnectionProblem)), .recover)
        context.rebuilding = true
        XCTAssertEqual(context.resolve(.inactive), .ignore)
        XCTAssertEqual(context.resolve(.canceled, reason: .userCanceled), .ignore)
        context.leaving = true
        XCTAssertEqual(context.resolve(.left, reason: .network(.rejectedDueToConnectionProblem)), .finish(.left))
        context.leaving = false; context.rebuilding = false; context.recoveringAudio = false
        XCTAssertEqual(context.resolve(.left), .finish(.left), "Ordinary end is not silently treated as a hold")
        context.recoveringNetwork = true
        XCTAssertEqual(context.resolve(.inactive), .recover)
    }

    func testRecoveryAfterLongCallWithoutActivationOrUnholdCallbacks() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var activations = 0, ended = 0, muteChanges = 0
        var gate = CallAudioRecoveryGate()
        let calls = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
            callSnapshot: { snapshot }, activateAudioSession: { activations += 1 })
        calls.onActivated = { gate.activate() }
        calls.onDeactivated = { gate.deactivate() }
        calls.onHoldChanged = { gate.setHeld($0) }
        calls.onEnded = { _ in ended += 1 }
        calls.onMuteChanged = { _ in muteChanges += 1 }
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID), other = UUID()
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: false)]
        calls.provider(provider, didActivate: .sharedInstance())
        XCTAssertTrue(gate.takeRecovery())
        snapshot = [.init(id: id, connected: true, held: true),
                    .init(id: other, connected: true, held: false)]
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        calls.provider(provider, didDeactivate: .sharedInstance())
        // Missing callbacks are the significant difference after suspension.
        // Repeated checks during a 54+ second call must not steal audio or spend recovery.
        for _ in 0..<90 {
            XCTAssertFalse(try calls.reactivateAudioIfPossible())
            XCTAssertFalse(gate.takeRecovery())
        }
        XCTAssertEqual(activations, 0)
        snapshot = [.init(id: id, connected: true, held: false)]
        XCTAssertTrue(try calls.reactivateAudioIfPossible())
        XCTAssertEqual(activations, 1)
        XCTAssertTrue(calls.canRestoreAudio)
        XCTAssertTrue(gate.takeRecovery(), "Current ownership repairs both missing resume callbacks")
        XCTAssertFalse(gate.takeRecovery())
        calls.provider(provider, didDeactivate: .sharedInstance())
        XCTAssertFalse(calls.canRestoreAudio, "A late deactivation must not leave the meeting permanently silent")
        XCTAssertFalse(try calls.reactivateAudioIfPossible(), "A fresh deactivation cannot reuse the previous call's release")
        calls.provider(provider, didActivate: .sharedInstance())
        XCTAssertTrue(try calls.reactivateAudioIfPossible())
        XCTAssertTrue(gate.takeRecovery())
        XCTAssertEqual(calls.callID, id)
        XCTAssertEqual(ended, 0); XCTAssertEqual(muteChanges, 0)
        calls.markEnded(reason: .remoteEnded)
    }

    func testReactivationRequiresLiveUnheldOwnershipAndSuccessfulActivation() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var attempts = 0, activated = 0
        var reject = true
        let calls = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
            callSnapshot: { snapshot }, activateAudioSession: {
                attempts += 1
                if reject { throw NSError(domain: "AudioStillSettling", code: 1) }
            })
        calls.onActivated = { activated += 1 }
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID)
        for unavailable in [[], [.init(id: id, connected: false, held: false)],
                            [.init(id: id, connected: true, held: true)],
                            [.init(id: id, connected: true, held: false, ended: true)],
                            [.init(id: id, connected: true, held: false),
                             .init(id: UUID(), connected: false, held: false)]] as [[SystemCallCoordinator.ObservedCall]] {
            snapshot = unavailable
            XCTAssertFalse(try calls.reactivateAudioIfPossible())
        }
        XCTAssertEqual(attempts, 0)
        snapshot = [.init(id: id, connected: true, held: false)]
        XCTAssertThrowsError(try calls.reactivateAudioIfPossible())
        XCTAssertEqual(activated, 0); XCTAssertFalse(calls.canRestoreAudio)
        reject = false
        XCTAssertTrue(try calls.reactivateAudioIfPossible())
        XCTAssertEqual(activated, 1)
        calls.markEnded(reason: .remoteEnded)
        XCTAssertFalse(try calls.reactivateAudioIfPossible())
        XCTAssertEqual(attempts, 2)
    }

    func testDelayedCompetingCallObservationStillResumes() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var transactions: [CXTransaction] = []
        var changes = 0
        let calls = SystemCallCoordinator(transactionRequester: { tx, done in transactions.append(tx); done(nil) },
            callSnapshot: { snapshot })
        calls.onCallStateChanged = { changes += 1 }
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID), other = UUID()
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: true)]
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        // Deliver beyond the former three-second attribution window.
        Thread.sleep(forTimeInterval: 3.1)
        let competitor = SystemCallCoordinator.ObservedCall(id: other, connected: true, held: false)
        snapshot.append(competitor)
        calls.observedCallChanged(competitor)
        XCTAssertFalse(transactions.contains { $0.actions.contains { ($0 as? CXSetHeldCallAction)?.isOnHold == false } })
        snapshot.removeLast()
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        XCTAssertTrue(transactions.contains { $0.actions.contains { ($0 as? CXSetHeldCallAction)?.isOnHold == false } })
        XCTAssertEqual(changes, 2)
        calls.markEnded(reason: .remoteEnded)
    }

    func testHandoffHoldCannotBeAutomaticallyReactivated() async throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var actions: [CXAction] = []
        var activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { tx, done in
            XCTAssertTrue(Thread.isMainThread, "Transfer state and CallKit callbacks share the main actor")
            actions += tx.actions; done(nil)
        }, callSnapshot: { snapshot }, activateAudioSession: { activations += 1 })
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID)
        snapshot = [.init(id: id, connected: true, held: false)]
        let task = Task { try await calls.setTransferHeld(true) }
        while !actions.contains(where: { $0 is CXSetHeldCallAction }) { await Task.yield() }
        calls.resumeIfPossible()
        XCTAssertFalse(try calls.reactivateAudioIfPossible(), "Even a stale unheld snapshot cannot override explicit handoff")
        let hold = try XCTUnwrap(actions.compactMap { $0 as? CXSetHeldCallAction }.last)
        calls.provider(CXProvider(configuration: CXProviderConfiguration()), perform: hold)
        try await task.value
        XCTAssertFalse(try calls.reactivateAudioIfPossible())
        XCTAssertEqual(activations, 0)
        calls.markEnded(reason: .remoteEnded)
    }

    func testHeldToUnheldSnapshotRepairsMissingProviderCallbacks() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var actions: [CXAction] = []
        let calls = SystemCallCoordinator(transactionRequester: { tx, done in actions += tx.actions; done(nil) },
            callSnapshot: { snapshot }, activateAudioSession: {})
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID)
        snapshot = [.init(id: id, connected: true, held: true)]
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        XCTAssertFalse(actions.contains { ($0 as? CXSetHeldCallAction)?.isOnHold == false })
        calls.resumeIfPossible()
        XCTAssertEqual(actions.filter { ($0 as? CXSetHeldCallAction)?.isOnHold == false }.count, 0,
                       "Foreground checking cannot override an unresolved system hold")
        calls.resumeIfPossible()
        XCTAssertEqual(actions.filter { ($0 as? CXSetHeldCallAction)?.isOnHold == false }.count, 0)
        XCTAssertFalse(try calls.reactivateAudioIfPossible(), "The resume request is not proof that hold ended")
        snapshot[0].held = false
        XCTAssertTrue(try calls.reactivateAudioIfPossible())
        XCTAssertTrue(calls.canRestoreAudio)
        calls.markEnded(reason: .remoteEnded)
    }

    func testResumeTimeoutAllowsRetryWithoutAffectingNewerRequest() throws {
        var actions: [CXAction] = []
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        let calls = SystemCallCoordinator(transactionRequester: { tx, done in actions += tx.actions; done(nil) },
                                          callSnapshot: { snapshot })
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID), other = UUID()
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: true), .init(id: other, connected: false, held: false)]
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        snapshot.removeLast()
        calls.resumeIfPossible()
        let first = try XCTUnwrap(actions.compactMap { $0 as? CXSetHeldCallAction }.last)
        calls.provider(provider, timedOutPerforming: first)
        calls.resumeIfPossible()
        let second = try XCTUnwrap(actions.compactMap { $0 as? CXSetHeldCallAction }.last)
        XCTAssertNotEqual(first.uuid, second.uuid)
        calls.provider(provider, timedOutPerforming: first)
        calls.resumeIfPossible()
        XCTAssertEqual(actions.filter { $0 is CXSetHeldCallAction }.count, 2)
        calls.markEnded(reason: .remoteEnded)
    }

    func testStaleUnheldSnapshotCannotOverrideFreshSystemHoldOrDeactivation() throws {
        for holdBeforeDeactivation in [true, false] {
            var snapshot: [SystemCallCoordinator.ObservedCall] = []
            var actions: [CXAction] = []
            var activations = 0, holdChanges: [Bool] = []
            let calls = SystemCallCoordinator(transactionRequester: { tx, done in actions += tx.actions; done(nil) },
                callSnapshot: { snapshot }, activateAudioSession: { activations += 1 })
            calls.start(); calls.markConnected()
            let id = try XCTUnwrap(calls.callID), other = UUID()
            let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
            snapshot = [.init(id: id, connected: true, held: false)]
            calls.provider(provider, didActivate: .sharedInstance())
            calls.onHoldChanged = { holdChanges.append($0) }
            if holdBeforeDeactivation { calls.provider(provider, perform: HoldAction(call: id, onHold: true)) }
            calls.provider(provider, didDeactivate: .sharedInstance())
            // Phone is beginning to dial, but CXCallObserver still describes the meeting before hold.
            for _ in 0..<90 {
                calls.resumeIfPossible()
                XCTAssertFalse(try calls.reactivateAudioIfPossible())
            }
            XCTAssertEqual(activations, 0)
            XCTAssertFalse(actions.contains { ($0 as? CXSetHeldCallAction)?.isOnHold == false })
            XCTAssertFalse(holdChanges.contains(false))
            XCTAssertFalse(calls.canRestoreAudio)
            if !holdBeforeDeactivation { calls.provider(provider, perform: HoldAction(call: id, onHold: true)) }
            let competitor = SystemCallCoordinator.ObservedCall(id: other, connected: false, held: false)
            snapshot = [.init(id: id, connected: true, held: true), competitor]
            calls.observedCallChanged(competitor)
            XCTAssertFalse(try calls.reactivateAudioIfPossible(), "An unconnected dialing call still owns the interruption")
            snapshot = [.init(id: id, connected: true, held: true)]
            calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
            XCTAssertEqual(actions.filter { ($0 as? CXSetHeldCallAction)?.isOnHold == false }.count, 1)
            XCTAssertFalse(try calls.reactivateAudioIfPossible())
            snapshot[0].held = false
            XCTAssertTrue(try calls.reactivateAudioIfPossible())
            XCTAssertEqual(activations, 1)
            XCTAssertTrue(calls.canRestoreAudio)
            XCTAssertEqual(holdChanges.last, false)
            XCTAssertEqual(calls.callID, id)
            calls.markEnded(reason: .remoteEnded)
        }
    }

    func testPreviousOrUnseenCompetingCallCannotAuthorizeNewInterruption() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var actions: [CXAction] = []
        var activations = 0
        let calls = SystemCallCoordinator(transactionRequester: { tx, done in actions += tx.actions; done(nil) },
            callSnapshot: { snapshot }, activateAudioSession: { activations += 1 })
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID), other = UUID()
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: true), .init(id: other, connected: true, held: false)]
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        calls.provider(provider, didDeactivate: .sharedInstance())
        snapshot = [.init(id: id, connected: true, held: false)]
        XCTAssertTrue(try calls.reactivateAudioIfPossible())
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        calls.provider(provider, didDeactivate: .sharedInstance())
        calls.observedCallChanged(.init(id: other, connected: true, held: false, ended: true))
        calls.resumeIfPossible()
        XCTAssertFalse(try calls.reactivateAudioIfPossible())
        XCTAssertEqual(activations, 1)
        XCTAssertFalse(actions.contains { ($0 as? CXSetHeldCallAction)?.isOnHold == false })
        calls.provider(provider, perform: HoldAction(call: id, onHold: false))
        XCTAssertTrue(try calls.reactivateAudioIfPossible(), "A fresh system unhold authorizes recovery")
        XCTAssertEqual(activations, 2)
        calls.markEnded(reason: .remoteEnded)
    }

    func testDeactivationBeforeDelayedHoldRetainsCompletedCompetitorEvidence() throws {
        var snapshot: [SystemCallCoordinator.ObservedCall] = []
        var actions: [CXAction] = []
        let calls = SystemCallCoordinator(transactionRequester: { tx, done in actions += tx.actions; done(nil) },
                                          callSnapshot: { snapshot }, activateAudioSession: {})
        calls.start(); calls.markConnected()
        let id = try XCTUnwrap(calls.callID), other = UUID()
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        snapshot = [.init(id: id, connected: true, held: false)]
        calls.provider(provider, didActivate: .sharedInstance())
        snapshot.append(.init(id: other, connected: false, held: false))
        calls.provider(provider, didDeactivate: .sharedInstance())
        snapshot = [.init(id: id, connected: true, held: true)]
        calls.provider(provider, perform: HoldAction(call: id, onHold: true))
        calls.resumeIfPossible()
        XCTAssertEqual(actions.filter { ($0 as? CXSetHeldCallAction)?.isOnHold == false }.count, 1)
        XCTAssertFalse(try calls.reactivateAudioIfPossible())
        snapshot[0].held = false
        XCTAssertTrue(try calls.reactivateAudioIfPossible())
        calls.markEnded(reason: .remoteEnded)
    }

    func testFreshYieldCannotReuseSystemUnholdBeforePreviousRecoveryCompletes() throws {
        for nextStartsWithHold in [true, false] {
            var snapshot: [SystemCallCoordinator.ObservedCall] = []
            var activations = 0
            let calls = SystemCallCoordinator(transactionRequester: { _, done in done(nil) },
                callSnapshot: { snapshot }, activateAudioSession: { activations += 1 })
            calls.start(); calls.markConnected()
            let id = try XCTUnwrap(calls.callID)
            let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
            snapshot = [.init(id: id, connected: true, held: true)]
            calls.provider(provider, perform: HoldAction(call: id, onHold: true))
            calls.provider(provider, perform: HoldAction(call: id, onHold: false))
            snapshot[0].held = false
            if nextStartsWithHold { calls.provider(provider, perform: HoldAction(call: id, onHold: true)) }
            calls.provider(provider, didDeactivate: .sharedInstance())
            XCTAssertFalse(try calls.reactivateAudioIfPossible())
            XCTAssertEqual(activations, 0)
            calls.markEnded(reason: .remoteEnded)
        }
    }

    func testMeetingAdvertisesHoldSupportAtStartAndConnection() throws {
        var transactions: [CXTransaction] = []
        var updates: [(UUID, CXCallUpdate)] = []
        let calls = SystemCallCoordinator(transactionRequester: { transaction, completion in
            transactions.append(transaction); completion(nil)
        }, callUpdateReporter: { updates.append(($0, $1)) })
        let configuration = SystemCallCoordinator.providerConfiguration()
        XCTAssertEqual(configuration.maximumCallGroups, 2)
        XCTAssertEqual(configuration.maximumCallsPerCallGroup, 1)
        let provider = CXProvider(configuration: configuration)
        calls.start()
        let requested = try XCTUnwrap(transactions.first?.actions.first as? CXStartCallAction)
        let start = StartAction(call: requested.callUUID, handle: requested.handle)
        calls.provider(provider, perform: start)
        XCTAssertTrue(start.fulfilled)
        XCTAssertEqual(updates.count, 1)
        calls.markConnected()
        XCTAssertEqual(updates.count, 2)
        for (id, update) in updates {
            XCTAssertEqual(id, calls.callID)
            XCTAssertTrue(update.supportsHolding)
            XCTAssertFalse(update.supportsGrouping)
            XCTAssertFalse(update.supportsUngrouping)
            XCTAssertFalse(update.supportsDTMF)
        }
        let count = transactions.count
        calls.start()
        XCTAssertEqual(transactions.count, count, "Two system groups must not start a second meeting")
        calls.markEnded(reason: .remoteEnded)
    }

    func testSystemHoldAndResumeKeepMeetingIdentityAndMuteIntent() throws {
        let calls = SystemCallCoordinator(transactionRequester: { _, completion in completion(nil) })
        var holds: [Bool] = []
        var muteChanges = 0, ends = 0
        calls.onHoldChanged = { holds.append($0) }
        calls.onMuteChanged = { _ in muteChanges += 1 }
        calls.onEnded = { _ in ends += 1 }
        calls.start()
        let id = try XCTUnwrap(calls.callID)
        let provider = CXProvider(configuration: SystemCallCoordinator.providerConfiguration())
        for held in [true, false] {
            let action = HoldAction(call: id, onHold: held)
            calls.provider(provider, perform: action)
            XCTAssertTrue(action.fulfilled)
            XCTAssertEqual(calls.callID, id)
        }
        XCTAssertEqual(holds, [true, false])
        XCTAssertEqual(muteChanges, 0)
        XCTAssertEqual(ends, 0)
        calls.markEnded(reason: .remoteEnded)
    }

    func testTimedOutHoldCallbacksCannotCompleteNewResume() async throws {
        var transactions: [CXTransaction] = []
        var completions: [(Error?) -> Void] = []
        let calls = SystemCallCoordinator(transactionRequester: { transaction, callback in
            transactions.append(transaction); completions.append(callback)
        })
        calls.start()
        let hold = Task { try? await calls.setTransferHeld(true) }
        while transactions.count < 2 { await Task.yield() }
        let oldHold = try XCTUnwrap(transactions[1].actions.first as? CXSetHeldCallAction)
        let oldError = completions[1]
        await hold.value // Exercise the real eight-second deadline.
        var finished = false
        var resumeError: Error?
        let resume = Task {
            do { try await calls.setTransferHeld(false) } catch { resumeError = error }
            finished = true
        }
        while transactions.count < 3 { await Task.yield() }
        let resumeAction = try XCTUnwrap(transactions[2].actions.first as? CXSetHeldCallAction)
        let provider = CXProvider(configuration: CXProviderConfiguration())
        oldError(NSError(domain: "OldHold", code: 1))
        calls.provider(provider, perform: oldHold)
        await withCheckedContinuation { result in DispatchQueue.main.async { result.resume() } }
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertFalse(finished, "Neither the old error nor its late action acknowledges the new resume")
        calls.provider(provider, perform: resumeAction)
        await resume.value
        XCTAssertNil(resumeError)
        calls.markEnded(reason: .remoteEnded)
    }

    func testDelayedEndFailureCannotEndNewCall() async {
        var completions: [(Error?) -> Void] = []
        let calls = SystemCallCoordinator(transactionRequester: { _, callback in completions.append(callback) })
        var ended = 0
        calls.onEnded = { _ in ended += 1 }
        calls.start()
        let first = calls.callID
        calls.end()
        let endOfA = completions.last!
        calls.markEnded(reason: .remoteEnded)
        calls.start()
        let second = calls.callID
        XCTAssertNotEqual(first, second)
        endOfA(NSError(domain: "delayed-end", code: 1))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(calls.callID, second)
        XCTAssertEqual(ended, 0)
        calls.markEnded(reason: .remoteEnded)
    }

    func testRoomIdentityDoesNotRequireSDKLinkBuilder() {
        let expected = JazzRoom(id: "room", decodedPassword: "secret", host: "meeting.example.test")
        XCTAssertTrue(EventRelay.matches(expected, expected))
        XCTAssertFalse(EventRelay.matches(JazzRoom(id: "other", decodedPassword: "secret", host: expected.host), expected))
        XCTAssertFalse(EventRelay.matches(JazzRoom(id: expected.id, decodedPassword: "secret", host: "other.example.test"), expected))
    }

    func testQueuedRelayEventRetainsOriginalRecipient() async {
        let relay = EventRelay()
        var a = 0
        var b = 0
        relay.onEvent = { _, _ in a += 1 }
        relay.deliver(.left)
        relay.onEvent = { _, _ in b += 1 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(a, 1)
        XCTAssertEqual(b, 0)
    }

    func testQueuedMediaReadinessCannotCompleteReplacementAttempt() async {
        let relay = EventRelay()
        var old = 0, replacement = 0
        relay.onMediaConnected = { old += 1 }
        relay.onMediaConnectionEstablished(timeInterval: 0.1)
        relay.onMediaConnected = { replacement += 1 }
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(old, 1)
        XCTAssertEqual(replacement, 0)
        relay.onMediaConnectionEstablished(timeInterval: 0.2)
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        XCTAssertEqual(replacement, 1)
    }
}
