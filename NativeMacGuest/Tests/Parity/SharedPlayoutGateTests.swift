import Foundation
import XCTest
@testable import RockNativeDesktop

private final class OutputGainFixture: NSObject {
    var gain = 1.0
    var writes: [Double] = []
    var didWrite: ((Double) -> Void)?
    func set(_ value: Double) -> Bool {
        gain = value; writes.append(value); didWrite?(value); return true
    }
}

@MainActor final class SharedPlayoutGateTests: XCTestCase {
    func testSharedInputKeepsItsPhysicalOutputDependencyAcrossSoundAndRoomTransitions() {
        let transitions: [(input: Bool, sound: Bool)] = [
            (true, false), // Foreground input preparation.
            (true, true),  // Adopt with Sound on.
            (true, false), // Sound off, detach and reconnect retain input.
            (true, true), (true, false),
            (false, false)] // Withdraw idle preparation or fully shut down.
        let actual = transitions.map {
            GuestPhysicalAudioAvailability(input: $0.input, playoutRequested: $0.sound, sharedNativeOwner: true)
        }
        XCTAssertTrue(actual.dropLast().allSatisfy { $0.input && $0.output })
        XCTAssertEqual(actual.last, GuestPhysicalAudioAvailability(input: false, playoutRequested: false, sharedNativeOwner: true))
        XCTAssertFalse(actual.last!.input); XCTAssertFalse(actual.last!.output)
        for input in [false, true] {
            for sound in [false, true] {
                let ordinary = GuestPhysicalAudioAvailability(input: input, playoutRequested: sound, sharedNativeOwner: false)
                XCTAssertEqual(ordinary.input, input)
                XCTAssertEqual(ordinary.output, sound, "Other owners retain their original availability contract")
            }
        }
    }

    func testSoundOffSilencesNewDefaultGainReceiversBeforeTheirRegistrationCallback() {
        let gate = GuestSharedPlayoutGate(enabled: true), output = OutputGainFixture()
        XCTAssertTrue(gate.reset(sound: false))
        let epoch = gate.currentEpoch
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        var unregisteredTrackGain = 1.0
        XCTAssertEqual(output.gain * unregisteredTrackGain, 0)
        XCTAssertFalse(gate.open(expected: epoch))
        XCTAssertTrue(gate.setSound(true, expected: epoch))
        XCTAssertEqual(output.gain, 0, "Sound on alone cannot bypass startup readiness")
        XCTAssertTrue(gate.open(expected: epoch)); XCTAssertEqual(output.gain, 1)
        XCTAssertTrue(gate.setSound(false, expected: epoch))
        unregisteredTrackGain = 1
        XCTAssertEqual(output.gain * unregisteredTrackGain, 0, "The gate protects a receiver absent from the source registry")
    }

    func testMeetingVolumeScalesOnlyAnOpenGateAndSoundOffStaysExactZero() {
        let gate = GuestSharedPlayoutGate(enabled: true), output = OutputGainFixture()
        XCTAssertTrue(gate.reset(sound: true)); let epoch = gate.currentEpoch
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        XCTAssertTrue(gate.setVolume(0.4)); XCTAssertEqual(output.gain, 0, "Volume never bypasses startup readiness")
        XCTAssertTrue(gate.open(expected: epoch)); XCTAssertEqual(output.gain, 0.4)
        XCTAssertTrue(gate.isOpen(expected: epoch))
        XCTAssertTrue(gate.setVolume(0.8)); XCTAssertEqual(output.gain, 0.8)
        XCTAssertTrue(gate.setSound(false, expected: epoch)); XCTAssertEqual(output.gain, 0)
        XCTAssertTrue(gate.setVolume(0.6)); XCTAssertEqual(output.gain, 0, "Sound off stays an exact zero")
        XCTAssertTrue(gate.setSound(true, expected: epoch)); XCTAssertEqual(output.gain, 0.6)
        XCTAssertTrue(gate.setVolume(.nan)); XCTAssertEqual(output.gain, 1)
    }

