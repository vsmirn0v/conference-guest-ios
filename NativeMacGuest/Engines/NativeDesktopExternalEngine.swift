import AVFoundation
import Foundation
import CoreGraphics
import LiveKitWebRTC

enum NativeDesktopMeetingPhase: String { case idle, connecting, connected, reconnecting, leaving, left, failed }
enum NativeDesktopVideoSource: String { case camera, screen }
struct NativeDesktopParticipant: Identifiable, Equatable {
    let id: String
    var name: String
    var isLocal = false
    var microphoneOn: Bool?
    var cameraOn: Bool?
    var sharing: Bool?
    var speaking: Bool?
}
struct NativeDesktopExternalVideo: Identifiable {
    let id: String
    let participantID: String
    let source: NativeDesktopVideoSource
    let track: LKRTCVideoTrack
    /// Top-left normalized rectangle supplied by a composite server.
    var crop: CGRect? = nil
}
struct NativeDesktopExternalSnapshot: Equatable {
    var phase: NativeDesktopMeetingPhase = .idle
    var microphoneOn = false
    var cameraOn = false
    var playoutOn = true
    var sharing = false
    var participants: [NativeDesktopParticipant] = []
    var lastError: String?
    var microphoneLevel: Float?
    /// The meeting ended for this participant on the organizer's side, not by a fault.
    var endedByOrganizer = false
}

/// Actions request media intent. Snapshot changes confirm effective local media
/// and accepted signaling; reconnecting never presents unconfirmed capture as on.
/// The shell owns screen capture and stops it before releasing the engine.
@MainActor
protocol NativeDesktopMeetingEngine: AnyObject {
    var onState: ((NativeDesktopExternalSnapshot) -> Void)? { get set }
    var onVideo: (([NativeDesktopExternalVideo]) -> Void)? { get set }
    var onLocalCamera: ((LKRTCVideoTrack?) -> Void)? { get set }
    var onTitle: ((String) -> Void)? { get set }
    var factory: LKRTCPeerConnectionFactory? { get }
    var snapshot: NativeDesktopExternalSnapshot { get }
    var incomingVideo: [NativeDesktopExternalVideo] { get }
    var privateAudioLevel: Float? { get }
    var microphoneReadinessPolicy: (() -> Bool)? { get set }
    func connect(invitation: URL, name: String, quiet: Bool) async throws
    func reconnect() async throws
    func setMicrophone(_ enabled: Bool) async throws
    func setCamera(_ enabled: Bool) async throws
    func setPlayout(_ enabled: Bool) async throws
    /// App-only meeting level (0...1); never changes the macOS output volume.
    func setPlayoutVolume(_ volume: Double) async
    /// Engines that receive each speaker separately report true; others never show the control.
    var supportsParticipantVolume: Bool { get }
    /// An additional simultaneous meeting owns separate audio; call before connect.
    func configureConcurrentAudio(_ concurrent: Bool)
    /// Only the talk meeting may hold physical input. false mutes and releases it
    /// (true when confirmed); true permits a later unmute and starts nothing.
    func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool
    /// Listener-only level (0...2) for one remote participant; 1 removes the override.
    func setParticipantVolume(_ volume: Double, participantID: String) async
    func setScreenTrack(_ track: LKRTCVideoTrack?) async throws
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws
    /// Engines that can subscribe screens without cameras report true; the shell
    /// offers "Screen shares" only for them and never sends cameras: false otherwise.
    var supportsScreenOnlyVideo: Bool { get }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?, cameras: Bool) async throws
    func prepareMutedCaptureForAccessories() async throws
    func setMicrophoneReadinessForRecovery(_ enabled: Bool)
    func cameraCaptureDevice() async -> AVCaptureDevice?
    func startPrivateAudioCheck() async throws
    func stopPrivateAudioCheck() async throws
    /// Your microphone's buffers for local transcription, delivered on the audio
    /// thread whenever this engine holds physical input; nil stops delivery.
    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?)
    /// The engine can hand remote audio to local transcription.
    var supportsLocalTranscription: Bool { get }
    /// Receives the current remote audio sources now and on every change; nil stops.
    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?)
    /// Keeps remote audio decoded while sound is off; what is heard stays silent.
    func setTranscriptionOutput(_ keep: Bool) async -> Bool
    /// Before connecting: receive audio even when joining with sound off, so a
    /// meeting joined silently can still be transcribed.
    func setTranscriptionRequested(_ requested: Bool)
    /// The last unmute's steps in milliseconds (permission, activation, then the
    /// service step: confirmation or renegotiation), for move diagnostics.
    var microphoneStartupMilliseconds: [String: Double] { get }
    /// Releasing input for another meeting. With `keepDeviceWarm` the device and
    /// voice processing keep running muted, so moving back is faster.
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool
    /// A meeting without the talk role starts its device muted now, as a warm
    /// release would leave it; true when it is running muted.
    func prewarmInput() async -> Bool
    /// Voice replies: a microphone gate and a player in the input graph.
    var supportsVoiceReply: Bool { get }
    /// Closing the gate removes your microphone from what is sent; the player still plays.
    func setMicrophoneGate(open: Bool) async -> Bool
    /// Plays one buffer into what the meeting receives; true when it finished playing.
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool
    func leave() async -> Bool
}
extension NativeDesktopMeetingEngine {
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?) async throws {}
    var supportsScreenOnlyVideo: Bool { false }
    func setVisibleParticipantIDs(_ ids: Set<String>?, focusedParticipantID: String?, cameras: Bool) async throws {
        try await setVisibleParticipantIDs(ids, focusedParticipantID: focusedParticipantID)
    }
    func setPlayoutVolume(_ volume: Double) async {}
    var supportsParticipantVolume: Bool { false }
    func configureConcurrentAudio(_ concurrent: Bool) {}
    func setPhysicalInputPermitted(_ permitted: Bool) async -> Bool { true }
    func setParticipantVolume(_ volume: Double, participantID: String) async {}
    func prepareMutedCaptureForAccessories() async throws {}
    func setMicrophoneReadinessForRecovery(_ enabled: Bool) {}
    func cameraCaptureDevice() async -> AVCaptureDevice? { nil }
    var privateAudioLevel: Float? { nil }
    var microphoneReadinessPolicy: (() -> Bool)? { get { nil } set {} }
    func startPrivateAudioCheck() async throws { throw NativeDesktopPrivateAudioError.unavailable }
    func stopPrivateAudioCheck() async throws {}
    func setLocalAudioSink(_ sink: ((AVAudioPCMBuffer) -> Void)?) {}
    var supportsLocalTranscription: Bool { false }
    func setTranscriptionAudioHandler(_ handler: (([MeetingAudioSource]) -> Void)?) {}
    func setTranscriptionOutput(_ keep: Bool) async -> Bool { !keep }
    func setTranscriptionRequested(_ requested: Bool) {}
    var microphoneStartupMilliseconds: [String: Double] { [:] }
    func setPhysicalInputPermitted(_ permitted: Bool, keepDeviceWarm: Bool) async -> Bool {
        await setPhysicalInputPermitted(permitted)
    }
    func prewarmInput() async -> Bool { false }
    var supportsVoiceReply: Bool { false }
    func setMicrophoneGate(open: Bool) async -> Bool { open }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { false }
}
enum NativeDesktopPrivateAudioError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Private microphone checking is unavailable for this meeting engine." }
}
typealias NativeDesktopExternalEngine = NativeDesktopMeetingEngine
