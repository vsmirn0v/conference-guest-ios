import AVFoundation
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

/// Microphone moves and voice replies: the move record, keeping the device warm,
/// the gate and player in a real (offline-rendered) audio graph, and the order in
/// which a meeting closes the gate, unmutes, plays, mutes and reopens.
@MainActor final class MicrophoneMoveTests: XCTestCase {

    // MARK: R0 — move record

    func testHandoverRecordCarriesEveryPhase() {
        let record = TalkHandoverRecord(from: "telemost", to: "guest", releaseMilliseconds: 412.34, assumeMilliseconds: 3.21,
            totalMilliseconds: 1834.56, steps: ["permission": 0.42, "activation": 905.55, "unmuteConfirmation": 410.04],
            keptWarm: false, live: true)
        let fields = record.fields
        XCTAssertEqual(fields["from"] as? String, "telemost"); XCTAssertEqual(fields["to"] as? String, "guest")
        XCTAssertEqual(fields["releaseMs"] as? Double, 412.3); XCTAssertEqual(fields["totalMs"] as? Double, 1834.6)
        XCTAssertEqual((fields["steps"] as? [String: Double])?["activation"], 905.6)
        XCTAssertEqual(fields["live"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(fields), "The record is loggable as a diagnostics line")
        XCTAssertNil(TalkHandoverRecord(from: nil, to: "guest", totalMilliseconds: 1, steps: [:], keptWarm: true, live: false)
            .fields["from"], "A first unmute has no previous meeting")
    }

    // MARK: R1 — keeping the device warm

    func testRelinquishKeepsTheDeviceWarmOnlyWhenChosen() async throws {
        for warm in [false, true] {
            let engine = VoiceTestEngine()
            let model = try await meeting(engine)
            model.keepMicrophoneWarm = { warm }
            let released = await model.relinquishMicrophone(); XCTAssertTrue(released)
            XCTAssertEqual(engine.events.last, "permit:false warm:\(warm)")
            XCTAssertFalse(model.ownsMicrophone)
            _ = await model.leave()
        }
    }

    /// A real audio owner (no microphone needed): a warm release mutes and
    /// refuses to unmute until the permit returns, and says it kept input.
    func testWarmReleaseMutesAndRefusesUnmuteUntilPermitted() async throws {
        let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, concurrent: true)
        defer { Task { _ = await owner.shutdown() } }
        let released = await owner.setInputPermitted(false, keepWarm: true); XCTAssertTrue(released)
        XCTAssertEqual(owner.snapshot["inputKeptWarm"] as? Bool, true)
        XCTAssertEqual(owner.snapshot["inputPermitted"] as? Bool, false)
        XCTAssertEqual(owner.snapshot["microphoneMuted"] as? Bool, true)
        let unmuted = await owner.setMicrophoneMuted(false)
        XCTAssertFalse(unmuted, "Unmuting is refused while another meeting holds the talk role")
        let granted = await owner.setInputPermitted(true); XCTAssertTrue(granted)
        XCTAssertEqual(owner.snapshot["inputKeptWarm"] as? Bool, false)
        XCTAssertFalse(owner.setMicrophoneGate(open: false), "A cold graph cannot prove that the raw microphone is gated")
        XCTAssertEqual(owner.snapshot["microphoneMuted"] as? Bool, true)
        let played = await owner.playVoiceReply(Self.tone(seconds: 0.1, frequency: 300, amplitude: 0.2))
        XCTAssertFalse(played, "Nothing plays without an input graph")
        XCTAssertTrue(owner.setMicrophoneGate(open: true))
    }

