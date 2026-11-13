import AVFoundation
import LiveKit
import LiveKitWebRTC

// R4 S4: Rock (LiveKit) on the shared engine. LiveKit keeps one factory for the process
// (`RTC.peerConnectionFactory`); the patched SDK takes ours if it is installed before
// LiveKit first needs one. From then on the owner is pinned: it idles, never shuts down.

extension SharedAudioEngine {
    /// A factory LiveKit can adopt: LiveKit's audio processing module (publishing waits on
    /// its capture delegate) and codec factories; nil parts fall back to WebRTC defaults.
    nonisolated static func liveKitFactory(voiceProcessing: Bool) -> LKRTCPeerConnectionFactory {
        LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: !voiceProcessing,
            encoderFactory: SharedPeerConnectionFactory.videoEncoderFactory as? LKRTCVideoEncoderFactory ?? LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: SharedPeerConnectionFactory.videoDecoderFactory as? LKRTCVideoDecoderFactory ?? LKRTCDefaultVideoDecoderFactory(),
            audioProcessingModule: SharedPeerConnectionFactory.audioProcessingModule as? LKRTCAudioProcessingModule)
    }

    /// Hands the owner's factory and its input/output wiring to LiveKit as one operation.
    func installIntoLiveKit() -> GuestSystemAudio.ForwardObserverInstallation {
        guard let owner = guestOwner else { return .factoryUnavailable }
        if pinnedForProcess { return owner.hasForwardObserver ? .installed : .observerUnavailable }
        let result = owner.installForwardObserver(installFactory: { SharedPeerConnectionFactory.install($0) }, makeObserver: {
            AudioManager.shared.sdkAudioDeviceModuleObserver as? LKRTCAudioDeviceModuleDelegate
        }, proveInput: { engine, source, inputMixer in
            AudioManager.shared.mixer.nativeAppReplyInputIsConnected(engine: engine, source: source, inputMixer: inputMixer)
        })
        if result == .installed || result == .observerUnavailable { pinForProcess() }
        return result
    }
}

/// Rock's published microphone as a shared-engine sender (the SDK keeps owning the track).
final class NativeRockMicrophoneSender: MeetingAudioSender {
    let track: LocalAudioTrack
    init(track: LocalAudioTrack) { self.track = track }
    var isEnabled: Bool {
        get { track.sharedEngineSenderEnabled }
        set { track.sharedEngineSenderEnabled = newValue }
    }
}

/// The prejoin microphone check while the shared owner is pinned: it borrows the shared
/// engine's input (no meeting may be sending meanwhile) instead of a second owner.
@MainActor final class SharedPrivateAudioCheck: NativeDesktopPrivateAudioOwner {
    private let engine: SharedAudioEngine
    init(engine: SharedAudioEngine) { self.engine = engine }
    var privateInputLevel: Float? { engine.guestOwner?.privateInputLevel }
    func startPrivateCheck() async -> Bool {
        guard await engine.beginPrivateCheck() else { return false }
        engine.guestOwner?.setPrivateInputMeterEnabled(true)
        return true
    }
    func closePrivateCheck() async -> Bool {
        engine.guestOwner?.setPrivateInputMeterEnabled(false)
        return await engine.endPrivateCheck()
    }
}
