import AVFoundation
import LiveKitWebRTC
import XCTest
@testable import RockNativeDesktop

/// R4 spike S0a (docs/r4-shared-engine-plan.md): several calls on ONE WebRTC factory and
/// audio module. The module runs in manual rendering mode with a tone in place of the
/// microphone, so no device is needed. Each call is a loopback pair of peer connections on
/// the shared factory. Proves or disproves:
///  - a second call attaches while the engine already runs;
///  - enabling one call's sender and disabling the other's switches who carries the input,
///    without the engine restarting;
///  - how long a switch takes until the other side hears it.
final class SharedEngineSpikeTests: XCTestCase {

    func testTwoCallsShareOneEngineAndSwitchSendersWithoutRestart() async throws {
        try await runSpike(hardware: false)
    }

    /// The same on real hardware with Apple Voice Processing I/O: the real microphone opens
    /// (tone mixed on top), the required output leg stays active but its mixer is silent.
    /// Skipped without microphone access.
    func testTwoCallsShareOneVoiceProcessingEngineOnHardware() async throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw XCTSkip("The test host has no microphone access")
        }
        try await runSpike(hardware: true)
    }

    private func runSpike(hardware: Bool) async throws {
        // The headset integration closes WebRTC's process-wide capture gate when a meeting ends
        // (it fails closed), which zeroes the input of every engine in the process. Earlier
        // tests' meetings leave it closed; open it for the spike and close it again after.
        LKRTCSetApplicationInputMuteIntent(-1)
        LKRTCSetApplicationCaptureMuted(0)
        defer { LKRTCSetApplicationCaptureMuted(1) }
        _ = LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: !hardware,
            encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(),
            audioProcessingModule: nil)
        // Bind WebRtcVoiceEngine to the audio transport before hardware availability
        // can start VPIO, matching the production shared owner's media context.
        let mediaContext = factory.peerConnection(with: LKRTCConfiguration(),
            constraints: LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil)
        defer { mediaContext?.close() }
        let module = factory.audioDeviceModule
        let observer = SpikeToneObserver()
        module.observer = observer
        if hardware {
            XCTAssertEqual(module.setPlatformVoiceProcessingAllowed(true), 0)
        } else {
            XCTAssertEqual(module.setManualRenderingMode(true), 0, "Manual rendering: no device needed")
        }
        XCTAssertEqual(module.setMuteMode(.inputMixer), 0)
        XCTAssertEqual(module.setMicrophoneMuted(false), 0)
        var availability = LKRTCAudioEngineAvailability()
        // VPIO needs its output leg for a valid render reference. The observer
        // silences the output mixer, so keeping it available cannot play the tone.
        availability.isInputAvailable = true; availability.isOutputAvailable = true
        XCTAssertEqual(module.setEngineAvailability(availability), 0)

        let callA = try await SpikeLoopCall.connect(factory: factory, name: "A")
        try await Task.sleep(for: .seconds(1.5))
        let enginesBeforeB = observer.counts
        let startedB = ProcessInfo.processInfo.systemUptime
        let callB = try await SpikeLoopCall.connect(factory: factory, name: "B")
        let attachB = ProcessInfo.processInfo.systemUptime - startedB
        XCTAssertGreaterThan(observer.counts.inputConfigured, 0, "The tone reached the input graph")

        // A talks, B is silent.
        callB.sender.isEnabled = false
        try await Task.sleep(for: .seconds(1.5))
        let windowA = try await (callA.measure(seconds: 1.0), callB.measure(seconds: 1.0))
        // Switch: B talks, A is silent. Time until B's far side hears the tone.
        let enginesBeforeSwitch = observer.counts
        let switchStarted = ProcessInfo.processInfo.systemUptime
        callA.sender.isEnabled = false; callB.sender.isEnabled = true
        let heard = await callB.waitForBytes(rate: 3000, timeout: 3)
        let switchSeconds = ProcessInfo.processInfo.systemUptime - switchStarted
        try await Task.sleep(for: .seconds(1.0))
        let windowB = try await (callA.measure(seconds: 1.0), callB.measure(seconds: 1.0))
        let enginesAfter = observer.counts

        let report: [String: Any] = [
            "attachSecondCallSeconds": attachB, "switchSeconds": switchSeconds, "heardAfterSwitch": heard,
            "phaseA_talkA": [windowA.0.rms, windowA.0.bytesPerSecond, windowA.0.sourceEnergyPerSecond],
            "phaseA_silentB": [windowA.1.rms, windowA.1.bytesPerSecond, windowA.1.sourceEnergyPerSecond],
            "phaseB_silentA": [windowB.0.rms, windowB.0.bytesPerSecond, windowB.0.sourceEnergyPerSecond],
            "phaseB_talkB": [windowB.1.rms, windowB.1.bytesPerSecond, windowB.1.sourceEnergyPerSecond],
            "enginesBeforeB": enginesBeforeB.description, "enginesBeforeSwitch": enginesBeforeSwitch.description,
            "enginesAfter": enginesAfter.description, "engineRunning": module.isEngineRunning, "recording": module.isRecording,
            "playing": module.isPlaying, "hardware": hardware,
            "voiceProcessingActive": module.platformAudioProcessingState.isVoiceProcessingEnabledActive]
        print("R4-SPIKE " + String(data: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), encoding: .utf8)!)

        // Sending side: what each call's sender put on the wire (manual rendering does not pull playout).
        // Sending side: what each call's sender put on the wire (manual rendering does not pull
        // playout, and media-source energy is measured before the enabled check, so it is shared).
        XCTAssertGreaterThan(windowA.0.bytesPerSecond, windowA.1.bytesPerSecond * 1.5, "The talking call carries the input")
        XCTAssertTrue(heard, "After the switch the other call carries the input")
        XCTAssertGreaterThan(windowB.1.bytesPerSecond, windowB.0.bytesPerSecond * 1.5, "…and the first call sends only silence")
        XCTAssertLessThan(switchSeconds, 1.0, "A switch is a flag on a running engine")
        XCTAssertEqual(enginesAfter.created, enginesBeforeSwitch.created, "Switching senders never rebuilds the engine")
        XCTAssertEqual(enginesAfter.started, enginesBeforeSwitch.started, "…or restarts it")

        await callA.close(); await callB.close()
        module.observer = nil
    }
}