    /// A listening meeting starts its device muted at join only when the warm
    /// microphone is chosen; the talk meeting never takes this path.
    func testListenerPrewarmsAtJoinOnlyWhenChosen() async throws {
        for (warm, owns) in [(true, false), (false, false), (true, true)] {
            let engine = VoiceTestEngine()
            let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://example.test/calls/warm-\(UUID())")!, engine: .guest),
                                                  name: "Vitalii", title: "Warm", engine: engine)
            model.keepMicrophoneWarm = { warm }
            model.configureForConcurrentJoin(ownsMicrophone: owns)
            try await model.connect()
            for _ in 0..<50 where !engine.events.contains("prewarm") { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(engine.events.contains("prewarm"), warm && !owns, "warm \(warm), owns \(owns)")
            XCTAssertFalse(engine.events.contains("mic:true"), "Prewarming never unmutes")
            _ = await model.leave()
        }
    }

    /// A real audio owner: prewarming is refused while it holds the permit, and
    /// otherwise leaves it muted, unpermitted and refusing to unmute.
    func testPrewarmKeepsInputMutedAndUnpermitted() async throws {
        let owner = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, concurrent: true)
        defer { Task { _ = await owner.shutdown() } }
        let whilePermitted = await owner.prewarmInput()
        XCTAssertFalse(whilePermitted, "The talk meeting uses the ordinary activation")
        let released = await owner.setInputPermitted(false); XCTAssertTrue(released)
        let warm = await owner.prewarmInput()
        XCTAssertEqual(warm, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
                       "Without microphone access nothing starts")
        XCTAssertEqual(owner.snapshot["inputPermitted"] as? Bool, false)
        XCTAssertEqual(owner.snapshot["microphoneMuted"] as? Bool, true)
        let unmuted = await owner.setMicrophoneMuted(false)
        XCTAssertFalse(unmuted, "Unmuting is refused until the talk role moves here")
    }

    // MARK: Beta 58 hang — one owner's native audio work at a time

    /// The gate admits one owner at a time and drains every other owner first.
    func testEngineGateRunsOwnersOneAtATimeAfterDrainingOthers() {
        let gate = GuestAudioEngineGate()
        final class Log: @unchecked Sendable { let lock = NSLock(); var items: [String] = []
            func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() } }
        let log = Log()
        let a = NSObject(), b = NSObject(), c = NSObject()
        for (name, owner) in [("a", a), ("b", b), ("c", c)] {
            gate.register(ObjectIdentifier(owner)) { log.add("drain-\(name)") }
        }
        DispatchQueue.concurrentPerform(iterations: 30) { index in
            let owner = [a, b, c][index % 3]
            gate.run(for: ObjectIdentifier(owner)) { usleep(1_000) }
        }
        XCTAssertEqual(gate.maximumConcurrent, 1, "Never two owners at once")
        XCTAssertEqual(gate.passes, 30)
        log.items = []
        gate.run(for: ObjectIdentifier(a)) { log.add("body-a") }
        XCTAssertEqual(Array(log.items.prefix(2)).sorted(), ["drain-b", "drain-c"], "Others' queued work finishes first")
        XCTAssertEqual(log.items.dropFirst(2).first, "body-a")
        XCTAssertEqual(log.items.last, "drain-a", "Its own queued work finishes before the next owner")
        gate.unregister(ObjectIdentifier(b))
        log.items = []
        gate.run(for: ObjectIdentifier(a)) {}
        XCTAssertFalse(log.items.contains("drain-b"), "A finished owner is not drained")
    }

    /// Two real audio owners changing availability in parallel (as two meetings
    /// do when the microphone moves) go through the gate strictly one at a time.
    func testTwoAudioOwnersChangeAvailabilityOneAtATime() async throws {
        let first = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, concurrent: true)
        let second = try await GuestSystemAudio.create(microphoneEnabled: false, playoutEnabled: false, concurrent: true)
        XCTAssertGreaterThanOrEqual(GuestAudioEngineGate.shared.registeredOwners, 2)
        GuestAudioEngineGate.shared.resetEvidenceForTesting()
        let results = await withTaskGroup(of: Bool.self) { group in
            for round in 0..<6 {
                group.addTask { await first.setInputPermitted(round % 2 == 1) }
                group.addTask { await second.setInputPermitted(round % 2 == 0) }
                group.addTask { await first.setTranscriptionOutput(round % 2 == 0) }
                group.addTask { await second.setTranscriptionOutput(round % 2 == 1) }
            }
            var all: [Bool] = []
            for await result in group { all.append(result) }
            return all
        }
        XCTAssertEqual(results.count, 24); XCTAssertTrue(results.allSatisfy { $0 }, "No operation failed or timed out")
        XCTAssertEqual(GuestAudioEngineGate.shared.maximumConcurrent, 1)
        XCTAssertGreaterThanOrEqual(GuestAudioEngineGate.shared.passes, 24)
        let stoppedFirst = await first.shutdown(), stoppedSecond = await second.shutdown()
        XCTAssertTrue(stoppedFirst && stoppedSecond)
    }

    // MARK: R2 — the gate and the player in a real audio graph

    func testGateRemovesTheMicrophoneButNotTheReply() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let engine = AVAudioEngine()
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        let microphone = Self.sine(format: format, frequency: 440, amplitude: 0.5)
        let inputMixer = AVAudioMixerNode()
        engine.attach(microphone); engine.attach(inputMixer)
        engine.connect(inputMixer, to: engine.mainMixerNode, format: format)
        let graph = GuestVoiceReplyGraph(engine: engine, gateOpen: true)
        XCTAssertTrue(graph.connect(source: microphone, inputMixer: inputMixer, format: format))
        let gateInputs = (0..<graph.gate.numberOfInputs).compactMap {
            engine.inputConnectionPoint(for: graph.gate, inputBus: $0)?.node
        }
        XCTAssertEqual(gateInputs.count, 2,
                       "The VPIO microphone gate must remain a mixer, as in LiveKit's own input graph")
        try engine.start()
        defer { engine.stop() }

        let microphoneOnly = try Self.render(engine, format: format)
        XCTAssertEqual(microphoneOnly, Float(0.5 / 2.squareRoot()), accuracy: 0.01, "Open gate passes the microphone")
        graph.setGate(open: false); XCTAssertFalse(graph.gateOpen)
        // The mixer ramps volume changes. Find when the closed gate reaches silence:
        // this bounds the settle time a reply waits before anything unmutes.
        var silentAfter: Int?
        for chunk in 0..<30 where silentAfter == nil {
            if try Self.render(engine, format: format, frames: 480) == 0 { silentAfter = chunk * 10 }
        }
        let settle = try XCTUnwrap(silentAfter, "The closed gate must reach exact silence")
        XCTAssertLessThanOrEqual(settle, GuestVoiceReplyGraph.gateSettleMilliseconds, "Closing settles within the reply's wait")
        XCTAssertEqual(try Self.render(engine, format: format), 0, accuracy: 0, "Closed gate then sends exact silence")

        let reply = Self.tone(seconds: 1, frequency: 220, amplitude: 0.3)
        XCTAssertNotNil(graph.schedule(reply) {})
        let replyOnly = try Self.render(engine, format: format)
        XCTAssertEqual(replyOnly, Float(0.3 / 2.squareRoot()), accuracy: 0.01, "The reply plays while the microphone is held back")
        graph.setGate(open: true)
        _ = try Self.render(engine, format: format)
        let both = try Self.render(engine, format: format)
        XCTAssertEqual(both, (microphoneOnly * microphoneOnly + replyOnly * replyOnly).squareRoot(), accuracy: 0.02,
                       "With the gate open both are mixed, so the closed result above had no microphone in it")
        graph.detach()
    }

    func testReplyIsConvertedToThePlayerFormat() throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source = Self.tone(seconds: 0.5, frequency: 220, amplitude: 0.3, sampleRate: 22_050)
        let converted = try XCTUnwrap(GuestVoiceReplyGraph.convert(source, to: format))
        XCTAssertEqual(converted.format.sampleRate, 48_000)
        XCTAssertEqual(Double(converted.frameLength) / 48_000, 0.5, accuracy: 0.02, "Length is kept")
    }

    // MARK: R2 — what a meeting does around a reply

    func testReplyClosesTheGateBeforeUnmutingAndReopensAfterMuting() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        engine.events = []
        try await model.speak(Self.tone(seconds: 0.2, frequency: 300, amplitude: 0.2))
        XCTAssertEqual(engine.events, ["gate:false", "mic:true", "play", "mic:false", "gate:true"])
        XCTAssertFalse(model.snapshot.microphoneOn); XCTAssertFalse(model.voiceReplyActive)
        _ = await model.leave()
    }

    func testReplyWhileLiveKeepsTheMicrophoneOn() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        await model.setMicrophoneForTesting(true)
        XCTAssertTrue(model.snapshot.microphoneOn)
        engine.events = []
        try await model.speak(Self.tone(seconds: 0.2, frequency: 300, amplitude: 0.2))
        XCTAssertEqual(engine.events, ["gate:false", "play", "gate:true"])
        XCTAssertTrue(model.snapshot.microphoneOn)
        _ = await model.leave()
    }

    func testFailedMuteAfterAReplyKeepsTheGateClosedUntilMuted() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        engine.events = []; engine.failMute = true
        do { try await model.speak(Self.tone(seconds: 0.2, frequency: 300, amplitude: 0.2)); XCTFail("mute failed") }
        catch { XCTAssertEqual(error as? NativeDesktopMeetingModel.VoiceReplyError, .mute) }
        XCTAssertFalse(engine.events.contains("gate:true"), "Your microphone stays held back while the meeting is still live")
        engine.failMute = false
        engine.forceMicrophone(false)
        for _ in 0..<50 where !engine.events.contains("gate:true") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(engine.events.last, "gate:true", "Once muted, the gate reopens")
        _ = await model.leave()
    }

    func testPushToTalkGateFailureDoesNotUndoFailedReplyMute() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        engine.failMute = true
        do { try await model.speak(Self.tone(seconds: 0.2, frequency: 300, amplitude: 0.2)); XCTFail("mute failed") }
        catch { XCTAssertEqual(error as? NativeDesktopMeetingModel.VoiceReplyError, .mute) }
        engine.events = []; engine.failGate = true
        let held = await model.holdMicrophoneForAssistant()
        XCTAssertFalse(held)
        XCTAssertEqual(engine.events, ["gate:false"], "A failed local-capture hold must not reopen the safety gate")
        engine.failGate = false; engine.failMute = false; engine.forceMicrophone(false)
        _ = await model.leave()
    }

    func testFailedPlaybackStillMutesAndReopens() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        engine.events = []; engine.playResult = false
        do { try await model.speak(Self.tone(seconds: 0.2, frequency: 300, amplitude: 0.2)); XCTFail("playback failed") }
        catch { XCTAssertEqual(error as? NativeDesktopMeetingModel.VoiceReplyError, .playback) }
        XCTAssertEqual(engine.events, ["gate:false", "mic:true", "play", "mic:false", "gate:true"])
        _ = await model.leave()
    }

    func testReplyIsRefusedWhereUnsupported() async throws {
        let engine = VoiceTestEngine(); engine.voiceReply = false
        let model = try await meeting(engine)
        engine.events = []
        do { try await model.speak(Self.tone(seconds: 0.1, frequency: 300, amplitude: 0.2)); XCTFail("unsupported") }
        catch { XCTAssertEqual(error as? NativeDesktopMeetingModel.VoiceReplyError, .unavailable) }
        XCTAssertTrue(engine.events.isEmpty, "Nothing is touched")
        _ = await model.leave()
    }

