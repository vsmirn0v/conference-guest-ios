import AVFoundation
import Foundation
import CoreGraphics
import LiveKitWebRTC

public enum NativeDesktopMeetingPhase: String { case idle, connecting, lobby, connected, reconnecting, leaving, left, failed }
public enum NativeDesktopVideoSource: String { case camera, screen }
public struct NativeDesktopParticipant: Identifiable, Equatable {
    public let id: String
    public var name: String
    public var isLocal = false
    public var microphoneOn: Bool?
    public var cameraOn: Bool?
    public var sharing: Bool?
    public var speaking: Bool?

    public init(id: String, name: String, isLocal: Bool = false, microphoneOn: Bool? = nil,
                cameraOn: Bool? = nil, sharing: Bool? = nil, speaking: Bool? = nil) {
        self.id = id; self.name = name; self.isLocal = isLocal
        self.microphoneOn = microphoneOn; self.cameraOn = cameraOn; self.sharing = sharing; self.speaking = speaking
    }
}
public struct NativeDesktopExternalVideo: Identifiable {
    public let id: String
    public let participantID: String
    public let source: NativeDesktopVideoSource
    public let track: LKRTCVideoTrack
    /// Top-left normalized rectangle supplied by a composite server.
    public var crop: CGRect? = nil

    public init(id: String, participantID: String, source: NativeDesktopVideoSource,
                track: LKRTCVideoTrack, crop: CGRect? = nil) {
        self.id = id; self.participantID = participantID; self.source = source
        self.track = track; self.crop = crop
    }
}
public struct NativeDesktopExternalSnapshot: Equatable {
    public var phase: NativeDesktopMeetingPhase = .idle
    public var lobbyModeratorPresent: Bool? = nil
    public var microphoneOn = false
    public var cameraOn = false
    public var playoutOn = true
    public var sharing = false
    public var participants: [NativeDesktopParticipant] = []
    public var lastError: String?
    public var microphoneLevel: Float?
    /// The meeting ended for this participant on the organizer's side, not by a fault.
    public var endedByOrganizer = false

    public init(phase: NativeDesktopMeetingPhase = .idle, lobbyModeratorPresent: Bool? = nil,
                microphoneOn: Bool = false, cameraOn: Bool = false, playoutOn: Bool = true,
                sharing: Bool = false, participants: [NativeDesktopParticipant] = [],
                lastError: String? = nil, microphoneLevel: Float? = nil, endedByOrganizer: Bool = false) {
        self.phase = phase; self.lobbyModeratorPresent = lobbyModeratorPresent
        self.microphoneOn = microphoneOn; self.cameraOn = cameraOn; self.playoutOn = playoutOn
        self.sharing = sharing; self.participants = participants; self.lastError = lastError
        self.microphoneLevel = microphoneLevel; self.endedByOrganizer = endedByOrganizer
    }
}

/// Actions request media intent. Snapshot changes confirm effective local media
/// and accepted signaling; reconnecting never presents unconfirmed capture as on.
/// The shell owns screen capture and stops it before releasing the engine.
@MainActor
public protocol NativeDesktopMeetingEngine: AnyObject {
    /// Cached control-plane data only; never synchronously inspect media or SDK state.
    var ownershipDiagnostics: [String: Any] { get }
    var microphoneTrackProbe: GuestMicrophoneTrackProbe? { get }
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
    var voiceMicrophoneGateIsClosed: Bool { get }
    /// Plays one buffer into what the meeting receives; true when it finished playing.
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool
    func leave() async -> Bool
}
public extension NativeDesktopMeetingEngine {
    var ownershipDiagnostics: [String: Any] { ["executor": "unavailable"] }
    var microphoneTrackProbe: GuestMicrophoneTrackProbe? { nil }
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
    var voiceMicrophoneGateIsClosed: Bool { false }
    func playVoiceReply(_ buffer: AVAudioPCMBuffer) async -> Bool { false }
}
public enum NativeDesktopPrivateAudioError: LocalizedError {
    case unavailable
    public var errorDescription: String? { "Private microphone checking is unavailable for this meeting engine." }
}
typealias NativeDesktopExternalEngine = NativeDesktopMeetingEngine
