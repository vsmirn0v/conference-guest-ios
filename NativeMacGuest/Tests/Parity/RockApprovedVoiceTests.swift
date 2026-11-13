import AVFoundation
@testable import LiveKit
import XCTest
@testable import RockNativeDesktop

@MainActor final class RockApprovedVoiceTests: XCTestCase {
    func testApprovedReplyUsesSeparateMonitorAndMeetingGainOnlyAffectsLocalPCM() async throws {
        let audio = try OfflineVoiceGraph(connectMonitor: true, startImmediately: false)
        let monitorMixer = try XCTUnwrap(audio.monitorMixer)
        let reply = NativeAppReplyPlayer()
        audio.engine.attach(reply.node)
        audio.engine.attach(reply.monitor)
        reply.connect(to: audio.inputMixer, engine: audio.engine, format: audio.format)
        reply.connectMonitor(to: monitorMixer, engine: audio.engine, format: audio.format)
        try audio.engine.start()
        defer { reply.invalidateRoute(); audio.engine.stop() }

        let playback = Task { await reply.play(audio.tone(seconds: 3), localGain: 0.5) { true } }
        for _ in 0..<100 where !reply.node.isPlaying { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(reply.node.isPlaying)
        try audio.checkRouteLevels(local: 0.1, outgoing: 0.2)

        reply.setMonitorGain(0.25)
        try audio.checkRouteLevels(local: 0.05, outgoing: 0.2)

        playback.cancel()
        let completed = await playback.value
        XCTAssertFalse(completed)
        try audio.checkRouteLevels(local: 0, outgoing: 0)
    }

    func testReplyUsesTheExistingMixerAndFlushesBeforeTheNextPhrase() async throws {
        let engine = AVAudioEngine()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let frameCount: AVAudioFrameCount = 4_800
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frameCount)
        let mixer = MixerEngineObserver()
        XCTAssertEqual(mixer.engineDidCreate(engine), 0)
        XCTAssertEqual(mixer.engineWillConnectInput(engine, src: nil, dst: engine.mainMixerNode, format: format, context: [:]), 0)
        XCTAssertTrue(mixer.nativeAppReplyInputIsConnected(engine: engine, source: nil, inputMixer: engine.mainMixerNode))
        XCTAssertFalse(mixer.nativeAppReplyInputIsConnected(engine: engine, source: nil, inputMixer: AVAudioMixerNode()))
        let physical = AVAudioEngine()
        XCTAssertEqual(mixer.engineWillConnectInput(physical, src: nil, dst: physical.mainMixerNode, format: format, context: [:]), -1)
        XCTAssertEqual(mixer.engineWillStart(engine, isPlayoutEnabled: false, isRecordingEnabled: true), 0)
        try engine.start()
        defer {
            engine.stop()
            _ = mixer.engineDidStop(engine, isPlayoutEnabled: false, isRecordingEnabled: true)
            _ = mixer.engineWillRelease(engine)
        }
        mixer.micVolume = 0
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount))
        func renderRMS() throws -> Double {
            XCTAssertEqual(try engine.renderOffline(frameCount, to: output), .success)
            let samples = try XCTUnwrap(output.floatChannelData?[0])
            return ((0..<Int(output.frameLength)).reduce(0) { sum, index in
                let value = Double(samples[index])
                return sum + value * value
            } / Double(output.frameLength)).squareRoot()
        }

        let cancelledBeforeStart = await mixer.playNativeAppReply(tone(seconds: 0.5, amplitude: 0.15)) { false }
        XCTAssertFalse(cancelledBeforeStart)
        XCTAssertEqual(try renderRMS(), 0, accuracy: 0)
        let started = expectation(description: "Admitted a long voice reply to the mixer")
        let first = Task {
            await mixer.playNativeAppReply(tone(seconds: 2.2, amplitude: 0.2)) {
                started.fulfill()
                return mixer.micVolume == 0
            }
        }
        await fulfillment(of: [started], timeout: 2)
        for _ in 0..<15 {
            XCTAssertEqual(try renderRMS(), 0.2 / 2.squareRoot(), accuracy: 0.012)
        }
        let secondStart = await mixer.playNativeAppReply(tone(seconds: 0.5, amplitude: 0.35)) { true }
        XCTAssertFalse(secondStart, "Two outgoing replies cannot use the same player")
        first.cancel()
        let cancelled = await first.value
        XCTAssertFalse(cancelled)
        for _ in 0..<4 { XCTAssertEqual(try renderRMS(), 0, accuracy: 0) }

        let nextStarted = expectation(description: "Admitted a distinct second phrase")
        let next = Task {
            await mixer.playNativeAppReply(tone(seconds: 0.5, amplitude: 0.35)) {
                nextStarted.fulfill()
                return true
            }
        }
        await fulfillment(of: [nextStarted], timeout: 2)
        first.cancel()
        XCTAssertEqual(try renderRMS(), 0.35 / 2.squareRoot(), accuracy: 0.012)
        XCTAssertEqual(mixer.micVolume, 0, "Reply cancellation never opens the raw microphone mixer")
        engine.stop()
        _ = mixer.engineDidStop(engine, isPlayoutEnabled: false, isRecordingEnabled: true)
        let interruptedByRoute = await next.value
        XCTAssertFalse(interruptedByRoute)
        XCTAssertEqual(mixer.engineWillStart(engine, isPlayoutEnabled: false, isRecordingEnabled: true), 0)
        try engine.start()
        for _ in 0..<3 { XCTAssertEqual(try renderRMS(), 0, accuracy: 0) }
    }

    private func tone(seconds: Double, amplitude: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let frames = AVAudioFrameCount(format.sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(amplitude * sin(2 * .pi * 440 * Double(index) / format.sampleRate))
        }
        return buffer
    }
}