#if DEBUG
    func testParticipationSoundOffAndZeroVolumeInterruptBothAudioRoutes() async throws {
        let silence: [(NativeDesktopMeetingModel) -> Void] = [
            { $0.togglePlayout() },
            { $0.setMeetingVolume(0, persist: false) },
        ]
        for silenceMeeting in silence {
            let model = try await meeting(VoiceTestEngine())
            await model.setMicrophoneForTesting(true)
            XCTAssertTrue(model.participationMeetingSoundOn)
            let audio = try OfflineVoiceGraph(connectMonitor: true)
            defer { audio.engine.stop() }
            let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
            let reply = ParticipationVoiceReply(id: UUID().uuidString, text: "The rollout starts Friday.",
                                                createdAt: Date(), status: .speaking)
            model.participation.setVoicePlaybackForTesting(permit, reply: reply)
            let phrase = audio.tone(seconds: 1)
            let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit, localGain: { 0.5 }) }
            defer { permit.cancel() }
            try await audio.waitForStart(permit)
            XCTAssertEqual(try audio.renderRMS(), Float(0.3 / 2.squareRoot()), accuracy: 0.01)

            silenceMeeting(model)
            XCTAssertFalse(model.participationMeetingSoundOn)
            XCTAssertFalse(audio.graph.player.isPlaying)
            XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
            let outcome = await playback.value
            XCTAssertEqual(outcome, .interrupted)
            XCTAssertTrue(model.snapshot.microphoneOn, "Silencing the meeting does not change the user's microphone choice")
            XCTAssertEqual(model.participation.voiceReplies.map(\.text), [reply.text])
            _ = await model.leave()
        }
    }

    func testParticipationMicrophoneMuteStopsVoiceAndKeepsTheGateClosedUntilConfirmed() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        await model.setMicrophoneForTesting(true)
        XCTAssertTrue(model.snapshot.microphoneOn)
        engine.events.removeAll()

        let audio = try OfflineVoiceGraph(connectMonitor: true)
        defer { audio.engine.stop() }
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        model.participation.setVoicePlaybackForTesting(permit)
        let phrase = audio.tone(seconds: 1)
        let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit, localGain: { 0.5 }) }
        defer { permit.cancel() }
        try await audio.waitForStart(permit)
        XCTAssertEqual(try audio.renderRMS(), Float(0.3 / 2.squareRoot()), accuracy: 0.01)

        let (muteRelease, releaseMute) = AsyncStream.makeStream(of: Void.self)
        defer { releaseMute.finish() }
        engine.beforeMicrophoneChange = { enabled in
            guard !enabled else { return }
            for await _ in muteRelease {}
        }
        let mute = Task { await model.setMicrophoneForTesting(false) }
        for _ in 0..<100 where !engine.events.contains("mic:false") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(engine.events.contains("mic:false"))
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        XCTAssertTrue(model.snapshot.microphoneOn, "The mute is still waiting for confirmation")

        model.restoreParticipationVoiceGateForTesting { XCTFail("Microphone gate opened before the mute was confirmed") }
        XCTAssertTrue(model.participationVoiceGateHeldForTesting)
        releaseMute.finish()
        await mute.value
        XCTAssertFalse(model.snapshot.microphoneOn)
        XCTAssertFalse(model.participationVoiceGateHeldForTesting)
        for _ in 0..<50 where !engine.events.contains("gate:true") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(engine.events.contains("gate:true"))
        _ = await model.leave()
    }

    func testMovingTheTalkRoleClearsOldParticipationVoiceBeforeReleasingTheInput() async throws {
        for microphoneWasOn in [true, false] {
            let engine = VoiceTestEngine()
            let model = try await meeting(engine)
            if microphoneWasOn { await model.setMicrophoneForTesting(true) }
            let audio = try OfflineVoiceGraph()
            defer { audio.engine.stop() }
            let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
            model.participation.setVoicePlaybackForTesting(permit)
            let phrase = audio.tone(seconds: 1)
            let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit) }
            defer { permit.cancel() }
            try await audio.waitForStart(permit)
            XCTAssertGreaterThan(try audio.renderRMS(), 0.1)

            engine.beforeInputPermitChange = { permitted in
                if !permitted { XCTAssertFalse(audio.graph.player.isPlaying, "Voice must stop before the microphone is released") }
            }
            let released = await model.relinquishMicrophone()
            let outcome = await playback.value
            XCTAssertTrue(released)
            XCTAssertFalse(model.ownsMicrophone)
            XCTAssertEqual(outcome, .interrupted)
            XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
            await model.assumeMicrophone()
            XCTAssertTrue(model.ownsMicrophone)
            XCTAssertFalse(model.snapshot.microphoneOn)
            let stalePlayback = await audio.graph.playAutonomous(phrase, permit: permit)
            XCTAssertEqual(stalePlayback, .notStarted)
            XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
            _ = await model.leave()
        }
    }

    func testLeavingAMutedMeetingStopsParticipationVoiceWithoutChangingMicIntent() async throws {
        let engine = VoiceTestEngine()
        let model = try await meeting(engine)
        XCTAssertFalse(model.snapshot.microphoneOn)
        let audio = try OfflineVoiceGraph(connectMonitor: true)
        defer { audio.engine.stop() }
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        model.participation.setVoicePlaybackForTesting(permit)
        let phrase = audio.tone(seconds: 1)
        let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit, localGain: { 0.5 }) }
        defer { permit.cancel() }
        try await audio.waitForStart(permit)
        XCTAssertGreaterThan(try audio.renderRMS(), 0.1)

        let left = await model.leave()
        let outcome = await playback.value
        XCTAssertTrue(left)
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(model.snapshot.microphoneOn)
        XCTAssertFalse(engine.events.contains("mic:true"))
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        let stalePlayback = await audio.graph.playAutonomous(phrase, permit: permit)
        XCTAssertEqual(stalePlayback, .notStarted)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }

    func testNonTalkRoomCanSpeakApprovedReplyWithoutStealingMicrophoneOrOpeningGate() async throws {
        let engineA = VoiceTestEngine()
        let meetingA = NativeDesktopMeetingModel(
            destination: try .verified(URL(string: "https://example.test/calls/talk-\(UUID())")!, engine: .guest),
            name: "Vitalii",
            title: "Talk",
            engine: engineA
        )
        meetingA.configureForConcurrentJoin(ownsMicrophone: true)
        try await meetingA.connect()

        let engineB = VoiceTestEngine()
        let meetingB = NativeDesktopMeetingModel(
            destination: try .verified(URL(string: "https://example.test/calls/nontalk-\(UUID())")!, engine: .guest),
            name: "Vitalii",
            title: "Listen",
            engine: engineB
        )
        var arbiterCalls = 0
        meetingB.microphoneArbiter = { _ in arbiterCalls += 1; return true }
        meetingB.configureForConcurrentJoin(ownsMicrophone: false)
        try await meetingB.connect()

        XCTAssertTrue(meetingA.ownsMicrophone)
        XCTAssertFalse(meetingB.ownsMicrophone)
        XCTAssertTrue(meetingB.canSpeakApprovedWorkspaceReply)

        engineA.events = []
        engineB.events = []
        try await meetingB.speak(Self.tone(seconds: 0.2, frequency: 300, amplitude: 0.2))

        XCTAssertEqual(engineB.events, ["play"])
        XCTAssertEqual(arbiterCalls, 0)
        XCTAssertTrue(meetingA.ownsMicrophone)
        XCTAssertFalse(meetingB.ownsMicrophone)
        XCTAssertFalse(meetingB.snapshot.microphoneOn)
        XCTAssertTrue(engineA.events.isEmpty)

        _ = await meetingB.leave()
        _ = await meetingA.leave()
    }

    func testSyntheticAudioSourceDeliversRTPFramesOverLoopbackWithoutHardwareADM() async throws {
        let factory = SharedAudioEngine.liveKitFactory(voiceProcessing: false)
        let config = LKRTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let relay = LoopbackSyntheticPeerRelay()
        guard let sender = factory.peerConnection(with: config, constraints: constraints, delegate: relay),
              let receiver = factory.peerConnection(with: config, constraints: constraints, delegate: relay) else {
            XCTFail("Failed to create loopback peer connections")
            return
        }
        relay.attach(sender: sender, receiver: receiver)
        defer {
            sender.close()
            receiver.close()
        }

        let source = factory.syntheticAudioSource()
        XCTAssertTrue(source.isSynthetic)
        let track = factory.audioTrack(with: source, trackId: "synth0")
        track.isEnabled = true
        let transceiverInit = LKRTCRtpTransceiverInit()
        transceiverInit.direction = .sendOnly
        _ = sender.addTransceiver(with: track, init: transceiverInit)

        let offer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LKRTCSessionDescription, Error>) in
            sender.offer(for: constraints) { sdp, error in
                if let error { cont.resume(throwing: error) }
                else if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: NativeDesktopRTCError.invalidResponse) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sender.setLocalDescription(offer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            receiver.setRemoteDescription(offer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        relay.remoteDescriptionSet(forReceiver: true)

        let answer = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<LKRTCSessionDescription, Error>) in
            receiver.answer(for: constraints) { sdp, error in
                if let error { cont.resume(throwing: error) }
                else if let sdp { cont.resume(returning: sdp) }
                else { cont.resume(throwing: NativeDesktopRTCError.invalidResponse) }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            receiver.setLocalDescription(answer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            sender.setRemoteDescription(answer) { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            }
        }
        relay.remoteDescriptionSet(forReceiver: false)

        for _ in 0..<100 where sender.iceConnectionState != .connected && sender.iceConnectionState != .completed {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(sender.iceConnectionState == .connected || sender.iceConnectionState == .completed,
                      "Loopback ICE did not connect: \(sender.iceConnectionState.rawValue)")

        let played = await SyntheticVoiceReplyPlayer.play(
            Self.tone(seconds: 0.25, frequency: 330, amplitude: 0.35),
            into: source,
            localGain: nil,
            canContinue: { true }
        )
        XCTAssertTrue(played)
        try await Task.sleep(for: .milliseconds(50))

        let stats = await withCheckedContinuation { (cont: CheckedContinuation<(packets: Int, bytes: Int), Never>) in
            sender.statistics { report in
                let outbound = report.statistics.values.filter {
                    $0.type == "outbound-rtp" && ($0.values["kind"] as? String ?? $0.values["mediaType"] as? String) == "audio"
                }
                let packets = outbound.compactMap { ($0.values["packetsSent"] as? NSNumber)?.intValue }.reduce(0, +)
                let bytes = outbound.compactMap { ($0.values["bytesSent"] as? NSNumber)?.intValue }.reduce(0, +)
                cont.resume(returning: (packets, bytes))
            }
        }
        XCTAssertGreaterThanOrEqual(stats.packets, 5, "Expected >=5 synthetic audio RTP packets, got \(stats.packets)")
        XCTAssertGreaterThanOrEqual(stats.bytes, 200, "Expected >=200 synthetic audio RTP bytes, got \(stats.bytes)")
    }
#endif

    // MARK: Helpers

    private func meeting(_ engine: VoiceTestEngine) async throws -> NativeDesktopMeetingModel {
        let model = NativeDesktopMeetingModel(destination: try .verified(URL(string: "https://example.test/calls/voice-\(UUID())")!, engine: .guest),
                                              name: "Vitalii", title: "Voice", engine: engine)
        try await model.connect()
        return model
    }

    static func tone(seconds: Double, frequency: Double, amplitude: Float, sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = amplitude * Float(sin(2 * .pi * frequency * Double(index) / sampleRate))
        }
        return buffer
    }

    private final class Phase: @unchecked Sendable { var value = 0.0 }
    private static func sine(format: AVAudioFormat, frequency: Double, amplitude: Float) -> AVAudioSourceNode {
        let phase = Phase(), step = 2 * Double.pi * frequency / format.sampleRate
        return AVAudioSourceNode(format: format) { _, _, frames, list in
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frames) {
                let value = amplitude * Float(sin(phase.value)); phase.value += step
                for buffer in buffers { buffer.mData!.assumingMemoryBound(to: Float.self)[frame] = value }
            }
            return noErr
        }
    }

    /// RMS of `frames` (default 0.1 s) rendered offline.
    private static func render(_ engine: AVAudioEngine, format: AVAudioFormat, frames: AVAudioFrameCount = 4800) throws -> Float {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: frames)!
        let status = try engine.renderOffline(frames, to: buffer)
        XCTAssertEqual(status, .success)
        let samples = UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }
}

