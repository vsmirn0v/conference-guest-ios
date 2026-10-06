#if DEBUG
import AVFoundation
import AudioToolbox
import ConferenceCore
import LiveKit
import XCTest
@testable import RockNRoll

/// Local engine diagnostic: no Room, network transport, file, or saved PCM.
@MainActor
final class AudioPipelineDeviceExperimentTests: XCTestCase {
    func testStudioProfilesApplyToLiveSender() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_STUDIO_AUDIO"] == "1",
              ProcessInfo.processInfo.isiOSAppOnMac,
              let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_OUTGOING_JAM_URL"] else {
            throw XCTSkip("Opt-in Mac live Studio processing check")
        }
        let session = AVAudioSession.sharedInstance(), manager = AudioManager.shared
        guard !manager.isEngineRunning else { throw XCTSkip("Requires an idle engine") }
        let category = session.category, mode = session.mode, options = session.categoryOptions
        let manual = manager.isManualRenderingMode
        let room = Room()
        var feed: Task<Void, Never>?
        defer {
            feed?.cancel()
            try? manager.stopLocalRecording()
            try? manager.setManualRenderingMode(manual)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(category, mode: mode, options: options)
        }
        do {
            // A synthetic silence source exercises a real sender without opening
            // the microphone or sending any local audio to the test room.
            try manager.setManualRenderingMode(true)
            let credentials = try await JamService().join(try JamTarget.parse(invitation), name: "Sound settings QA")
            try await room.connect(url: credentials.serverURL.absoluteString, token: credentials.participantToken,
                                   connectOptions: ConnectOptions(autoSubscribe: false))
            let track = await LocalAudioTrack.createTrack(options: AudioCaptureOptions(), reportStatistics: true)
            _ = try await room.localParticipant.publish(audioTrack: track, options: AudioPublishOptions(dtx: false))
            feed = Task { @MainActor in
                let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
                while !Task.isCancelled {
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
                    buffer.frameLength = 480
                    if let data = buffer.floatChannelData { memset(data[0], 0, 480 * MemoryLayout<Float>.size) }
                    manager.mixer.capture(appAudio: buffer)
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
            var previousPackets = 0.0
            for profile in [StudioAudioProfile.conversation, .music, .conversation] {
                _ = try await Task.detached { try track.setAudioProcessingOptions(StudioAudioPolicy.processingOptions(for: profile)) }.value
                try await Task.sleep(for: .seconds(2))
                let state = manager.audioProcessingState
                XCTAssertEqual(state.echoCancellation.requested?.isEnabled, true)
                XCTAssertEqual(state.noiseSuppression.requested?.isEnabled, profile == .conversation)
                XCTAssertEqual(state.autoGainControl.requested?.isEnabled, profile == .conversation)
                if profile == .music {
                    XCTAssertEqual(state.echoCancellation.effective, .software)
                    XCTAssertEqual(state.noiseSuppression.effective, .disabled)
                    XCTAssertEqual(state.autoGainControl.effective, .disabled)
                }
                let packets = track.statistics?.outboundRtpStream.reduce(0.0) { $0 + Double($1.packetsSent ?? 0) } ?? 0
                XCTAssertGreaterThan(packets, previousPackets, "Audio packets stopped after a profile change")
                previousPackets = packets
                print("STUDIO_AUDIO,profile=\(profile.rawValue),aec=\(state.echoCancellation.effective.rawValue),noise=\(state.noiseSuppression.effective.rawValue),gain=\(state.autoGainControl.effective.rawValue)")
            }
            feed?.cancel()
            await room.disconnect()
        } catch {
            feed?.cancel()
            await room.disconnect()
            throw error
        }
    }

    func testPlatformVoiceProcessingAndOpusAvailability() async throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_AUDIO_DEVICE"] == "1" else {
            throw XCTSkip("Opt-in local audio capture diagnostic")
        }
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical audio hardware")
        #else
        let session = AVAudioSession.sharedInstance()
        print("AUDIO_OPUS_ENCODERS,manufacturers=\(opusEncoderManufacturers().joined(separator: ":"))")
        guard session.recordPermission == .granted else { throw XCTSkip("Microphone permission not granted") }
        let category = session.category, mode = session.mode, options = session.categoryOptions
        let manager = AudioManager.shared
        guard !manager.isEngineRunning else { throw XCTSkip("Do not interrupt an existing audio engine") }
        defer {
            try? manager.stopLocalRecording()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            try? session.setCategory(category, mode: mode, options: options)
        }
        try AudioCoordinator().prepareForJoin()
        try session.setActive(true)
        try manager.startLocalRecording(audioProcessingOptions: AudioProcessingOptions())
        try await Task.sleep(for: .seconds(3))
        let p = manager.platformVoiceProcessingState
        let a = manager.audioProcessingState
        print("AUDIO_ENGINE,session_rate=\(session.sampleRate),preferred_rate=\(session.preferredSampleRate),io_ms=\(session.ioBufferDuration * 1000),input_ms=\(session.inputLatency * 1000),output_ms=\(session.outputLatency * 1000),topology=\(p.topology.rawValue),voice_active=\(p.voiceProcessingEnabled.isActive),voice_bypassed=\(p.voiceProcessingBypassed.isActive),platform_aec=\(p.echoCancellation.isActive),platform_ns=\(p.noiseSuppression.isActive),platform_agc=\(p.autoGainControl.isActive),effective_aec=\(a.echoCancellation.effective.rawValue),effective_ns=\(a.noiseSuppression.effective.rawValue),effective_agc=\(a.autoGainControl.effective.rawValue),software_aec=\(a.echoCancellation.software.isActive),software_ns=\(a.noiseSuppression.software.isActive),software_agc=\(a.autoGainControl.software.isActive)")
        XCTAssertTrue(p.voiceProcessingEnabled.isActive, "Automatic processing did not enable the platform path")
        XCTAssertFalse(p.voiceProcessingBypassed.isActive)
        XCTAssertFalse(a.echoCancellation.software.isActive, "Unexpected duplicate software AEC")
        XCTAssertFalse(a.noiseSuppression.software.isActive, "Unexpected duplicate software suppression")
        XCTAssertFalse(a.autoGainControl.software.isActive, "Unexpected duplicate software gain control")
        XCTAssertGreaterThan(session.sampleRate, 0)
        #endif
    }

    private func opusEncoderManufacturers() -> [String] {
        var format = kAudioFormatOpus
        var size: UInt32 = 0
        guard AudioFormatGetPropertyInfo(kAudioFormatProperty_Encoders, UInt32(MemoryLayout.size(ofValue: format)),
            &format, &size) == noErr else { return [] }
        var encoders = [AudioClassDescription](repeating: AudioClassDescription(),
            count: Int(size) / MemoryLayout<AudioClassDescription>.stride)
        let status = encoders.withUnsafeMutableBytes { bytes in
            AudioFormatGetProperty(kAudioFormatProperty_Encoders, UInt32(MemoryLayout.size(ofValue: format)),
                &format, &size, bytes.baseAddress)
        }
        guard status == noErr else { return [] }
        return encoders.map { encoder in
            let value = encoder.mManufacturer
            return String(bytes: [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }, encoding: .ascii) ?? "unknown"
        }
    }
}
#endif
