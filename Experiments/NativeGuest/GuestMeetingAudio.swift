import AVFoundation
import Foundation
import LiveKitWebRTC

/// The physical-audio surface a Guest meeting uses. `GuestSystemAudio` (one engine per
/// meeting) provides it directly; with one engine for all meetings (R4) the app supplies
/// a per-meeting adapter over the shared engine.
@MainActor protocol GuestMeetingAudio: AnyObject {
    var factory: LKRTCPeerConnectionFactory { get }
    var profile: GuestAudioProfile { get }
    var snapshot: [String: Any] { get }
    var playoutEpoch: UUID? { get }
    var startupAudioObservation: GuestStartupAudioObservation { get }
    var canUnmuteMicrophone: Bool { get }
    var privateInputLevel: Float? { get }
    var privateInputMeterEvidence: [String: Any] { get }
    var playoutMeterEvidence: [String: Any] { get }
    /// Multiplied into every remote participant's level by the session (1 when the
    /// owner's own mixer applies the meeting volume).
    var meetingLevel: Double { get }
#if DEBUG
    var sharedPlayoutGateForTesting: GuestSharedPlayoutGate { get }
    var startupCallbackEvidence: [String: Any] { get }
#endif
    /// The meeting's microphone track, created disabled. An owner shared by several
    /// meetings enables it only while this meeting may be heard.
    func registerMicrophoneTrack(_ track: LKRTCAudioTrack)
    func activateMicrophone(timeout: TimeInterval?) async -> Bool
    func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval) async -> Bool
    func suppressMicrophone()
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool, timeout: TimeInterval) async -> Bool
    func prewarmInput(timeout: TimeInterval) async -> Bool
    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval, expectedEpoch: UUID?) async -> Bool
    func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval) async -> Bool
    func openSharedPlayout(expected: UUID?) -> Bool
    func setSharedSoundIntent(_ sound: Bool, expected: UUID?) -> Bool
    func closeSharedPlayout(expected: UUID?) -> Bool
    func sharedPlayoutIsOpen(expected: UUID?) -> Bool
    func setMeetingVolume(_ volume: Double) -> Bool
    func refreshSnapshot(timeout: TimeInterval) async -> Bool
    func beginPrivateInputCheck(timeout: TimeInterval?) async -> Bool
    func endPrivateInputCheck(timeout: TimeInterval) async -> Bool
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?)
    func setPrivateInputMeterEnabled(_ enabled: Bool)
    func setMicrophoneGate(open: Bool) -> Bool
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool
    func shutdown(timeout: TimeInterval) async -> Bool
}

/// The same defaults `GuestSystemAudio` declares, for calls through the protocol.
extension GuestMeetingAudio {
    func activateMicrophone() async -> Bool { await activateMicrophone(timeout: nil) }
    func setMicrophoneMuted(_ muted: Bool) async -> Bool { await setMicrophoneMuted(muted, timeout: 2) }
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool = false) async -> Bool {
        await setInputPermitted(permitted, keepWarm: keepWarm, timeout: 8)
    }
    func prewarmInput() async -> Bool { await prewarmInput(timeout: 8) }
    func setPlayoutEnabled(_ enabled: Bool, expectedEpoch: UUID? = nil) async -> Bool {
        await setPlayoutEnabled(enabled, timeout: 2, expectedEpoch: expectedEpoch)
    }
    func setTranscriptionOutput(_ keep: Bool) async -> Bool { await setTranscriptionOutput(keep, timeout: 2) }
    @discardableResult func refreshSnapshot() async -> Bool { await refreshSnapshot(timeout: 2) }
    func beginPrivateInputCheck() async -> Bool { await beginPrivateInputCheck(timeout: nil) }
    func endPrivateInputCheck() async -> Bool { await endPrivateInputCheck(timeout: 2) }
    func shutdown() async -> Bool { await shutdown(timeout: 2) }
}

extension GuestSystemAudio: GuestMeetingAudio {
    /// One meeting per owner: the module's mute is the meeting's mute.
    func registerMicrophoneTrack(_ track: LKRTCAudioTrack) {}
    var meetingLevel: Double { 1 }
}
