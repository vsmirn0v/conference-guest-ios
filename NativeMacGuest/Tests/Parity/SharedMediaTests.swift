import AudioToolbox
import XCTest
@testable import RockNativeDesktop

private final class SharedAudioFixture: NativeDesktopSharedAudioOwner {
    let profile: GuestAudioProfile
    var prepares = 0, shutdowns = 0
    var resets: [(playout: Bool, input: Bool)] = []
    var prepareSucceeds = true, resetSucceeds = true, shutdownSucceeds = true
    var input = false
    var sound = false
    var physicalHistory: [GuestPhysicalAudioAvailability] = []
    var physical: GuestPhysicalAudioAvailability {
        .init(input: input, playoutRequested: sound, sharedNativeOwner: true)
    }
    var microphoneMutedForReadiness = true
    var unmuteAfterCallbacks: UInt64?
    var callbacks: UInt64 = 0
    var devices = 0
    var advance = true
    var prepareWait: (() async -> Void)?
    var refreshWait: ((TimeInterval) async -> Bool)?
    var shutdownWait: (() async -> Void)?
    var prepareTimeouts: [TimeInterval] = [], refreshTimeouts: [TimeInterval] = []
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var formatFlags: UInt32 = kAudioFormatFlagIsFloat
    init(_ profile: GuestAudioProfile = .speech) { self.profile = profile }
    var startupAudioObservation: GuestStartupAudioObservation {
        let asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: formatFlags, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        return .init(snapshot: ["engineRunning": input, "inputAvailable": input, "inputEnabled": input,
            "inputRunning": input, "outputAvailable": physical.output, "outputEnabled": physical.output,
            "inputASBD": [48000, Double(kAudioFormatLinearPCM), Double(formatFlags), 4, 1, 4, 1, 32, 0],
            "deviceUpdates": devices], inputCallbacks: callbacks, outputCallbacks: 0,
            inputCallback: .init(count: callbacks, frames: 480, format: .init(asbd),
                uptime: clock()))
    }
    func prepareIdleInput(timeout: TimeInterval) async -> Bool {
        prepares += 1; prepareTimeouts.append(timeout)
        await prepareWait?(); input = prepareSucceeds; sound = false
        physicalHistory.append(physical); microphoneMutedForReadiness = true; return prepareSucceeds
    }
    func resetForRoom(playout: Bool, preparedInput: Bool) async -> Bool {
        resets.append((playout, preparedInput)); input = preparedInput; sound = playout
        physicalHistory.append(physical); microphoneMutedForReadiness = true; return resetSucceeds
    }
    func refreshSnapshot(timeout: TimeInterval) async -> Bool {
        refreshTimeouts.append(timeout)
        if let refreshWait, !(await refreshWait(timeout)) { return false }
        if advance { callbacks += 1 }
        if let unmuteAfterCallbacks, callbacks >= unmuteAfterCallbacks { microphoneMutedForReadiness = false }
        return true
    }
    func shutdown(timeout: TimeInterval) async -> Bool {
        shutdowns += 1; await shutdownWait?()
        if shutdownSucceeds { input = false; sound = false; physicalHistory.append(physical) }
        return shutdownSucceeds
    }
}

