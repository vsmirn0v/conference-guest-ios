import AVFoundation
import XCTest
@testable import RockNativeDesktop

@MainActor
final class ParticipationVoiceGraphTests: XCTestCase {
    func testCancelledExpiredAndIneligibleVoiceNeverReachTheInputMixer() async throws {
        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        let phrase = audio.tone(seconds: 0.25)
        let cancelled = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        cancelled.cancel()
        let expired = GuestAutonomousVoicePlayback(deadline: .distantPast)
        let noLongerOwnsMicrophone = GuestAutonomousVoicePlayback(deadline: .distantFuture)

        let afterCancellation = await audio.graph.playAutonomous(phrase, permit: cancelled)
        XCTAssertEqual(afterCancellation, .notStarted)
        XCTAssertFalse(cancelled.started)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        let afterExpiry = await audio.graph.playAutonomous(phrase, permit: expired)
        XCTAssertEqual(afterExpiry, .notStarted)
        XCTAssertFalse(expired.started)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        let afterOwnershipLoss = await audio.graph.playAutonomous(phrase, permit: noLongerOwnsMicrophone, canStart: { false })
        XCTAssertEqual(afterOwnershipLoss, .notStarted)
        XCTAssertFalse(noLongerOwnsMicrophone.started)
        XCTAssertFalse(audio.graph.player.isPlaying)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }

    func testAssistantVoiceRendersWhileTheMutedMicrophoneSignalStaysOutOfTheMix() async throws {
        let audio = try OfflineVoiceGraph(withMicrophone: true, gateOpen: true)
        defer { audio.engine.stop() }
        let microphone = try XCTUnwrap(audio.microphone)
        microphone.scheduleBuffer(audio.tone(seconds: 2, frequency: 600, amplitude: 0.5), completionHandler: nil)
        microphone.play()
        XCTAssertEqual(try audio.renderRMS(), Float(0.5 / 2.squareRoot()), accuracy: 0.01)

        audio.graph.setGate(open: false)
        for _ in 0..<2 { _ = try audio.renderRMS() }
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        let phrase = audio.tone(seconds: 1)
        let playback = Task {
            await audio.graph.playAutonomous(phrase, permit: permit, canStart: { !audio.graph.gateOpen })
        }
        defer { permit.cancel() }

        try await audio.waitForStart(permit)
        XCTAssertTrue(microphone.isPlaying)
        XCTAssertFalse(audio.graph.gateOpen)
        XCTAssertEqual(try audio.renderRMS(), Float(0.2 / 2.squareRoot()), accuracy: 0.01)
        permit.cancel()
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertFalse(audio.graph.gateOpen)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }

    func testCancellingAnAudiblePhraseClearsThePlayerForTheNextPhrase() async throws {
        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        let first = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        let phrase = audio.tone(seconds: 1)
        let playback = Task { await audio.graph.playAutonomous(phrase, permit: first) }
        defer { first.cancel() }

        try await audio.waitForStart(first)
        XCTAssertEqual(try audio.renderRMS(), Float(0.2 / 2.squareRoot()), accuracy: 0.01)
        first.cancel()
        XCTAssertFalse(audio.graph.player.isPlaying)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        let cancelledOutcome = await playback.value
        XCTAssertEqual(cancelledOutcome, .interrupted)

        let next = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        let nextPhrase = audio.tone(seconds: 0.2, amplitude: 0.35)
        let nextPlayback = Task { await audio.graph.playAutonomous(nextPhrase, permit: next) }
        defer { next.cancel() }
        try await audio.waitForStart(next)
        first.cancel()
        XCTAssertEqual(try audio.renderRMS(), Float(0.35 / 2.squareRoot()), accuracy: 0.01)
        XCTAssertEqual(try audio.renderRMS(), Float(0.35 / 2.squareRoot()), accuracy: 0.01)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        // Manual rendering produces PCM without delivering a playback completion callback.
        next.cancel()
        _ = await nextPlayback.value
    }

