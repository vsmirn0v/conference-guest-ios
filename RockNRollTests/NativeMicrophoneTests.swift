import AudioToolbox
import AVFoundation
import Foundation
import LiveKitWebRTC
import XCTest
@testable import RockNRoll

/// Exercises the production publisher with encoded/decoded input samples. The
/// custom device never opens a microphone and cannot capture another meeting.
@MainActor
final class NativeMicrophoneTests: XCTestCase {
    func testMacDefaultMicrophonePublishesRealInputAndMutesSamples() async throws {
        guard ProcessInfo.processInfo.isiOSAppOnMac,
              ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NATIVE_MICROPHONE"] == "1" else {
            throw XCTSkip("Opt-in actual Mac microphone check; play the spoken marker during the enabled window")
        }
        try Task.checkCancellation()
        let session = AVAudioSession.sharedInstance(), rtc = LKRTCAudioSession.sharedInstance()
        let permitted = await withCheckedContinuation { continuation in session.requestRecordPermission { continuation.resume(returning: $0) } }
        guard permitted else { throw XCTSkip("Mac microphone permission was declined") }
        let category = session.category, mode = session.mode, options = session.categoryOptions
        let manual = rtc.useManualAudio, enabled = rtc.isAudioEnabled
        defer {
            rtc.isAudioEnabled = false; rtc.audioSessionDidDeactivate(session)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(category, mode: mode, options: options)
            rtc.useManualAudio = manual; rtc.isAudioEnabled = enabled
        }
        try AudioCoordinator().prepareForJoin()
        rtc.useManualAudio = true; rtc.isAudioEnabled = false
        try session.setActive(true); rtc.audioSessionDidActivate(session); rtc.isAudioEnabled = true
        let inputFactory = try NativeRTCPeer.makeFactory()
        let output = MicrophoneFixtureDevice()
        let outputFactory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: output)
        let sender = try NativeRTCPeer(target: "PUBLISHER", factory: inputFactory, ice: [])
        let receiver = try NativeRTCPeer(target: "SUBSCRIBER", factory: outputFactory, ice: [])
        sender.onCandidate = { value in Task { try? await receiver.addCandidate(value) } }
        receiver.onCandidate = { value in Task { try? await sender.addCandidate(value) } }
        do {
            let offer = try await sender.offer(), answer = try await receiver.answer(offer)
            sender.localSDPSent(); receiver.localSDPSent(); try await sender.accept(answer)
            print("NATIVE_REAL_MICROPHONE_INITIAL_MUTED_MARKER_READY")
            fflush(stdout)
            try await Task.sleep(nanoseconds: 600_000_000); output.resetWindow()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let initial = output.window
            XCTAssertLessThan(initial.rms, 0.001, "Actual microphone input leaked before unmute")
            sender.setMicrophone(true, profile: .music)
            let sendingOffer = try await sender.offer(), sendingAnswer = try await receiver.answer(sendingOffer)
            sender.localSDPSent(); receiver.localSDPSent(); try await sender.accept(sendingAnswer)
            print("NATIVE_REAL_MICROPHONE_MARKER_READY input=\(session.currentRoute.inputs.map(\.portName).joined(separator: ",")) rate=\(session.sampleRate)")
            fflush(stdout)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            output.resetWindow()
            var peak: Float = 0
            for _ in 0..<32 {
                peak = max(peak, await sender.microphoneLevel() ?? 0)
                try await Task.sleep(nanoseconds: 250_000_000)
            }
            let on = output.window
            XCTAssertGreaterThan(on.samples, 20_000, "The independent receiver decoded no actual input")
            XCTAssertGreaterThan(on.rms, 0.002, "The actual default audio device forwarded no non-silent microphone content")
            XCTAssertGreaterThan(peak, 0.002, "The real microphone had no capture energy")
            sender.setMicrophone(false, profile: .music)
            print("NATIVE_REAL_MICROPHONE_MUTED_MARKER_READY")
            fflush(stdout)
            try await Task.sleep(nanoseconds: 600_000_000); output.resetWindow()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let off = output.window
            XCTAssertLessThan(off.rms, 0.001, "Actual microphone samples continued after mute")
            print("NATIVE_REAL_MICROPHONE_CONTENT initial=\(initial.rms) on=\(on.rms) off=\(off.rms) peak=\(peak)")
            await sender.close(); await receiver.close()
        } catch { await sender.close(); await receiver.close(); throw error }
    }
    func testSplitPublisherMuteAndResumePreserveAudioContent() async throws {
        try await checkAudio(topology: .split)
    }
    func testCompositePublisherStartsSilentAndResumesAudioContent() async throws {
        try await checkAudio(topology: .composite)
    }
    private func checkAudio(topology: NativeRTCPeer.Topology) async throws {
        _ = LKRTCInitializeSSL()
        let device = MicrophoneFixtureDevice()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: device)
        let composite = topology == .composite
        let sender = try NativeRTCPeer(target: composite ? "COMPOSITE" : "PUBLISHER", factory: factory, ice: [], topology: topology)
        let receiver = try NativeRTCPeer(target: composite ? "PUBLISHER" : "SUBSCRIBER", factory: factory, ice: [])
        sender.onCandidate = { candidate in Task { try? await receiver.addCandidate(candidate) } }
        receiver.onCandidate = { candidate in Task { try? await sender.addCandidate(candidate) } }
        func negotiate(_ from: NativeRTCPeer, _ to: NativeRTCPeer) async throws {
            let offer = try await from.offer()
            let answer = try await to.answer(offer)
            from.localSDPSent(); to.localSDPSent()
            try await from.accept(answer)
        }
        do {
            if composite { try await negotiate(receiver, sender); try sender.enablePublishing() }
            sender.setMicrophone(false, profile: .music)
            try await negotiate(sender, receiver)
            let initial = try await measure(device)
            XCTAssertLessThan(initial.rms, 0.001, "Muted join forwarded input samples")
            let identity = try XCTUnwrap(sender.connection.senders.first { $0.track?.kind == "audio" }?.track)

            sender.setMicrophone(true, profile: .music)
            try await negotiate(sender, receiver)
            let enabled = try await measure(device)
            XCTAssertGreaterThan(enabled.samples, 20_000, "No decoded output was measured")
            XCTAssertGreaterThan(enabled.rms, 0.01, "Unmute did not deliver real encoded input content")
            let liveTrack = try XCTUnwrap(sender.connection.senders.first { $0.track?.kind == "audio" }?.track)
            XCTAssertEqual(identity.trackId, liveTrack.trackId)

            sender.setMicrophone(false, profile: .music)
            XCTAssertFalse(liveTrack.isEnabled, "A retained sender track must stop immediately on mute")
            // No SDP renegotiation is required to stop real capture content.
            let muted = try await measure(device)
            XCTAssertLessThan(muted.rms, 0.001, "Mute still forwarded input through the negotiated sender")

            sender.setMicrophone(true, profile: .conversation)
            XCTAssertFalse(liveTrack.isEnabled, "A replaced profile track continued capturing")
            sender.setMicrophone(false, profile: .conversation)
            let changed = try await measure(device)
            XCTAssertLessThan(changed.rms, 0.001, "Changing audio processing revived muted input")

            sender.setMicrophone(true, profile: .music)
            let resumed = try await measure(device)
            XCTAssertGreaterThan(resumed.rms, 0.01, "Repeated unmute lost the negotiated audio source")
            await sender.close(); await receiver.close()
            sender.setMicrophone(true, profile: .music)
            XCTAssertFalse(sender.microphoneSending, "A retired publisher resumed capture")
            print("NATIVE_AUDIO_CONTENT composite=\(composite) initial=\(initial.rms) enabled=\(enabled.rms) muted=\(muted.rms) profileMuted=\(changed.rms) resumed=\(resumed.rms)")
        } catch { await sender.close(); await receiver.close(); throw error }
    }
    private func measure(_ device: MicrophoneFixtureDevice) async throws -> MicrophoneFixtureDevice.Window {
        // Discard the decoder's jitter buffer and processing tail from the
        // previous state, then measure only this state rather than total bytes.
        try await Task.sleep(nanoseconds: 600_000_000)
        device.resetWindow()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        return device.window
    }
}