@MainActor final class SharedMediaTests: XCTestCase {
    private func expectTrue(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, file: file, line: line) }
    private func expectFalse(_ value: Bool, file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, file: file, line: line) }
    private func seconds(_ duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
    private func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Shared media fixture did not advance")
    }
    func testExclusiveNativeOwnerBlocksCompetingBackendsWithoutChangingLegacyDefaults() {
        var ordinary = GuestAudioOwnerLease(privateCheck: false)
        var second = GuestAudioOwnerLease(privateCheck: false)
        XCTAssertNotNil(ordinary); XCTAssertNotNil(second)
        XCTAssertNil(GuestAudioOwnerLease(privateCheck: false, exclusive: true))
        ordinary = nil; second = nil
        var native = GuestAudioOwnerLease(privateCheck: false, exclusive: true)
        XCTAssertNotNil(native)
        XCTAssertNil(GuestAudioOwnerLease(privateCheck: false))
        XCTAssertNil(GuestAudioOwnerLease(privateCheck: true))
        XCTAssertNil(GuestAudioOwnerLease(privateCheck: false, exclusive: true))
        native = nil
        XCTAssertNotNil(GuestAudioOwnerLease(privateCheck: false))
    }
    func testColdRoomPreparationRetainsJoinPolicyWithoutForegroundSpeculation() {
        var authorized = true
        let media = NativeDesktopSharedMedia<GuestSystemAudio>(authorized: { authorized }, create: { _ in
            XCTFail("Policy evaluation must not allocate an audio owner")
            throw GuestSystemAudioError.setupFailedOrTimedOut
        })
        let engine = NativeDesktopGuestEngine(media: media, microphoneAuthorized: { authorized })
        XCTAssertFalse(media.foregroundActive)
        for mode in NativeDesktopMediaReadinessMode.allCases {
            for pluggedIn in [false, true] {
                for lowPowerMode in [false, true] {
                    let power = NativeDesktopPowerSnapshot(pluggedIn: pluggedIn, lowPowerMode: lowPowerMode)
                    engine.microphoneReadinessPolicy = { mode.allows(power) }
                    for allowed in [false, true] {
                        authorized = allowed
                        XCTAssertEqual(engine.permitsMicrophonePreparation(quiet: false), allowed && mode.allows(power))
                        XCTAssertFalse(engine.permitsMicrophonePreparation(quiet: true))
                    }
                }
            }
        }
        XCTAssertFalse(media.foregroundActive, "Active-room eligibility cannot enable idle speculation")
    }
    func testSharedSoftwareContextStartsBeforeRecordingAndRetiresBeforeLeaseRelease() async throws {
        let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, exclusive: true)
        let initial = owner.snapshot
        XCTAssertEqual(initial["mediaContextPrepared"] as? Bool, true)
        XCTAssertEqual(initial["mediaContextSenders"] as? Int, 0)
        XCTAssertEqual(initial["mediaContextReceivers"] as? Int, 0)
        XCTAssertEqual(initial["mediaContextTransceivers"] as? Int, 0)
        XCTAssertEqual(initial["mediaContextGatheringNew"] as? Bool, true)
        XCTAssertEqual(initial["engineRunning"] as? Bool, false)
        XCTAssertEqual(initial["recording"] as? Bool, false)
        XCTAssertEqual(initial["playing"] as? Bool, false)
        XCTAssertNil(GuestAudioOwnerLease(privateCheck: false), "The software context belongs to the same exclusive owner")
        expectTrue(await owner.shutdown())
        XCTAssertEqual(owner.snapshot["mediaContextClosed"] as? Bool, true)
        XCTAssertEqual(owner.snapshot["cleanupSucceeded"] as? Bool, true)
        XCTAssertNotNil(GuestAudioOwnerLease(privateCheck: false))
        let trace = owner.snapshot["audioOperations"] as? [[String: Any]] ?? []
        let createCalls = trace.first { $0["name"] as? String == "create" }?["nativeCalls"] as? [[String: Any]] ?? []
        XCTAssertTrue(createCalls.contains { $0["name"] as? String == "prepare-media-context" })
        let shutdownCalls = trace.first { $0["name"] as? String == "shutdown" }?["nativeCalls"] as? [[String: Any]] ?? []
        let names = shutdownCalls.compactMap { $0["name"] as? String }
        let stopped = try XCTUnwrap(names.firstIndex(of: "verify-stopped"))
        let closed = try XCTUnwrap(names.firstIndex(of: "close-media-context"))
        XCTAssertLessThan(stopped, closed)
    }
    func testNativeRecordingStartupRestoresTheMuteStateThatStartupResets() {
        var muted = false, starts = 0, mutes = 0
        let prepared = GuestMutedInputPreparation.start(mute: { mutes += 1; muted = true; return true },
            makeAvailable: { true }, startRecording: {
                starts += 1; muted = false // Observed SDK startup behavior on AirPods.
                return true
            }, isMuted: { muted })
        XCTAssertTrue(prepared); XCTAssertTrue(muted)
        XCTAssertEqual(starts, 1); XCTAssertEqual(mutes, 2)
    }
    func testRecordingStartupCannotClaimReadinessWhenPostStartMuteFails() {
        for failedReadback in [false, true] {
            var calls = 0
            let prepared = GuestMutedInputPreparation.start(mute: {
                calls += 1; return calls == 1 || failedReadback
            }, makeAvailable: { true }, startRecording: { true }, isMuted: { false })
            XCTAssertFalse(prepared, "Both native mute success and its final readback are required")
        }
        var started = false
        XCTAssertFalse(GuestMutedInputPreparation.start(mute: { false }, makeAvailable: { true },
            startRecording: { started = true; return true }, isMuted: { true }))
        XCTAssertFalse(started, "A failed initial privacy barrier cannot start recording")
        var muted = true
        XCTAssertFalse(GuestMutedInputPreparation.start(mute: { muted = true; return true }, makeAvailable: { true },
            startRecording: { muted = false; return false }, isMuted: { muted }))
        XCTAssertTrue(muted, "A partially failed native start must still restore the privacy barrier")
    }
    func testReceiveReadinessWaitsForActiveAudioBeforeReceiverAttachment() {
        let pendingSubscription = GuestStartupAudioReceiveReadiness(activePublication: true,
            sourceRequiresTransport: false, transportConnected: false)
        XCTAssertFalse(pendingSubscription.ready, "A subscription can still be awaiting acknowledgement or didAdd")
        XCTAssertTrue(GuestStartupAudioReceiveReadiness(activePublication: true,
            sourceRequiresTransport: false, transportConnected: true).ready)
        XCTAssertFalse(GuestStartupAudioReceiveReadiness(activePublication: false,
            sourceRequiresTransport: true, transportConnected: false).ready,
            "An attached source with unknown mute metadata also requires receive transport")
        XCTAssertTrue(GuestStartupAudioReceiveReadiness(activePublication: false,
            sourceRequiresTransport: false, transportConnected: false).ready,
            "Empty, video-only and known-muted audio impose no receive-audio wait")
    }
    func testSourceArrivingBetweenReadinessAndAtomicGainReleaseStaysMuted() {
        let gain = GuestStartupPlaybackGain(sound: true)
        let known = NSObject(), late = NSObject()
        var firstVolume = 0.7, lateVolume = 0.8
        gain.register(identity: known, source: .init(trackID: "TR_known"), gain: { firstVolume }, setGain: { firstVolume = $0 })
        let witness = gain.sourceSnapshot
        gain.register(identity: late, source: .init(trackID: "TR_late"), gain: { lateVolume }, setGain: { lateVolume = $0 })
        XCTAssertFalse(gain.open(expectedSourceRevision: witness.revision))
        XCTAssertFalse(gain.isOpen); XCTAssertEqual(firstVolume, 0); XCTAssertEqual(lateVolume, 0)
        XCTAssertTrue(gain.open(expectedSourceRevision: gain.sourceSnapshot.revision))
        XCTAssertEqual(firstVolume, 0.7); XCTAssertEqual(lateVolume, 0.8)
        gain.close()
    }
    func testReceiveTransportLossInvalidatesTheFinalReleaseDecision() {
        let beforeAwait = GuestStartupAudioReceiveReadiness(activePublication: true,
            sourceRequiresTransport: true, transportConnected: true)
        let atRelease = GuestStartupAudioReceiveReadiness(activePublication: true,
            sourceRequiresTransport: true, transportConnected: false)
        XCTAssertTrue(beforeAwait.ready); XCTAssertFalse(atRelease.ready)
        let soundOff = GuestStartupPlaybackGain(sound: false)
        XCTAssertFalse(soundOff.open(expectedSourceRevision: soundOff.sourceSnapshot.revision))
        XCTAssertFalse(soundOff.isOpen)
    }
    func testFastForegroundStartLeavesItsBudgetForFiniteNativeGraphRebuilds() async {
        var time = 100.0, reads = 0
        let began = time, audio = SharedAudioFixture()
        audio.clock = { time }
        audio.prepareWait = { time += 0.85 }
        audio.refreshWait = { _ in
            reads += 1
            switch reads {
            case 1: time += 2.11; audio.input = false; audio.devices += 1
            case 2: time += 0.0004; audio.input = true
            case 3: time += 0.8; audio.devices += 1
            default: break
            }
            return true
        }
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, clock: { time },
            sleep: { time += self.seconds($0) }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        XCTAssertEqual(media.evidence["ready"] as? Bool, true)
        XCTAssertEqual(audio.shutdowns, 0)
        XCTAssertGreaterThan(time - began, 3.85, "The observed rebuild sequence exceeds the former independent proof cap")
        XCTAssertLessThan(time - began, 8)
        XCTAssertEqual(audio.prepareTimeouts.first ?? 0, 8, accuracy: 0.001)
        XCTAssertEqual(audio.refreshTimeouts.first ?? 0, 7.15, accuracy: 0.001)
        expectTrue(await media.shutdown())
    }
    func testSlowForegroundStartConsumesTheSameBudgetAsPhysicalStabilization() async {
        for (startSeconds, expectedReady) in [(7.5, true), (7.8, false), (8.0, false)] {
            var time = 100.0
            let audio = SharedAudioFixture(); audio.clock = { time }
            audio.prepareWait = { time += startSeconds }
            let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, clock: { time },
                sleep: { time += self.seconds($0) }, create: { _ in audio })
            media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
            XCTAssertEqual(media.evidence["ready"] as? Bool, expectedReady)
            XCTAssertEqual(audio.shutdowns, expectedReady ? 0 : 1)
            XCTAssertFalse(media.cleanupFailed)
            XCTAssertEqual(audio.prepareTimeouts.first ?? 0, 8, accuracy: 0.001)
            if startSeconds < 8 {
                XCTAssertEqual(audio.refreshTimeouts.first ?? 0, 8 - startSeconds, accuracy: 0.001)
                XCTAssertTrue(audio.refreshTimeouts.allSatisfy { $0 > 0 && $0 <= 8 - startSeconds + 0.001 })
            } else {
                XCTAssertTrue(audio.refreshTimeouts.isEmpty, "Start completion at the deadline leaves no proof time")
            }
            expectTrue(await media.shutdown())
        }
    }
    func testForegroundNativeReadCannotReleaseReadinessAtOrAfterTheCombinedDeadline() async {
        for overrun in [0.0, 0.01] {
            var time = 100.0, reads = 0
            let audio = SharedAudioFixture(); audio.clock = { time }
            audio.prepareWait = { time += 0.85 }
            audio.refreshWait = { remaining in
                reads += 1
                if reads == 2 { time += remaining + overrun }
                return true // Native success and fresh callbacks cannot override the absolute deadline.
            }
            let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, clock: { time },
                sleep: { time += self.seconds($0) }, create: { _ in audio })
            media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
            XCTAssertEqual(reads, 2)
            XCTAssertEqual(media.evidence["ready"] as? Bool, false)
            XCTAssertEqual(media.evidence["ownerID"] as? String, "")
            XCTAssertEqual(audio.shutdowns, 1)
            XCTAssertFalse(media.cleanupFailed)
            XCTAssertEqual(audio.refreshTimeouts.last ?? 0, 7.1, accuracy: 0.001)
#if DEBUG
            let trace = media.foregroundInputPreparationForTesting
            XCTAssertEqual(trace["reason"] as? String, "deadlineAfterRead")
            XCTAssertEqual(trace["state"] as? String, "failed")
#endif
            expectTrue(await media.shutdown())
        }
    }