    func testSpeakerLevelsScaleOnlyRestoredSourceGain() {
        let gain = GuestStartupPlaybackGain(sound: true)
        var loud = 0.0, quiet = 0.0, unknown = 0.0
        gain.register(identity: NSObject(), source: .init(trackID: "loud"), gain: { 1 }, setGain: { loud = $0 })
        gain.register(identity: NSObject(), source: .init(trackID: "quiet"), gain: { 1 }, setGain: { quiet = $0 })
        gain.register(identity: NSObject(), source: .init(trackID: nil), gain: { 1 }, setGain: { unknown = $0 })
        var levels = ["loud": 3.0, "quiet": 0.25]
        gain.level = { levels[$0.trackID ?? ""] ?? 1 }
        gain.reconcile()
        XCTAssertEqual([loud, quiet, unknown], [0, 0, 0], "A level never bypasses startup readiness")
        XCTAssertTrue(gain.open())
        XCTAssertEqual([loud, quiet, unknown], [2, 0.25, 1], "Levels clamp to 200% and unknown speakers stay at 100%")
        levels["quiet"] = 0; gain.reconcile(); XCTAssertEqual(quiet, 0)
        gain.setSound(false); XCTAssertEqual([loud, quiet, unknown], [0, 0, 0], "Sound off stays an exact zero")
        gain.setSound(true); XCTAssertEqual(loud, 2)
        gain.close(); XCTAssertEqual(loud, 0)
    }

    func testRequiredOpenFailureRollsBackSourcesAndCanRecoverWithoutDiscardingThem() {
        let gate = GuestSharedPlayoutGate(enabled: true)
        XCTAssertTrue(gate.reset(sound: true))
        let gain = GuestStartupPlaybackGain(sound: true), identity = NSObject()
        var sourceGain = 0.7
        gain.register(identity: identity, gain: { sourceGain }, setGain: { sourceGain = $0 })
        let revision = gain.sourceSnapshot.revision, epoch = gate.currentEpoch
        XCTAssertFalse(gain.open(expectedSourceRevision: revision, releaseGlobal: { gate.open(expected: epoch) }))
        XCTAssertFalse(gain.isOpen); XCTAssertTrue(gain.hasSources); XCTAssertEqual(sourceGain, 0)
        let output = OutputGainFixture()
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        XCTAssertEqual(output.gain, 0)
        XCTAssertTrue(gain.open(expectedSourceRevision: revision, releaseGlobal: { gate.open(expected: epoch) }))
        XCTAssertTrue(gain.isOpen); XCTAssertEqual(sourceGain, 0.7); XCTAssertEqual(output.gain, 1)
    }

    func testDeadlineCrossedBySourceOrMasterWorkClosesMasterBeforeSourceRollback() {
        for expireAtSource in [true, false] {
            var time = 100.0, sourceGain = 1.0, masterOpens = 0
            let deadline = 101.0, gate = GuestSharedPlayoutGate(enabled: true), output = OutputGainFixture()
            var events: [String] = []
            XCTAssertTrue(gate.reset(sound: true)); let epoch = gate.currentEpoch
            output.didWrite = { value in
                if value == 0 { events.append("master0") }
                if value == 1 && !expireAtSource { time = deadline }
            }
            XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
            let gain = GuestStartupPlaybackGain(sound: true), identity = NSObject()
            gain.register(identity: identity, gain: { sourceGain }, setGain: { value in
                sourceGain = value
                if value == 0 { events.append("source0") }
                if value > 0 && expireAtSource { time = deadline }
            })
            XCTAssertFalse(gain.open(releaseGlobal: {
                guard time < deadline else { return false }
                masterOpens += 1
                guard gate.open(expected: epoch), time < deadline else {
                    _ = gate.close(expected: epoch); return false
                }
                return true
            }))
            XCTAssertEqual(masterOpens, expireAtSource ? 0 : 1)
            XCTAssertFalse(gain.isOpen); XCTAssertTrue(gain.hasSources)
            XCTAssertFalse(gate.isOpen(expected: epoch)); XCTAssertEqual(sourceGain, 0); XCTAssertEqual(output.gain, 0)
            if !expireAtSource {
                XCTAssertLessThan(events.lastIndex(of: "master0")!, events.lastIndex(of: "source0")!)
            }
        }
    }