final class MicrophoneFixtureDevice: NSObject, LKRTCAudioDevice, @unchecked Sendable {
    let deviceInputSampleRate = 48_000.0, deviceOutputSampleRate = 48_000.0
    let inputIOBufferDuration = 0.01, outputIOBufferDuration = 0.01
    let inputNumberOfChannels = 1, outputNumberOfChannels = 1
    let inputLatency = 0.0, outputLatency = 0.0
    private(set) var isInitialized = false, isPlayoutInitialized = false, isRecordingInitialized = false
    private(set) var isPlaying = false, isRecording = false
    private var delegate: LKRTCAudioDeviceDelegate?
    private var worker: Thread?
    private let lock = NSLock()
    private var stopped = false, samples = 0, energy = 0.0
    struct Window { let samples: Int; let rms: Double }
    var window: Window {
        lock.lock(); defer { lock.unlock() }
        return .init(samples: samples, rms: samples > 0 ? sqrt(energy / Double(samples)) : 0)
    }
    func resetWindow() { lock.lock(); samples = 0; energy = 0; lock.unlock() }
    func initialize(with delegate: LKRTCAudioDeviceDelegate) -> Bool {
        self.delegate = delegate; isInitialized = true; stopped = false
        let thread = Thread { [weak self] in self?.process() }; worker = thread; thread.start()
        return true
    }
    func terminateDevice() -> Bool {
        lock.lock(); stopped = true; lock.unlock()
        while worker?.isFinished == false { Thread.sleep(forTimeInterval: 0.001) }
        delegate = nil; worker = nil; isInitialized = false; return true
    }
    func initializePlayout() -> Bool { isPlayoutInitialized = true; return true }
    func initializeRecording() -> Bool { isRecordingInitialized = true; return true }
    func startPlayout() -> Bool { lock.lock(); isPlaying = true; lock.unlock(); return true }
    func stopPlayout() -> Bool { lock.lock(); isPlaying = false; lock.unlock(); return true }
    func startRecording() -> Bool { lock.lock(); isRecording = true; lock.unlock(); return true }
    func stopRecording() -> Bool { lock.lock(); isRecording = false; lock.unlock(); return true }
    private func process() {
        var sampleIndex = 0, input = [Int16](repeating: 0, count: 480), output = input
        var deadline = ProcessInfo.processInfo.systemUptime
        while true {
            lock.lock(); let stop = stopped, play = isPlaying, record = isRecording; lock.unlock()
            if stop { return }
            var flags = AudioUnitRenderActionFlags()
            var stamp = AudioTimeStamp(); stamp.mSampleTime = Double(sampleIndex); stamp.mFlags = .sampleTimeValid
            if record {
                for index in input.indices { input[index] = Int16(3_000 * sin(Double(sampleIndex + index) * 2 * .pi * 440 / 48_000)) }
                input.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate?.deliverRecordedData(&flags, &stamp, 0, 480, &list, nil, nil)
                }
            }
            if play {
                output.withUnsafeMutableBytes { bytes in
                    var list = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 960, mData: bytes.baseAddress))
                    _ = delegate?.getPlayoutData(&flags, &stamp, 0, 480, &list)
                }
                let value = output.reduce(0.0) { $0 + pow(Double($1) / 32768, 2) }
                lock.lock(); samples += output.count; energy += value; lock.unlock()
            }
            sampleIndex += 480; deadline += 0.01
            Thread.sleep(forTimeInterval: max(0.001, deadline - ProcessInfo.processInfo.systemUptime))
        }
    }
}