// MARK: - Spike helpers

/// Feeds a 440 Hz tone into the module's input mixer and counts engine lifecycle events.
final class SpikeToneObserver: NSObject, LKRTCAudioDeviceModuleDelegate, @unchecked Sendable {
    struct Counts: CustomStringConvertible {
        var created = 0, started = 0, stopped = 0, released = 0, inputConfigured = 0
        var description: String { "created=\(created) started=\(started) stopped=\(stopped) released=\(released) input=\(inputConfigured)" }
    }
    private let lock = NSLock()
    private var value = Counts()
    private var phase = 0.0
    var counts: Counts { lock.lock(); defer { lock.unlock() }; return value }
    private func bump(_ change: (inout Counts) -> Void) { lock.lock(); change(&value); lock.unlock() }

    /// Another observer that also needs the module's events (the LiveKit SDK's own, when
    /// the SDK runs on this shared factory). Events go to it first; the tone is added after.
    weak var forward: LKRTCAudioDeviceModuleDelegate?

    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didReceiveSpeechActivityEvent event: LKRTCSpeechActivityEvent) {
        forward?.audioDeviceModule(module, didReceiveSpeechActivityEvent: event)
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didCreateEngine engine: AVAudioEngine) -> Int {
        bump { $0.created += 1 }; return forward?.audioDeviceModule(module, didCreateEngine: engine) ?? 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willEnableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool, isVoiceProcessingEnabled: Bool) -> Int {
        guard let forward else { return 0 }
        if forward.responds(to: #selector(LKRTCAudioDeviceModuleDelegate.audioDeviceModule(_:willEnableEngine:isPlayoutEnabled:isRecordingEnabled:isVoiceProcessingEnabled:))) {
            return forward.audioDeviceModule?(module, willEnableEngine: engine, isPlayoutEnabled: isPlayoutEnabled,
                                              isRecordingEnabled: isRecordingEnabled, isVoiceProcessingEnabled: isVoiceProcessingEnabled) ?? 0
        }
        return forward.audioDeviceModule?(module, willEnableEngine: engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willStartEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        bump { $0.started += 1 }
        return forward?.audioDeviceModule(module, willStartEngine: engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didStopEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        bump { $0.stopped += 1 }
        return forward?.audioDeviceModule(module, didStopEngine: engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, didDisableEngine engine: AVAudioEngine,
                           isPlayoutEnabled: Bool, isRecordingEnabled: Bool) -> Int {
        forward?.audioDeviceModule(module, didDisableEngine: engine, isPlayoutEnabled: isPlayoutEnabled, isRecordingEnabled: isRecordingEnabled) ?? 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, willReleaseEngine engine: AVAudioEngine) -> Int {
        bump { $0.released += 1 }; return forward?.audioDeviceModule(module, willReleaseEngine: engine) ?? 0
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureInputFromSource source: AVAudioNode?,
                           toDestination destination: AVAudioNode, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        bump { $0.inputConfigured += 1 }
        let forwarded = forward?.audioDeviceModule(module, engine: engine, configureInputFromSource: source, toDestination: destination,
                                                   format: format, context: context) ?? 0
        let mixer = context[kLKRTCAudioEngineInputMixerNodeKey] as? AVAudioMixerNode
        let target: AVAudioNode = mixer ?? destination
        // Directly adding a second input beside AVAudioInputNode can leave VPIO's
        // sink unrendered. Mix the microphone and tone upstream, as the production
        // voice-reply graph does, and give WebRTC's input mixer one source.
        let inputStage = AVAudioMixerNode()
        engine.attach(inputStage)
        if let source { engine.connect(source, to: inputStage, format: format) }
        engine.connect(inputStage, to: target, format: format)
        let step = 2 * Double.pi * 440 / format.sampleRate
        let tone = AVAudioSourceNode(format: format) { [weak self] _, _, frames, list in
            guard let self else { return noErr }
            let buffers = UnsafeMutableAudioBufferListPointer(list)
            for frame in 0..<Int(frames) {
                let sample = Float(0.3 * sin(phase)); phase += step
                for buffer in buffers { buffer.mData?.assumingMemoryBound(to: Float.self)[frame] = sample }
            }
            return noErr
        }
        engine.attach(tone)
        engine.connect(tone, to: inputStage, format: format)
        return forwarded
    }
    func audioDeviceModule(_ module: LKRTCAudioDeviceModule, engine: AVAudioEngine, configureOutputFromSource source: AVAudioNode,
                           toDestination destination: AVAudioNode?, format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
        let forwarded = forward?.audioDeviceModule(module, engine: engine, configureOutputFromSource: source, toDestination: destination,
                                                   format: format, context: context) ?? 0
        // The loopback tone is test input, not something to play over speakers.
        (source as? AVAudioMixerNode)?.outputVolume = 0
        return forwarded
    }
    func audioDeviceModuleDidUpdateDevices(_ module: LKRTCAudioDeviceModule) { forward?.audioDeviceModuleDidUpdateDevices(module) }
}

/// RMS of what one call's far side receives.
final class SpikeEnergyMeter: NSObject, LKRTCAudioRenderer, @unchecked Sendable {
    private let lock = NSLock()
    private var sum = 0.0, count = 0, recent = 0.0
    func render(pcmBuffer: AVAudioPCMBuffer) {
        guard let data = pcmBuffer.floatChannelData else {
            if let ints = pcmBuffer.int16ChannelData {
                var local = 0.0
                for index in 0..<Int(pcmBuffer.frameLength) { let s = Double(ints[0][index]) / 32768; local += s * s }
                store(local, Int(pcmBuffer.frameLength))
            }
            return
        }
        var local = 0.0
        for index in 0..<Int(pcmBuffer.frameLength) { let s = Double(data[0][index]); local += s * s }
        store(local, Int(pcmBuffer.frameLength))
    }
    private func store(_ local: Double, _ frames: Int) {
        lock.lock(); sum += local; count += frames; recent = frames > 0 ? (local / Double(frames)).squareRoot() : 0; lock.unlock()
    }
    func reset() { lock.lock(); sum = 0; count = 0; lock.unlock() }
    var rms: Double { lock.lock(); defer { lock.unlock() }; return count > 0 ? (sum / Double(count)).squareRoot() : 0 }
    var recentRMS: Double { lock.lock(); defer { lock.unlock() }; return recent }
}

/// A loopback call: sender and receiver peer connections on the same factory.
final class SpikeLoopCall: NSObject, LKRTCPeerConnectionDelegate, @unchecked Sendable {
    let name: String
    private(set) var caller: LKRTCPeerConnection!
    private(set) var callee: LKRTCPeerConnection!
    private(set) var sender: LKRTCAudioTrack!
    let meter = SpikeEnergyMeter()
    private var remoteAttached = false
    private let lock = NSLock()

    init(name: String) { self.name = name }

    static func connect(factory: LKRTCPeerConnectionFactory, name: String) async throws -> SpikeLoopCall {
        let call = SpikeLoopCall(name: name)
        let configuration = LKRTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan; configuration.iceServers = []
        let constraints = LKRTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        call.caller = factory.peerConnection(with: configuration, constraints: constraints, delegate: call)
        call.callee = factory.peerConnection(with: configuration, constraints: constraints, delegate: call)
        let source = factory.audioSource(with: constraints)
        call.sender = factory.audioTrack(with: source, trackId: "mic-\(name)")
        _ = call.caller.add(call.sender, streamIds: ["s-\(name)"])
        let offer = try await call.caller.offer(for: constraints)
        try await call.caller.setLocalDescription(offer)
        try await call.callee.setRemoteDescription(offer)
        let answer = try await call.callee.answer(for: constraints)
        try await call.callee.setLocalDescription(answer)
        try await call.caller.setRemoteDescription(answer)
        for _ in 0..<200 where call.caller.iceConnectionState != .connected && call.caller.iceConnectionState != .completed {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard [.connected, .completed].contains(call.caller.iceConnectionState) else {
            throw NSError(domain: "R4Spike", code: 1, userInfo: [NSLocalizedDescriptionKey: "call \(name) did not connect"])
        }
        call.attachRemoteIfNeeded()
        return call
    }

    private func attachRemoteIfNeeded() {
        lock.lock(); defer { lock.unlock() }
        guard !remoteAttached, let track = callee?.transceivers.compactMap({ $0.receiver.track as? LKRTCAudioTrack }).first else { return }
        track.add(meter); remoteAttached = true
    }

    struct Window { var rms: Double; var bytesPerSecond: Double; var sourceEnergyPerSecond: Double }
    struct Sample { var bytes: Int; var energy: Double }

    /// Far-side RMS (needs playout to be pulled), bytes sent, and the energy WebRTC
    /// measured on this call's outgoing audio (media-source stats, per sender).
    func measure(seconds: Double) async throws -> Window {
        attachRemoteIfNeeded()
        let before = await sample()
        meter.reset()
        try await Task.sleep(for: .seconds(seconds))
        let after = await sample()
        return .init(rms: meter.rms, bytesPerSecond: Double(after.bytes - before.bytes) / seconds,
                     sourceEnergyPerSecond: (after.energy - before.energy) / seconds)
    }

    /// Waits until this call sends at more than `rate` bytes a second over a 100 ms window:
    /// the tone in Opus is ~3.5–4 KB/s, a disabled sender's silence far less.
    func waitForBytes(rate: Double, timeout: TimeInterval) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var last = await sample(), lastTime = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            let now = await sample(), time = ProcessInfo.processInfo.systemUptime
            if Double(now.bytes - last.bytes) / (time - lastTime) > rate { return true }
            last = now; lastTime = time
        }
        return false
    }

    func sample() async -> Sample {
        await withCheckedContinuation { continuation in
            caller.statistics { report in
                let values = report.statistics.values
                let bytes = values.filter { $0.type == "outbound-rtp" }
                    .compactMap { ($0.values["bytesSent"] as? NSNumber)?.intValue }.reduce(0, +)
                let energy = values.filter { $0.type == "media-source" }
                    .compactMap { ($0.values["totalAudioEnergy"] as? NSNumber)?.doubleValue }.reduce(0, +)
                continuation.resume(returning: .init(bytes: bytes, energy: energy))
            }
        }
    }

    func close() async { caller?.close(); callee?.close() }

    // Delegate: trickle ICE between the two ends.
    func peerConnection(_ pc: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {
        let other = pc === caller ? callee : caller
        other?.add(candidate) { _ in }
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
