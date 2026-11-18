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
        LKRTCPeerConnectionFactory.configureFieldTrials("\(kLKRTCFieldTrialIceHandshakeDtlsKey)/\(kLKRTCFieldTrialEnabledValue)/")
        return LKRTCPeerConnectionFactory(audioDeviceModuleType: .audioEngine, bypassVoiceProcessing: !voiceProcessing,
            encoderFactory: SharedPeerConnectionFactory.videoEncoderFactory as? LKRTCVideoEncoderFactory ?? LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: SharedPeerConnectionFactory.videoDecoderFactory as? LKRTCVideoDecoderFactory ?? LKRTCDefaultVideoDecoderFactory(),
            audioProcessingModule: SharedPeerConnectionFactory.audioProcessingModule as? LKRTCAudioProcessingModule)
    }

    /// Hands the owner's factory and its input/output wiring to LiveKit as one operation.
    @discardableResult public func installIntoLiveKit() -> GuestSystemAudio.ForwardObserverInstallation {
        guard let owner = guestOwner else { return .factoryUnavailable }
        if pinnedForProcess { return owner.hasForwardObserver ? .installed : .observerUnavailable }
        let controller: GuestSystemAudio.ForwardedVoiceReplyController?
#if os(macOS)
        controller = GuestSystemAudio.ForwardedVoiceReplyController(
            setGateOpen: { open in
                let mixer = AudioManager.shared.mixer
                mixer.micVolume = open ? 1 : 0
                return (mixer.micVolume != 0) == open
            },
            isGateOpen: { AudioManager.shared.mixer.micVolume != 0 },
            setMonitorGain: { gain in
                AudioManager.shared.mixer.setNativeAppReplyMonitorGain(gain)
            },
            play: { buffer, localGain, canStart in
                await AudioManager.shared.mixer.playNativeAppReply(buffer, localGain: localGain, canStart: canStart)
            }
        )
#else
        controller = nil
#endif
        let result = owner.installForwardObserver(installFactory: { SharedPeerConnectionFactory.install($0) }, makeObserver: {
            AudioManager.shared.sdkAudioDeviceModuleObserver as? LKRTCAudioDeviceModuleDelegate
        }, proveInput: { engine, source, inputMixer in
#if os(macOS)
            AudioManager.shared.mixer.nativeAppReplyInputIsConnected(engine: engine, source: source, inputMixer: inputMixer)
#else
            _ = (engine, source, inputMixer)
            return true
#endif
        }, voiceController: controller)
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
