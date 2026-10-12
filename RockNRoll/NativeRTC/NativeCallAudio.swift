import AVFoundation
import LiveKitWebRTC

/// Transport-independent audio conditions shared by the native WebRTC engines.
struct NativeCallAudioState {
    var joined: Bool
    var connected: Bool
    var leaving: Bool
    var held: Bool
    var quiet: Bool
    var microphoneIntent: Bool
    var permitsAudio: Bool { joined && !leaving && !held && !quiet }
}

protocol NativeRTCAudioControl: AnyObject {
    var useManualAudio: Bool { get set }
    var isAudioEnabled: Bool { get set }
    func audioSessionDidActivate(_ audioSession: AVAudioSession)
    func audioSessionDidDeactivate(_ audioSession: AVAudioSession)
}
extension LKRTCAudioSession: NativeRTCAudioControl {}

/// Owns the WebRTC audio-session lifecycle; each engine retains its signaling,
/// media negotiation and screen-sharing teardown.
@MainActor
final class NativeCallAudio {
    enum Restoration: Equatable { case blocked, updateMedia, reconnect }
    private let owner: SystemCallCoordinator
    private let audio: AudioCoordinator
    private let rtc: NativeRTCAudioControl
    private var previous: (manual: Bool, enabled: Bool)?
    private var active = false

    init(owner: SystemCallCoordinator, audio: AudioCoordinator,
         rtc: NativeRTCAudioControl = LKRTCAudioSession.sharedInstance()) {
        self.owner = owner; self.audio = audio; self.rtc = rtc
    }

    func begin() {
        guard previous == nil else { return }
        previous = (rtc.useManualAudio, rtc.isAudioEnabled)
        rtc.useManualAudio = true; rtc.isAudioEnabled = false
    }
    func activate() {
        guard !active else { return }
        rtc.audioSessionDidActivate(AVAudioSession.sharedInstance()); active = true
    }
    func deactivate() {
        guard active else { return }
        rtc.audioSessionDidDeactivate(AVAudioSession.sharedInstance()); active = false
    }
    func pause() { rtc.isAudioEnabled = false }
    func finish() {
        guard let previous else { return }
        pause(); deactivate()
        rtc.isAudioEnabled = previous.enabled; rtc.useManualAudio = previous.manual
        self.previous = nil
    }

    var canUseCallAudio: Bool {
        #if DEBUG && targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_DIRECT_MEDIA"] == "1" { return true }
        #endif
        return owner.canRestoreAudio
    }
    func shouldSendMicrophone(_ state: NativeCallAudioState) -> Bool {
        state.microphoneIntent && state.permitsAudio && canUseCallAudio && rtc.isAudioEnabled
    }
    func microphoneStatus(_ state: NativeCallAudioState, sending: Bool) -> PiPMicrophoneStatus {
        guard state.permitsAudio, state.connected, canUseCallAudio, rtc.isAudioEnabled else { return .unavailable }
        return state.microphoneIntent && sending ? .on : .muted
    }
    func restore(_ state: NativeCallAudioState) -> Restoration {
        guard state.permitsAudio, canUseCallAudio else { return .blocked }
        let wasPaused = !rtc.isAudioEnabled
        rtc.isAudioEnabled = true
        audio.ensureMixing()
        return state.connected && wasPaused ? .reconnect : .updateMedia
    }
    func resumeIfPossible(_ state: NativeCallAudioState) throws -> Bool {
        owner.resumeIfPossible()
        guard state.permitsAudio, owner.canRestoreAudio, !rtc.isAudioEnabled else { return false }
        // The owner grants AVAudioSession on its worker. Repeating activation
        // here could race a newly arriving competitor during that extra await.
        audio.ensureMixing()
        activate()
        return true
    }
}