#if DEBUG
    func testForegroundFailureWitnessSurvivesRetirementWithoutAdditionalNativeReads() async {
        for readFails in [false, true] {
            var time = 100.0
            let audio = SharedAudioFixture(); audio.advance = false; audio.clock = { time }
            audio.refreshWait = { _ in !readFails }
            let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, clock: { time },
                sleep: { time += self.seconds($0) }, create: { _ in audio })
            media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
            let reads = audio.refreshTimeouts.count, trace = media.foregroundInputPreparationForTesting
            let observations = trace["observations"] as? [[String: Any]] ?? []
            XCTAssertEqual(media.evidence["ownerID"] as? String, "")
            XCTAssertFalse((trace["ownerID"] as? String ?? "").isEmpty)
            XCTAssertEqual(trace["state"] as? String, "failed")
            XCTAssertEqual(trace["reason"] as? String, readFails ? "nativeReadFailed" : "validationDeadline")
            XCTAssertEqual((trace["nativeStartCompletedObservation"] as? [String: Any])?["nativeSucceeded"] as? Bool, true)
            XCTAssertLessThanOrEqual(observations.count, 20)
            XCTAssertEqual(observations.last?["microphoneMuted"] as? Bool, true)
            XCTAssertEqual((observations.last?["audio"] as? [String: Any])?["engineRunning"] as? Bool, true)
            XCTAssertFalse(audio.input, "The witness must survive the later stop and owner retirement")
            if !readFails {
                XCTAssertGreaterThan(trace["totalObservations"] as? Int ?? 0, observations.count)
                XCTAssertTrue(observations.contains {
                    ($0["stability"] as? [String: Any])?["decision"] as? String == "callbackStale"
                })
            }
            _ = media.foregroundInputPreparationForTesting
            XCTAssertEqual(audio.refreshTimeouts.count, reads, "Reading retained evidence must never poll native audio")
            expectTrue(await media.shutdown())
        }
    }
