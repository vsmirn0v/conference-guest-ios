import AVFoundation
import LiveKitWebRTC
import XCTest
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
        XCTAssertTrue(owner.setMicrophoneGate(open: false), "Without an input graph the gate state is kept for when one is built")
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

    func connect(invitation: URL, name: String, quiet: Bool) async throws {
        snapshot = .init(phase: .connected, playoutOn: !quiet, participants: [.init(id: "me", name: name, isLocal: true)])
        onState?(snapshot)
    }
    func reconnect() async throws {}
    func setMicrophone(_ enabled: Bool) async throws {
        if !enabled && failMute { throw NativeDesktopRTCError.invalidResponse }
        events.append("mic:\(enabled)")
        snapshot.microphoneOn = enabled; onState?(snapshot)
    }
    func forceMicrophone(_ enabled: Bool) { snapshot.microphoneOn = enabled; onState?(snapshot) }
    func setCamera(_ enabled: Bool) async throws {}
    func setPlayout(_ enabled: Bool) async throws {}
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws {}
    func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool { await setPhysicalInputPermitted(permitted, keepDeviceWarm: false) }
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        events.append("permit:\(permitted) warm:\(keepDeviceWarm)"); return true
    }
    func prewarmInput() async -> Bool { events.append("prewarm"); return true }
    var supportsVoiceReply: Bool { voiceReply }
    func setMicrophoneGate(open: Bool) async -> Bool { events.append("gate:\(open)"); return !failGate }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { events.append("play"); return playResult }
    func leave() async -> Bool { snapshot.phase = .left; onState?(snapshot); return true }
}