/// Connects at once; records microphone, gate and playback calls in order.
@MainActor private final class VoiceTestEngine: NativeDesktopMeetingEngine {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)?
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)?
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)?
    var onTitle: ((String) -> Void)?
    var factory: LKRTCPeerConnectionFactory? { nil }
    private(set) var snapshot = NativeDesktopExternalSnapshot()
    var incomingVideo: [NativeDesktopExternalVideo] { [] }
    var events: [String] = []
    var voiceReply = true
    var failMute = false
    var failGate = false
    var playResult = true
    var beforeMicrophoneChange: ((Bool) async -> Void)?
    var beforeInputPermitChange: ((Bool) -> Void)?

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot = .init(phase: .connected, playoutOn: !quiet, participants: [.init(id: "me", name: name, isLocal: true)])
        onState?(snapshot)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws {
        if !enabled && failMute { throw NativeDesktopRTCError.invalidResponse }
        events.append("mic:\(enabled)")
        await beforeMicrophoneChange?(enabled)
        snapshot.microphoneOn = enabled; onState?(snapshot)
    }
    func forceMicrophone(_ enabled: Bool) { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws {}
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool { await setPhysicalInputPermitted(permitted, keepDeviceWarm: false) }
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        beforeInputPermitChange?(permitted)
        events.append("permit:\(permitted) warm:\(keepDeviceWarm)"); return true
    }
    func prewarmInput() async -> Bool { events.append("prewarm"); return true }
    var supportsVoiceReply: Bool { voiceReply }
    private(set) var voiceMicrophoneGateIsClosed = false
    func setMicrophoneGate(open: Bool) async -> Bool {
        events.append("gate:\(open)")
        guard !failGate else { return false }
        voiceMicrophoneGateIsClosed = !open
        return true
    }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { events.append("play"); return playResult }
    func leave() async -> Bool { snapshot.phase = .left; onState?(snapshot); return true }
}