#endif
    func testLateNativeMuteResetDuringIdleStabilizationCannotBeAdvertisedReady() async {
        let audio = SharedAudioFixture(); audio.unmuteAfterCallbacks = 2
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        XCTAssertEqual(audio.shutdowns, 1)
        XCTAssertEqual(media.evidence["ready"] as? Bool, false)
        XCTAssertEqual(media.evidence["ownerID"] as? String, "")
        XCTAssertFalse(media.cleanupFailed, "A confirmed idle retirement may still permit the cold fallback")
#if DEBUG
        let trace = media.foregroundInputPreparationForTesting
        XCTAssertEqual(trace["reason"] as? String, "microphoneNotMuted")
        XCTAssertEqual((trace["observations"] as? [[String: Any]])?.last?["microphoneMuted"] as? Bool, false)
        XCTAssertEqual(audio.refreshTimeouts.count, 2)
#endif
    }
    func testStaleMutedWitnessCannotBeAdoptedOrRemuteAnActiveRoom() async throws {
        let audio = SharedAudioFixture()
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        XCTAssertEqual(media.evidence["ready"] as? Bool, true)
        audio.microphoneMutedForReadiness = false
        let room = try await media.reserveRoom(profile: .speech), attempt = UUID()
        _ = try await media.attach(room, attempt: attempt, playout: true, preparedInput: true)
        XCTAssertEqual(media.evidence["adopted"] as? Bool, false)
        XCTAssertTrue(audio.microphoneMutedForReadiness, "Attachment must first establish its own current mute barrier")
        audio.microphoneMutedForReadiness = false // The active room's explicit transmit intent.
        let resets = audio.resets.count
        media.setForeground(false, microphone: false, profile: .speech)
        XCTAssertEqual(media.evidence["ready"] as? Bool, false)
        XCTAssertFalse(audio.microphoneMutedForReadiness)
        XCTAssertEqual(audio.resets.count, resets, "Idle policy must not remute an active room")
        expectTrue(await media.detach(room, attempt: attempt, clean: true))
        expectTrue(await media.releaseRoom(room, clean: true))
    }
    func testRoomWaitsForForegroundCreationAndAdoptsItsExactOwner() async throws {
        let audio = SharedAudioFixture()
        var creations = 0, resume: CheckedContinuation<Void, Never>?
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in
            creations += 1; await withCheckedContinuation { resume = $0 }; return audio
        })
        media.setForeground(true, microphone: true, profile: .speech)
        try await spin { resume != nil }
        let claim = Task { try await media.reserveRoom(profile: .speech) }
        try await spin { media.evidence["roomReserved"] as? Bool == true }
        do { _ = try await media.reserveRoom(profile: .speech); XCTFail("A second room was admitted") } catch {}
        resume?.resume(); resume = nil
        let room = try await claim.value, attempt = UUID()
        let adopted = try await media.attach(room, attempt: attempt, playout: true, preparedInput: true)
        XCTAssertTrue(adopted === audio); XCTAssertEqual(creations, 1)
        expectTrue(await media.detach(room, attempt: attempt, clean: true))
        media.setForeground(false, microphone: false, profile: .speech)
        expectTrue(await media.releaseRoom(room, clean: true))
        XCTAssertEqual(audio.shutdowns, 1)
    }
    func testBackgroundDuringAllocationCannotStartPhysicalInput() async throws {
        let audio = SharedAudioFixture()
        var resume: CheckedContinuation<Void, Never>?
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(grace: .milliseconds(10), authorized: { true }, create: { _ in
            await withCheckedContinuation { resume = $0 }; return audio
        })
        media.setForeground(true, microphone: true, profile: .speech)
        try await spin { resume != nil }
        XCTAssertNil(media.suspendIfDrained(), "An allocated but unfinished owner must be drained asynchronously")
        media.setForeground(false, microphone: false, profile: .speech)
        resume?.resume(); resume = nil
        try await spin { audio.shutdowns == 1 }
        XCTAssertEqual(audio.prepares, 0)
        XCTAssertEqual(media.evidence["ownerID"] as? String, "")
    }
    func testRecoveryKeepsRoomAndStaleDetachCannotMuteNewAttempt() async throws {
        let audio = SharedAudioFixture()
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in audio })
        let room = try await media.reserveRoom(profile: .speech), first = UUID(), second = UUID()
        _ = try await media.attach(room, attempt: first, playout: true, preparedInput: true)
        expectTrue(await media.detach(room, attempt: first, clean: true))
        XCTAssertTrue(audio.resets.last?.input == true, "Attempt retirement must retain the current input availability")
        _ = try await media.attach(room, attempt: second, playout: true, preparedInput: true)
        let resets = audio.resets.count
        expectTrue(await media.detach(room, attempt: first, clean: true))
        XCTAssertEqual(audio.resets.count, resets)
        media.setForeground(false, microphone: false, profile: .speech)
        try await Task.sleep(for: .milliseconds(25))
        XCTAssertEqual(audio.shutdowns, 0, "App/power withdrawal cannot retire an active room")
        do { _ = try await media.reserveRoom(profile: .speech); XCTFail("Recovery released its room") } catch {}
        expectTrue(await media.detach(room, attempt: second, clean: true))
        expectTrue(await media.releaseRoom(room, clean: true))
    }
    func testSoundOffAdoptionDetachAndRecoveryNeverWithdrawTheRetainedInputOutputDependency() async throws {
        var time = 100.0
        let audio = SharedAudioFixture(); audio.clock = { time }
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, clock: { time },
            sleep: { time += self.seconds($0) }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        let room = try await media.reserveRoom(profile: .speech)
        for _ in 0..<2 {
            let attempt = UUID()
            _ = try await media.attach(room, attempt: attempt, playout: false, preparedInput: true)
            XCTAssertFalse(audio.sound); XCTAssertTrue(audio.physical.input && audio.physical.output)
            expectTrue(await media.detach(room, attempt: attempt, clean: true))
        }
        expectTrue(await media.releaseRoom(room, clean: true)); await media.waitForWork()
        XCTAssertTrue(audio.physicalHistory.allSatisfy { $0.input && $0.output })
        media.setForeground(true, microphone: false, profile: .speech); await media.waitForWork()
        XCTAssertFalse(audio.physical.input); XCTAssertFalse(audio.physical.output)
        expectTrue(await media.shutdown())
        XCTAssertFalse(audio.physicalHistory.last!.input); XCTAssertFalse(audio.physicalHistory.last!.output)
    }
    func testFailedDetachQuarantinesTheSameOwner() async throws {
        let audio = SharedAudioFixture()
        var creations = 0
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in creations += 1; return audio })
        let room = try await media.reserveRoom(profile: .speech), attempt = UUID()
        _ = try await media.attach(room, attempt: attempt, playout: true, preparedInput: false)
        expectFalse(await media.detach(room, attempt: attempt, clean: false))
        expectFalse(await media.releaseRoom(room, clean: false))
        do { _ = try await media.reserveRoom(profile: .speech); XCTFail("Unproven owner was loaned again") } catch {}
        XCTAssertEqual(creations, 1); XCTAssertEqual(audio.shutdowns, 0)
        XCTAssertTrue(media.cleanupFailed)
    }
    func testFailedShutdownRetainsTheOwnerAndExclusionInsteadOfReplacingIt() async throws {
        var audio: SharedAudioFixture? = SharedAudioFixture()
        audio?.shutdownSucceeds = false
        weak var retained = audio
        var creations = 0
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { false }, create: { _ in
            creations += 1; return audio!
        })
        media.setForeground(true, microphone: false, profile: .speech); await media.waitForWork()
        let identity = media.evidence["ownerID"] as? String
        expectFalse(await media.shutdown())
        audio = nil
        XCTAssertNotNil(retained, "The service must retain the owner's factory/context after an unproven stop")
        XCTAssertEqual(media.evidence["ownerID"] as? String, identity)
        XCTAssertTrue(media.cleanupFailed)
        do { _ = try await media.reserveRoom(profile: .speech); XCTFail("A quarantined owner was replaced") } catch {}
        XCTAssertEqual(creations, 1)
    }
    func testPrivateBackendSuspensionDrainsAndExcludesForegroundRecreation() async throws {
        var owners: [SharedAudioFixture] = []
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { false }, create: { profile in
            let audio = SharedAudioFixture(profile); owners.append(audio); return audio
        })
        media.setForeground(true, microphone: false, profile: .speech); await media.waitForWork()
        let suspension = try await media.suspend()
        XCTAssertEqual(owners.first?.shutdowns, 1)
        media.setForeground(true, microphone: true, profile: .music); await media.waitForWork()
        XCTAssertEqual(owners.count, 1)
        do { _ = try await media.reserveRoom(profile: .speech); XCTFail("Private backend exclusion was lost") } catch {}
        media.resume(suspension, clean: true); await media.waitForWork()
        XCTAssertEqual(owners.count, 2); XCTAssertEqual(owners.last?.profile, .music)
        expectTrue(await media.shutdown())
    }
    func testDrainedUpdateClaimAtomicallySuppressesQueuedForegroundWork() async throws {
        var creations = 0
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { false }, create: { profile in
            creations += 1; return SharedAudioFixture(profile)
        })
        media.setForeground(true, microphone: false, profile: .speech)
        let token = try XCTUnwrap(media.suspendIfDrained())
        await media.waitForWork(); XCTAssertEqual(creations, 0)
        media.resume(token, clean: true); await media.waitForWork(); XCTAssertEqual(creations, 1)
        expectTrue(await media.shutdown())
    }
    func testReadinessRequiresFreshCallbacksAndInvalidatesFullFormatOrRoute() async throws {
        let audio = SharedAudioFixture()
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        XCTAssertEqual(media.evidence["ready"] as? Bool, true)
        let identity = media.evidence["ownerID"] as? String
        audio.formatFlags = kAudioFormatFlagIsSignedInteger
        XCTAssertEqual(media.evidence["ready"] as? Bool, false, "Full ASBD changes invalidate readiness")
        audio.devices += 1
        let room = try await media.reserveRoom(profile: .speech), attempt = UUID()
        _ = try await media.attach(room, attempt: attempt, playout: true, preparedInput: true)
        XCTAssertEqual(media.evidence["ownerID"] as? String, identity)
        XCTAssertEqual(media.evidence["adopted"] as? Bool, false, "Owner lifetime is not a readiness witness")
        expectTrue(await media.detach(room, attempt: attempt, clean: true))
        media.setForeground(false, microphone: false, profile: .speech)
        expectTrue(await media.releaseRoom(room, clean: true))
    }
    func testIdleGraceIsRevokedOnForegroundReturnAndLaterGuaranteesCleanup() async throws {
        let audio = SharedAudioFixture()
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(grace: .milliseconds(30), authorized: { false }, create: { _ in audio })
        media.setForeground(true, microphone: false, profile: .speech); await media.waitForWork()
        let identity = media.evidence["ownerID"] as? String
        media.setForeground(false, microphone: false, profile: .speech)
        media.setForeground(true, microphone: false, profile: .speech)
        try await Task.sleep(for: .milliseconds(50)); await media.waitForWork()
        XCTAssertEqual(audio.shutdowns, 0); XCTAssertEqual(media.evidence["ownerID"] as? String, identity)
        var releaseShutdown: (() -> Void)?, stopReleased = false
        audio.shutdownWait = {
            await withCheckedContinuation { continuation in
                Task { @MainActor in
                    if stopReleased { continuation.resume() }
                    else { releaseShutdown = { continuation.resume() } }
                }
            }
        }
        defer { stopReleased = true; releaseShutdown?(); releaseShutdown = nil }
        media.setForeground(false, microphone: false, profile: .speech)
        try await spin { releaseShutdown != nil }
        let release = try XCTUnwrap(releaseShutdown)
        XCTAssertEqual(audio.shutdowns, 1)
        XCTAssertEqual(media.evidence["ownerID"] as? String, identity, "Unconfirmed shutdown must retain ownership")
        stopReleased = true; releaseShutdown = nil; release()
        await media.waitForWork()
        XCTAssertEqual(media.evidence["ownerID"] as? String, "")
    }
    func testCallbackStallCannotRemainReadyEvenWhenFormatsStayIdentical() async throws {
        let audio = SharedAudioFixture()
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        XCTAssertEqual(media.evidence["ready"] as? Bool, true)
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(media.evidence["ready"] as? Bool, false)
        expectTrue(await media.shutdown())
    }
    func testQueuedOldIdleDeadlineCannotRetireANewRoom() async throws {
        let audio = SharedAudioFixture()
        var releasePreparation: CheckedContinuation<Void, Never>?, idleDeadlineFired = false
        audio.prepareWait = { await withCheckedContinuation { releasePreparation = $0 } }
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(grace: .milliseconds(1), authorized: { true }, sleep: { _ in
            idleDeadlineFired = true
        }, create: { _ in audio })
        media.setForeground(true, microphone: true, profile: .speech)
        try await spin { releasePreparation != nil }
        media.setForeground(false, microphone: false, profile: .speech)
        try await spin { idleDeadlineFired }
        let claim = Task { try await media.reserveRoom(profile: .speech) }
        try await spin { media.evidence["roomReserved"] as? Bool == true }
        releasePreparation?.resume(); releasePreparation = nil
        let room = try await claim.value, attempt = UUID()
        let adopted = try await media.attach(room, attempt: attempt, playout: true, preparedInput: true)
        XCTAssertTrue(adopted === audio); XCTAssertEqual(audio.shutdowns, 0)
        expectTrue(await media.detach(room, attempt: attempt, clean: true))
        expectTrue(await media.releaseRoom(room, clean: true))
    }
    func testFinalReleaseHoldsExclusionUntilShutdownActuallyCompletes() async throws {
        let audio = SharedAudioFixture()
        var releaseShutdown: CheckedContinuation<Void, Never>?
        audio.shutdownWait = { await withCheckedContinuation { releaseShutdown = $0 } }
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in audio })
        let room = try await media.reserveRoom(profile: .speech)
        let releasing = Task { await media.releaseRoom(room, clean: true) }
        try await spin { releaseShutdown != nil }
        do { _ = try await media.reserveRoom(profile: .speech); XCTFail("A half-retired owner was loaned") } catch {}
        releaseShutdown?.resume(); releaseShutdown = nil
        expectTrue(await releasing.value)
        XCTAssertEqual(media.evidence["ownerID"] as? String, "")
    }
    func testCleanSpeculativeFailureAllowsColdJoin() async throws {
        let failed = SharedAudioFixture(), cold = SharedAudioFixture()
        failed.prepareSucceeds = false
        var creations = 0
        let media = NativeDesktopSharedMedia<SharedAudioFixture>(authorized: { true }, create: { _ in
            creations += 1; return creations == 1 ? failed : cold
        })
        media.setForeground(true, microphone: true, profile: .speech); await media.waitForWork()
        XCTAssertEqual(failed.shutdowns, 1); XCTAssertFalse(media.cleanupFailed)
        let room = try await media.reserveRoom(profile: .speech), attempt = UUID()
        let audio = try await media.attach(room, attempt: attempt, playout: true, preparedInput: false)
        XCTAssertTrue(audio === cold); XCTAssertEqual(creations, 2)
        expectTrue(await media.detach(room, attempt: attempt, clean: true))
        media.setForeground(false, microphone: false, profile: .speech)
        expectTrue(await media.releaseRoom(room, clean: true))
    }
}
