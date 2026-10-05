#if DEBUG
import AVFoundation
import AudioToolbox
import LiveKit
import XCTest
@testable import RockNRoll

/// Local engine diagnostic: no Room, network transport, file, or saved PCM.
@MainActor
final class AudioPipelineDeviceExperimentTests: XCTestCase {
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