    func testIndependentSourceProofRequiresSoundOffReadySharedEpochAndVerifiedMasterZero() {
        let gate = GuestSharedPlayoutGate(enabled: true), output = OutputGainFixture()
        XCTAssertTrue(gate.reset(sound: true)); let epoch = gate.currentEpoch
        XCTAssertFalse(gate.permitsSoundOffProof(expected: epoch))
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        XCTAssertTrue(gate.open(expected: epoch))
        XCTAssertFalse(gate.permitsSoundOffProof(expected: epoch))
        XCTAssertTrue(gate.setSound(false, expected: epoch))
        XCTAssertTrue(gate.permitsSoundOffProof(expected: epoch))
        XCTAssertFalse(gate.permitsSoundOffProof(expected: UUID()))
        XCTAssertTrue(gate.close(retire: true))
        XCTAssertFalse(gate.permitsSoundOffProof(expected: epoch))
        XCTAssertFalse(GuestSharedPlayoutGate(enabled: false).permitsSoundOffProof(expected: nil))
    }

    func testReentrantCloseOrFailedZeroCannotFalselyReportARequiredOpen() {
        let gate = GuestSharedPlayoutGate(enabled: true), output = OutputGainFixture()
        XCTAssertTrue(gate.reset(sound: true)); let epoch = gate.currentEpoch
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        output.didWrite = { value in if value == 1 { _ = gate.close(expected: epoch) } }
        XCTAssertFalse(gate.open(expected: epoch))
        XCTAssertFalse(gate.isOpen(expected: epoch)); XCTAssertEqual(output.gain, 0)
        output.didWrite = nil
        XCTAssertTrue(gate.open(expected: epoch))
        let failing = NSObject()
        XCTAssertFalse(gate.bind(identity: ObjectIdentifier(failing), setGain: { $0 == 1 }))
        XCTAssertFalse(gate.isOpen(expected: epoch))
        XCTAssertFalse(gate.open(expected: epoch))
    }

    func testOldEpochCannotOpenMuteOrChangeSoundForANewerRoom() {
        let gate = GuestSharedPlayoutGate(enabled: true), output = OutputGainFixture()
        XCTAssertTrue(gate.reset(sound: true)); let old = gate.currentEpoch
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        XCTAssertTrue(gate.open(expected: old))
        XCTAssertTrue(gate.reset(sound: true)); let current = gate.currentEpoch
        XCTAssertNotEqual(old, current); XCTAssertEqual(output.gain, 0)
        XCTAssertTrue(gate.open(expected: current))
        XCTAssertFalse(gate.open(expected: old))
        XCTAssertFalse(gate.setSound(false, expected: old))
        XCTAssertTrue(gate.close(expected: old))
        XCTAssertTrue(gate.isOpen(expected: current)); XCTAssertEqual(output.gain, 1)
        XCTAssertTrue(gate.close(retire: true))
        XCTAssertFalse(gate.open(expected: current)); XCTAssertEqual(output.gain, 0)
    }