private final class LoopbackSyntheticPeerRelay: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "test.loopback.ice")
    private weak var sender: LKRTCPeerConnection?
    private weak var receiver: LKRTCPeerConnection?
    private var senderReady = false
    private var receiverReady = false
    private var pendingForSender: [LKRTCIceCandidate] = []
    private var pendingForReceiver: [LKRTCIceCandidate] = []

    func attach(sender: LKRTCPeerConnection, receiver: LKRTCPeerConnection) {
        queue.sync {
            self.sender = sender
            self.receiver = receiver
        }
    }

    func remoteDescriptionSet(forReceiver: Bool) {
        queue.async { [weak self] in
            guard let self else { return }
            if forReceiver {
                self.receiverReady = true
                let list = self.pendingForReceiver
                self.pendingForReceiver.removeAll()
                for c in list { self.receiver?.add(c) { _ in } }
            } else {
                self.senderReady = true
                let list = self.pendingForSender
                self.pendingForSender.removeAll()
                for c in list { self.sender?.add(c) { _ in } }
            }
        }
    }

    func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        queue.async { [weak self] in
            guard let self else { return }
            if pc === self.sender {
                if self.receiverReady { self.receiver?.add(candidate) { _ in } }
                else { self.pendingForReceiver.append(candidate) }
            } else {
                if self.senderReady { self.sender?.add(candidate) { _ in } }
                else { self.pendingForSender.append(candidate) }
            }
        }
    }

    func peerConnection(_ pc: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: LKRTCPeerConnection) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
    func peerConnection(_ pc: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}