    func testCancellingApprovedPlaybackStopsActualInputMixerAudio() async throws {
        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        let playback = Task { await audio.graph.play(audio.tone(seconds: 2)) }
        for _ in 0..<100 {
            if audio.graph.player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(audio.graph.player.isPlaying)
        XCTAssertEqual(try audio.renderRMS(), Float(0.2 / 2.squareRoot()), accuracy: 0.01)
        playback.cancel()
        let result = await playback.value
        XCTAssertFalse(result)
        XCTAssertFalse(audio.graph.player.isPlaying)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }

    func testStoppedEngineCannotReplayPendingApprovedAudioAfterRestart() async throws {
        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        let playback = Task { await audio.graph.play(audio.tone(seconds: 2)) }
        for _ in 0..<100 {
            if audio.graph.player.isPlaying { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(audio.graph.player.isPlaying)
        XCTAssertGreaterThan(try audio.renderRMS(), 0.1)
        audio.engine.stop()
        audio.graph.stop()
        let result = await playback.value
        XCTAssertFalse(result)
        try audio.engine.start()
        XCTAssertFalse(audio.graph.player.isPlaying)
        for _ in 0..<3 { XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0) }
        XCTAssertFalse(audio.graph.gateOpen)
    }

    func testStoppingTheGraphDuringPlaybackCompletesAsInterrupted() async throws {
        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        let phrase = audio.tone(seconds: 1)
        let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit) }
        defer { permit.cancel() }

        try await audio.waitForStart(permit)
        XCTAssertGreaterThan(try audio.renderRMS(), 0.1)
        audio.graph.stop()
        XCTAssertFalse(audio.graph.player.isPlaying)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
    }

    func testDetachingTheOldGraphDuringPlaybackInterruptsItsPhrase() async throws {
        let audio = try OfflineVoiceGraph()
        defer { audio.engine.stop() }
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        let phrase = audio.tone(seconds: 1)
        let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit) }
        defer { permit.cancel() }

        try await audio.waitForStart(permit)
        XCTAssertGreaterThan(try audio.renderRMS(), 0.1)
        audio.graph.detach()
        XCTAssertNil(audio.graph.player.engine)
        XCTAssertFalse(audio.graph.player.isPlaying)
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
    }

    func testApprovedVoiceMonitorsLocallyAtMeetingVolumeAndStopsBothRoutes() async throws {
        let audio = try OfflineVoiceGraph(connectMonitor: true)
        let playback = Task { await audio.graph.play(audio.tone(seconds: 3), localGain: 0.5) }
        for _ in 0..<100 where !audio.graph.player.isPlaying { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(audio.graph.player.isPlaying)
        try audio.checkRouteLevels(local: 0.1, outgoing: 0.2)

        audio.graph.setApprovedLocalGain(0.25)
        try audio.checkRouteLevels(local: 0.05, outgoing: 0.2)

        playback.cancel()
        let completed = await playback.value
        XCTAssertFalse(completed)
        try audio.checkRouteLevels(local: 0, outgoing: 0)
    }

    func testApprovedVoiceWithAnUnprovenLocalRouteSchedulesNeitherCopy() async throws {
        let audio = try OfflineVoiceGraph()
        let played = await audio.graph.play(audio.tone(seconds: 1), localGain: 0.5)
        XCTAssertFalse(played)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }

    func testSettingMonitorGainToZeroDoesNotInterruptTheIndependentOutgoingPlayer() async throws {
        let audio = try OfflineVoiceGraph(connectMonitor: true)
        defer { audio.engine.stop() }
        let permit = GuestAutonomousVoicePlayback(deadline: .distantFuture)
        let phrase = audio.tone(seconds: 1)
        let playback = Task { await audio.graph.playAutonomous(phrase, permit: permit, localGain: { 0.5 }) }
        defer { permit.cancel() }

        try await audio.waitForStart(permit)
        // The offline output sums the outgoing signal at full gain and the local monitor at half gain.
        XCTAssertEqual(try audio.renderRMS(), Float(0.3 / 2.squareRoot()), accuracy: 0.01)
        permit.setLocalGain(0)
        XCTAssertTrue(audio.graph.player.isPlaying)
        XCTAssertEqual(try audio.renderRMS(), Float(0.2 / 2.squareRoot()), accuracy: 0.01)
        XCTAssertEqual(try audio.renderRMS(), Float(0.2 / 2.squareRoot()), accuracy: 0.01)

        audio.graph.stop()
        let outcome = await playback.value
        XCTAssertEqual(outcome, .interrupted)
        XCTAssertEqual(try audio.renderRMS(), 0, accuracy: 0)
    }
}