    func testReplacementMixerIsMutedBeforeCallbackReturnsAndOldReleaseCannotDetachIt() async {
        let gate = GuestSharedPlayoutGate(enabled: true), old = OutputGainFixture(), replacement = OutputGainFixture()
        XCTAssertTrue(gate.reset(sound: true)); let epoch = gate.currentEpoch
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(old), setGain: old.set))
        XCTAssertTrue(gate.open(expected: epoch))
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(replacement), setGain: replacement.set))
        XCTAssertEqual(replacement.gain, 0)
        gate.remove(identity: ObjectIdentifier(old))
        for _ in 0..<1_000 { if gate.isOpen(expected: epoch) { break }; await Task.yield() }
        XCTAssertTrue(gate.isOpen(expected: epoch)); XCTAssertEqual(replacement.gain, 1)
        XCTAssertTrue(gate.setSound(false, expected: epoch))
        let another = OutputGainFixture()
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(another), setGain: another.set))
        await Task.yield()
        XCTAssertEqual(another.gain, 0)
    }

    func testBindingChurnHasBoundedReconciliationAndFailsClosed() {
        let gate = GuestSharedPlayoutGate(enabled: true)
        XCTAssertTrue(gate.reset(sound: true)); let epoch = gate.currentEpoch
        var nodes: [OutputGainFixture] = [], positiveWrites = 0
        func bindNext() {
            let output = OutputGainFixture(); nodes.append(output)
            output.didWrite = { [weak gate] value in
                if value == 1 { positiveWrites += 1; if gate != nil { bindNext() } }
            }
            XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        }
        bindNext()
        XCTAssertFalse(gate.open(expected: epoch))
        XCTAssertLessThanOrEqual(positiveWrites, 3)
        XCTAssertEqual(nodes.last?.gain, 0)
        XCTAssertFalse(gate.isOpen(expected: epoch))
        nodes.forEach { $0.didWrite = nil }
    }

    func testOtherOwnersNeverTouchTheMixer() {
        let gate = GuestSharedPlayoutGate(enabled: false), output = OutputGainFixture()
        XCTAssertTrue(gate.bind(identity: ObjectIdentifier(output), setGain: output.set))
        XCTAssertTrue(gate.reset(sound: false)); XCTAssertTrue(gate.open(expected: nil))
        XCTAssertTrue(gate.close(retire: true)); XCTAssertTrue(gate.setSound(false, expected: nil))
        XCTAssertTrue(output.writes.isEmpty); XCTAssertEqual(output.gain, 1)
    }

    func testFailedGlobalZeroStillAttemptsAndConfirmsNativeStopBeforeRetiringContext() async throws {
        let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, exclusive: true)
        let identity = NSObject()
        var failReadback = false
        XCTAssertTrue(owner.sharedPlayoutGateForTesting.bind(identity: ObjectIdentifier(identity), setGain: { _ in !failReadback }))
        failReadback = true
        let reset = await owner.resetForRoom(playout: false, preparedInput: false)
        XCTAssertFalse(reset)
        let state = owner.snapshot
        XCTAssertEqual(state["cleanupSucceeded"] as? Bool, true)
        XCTAssertEqual(state["mediaContextClosed"] as? Bool, true)
        let operations = state["audioOperations"] as? [[String: Any]] ?? []
        let shutdown = try XCTUnwrap(operations.last { $0["name"] as? String == "shutdown" })
        let calls = shutdown["nativeCalls"] as? [[String: Any]] ?? []
        let names = calls.compactMap { $0["name"] as? String }
        for expected in ["set-engine-unavailable", "stop-recording", "stop-playout", "verify-stopped", "close-media-context"] {
            XCTAssertTrue(names.contains(expected), "Failed global zero must still execute \(expected)")
        }
        XCTAssertLessThan(try XCTUnwrap(names.firstIndex(of: "verify-stopped")), try XCTUnwrap(names.firstIndex(of: "close-media-context")))
        XCTAssertNotNil(GuestAudioOwnerLease(privateCheck: false))
    }

    func testEmptyKnownMutedAndSoundOffJoinsReleaseWithoutCreatingAMixer() async throws {
        for (sound, mutedMetadata) in [(true, false), (true, true), (false, false)] {
            let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, exclusive: true)
            let engine = NativeGuestEngine(label: "No playout demand", systemAudio: owner)
            do {
                engine.configureStartupPlayback(sound: sound)
                if mutedMetadata {
                    try await engine.processEventForTesting(["event": "media-out", "payload": [
                        "method": "rtc:participants:update", "update": ["participants": [[
                            "sid": "remote", "identity": "remote", "version": 1, "state": "ACTIVE",
                            "tracks": [["sid": "audio", "type": "AUDIO", "muted": true]]]]]]])
                }
                try await engine.waitForStartupAudio()
                XCTAssertTrue(engine.releaseStartupAudio())
                let global = try XCTUnwrap(owner.snapshot["sharedPlayoutGate"] as? [String: Any])
                XCTAssertEqual(global["mixerBound"] as? Bool, false)
                XCTAssertEqual(global["lastGain"] as? Double, 0)
            } catch { _ = await engine.leave(sendLeave: false); throw error }
            let stopped = await engine.leave(sendLeave: false)
            XCTAssertTrue(stopped)
            XCTAssertEqual((owner.snapshot["sharedPlayoutGate"] as? [String: Any])?["retired"] as? Bool, true)
        }
    }
}
