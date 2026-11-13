import AVFoundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// R4 S1: guarantees 1, 2, 4 and 5 of docs/r4-shared-engine-plan.md on the shared
/// engine's arbitration, with a fake module that records every native call.
@MainActor final class SharedAudioEngineTests: XCTestCase {

    // Guarantee 1: muted means silent, per meeting.
    func testMutedMeansSilentPerMeeting() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        let a = FakeSender(), b = FakeSender()
        daily.addSender(a); infra.addSender(b)
        XCTAssertFalse(a.isEnabled || b.isEnabled, "Senders register disabled")

        let refused = await daily.setMuted(false)
        XCTAssertFalse(refused, "No talk role: unmute is refused")
        XCTAssertFalse(a.isEnabled); XCTAssertTrue(module.muted)

        ok(await daily.assumeTalk())
        XCTAssertTrue(module.muted, "The talk role arrives muted")
        ok(await daily.setMuted(false))
        XCTAssertTrue(a.isEnabled); XCTAssertFalse(b.isEnabled); XCTAssertFalse(module.muted)

        ok(await daily.setMuted(true))
        XCTAssertFalse(a.isEnabled); XCTAssertTrue(module.muted)
        no(await infra.setMuted(false), "A meeting without the talk role stays silent")
        XCTAssertFalse(b.isEnabled); XCTAssertTrue(module.muted)
    }

    func testCompanionExclusiveTalkDoesNotStealOrPermitOtherMeetings() async throws {
        let (engine, module) = make()
        let workspace = try await engine.attach(meetingID: UUID())
        let companion = try await engine.attach(meetingID: UUID())
        let sender = FakeSender()
        workspace.addSender(sender)
        ok(await workspace.assumeTalk()); ok(await workspace.setMuted(false))
        no(await companion.assumeTalkExclusively(), "Companion cannot displace an existing meeting")
        XCTAssertEqual(engine.talkMeetingID, workspace.meetingID)
        XCTAssertTrue(sender.isEnabled); XCTAssertFalse(module.muted)
        ok(await companion.detach()); ok(await workspace.detach())

        let alone = try await engine.attach(meetingID: UUID())
        ok(await alone.assumeTalkExclusively())
        do {
            _ = try await engine.attach(meetingID: UUID())
            XCTFail("Another meeting must not attach during an exclusive companion session")
        } catch {}
        XCTAssertEqual(engine.talkMeetingID, alone.meetingID)
        ok(await alone.detach())
        let next = try await engine.attach(meetingID: UUID())
        ok(await next.assumeTalk()); ok(await next.detach())
    }

    // Guarantee 2: only the talk meeting can be heard — two and four meetings.
    func testOnlyTheTalkMeetingCanBeHeardWithTwoAndFourMeetings() async throws {
        for count in [2, 4] {
            let (engine, module) = make()
            var meetings: [MeetingAudioAttachment] = [], senders: [FakeSender] = []
            for _ in 0..<count {
                let meeting = try await engine.attach(meetingID: UUID()), sender = FakeSender()
                meeting.addSender(sender); meetings.append(meeting); senders.append(sender)
            }
            // At the moment the module unmutes, only the talk meeting's sender may be on.
            module.onUnmute = {
                let talk = engine.talkMeetingID
                for (meeting, sender) in zip(meetings, senders) where meeting.meetingID != talk {
                    XCTAssertFalse(sender.isEnabled, "Another meeting's sender was on when the module unmuted")
                }
            }
            for round in 0..<(count * 2) {
                let speaker = meetings[round % count]
                ok(await speaker.assumeTalk())
                ok(await speaker.setMuted(false))
                let enabled = senders.enumerated().filter { $0.element.isEnabled }.map(\.offset)
                XCTAssertEqual(enabled, [round % count], "\(count) meetings, round \(round)")
                XCTAssertFalse(module.muted)
            }
            XCTAssertGreaterThan(module.unmutes, 0)
        }
    }

    func testMovingTheTalkRoleMutesFirstAndRefusesAStaleUnmute() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        let a = FakeSender(), b = FakeSender()
        daily.addSender(a); infra.addSender(b)
        ok(await daily.assumeTalk())
        let dailyEpoch = try XCTUnwrap(daily.talkEpoch)
        ok(await daily.setMuted(false))
        module.log.removeAll()

        ok(await infra.assumeTalk())
        XCTAssertFalse(a.isEnabled, "The previous talk meeting's sender is off")
        XCTAssertTrue(module.muted)
        XCTAssertEqual(module.log.first, "mute:true", "Muted before the role moves")
        no(await engine.setMuted(false, for: daily, epoch: dailyEpoch), "A stale meeting cannot unmute")
        XCTAssertFalse(a.isEnabled); XCTAssertTrue(module.muted)
        XCTAssertFalse(b.isEnabled, "The new talk meeting starts muted: it never inherits an unmute")

        // Back again: the old epoch from the first round is still refused.
        ok(await daily.assumeTalk())
        no(await engine.setMuted(false, for: daily, epoch: dailyEpoch))
        ok(await daily.setMuted(false))
        XCTAssertTrue(a.isEnabled); XCTAssertFalse(b.isEnabled)
    }

    func testAFailedUnmuteLeavesEverythingSilent() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), sender = FakeSender()
        daily.addSender(sender)
        ok(await daily.assumeTalk())
        module.failUnmute = true
        no(await daily.setMuted(false))
        XCTAssertFalse(sender.isEnabled); XCTAssertTrue(module.muted)
        XCTAssertTrue(module.log.contains("suppress"), "A failed unmute is followed by the privacy barrier")
        module.failUnmute = false; module.failActivation = true
        no(await daily.setMuted(false))
        XCTAssertFalse(sender.isEnabled, "No sender before the microphone is active")
    }

    func testReleasingTheTalkRoleReleasesTheDeviceUnlessKeptWarm() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), sender = FakeSender()
        daily.addSender(sender)
        ok(await daily.assumeTalk()); ok(await daily.setMuted(false))
        ok(await daily.relinquishTalk())
        XCTAssertFalse(sender.isEnabled); XCTAssertTrue(module.muted)
        XCTAssertNil(engine.talkMeetingID)
        XCTAssertEqual(module.log.last, "permit:false warm:false")
        engine.keepInputWarm = true
        ok(await daily.assumeTalk()); ok(await daily.relinquishTalk())
        XCTAssertEqual(module.log.last, "permit:false warm:true")
    }

    // Guarantee 4: the private microphone check only while no sender is enabled.
    func testPrivateCheckOnlyWhileNoSenderIsEnabled() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), sender = FakeSender()
        daily.addSender(sender)
        ok(await daily.assumeTalk()); ok(await daily.setMuted(false))
        no(await engine.beginPrivateCheck(), "Refused while a meeting sends")
        ok(await daily.setMuted(true))
        ok(await engine.beginPrivateCheck())
        XCTAssertTrue(engine.privateCheckActive)
        no(await daily.setMuted(false), "No unmute during the check")
        XCTAssertFalse(sender.isEnabled); XCTAssertTrue(module.muted)
        ok(await engine.endPrivateCheck())
        ok(await daily.setMuted(false))
        XCTAssertTrue(sender.isEnabled)
    }

    // Guarantee 5: cleanup failures quarantine the engine.
    func testAFailedReleaseBlocksNewMeetings() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), sender = FakeSender()
        daily.addSender(sender)
        ok(await daily.assumeTalk()); ok(await daily.setMuted(false))
        module.failShutdown = true
        no(await daily.detach())
        XCTAssertFalse(sender.isEnabled, "Senders are off even when release fails")
        XCTAssertTrue(engine.cleanupFailed)
        do { _ = try await engine.attach(meetingID: UUID()); XCTFail("A quarantined engine admits no meeting") }
        catch { XCTAssertEqual(error as? SharedAudioEngineError, .cleanupFailed) }
    }

    func testTheLastMeetingOutShutsTheModuleDownAndTheNextStartsAFreshOne() async throws {
        var created = 0
        let engine = SharedAudioEngine(reportFailedStop: {}) { created += 1; return FakeModule() }
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        XCTAssertEqual(created, 1, "Every meeting shares one module")
        ok(await daily.detach())
        ok(await infra.detach())
        XCTAssertTrue(engine.meetingIDs.isEmpty)
        _ = try await engine.attach(meetingID: UUID())
        XCTAssertEqual(created, 2)
        XCTAssertTrue(daily.detached); no(await daily.assumeTalk(), "A detached meeting cannot take the talk role")
    }

    // Guarantee 8: sound and volumes are per meeting on one output.
    func testSoundAndVolumesArePerMeetingOnOneOutput() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        var volumes: [String: Double] = [:]
        daily.addReceived(id: "anna") { volumes["anna"] = $0 }
        infra.addReceived(id: "boris", participantVolume: 0.5) { volumes["boris"] = $0 }
        XCTAssertEqual(volumes, ["anna": 0, "boris": 0], "Sound starts off")
        ok(await daily.setSound(true))
        XCTAssertTrue(module.playout); XCTAssertEqual(volumes, ["anna": 1, "boris": 0])
        ok(await infra.setSound(true)); infra.setMeetingVolume(0.4)
        XCTAssertEqual(volumes["boris"]!, 0.2, accuracy: 1e-9)
        infra.setParticipantVolume(1, id: "boris")
        XCTAssertEqual(volumes["boris"]!, 0.4, accuracy: 1e-9)
        ok(await daily.setSound(false)); ok(await infra.setSound(false))
        XCTAssertFalse(module.playout); XCTAssertEqual(volumes, ["anna": 0, "boris": 0])
        ok(await infra.setTranscriptionOutput(true))
        XCTAssertTrue(module.transcription, "Output runs silenced for transcription")
        XCTAssertFalse(module.playout); XCTAssertEqual(volumes, ["anna": 0, "boris": 0])
        ok(await daily.setSound(true))
        XCTAssertTrue(module.playout); XCTAssertFalse(module.transcription)
        XCTAssertEqual(volumes, ["anna": 1, "boris": 0], "A transcribing meeting stays silent beside one with sound")
        ok(await daily.detach())
        XCTAssertEqual(volumes["anna"], 0, "A detached meeting is silenced")
        XCTAssertFalse(module.playout); XCTAssertTrue(module.transcription)
    }

    func testOnlyTheTalkMeetingReceivesYourMicrophoneAndPlaysReplies() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        var heard: [String] = []
        daily.setInputTranscriptionSink { _ in heard.append("daily") }
        infra.setInputTranscriptionSink { _ in heard.append("infra") }
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!, frameCapacity: 16))
        module.deliver(buffer)
        XCTAssertEqual(heard, [], "No talk meeting: nobody hears the microphone")
        ok(await infra.assumeTalk()); module.deliver(buffer)
        ok(await daily.assumeTalk()); module.deliver(buffer)
        XCTAssertEqual(heard, ["infra", "daily"])
        ok(await infra.setSound(true))
        no(await infra.playVoiceReply(buffer)); XCTAssertFalse(infra.setMicrophoneGate(open: false))
        no(await daily.playVoiceReply(buffer), "The talk meeting keeps its reply private while sound is off")
        ok(await daily.setSound(true))
        XCTAssertTrue(daily.setMicrophoneGate(open: false))
        ok(await daily.playVoiceReply(buffer))
        XCTAssertEqual(module.replies, 1)
    }

    func testMutedParticipationUsesOnlyTheTalkOwnersSenderWithTheMicrophoneGateClosed() async throws {
        let (engine, module) = make()
        let talk = try await engine.attach(meetingID: UUID())
        let other = try await engine.attach(meetingID: UUID())
        let sender = FakeSender(), otherSender = FakeSender()
        talk.addSender(sender); other.addSender(otherSender)
        ok(await talk.assumeTalk())
        ok(await talk.setMuted(false)); ok(await talk.setMuted(true))

        let audio = try OfflineVoiceGraph(gateOpen: true)
        defer { audio.engine.stop() }
        module.participationGraph = audio.graph
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        defer { permit.cancel() }
        no(await talk.setParticipationSenderMuted(false, permit: permit), "The raw microphone gate is still open")
        XCTAssertTrue(module.muted)
        XCTAssertFalse(sender.isEnabled || otherSender.isEnabled)

        XCTAssertTrue(talk.setMicrophoneGate(open: false))
        no(await other.setParticipationSenderMuted(false, permit: permit), "Another meeting cannot use the talk sender")
        module.onUnmute = {
            XCTAssertFalse(audio.graph.gateOpen)
            XCTAssertFalse(sender.isEnabled || otherSender.isEnabled, "No sender before the module is ready behind the gate")
        }
        ok(await talk.setParticipationSenderMuted(false, permit: permit))
        XCTAssertFalse(engine.talkUnmuted, "Assistant playback does not change the user's muted state")
        XCTAssertFalse(module.muted)
        XCTAssertTrue(sender.isEnabled)
        XCTAssertFalse(otherSender.isEnabled)

        let phrase = audio.tone(seconds: 1)
        let playback = Task {
            await talk.playParticipationVoice(phrase, permit: permit, canStart: { true }, localGain: { nil }, onStarted: {})
        }
        try await audio.waitForStart(permit)
        XCTAssertFalse(audio.graph.gateOpen)
        XCTAssertEqual(try audio.renderRMS(), Float(0.2 / 2.squareRoot()), accuracy: 0.01)
        permit.cancel()
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
        ok(await talk.setParticipationSenderMuted(true, permit: permit))
        XCTAssertTrue(module.muted)
        XCTAssertFalse(engine.talkUnmuted)
        XCTAssertFalse(sender.isEnabled || otherSender.isEnabled)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }

    func testMutedParticipationHandoffCancelsOldVoiceAndRejectsStaleSenderChanges() async throws {
        let (engine, module) = make()
        let first = try await engine.attach(meetingID: UUID())
        let second = try await engine.attach(meetingID: UUID())
        let firstSender = FakeSender(), secondSender = FakeSender()
        first.addSender(firstSender); second.addSender(secondSender)
        ok(await first.assumeTalk())
        ok(await first.setMuted(false)); ok(await first.setMuted(true))

        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        module.participationGraph = audio.graph
        let old = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        defer { old.cancel() }
        ok(await first.setParticipationSenderMuted(false, permit: old))
        let phrase = audio.tone(seconds: 1)
        let playback = Task {
            await first.playParticipationVoice(phrase, permit: old, canStart: { true }, localGain: { nil }, onStarted: {})
        }
        try await audio.waitForStart(old)
        XCTAssertTrue(firstSender.isEnabled)
        XCTAssertGreaterThan(try audio.renderRMS(), 0.1)

        ok(await second.assumeTalk())
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(firstSender.isEnabled || secondSender.isEnabled)
        XCTAssertTrue(module.muted)
        XCTAssertTrue(audio.graph.gateOpen, "A new talk owner receives an open gate only after the senders are muted")
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        no(await first.setParticipationSenderMuted(false, permit: old))
        XCTAssertFalse(first.setMicrophoneGate(open: true))
        ok(await second.setMuted(false))
        ok(await first.setParticipationSenderMuted(true, permit: old), "Late cleanup is a no-op for the old room")
        XCTAssertTrue(secondSender.isEnabled)
        XCTAssertFalse(firstSender.isEnabled || module.muted)
    }

    /// The real owner: meetings share it, and the last one out releases its lease.
    func testLiveModuleIsSharedAndReleasedByTheLastMeeting() async throws {
        let engine = SharedAudioEngine.live()
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        let factory = try XCTUnwrap(daily.factory)
        XCTAssertTrue(infra.factory === factory, "Both meetings use one factory")
        XCTAssertNil(GuestAudioOwnerLease(privateCheck: true), "A private check cannot start beside the shared owner")
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "microphone")
        daily.addSender(track)
        XCTAssertFalse(track.isEnabled)
        ok(await infra.detach()); ok(await daily.detach())
        XCTAssertFalse(engine.cleanupFailed)
        XCTAssertNotNil(GuestAudioOwnerLease(privateCheck: true), "The last meeting out released the owner")
    }

    // Guarantee 9: a rebuild the app did not ask for silences everything until the talk
    // meeting's own confirmed unmute is restored.
    func testRebuildSilencesEveryoneThenRestoresOnlyTheTalkMeetingsUnmute() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), infra = try await engine.attach(meetingID: UUID())
        let a = FakeSender(), b = FakeSender()
        daily.addSender(a); infra.addSender(b)
        ok(await daily.assumeTalk()); ok(await daily.setMuted(false))
        XCTAssertTrue(engine.talkUnmuted)

        // Reported by the owner on its native worker, as a device change would be.
        module.onSpontaneousEngineChange?(.stopped)
        try await spin { engine.rebuilding }
        XCTAssertFalse(a.isEnabled, "Senders are off as soon as the engine stops")
        ok(await engine.engineChanged(.stopped)?.value ?? true, "A second stop report changes nothing")
        try await spin { module.muted }
        let restored = try XCTUnwrap(engine.engineChanged(.started))
        ok(await restored.value)
        XCTAssertTrue(a.isEnabled); XCTAssertFalse(b.isEnabled); XCTAssertFalse(module.muted)
        XCTAssertEqual(engine.recoveries, 1); XCTAssertFalse(engine.rebuilding)

        // A muted talk meeting stays muted.
        ok(await daily.setMuted(true))
        _ = await engine.engineChanged(.stopped)?.value
        ok(await engine.engineChanged(.started)?.value ?? false)
        XCTAssertFalse(a.isEnabled); XCTAssertTrue(module.muted)

        // The talk role moving during the rebuild: nobody inherits the old unmute.
        ok(await daily.setMuted(false))
        _ = await engine.engineChanged(.stopped)?.value
        ok(await infra.assumeTalk())
        ok(await engine.engineChanged(.started)?.value ?? false)
        XCTAssertFalse(a.isEnabled || b.isEnabled); XCTAssertTrue(module.muted)
    }

    // A rebuild while already muted (beta 84, Bluetooth → built-in): senders off, but no
    // native mute that would only wait on the rebuilding worker. Unconfirmed mutes still mute.
    func testRebuildWhileConfirmedMutedSkipsTheNativeMute() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), sender = FakeSender()
        daily.addSender(sender)
        ok(await daily.assumeTalk())
        XCTAssertTrue(engine.muteConfirmed)
        module.log.removeAll()
        ok(await engine.engineChanged(.stopped)?.value ?? false)
        XCTAssertFalse(sender.isEnabled)
        XCTAssertFalse(module.log.contains("mute:true"), "Confirmed muted: no native mute during the rebuild")
        ok(await engine.engineChanged(.started)?.value ?? false)
        XCTAssertTrue(module.muted)

        // An unmute that fails leaves the mute unconfirmed: the next rebuild mutes natively.
        module.failUnmute = true
        no(await daily.setMuted(false))
        XCTAssertFalse(engine.muteConfirmed)
        module.failUnmute = false; module.log.removeAll()
        ok(await engine.engineChanged(.stopped)?.value ?? false)
        XCTAssertTrue(module.log.contains("mute:true"))
        XCTAssertTrue(engine.muteConfirmed)
    }

    func testAFailedRestoreLeavesTheMeetingMutedAndReportsIt() async throws {
        let (engine, module) = make()
        let daily = try await engine.attach(meetingID: UUID()), sender = FakeSender()
        daily.addSender(sender)
        ok(await daily.assumeTalk()); ok(await daily.setMuted(false))
        var failed: [UUID] = []
        engine.onRecoveryFailed = { failed.append($0) }
        _ = await engine.engineChanged(.stopped)?.value
        module.failActivation = true
        no(await engine.engineChanged(.started)?.value ?? true)
        XCTAssertFalse(sender.isEnabled); XCTAssertTrue(module.muted)
        XCTAssertEqual(failed, [daily.meetingID]); XCTAssertFalse(engine.talkUnmuted)
        module.failActivation = false
        _ = await engine.engineChanged(.stopped)?.value
        ok(await engine.engineChanged(.started)?.value ?? false)
        XCTAssertFalse(sender.isEnabled, "After a failed restore the meeting must unmute itself again")
    }

    func testForegroundReadinessPreparesIdleInputAdoptsIntoFirstMeetingAndRetiresOnBackground() async throws {
        var created = 0
        let module = FakeModule()
        let engine = SharedAudioEngine(grace: .milliseconds(15), authorized: { true }, reportFailedStop: {}) {
            created += 1; return module
        }
        engine.setForeground(true, microphone: true)
        await engine.waitForWork()
        XCTAssertEqual(created, 1, "Foreground readiness creates the shared owner")
        XCTAssertEqual(module.log, ["prepare-idle"])
        XCTAssertTrue(module.muted && module.active && module.permitted)

        // First meeting attaches to the already-warm module without recreating it.
        let daily = try await engine.attach(meetingID: UUID())
        XCTAssertEqual(created, 1)
        ok(await daily.assumeTalk())
        ok(await daily.setMuted(false))
        XCTAssertFalse(module.muted)

        // Leaving while still in the foreground keeps the module warm instead of shutting it down.
        ok(await daily.detach())
        XCTAssertFalse(module.log.contains("shutdown"), "Foreground readiness keeps the shared module warm after the meeting leaves")
        XCTAssertEqual(module.log.last, "prepare-idle")
        XCTAssertTrue(module.muted && module.active)

        // Moving to the background retires the idle module after the grace period.
        engine.setForeground(false, microphone: true)
        try await spin { module.log.contains("shutdown") }
        await engine.waitForWork()
        XCTAssertFalse(engine.hasModule)
    }

    func testLiveForegroundPreparationStartsEngineAndFirstMeetingAdoptsWithoutRestart() async throws {
        GuestSystemAudio.microphoneAuthorizationOverrideForTesting = true
        defer { GuestSystemAudio.microphoneAuthorizationOverrideForTesting = nil }
        let engine = SharedAudioEngine.live(manualRenderingForTesting: true)
        engine.setForeground(true, microphone: true)
        await engine.waitForWork()

        let owner = try XCTUnwrap(engine.guestOwner)
        var snapshot = owner.snapshot
        XCTAssertEqual(snapshot["inputEnabled"] as? Bool, true)
        XCTAssertEqual(snapshot["inputRunning"] as? Bool, true)
        XCTAssertEqual(snapshot["recording"] as? Bool, true)
        XCTAssertEqual(snapshot["inputAvailable"] as? Bool, true)
        XCTAssertEqual(snapshot["outputAvailable"] as? Bool, true)
        XCTAssertEqual(snapshot["microphoneMuted"] as? Bool, true)
        XCTAssertEqual(snapshot["enginesCreated"] as? Int, 1)
        XCTAssertEqual(snapshot["engineStarts"] as? Int, 1)

        let meeting = try await SharedGuestMeetingAudio.attach(to: engine)
        ok(await meeting.beginAttempt(sound: true))
        ok(await meeting.setInputPermitted(true))
        ok(await meeting.activateMicrophone())
        snapshot = owner.snapshot
        XCTAssertEqual(snapshot["enginesCreated"] as? Int, 1)
        XCTAssertEqual(snapshot["engineStarts"] as? Int, 1, "Adopting foreground-prepared input into the first meeting must not restart the audio engine")
        XCTAssertNil(snapshot["engineStops"])
        XCTAssertEqual(snapshot["inputRunning"] as? Bool, true)
        XCTAssertEqual(snapshot["recording"] as? Bool, true)
        XCTAssertEqual(snapshot["microphoneMuted"] as? Bool, true)

        ok(await meeting.shutdown())
        XCTAssertTrue(engine.guestOwner === owner, "Leaving the meeting while foregrounded keeps the warm owner")
        snapshot = owner.snapshot
        XCTAssertEqual(snapshot["engineStarts"] as? Int, 1)
        XCTAssertNil(snapshot["engineStops"])
        XCTAssertEqual(snapshot["inputRunning"] as? Bool, true)
        XCTAssertEqual(snapshot["recording"] as? Bool, true)
        XCTAssertEqual(snapshot["microphoneMuted"] as? Bool, true)

        ok(await engine.shutdownIdle())
        XCTAssertNil(engine.guestOwner)
    }

    private func spin(_ condition: @escaping @MainActor () -> Bool, timeout: TimeInterval = 2) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { XCTFail("Condition not reached"); return }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testLiveTracksActAsSenders() {
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())
        let track = factory.audioTrack(with: factory.audioSource(with: nil), trackId: "microphone")
        track.isEnabled = true
        let sender: MeetingAudioSender = track
        sender.isEnabled = false
        XCTAssertFalse(track.isEnabled)
    }

    private func ok(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(value, message, file: file, line: line)
    }
    private func no(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(value, message, file: file, line: line)
    }

    private func make() -> (SharedAudioEngine, FakeModule) {
        let module = FakeModule()
        return (SharedAudioEngine(reportFailedStop: {}) { module }, module)
    }
}

