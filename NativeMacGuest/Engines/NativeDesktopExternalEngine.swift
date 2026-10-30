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
}
enum NativeDesktopPrivateAudioError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Private microphone checking is unavailable for this meeting engine." }
}
typealias NativeDesktopExternalEngine = NativeDesktopMeetingEngine