@MainActor
final class OfflineVoiceGraph {
    let engine = AVAudioEngine()
    let graph: GuestVoiceReplyGraph
    let microphone: AVAudioPlayerNode?
    let inputMixer = AVAudioMixerNode()
    let monitorMixer: AVAudioMixerNode?
    let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
    private let frames: AVAudioFrameCount = 4_800

    init(connectMonitor: Bool = false, withMicrophone: Bool = false, gateOpen: Bool = false,
         startImmediately: Bool = true) throws {
        microphone = withMicrophone ? AVAudioPlayerNode() : nil
        monitorMixer = connectMonitor ? AVAudioMixerNode() : nil
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: frames)
        engine.attach(inputMixer)
        if let microphone { engine.attach(microphone) }
        engine.connect(inputMixer, to: engine.mainMixerNode, format: format)
        graph = GuestVoiceReplyGraph(engine: engine, gateOpen: gateOpen)
        XCTAssertTrue(graph.connect(source: microphone, inputMixer: inputMixer, format: format))
        if let monitorMixer {
            engine.attach(monitorMixer)
            engine.connect(monitorMixer, to: engine.mainMixerNode, format: format)
            graph.connectMonitor(to: monitorMixer, format: format)
        }
        if startImmediately { try engine.start() }
    }

    func checkRouteLevels(local: Float, outgoing: Float, file: StaticString = #filePath, line: UInt = #line) throws {
        let monitorMixer = try XCTUnwrap(monitorMixer, file: file, line: line)
        inputMixer.outputVolume = 0
        monitorMixer.outputVolume = 1
        _ = try renderRMS() // Allow gain changes on the test sink to settle.
        XCTAssertEqual(try renderRMS(), local / Float(2).squareRoot(), accuracy: 0.009, file: file, line: line)
        inputMixer.outputVolume = 1
        monitorMixer.outputVolume = 0
        _ = try renderRMS()
        XCTAssertEqual(try renderRMS(), outgoing / Float(2).squareRoot(), accuracy: 0.009, file: file, line: line)
        monitorMixer.outputVolume = 1
    }

    func waitForStart(_ permit: GuestAutonomousVoicePlayback) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !permit.started && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertTrue(permit.started, "The playback never started")
    }

    func tone(seconds: Double, frequency: Double = 300, amplitude: Float = 0.2) -> AVAudioPCMBuffer {
        let count = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!
        buffer.frameLength = count
        for frame in 0..<Int(count) {
            let phase = 2 * .pi * frequency * Double(frame) / format.sampleRate
            buffer.floatChannelData![0][frame] = amplitude * Float(sin(phase))
        }
        return buffer
    }

    func renderRMS() throws -> Float {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        XCTAssertEqual(try engine.renderOffline(frames, to: buffer), .success)
        XCTAssertEqual(buffer.frameLength, frames)
        let samples = UnsafeBufferPointer(start: try XCTUnwrap(buffer.floatChannelData?.pointee),
                                          count: Int(buffer.frameLength))
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count))).squareRoot()
    }
}