private final class FakeSender: MeetingAudioSender { var isEnabled = true }

@MainActor private final class FakeModule: SharedAudioModule {
    var log: [String] = []
    var muted = true, playout = false, transcription = false, permitted = true, active = false
    var unmutes = 0, replies = 0
    var failUnmute = false, failActivation = false, failShutdown = false
    var onUnmute: (() -> Void)?
    var participationGraph: GuestVoiceReplyGraph?
    private var sink: ((AVAudioPCMBuffer) -> Void)?
    lazy var factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory())

    func deliver(_ buffer: AVAudioPCMBuffer) { sink?(buffer) }
    func prepareIdleInput(timeout: TimeInterval) async -> Bool {
        log.append("prepare-idle"); guard !failActivation else { return false }
        muted = true; permitted = true; active = true; return true
    }
    func activateMicrophone(timeout: TimeInterval?) async -> Bool {
        log.append("activate"); guard !failActivation, permitted else { return false }; active = true; return true
    }
    func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval) async -> Bool {
        log.append("mute:\(muted)")
        if !muted { guard !failUnmute, permitted, active else { return false }; onUnmute?(); unmutes += 1 }
        self.muted = muted; return true
    }
    func suppressMicrophone() { log.append("suppress"); muted = true }
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool, timeout: TimeInterval) async -> Bool {
        if permitted { log.append("permit:true") } else { log.append("permit:false warm:\(keepWarm)"); muted = true; if !keepWarm { active = false } }
        self.permitted = permitted; return true
    }
    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval, expectedEpoch: UUID?) async -> Bool { playout = enabled; return true }
    func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval) async -> Bool { transcription = keep; return true }
    func beginPrivateInputCheck(timeout: TimeInterval?) async -> Bool { log.append("check:begin"); return true }
    func endPrivateInputCheck(timeout: TimeInterval) async -> Bool { log.append("check:end"); return true }
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) { self.sink = sink }
    func setMicrophoneGate(open: Bool) -> Bool { participationGraph?.setGate(open: open); return true }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { replies += 1; return true }
    var hasParticipationVoiceGraph: Bool { participationGraph?.isConnected == true }
    var participationVoiceGateClosed: Bool { participationGraph.map { $0.isConnected && !$0.gateOpen } ?? false }
    func playParticipationVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                                canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                                onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        await participationGraph?.playAutonomous(buffer, permit: permit, canStart: canStart,
                                                 localGain: localGain, onStarted: onStarted) ?? .notStarted
    }
    func shutdown(timeout: TimeInterval) async -> Bool { log.append("shutdown"); return !failShutdown }
    var onSpontaneousEngineChange: ((GuestEngineChange) -> Void)?
}
