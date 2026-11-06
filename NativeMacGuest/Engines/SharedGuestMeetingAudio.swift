import AVFoundation
import Foundation
import LiveKitWebRTC

/// R4 S2: one Guest meeting on the shared audio engine, behind the surface the Guest
/// session already drives (`GuestMeetingAudio`). Mute, talk role and sound go through the
/// meeting's attachment; snapshots and meters come from the one physical owner, with the
/// values that are per meeting (talk, mute, input) answered for this meeting.
///
/// The shared owner has no per-meeting playout gate: it behaves as a disabled one (no
/// epoch, every call accepted). Per-meeting sound is the session's own per-track gain,
/// which also carries this meeting's volume through `meetingLevel`.
@MainActor final class SharedGuestMeetingAudio: GuestMeetingAudio {
    let attachment: MeetingAudioAttachment
    private let engine: SharedAudioEngine
    private let owner: GuestSystemAudio
    private(set) var meetingLevel: Double = 1
    /// Called after the meeting volume changes so the session re-applies track levels.
    var onLevelChange: (() -> Void)?
#if DEBUG
    let sharedPlayoutGateForTesting = GuestSharedPlayoutGate(enabled: false)
    var startupCallbackEvidence: [String: Any] { owner.startupCallbackEvidence }
#endif

    private init(attachment: MeetingAudioAttachment, engine: SharedAudioEngine, owner: GuestSystemAudio) {
        self.attachment = attachment; self.engine = engine; self.owner = owner
    }

    static func attach(to engine: SharedAudioEngine, meetingID: UUID = UUID()) async throws -> SharedGuestMeetingAudio {
        let attachment = try await engine.attach(meetingID: meetingID)
        guard let owner = engine.guestOwner else {
            _ = await attachment.detach(); throw SharedAudioEngineError.setupFailed
        }
        return .init(attachment: attachment, engine: engine, owner: owner)
    }

    // MARK: Connection attempts (GuestSession may rebuild its engine)

    /// A new attempt starts muted with no senders and this meeting's sound intent.
    func beginAttempt(sound: Bool) async -> Bool {
        attachment.removeAllSenders()
        let muted = await attachment.setMuted(true)
        let output = await attachment.setSound(sound)
        return muted && output
    }
    /// The attempt's tracks are gone; the meeting stays attached for the next one.
    func endAttempt(clean: Bool) async -> Bool {
        attachment.removeAllSenders()
        let muted = await attachment.setMuted(true)
        return clean && muted
    }

    // MARK: GuestMeetingAudio

    var factory: LKRTCPeerConnectionFactory { owner.factory }
    var profile: GuestAudioProfile { owner.profile }
    var snapshot: [String: Any] {
        let base = owner.snapshot, talk = attachment.isTalk
        return base.merging([
            "sharedAudioEngine": true, "talkMeeting": talk, "inputPermitted": talk,
            "microphoneMuted": !talk || attachment.moduleMuted || base["microphoneMuted"] as? Bool != false,
            "inputAvailable": talk && base["inputAvailable"] as? Bool == true,
            "microphoneOptIn": talk && base["microphoneOptIn"] as? Bool == true,
            "meetingSound": attachment.soundOn, "meetingLevel": meetingLevel,
        ]) { _, new in new }
    }
    var playoutEpoch: UUID? { nil }
    var startupAudioObservation: GuestStartupAudioObservation { owner.startupAudioObservation }
    var canUnmuteMicrophone: Bool {
        attachment.isTalk && !attachment.privateCheckActive && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }
    var privateInputLevel: Float? { owner.privateInputLevel }
    var privateInputMeterEvidence: [String: Any] { owner.privateInputMeterEvidence }
    var playoutMeterEvidence: [String: Any] { owner.playoutMeterEvidence }

    func registerMicrophoneTrack(_ track: LKRTCAudioTrack) { attachment.addSender(track) }
    func activateMicrophone(timeout: TimeInterval?) async -> Bool { await engine.activateInput(for: attachment) }
    func setMicrophoneMuted(_ muted: Bool, timeout: TimeInterval) async -> Bool { await attachment.setMuted(muted) }
    func suppressMicrophone() { attachment.suppress() }
    func setInputPermitted(_ permitted: Bool, keepWarm: Bool, timeout: TimeInterval) async -> Bool {
        if permitted { return await attachment.assumeTalk() }
        engine.keepInputWarm = keepWarm
        return await attachment.relinquishTalk()
    }
    /// The one device already runs while any meeting talks; nothing to prepare per meeting.
    func prewarmInput(timeout: TimeInterval) async -> Bool { false }
    func setPlayoutEnabled(_ enabled: Bool, timeout: TimeInterval, expectedEpoch: UUID?) async -> Bool {
        await attachment.setSound(enabled)
    }
    func setTranscriptionOutput(_ keep: Bool, timeout: TimeInterval) async -> Bool {
        await attachment.setTranscriptionOutput(keep)
    }
    func openSharedPlayout(expected: UUID?) -> Bool { true }
    func setSharedSoundIntent(_ sound: Bool, expected: UUID?) -> Bool { true }
    func closeSharedPlayout(expected: UUID?) -> Bool { true }
    func sharedPlayoutIsOpen(expected: UUID?) -> Bool { true }
    func setMeetingVolume(_ volume: Double) -> Bool {
        meetingLevel = volume.isFinite ? min(1, max(0, volume)) : 1
        attachment.setMeetingVolume(meetingLevel)
        onLevelChange?()
        return true
    }
    func setPrivateInputMeterEnabled(_ enabled: Bool) { owner.setPrivateInputMeterEnabled(enabled) }

    // MARK: Received audio (services without their own per-track gain: Telemost, TrueConf)

    /// The track's volume follows this meeting's sound and volume (0 with sound off).
    func addReceivedTrack(_ track: LKRTCAudioTrack, id: String) {
        addReceived(id: id) { [weak track] volume in track?.source.volume = volume }
    }
    func addReceived(id: String, setVolume: @escaping (Double) -> Void) {
        attachment.addReceived(id: id, setVolume: setVolume)
    }
    func removeAllReceivedTracks() { attachment.removeAllReceived() }
    /// A connection generation retires: its tracks are off and forgotten at once, so a
    /// replacement generation's tracks (registered later, disabled) are never touched;
    /// the module mute follows in order and the next unmute re-applies the intent.
    func retireTracks() {
        attachment.removeAllSenders(); attachment.removeAllReceived()
        attachment.suppress()
    }
    func refreshSnapshot(timeout: TimeInterval) async -> Bool { await owner.refreshSnapshot(timeout: timeout) }
    func beginPrivateInputCheck(timeout: TimeInterval?) async -> Bool { await engine.beginPrivateCheck() }
    func endPrivateInputCheck(timeout: TimeInterval) async -> Bool { await engine.endPrivateCheck() }
    func setInputTranscriptionSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) { attachment.setInputTranscriptionSink(sink) }
    /// Voice replies reach only the talk meeting: they share its input graph and sender.
    func setMicrophoneGate(open: Bool) -> Bool { attachment.setMicrophoneGate(open: open) }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { await attachment.playVoiceReply(buffer) }
    /// Leaves the shared engine; the last meeting out releases the device.
    func shutdown(timeout: TimeInterval) async -> Bool { await attachment.detach() }
}
