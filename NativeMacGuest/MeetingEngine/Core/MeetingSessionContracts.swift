import ConferenceCore
import Foundation

typealias MeetingSessionID = UUID

/// Monotonic generation token for one connection lifecycle within a session.
struct ConnectionGeneration: Hashable, Sendable {
    let id: UUID
    let epoch: UInt64

    init(id: UUID = UUID(), epoch: UInt64 = 0) {
        self.id = id
        self.epoch = epoch
    }

    func next() -> Self {
        Self(id: UUID(), epoch: epoch &+ 1)
    }
}

/// Monotonic revision token for fencing overlapping user/SDK media commands.
struct CommandRevision: Comparable, Hashable, Sendable {
    private(set) var rawValue: UInt64

    init(_ rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    mutating func advance() -> Self {
        rawValue &+= 1
        return self
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Stable identity for an active provider connection, used to fence Assistant/Participation
/// privacy state and voice gates without relying on raw native pointer identities.
struct MeetingConnectionIdentity: Hashable, Sendable {
    let sessionID: MeetingSessionID
    let provider: MeetingEngineKind
    let generation: UUID
    let providerScope: String

    init(sessionID: MeetingSessionID, provider: MeetingEngineKind, generation: UUID, providerScope: String = "") {
        self.sessionID = sessionID
        self.provider = provider
        self.generation = generation
        self.providerScope = providerScope
    }
}

struct MeetingMediaIntent: Equatable, Sendable {
    var microphoneOn = false
    var cameraOn = false
    var playoutOn = true
    var sharing = false
    var playoutVolume: Double = 1
}

struct MeetingEffectiveMedia: Equatable, Sendable {
    var microphoneOn = false
    var cameraOn = false
    var playoutOn = true
    var sharing = false
    var microphoneLevel: Float?
    var physicallyMuted = true
}

struct MeetingMediaPermission: Equatable, Sendable {
    var canShareMicrophone = true
    var canShareCamera = true
    var canShareScreen = true
    var microphoneRestriction: String?
}

/// Capabilities exposed uniformly to the shell/UI/Assistant without provider type checks.
struct MeetingSessionCapabilities: Equatable, Sendable {
    var supportsChatRead: Bool
    var supportsChatSend: Bool
    var supportsChatHistory: Bool
    var supportsApprovedChatCorrelation: Bool
    var supportsReactions: Bool
    var supportsProviderTranscript: Bool
    var supportsLocalTranscription: Bool
    /// Manual/approved voice reply on the shared input mixer (supported across all 4 providers).
    var supportsVoiceReply: Bool
    /// Autonomous participation voice replies (currently strictly Guest room scope + verified permissions).
    var supportsAutonomousParticipation: Bool
    var supportsParticipantVolume: Bool
    var supportsScreenOnlyVideo: Bool
    var supportsIndependentCameraAndShare: Bool
    var supportsScreenShareVP9: Bool
    var supportsPreJoinReadiness: Bool = false

    static func guest(canViewChat: Bool = false, canSendChat: Bool = false, canReact: Bool = false,
                      canViewTranscript: Bool = false, canManageTranscript: Bool = false,
                      supportsAutonomousParticipation: Bool = false,
                      supportsScreenShareVP9: Bool = false) -> Self {
        _ = canManageTranscript
        return Self(supportsChatRead: canViewChat, supportsChatSend: canSendChat,
                    supportsChatHistory: canViewChat, supportsApprovedChatCorrelation: true,
                    supportsReactions: canReact, supportsProviderTranscript: canViewTranscript,
                    supportsLocalTranscription: true, supportsVoiceReply: GuestSystemAudio.voiceRepliesEnabled,
                    supportsAutonomousParticipation: supportsAutonomousParticipation,
                    supportsParticipantVolume: true, supportsScreenOnlyVideo: true,
                    supportsIndependentCameraAndShare: true, supportsScreenShareVP9: supportsScreenShareVP9,
                    supportsPreJoinReadiness: true)
    }

    static let telemost = Self(
        supportsChatRead: true, supportsChatSend: false, supportsChatHistory: false,
        supportsApprovedChatCorrelation: false, supportsReactions: false, supportsProviderTranscript: false,
        supportsLocalTranscription: true, supportsVoiceReply: GuestSystemAudio.voiceRepliesEnabled,
        supportsAutonomousParticipation: false, supportsParticipantVolume: false, supportsScreenOnlyVideo: true,
        supportsIndependentCameraAndShare: true, supportsScreenShareVP9: false
    )

    static let trueconf = Self(
        supportsChatRead: false, supportsChatSend: false, supportsChatHistory: false,
        supportsApprovedChatCorrelation: false, supportsReactions: false, supportsProviderTranscript: false,
        supportsLocalTranscription: true, supportsVoiceReply: GuestSystemAudio.voiceRepliesEnabled,
        supportsAutonomousParticipation: false, supportsParticipantVolume: false, supportsScreenOnlyVideo: false,
        supportsIndependentCameraAndShare: false, supportsScreenShareVP9: false
    )

    static func rock(supportsMicrophone: Bool = true) -> Self {
        Self(supportsChatRead: true, supportsChatSend: true, supportsChatHistory: false,
             supportsApprovedChatCorrelation: true, supportsReactions: false, supportsProviderTranscript: false,
             supportsLocalTranscription: true,
             supportsVoiceReply: supportsMicrophone && GuestSystemAudio.voiceRepliesEnabled,
             supportsAutonomousParticipation: false, supportsParticipantVolume: true, supportsScreenOnlyVideo: true,
             supportsIndependentCameraAndShare: true, supportsScreenShareVP9: false)
    }
}

enum RecoveryExecutorKind: String, Sendable {
    case guestSession = "guest-session"
    case nativeAdapterSupervisor = "native-adapter-supervisor"
    case liveKitSDK = "livekit-sdk"
}

enum MeetingCommandOutcome<Value> {
    case applied(Value)
    case superseded
    case unavailable(String)
    case rejected(String)
}

extension MeetingCommandOutcome: Equatable where Value: Equatable {}
extension MeetingCommandOutcome: Sendable where Value: Sendable {}

enum MeetingSessionError: LocalizedError, Equatable {
    case notConnected
    case unavailable(String)
    case permissionDenied(String)
    case cleanupFailed
    case cancelled
    case staleCommand

    var errorDescription: String? {
        switch self {
        case .notConnected: L("Join a meeting before changing media.")
        case .unavailable(let reason): reason
        case .permissionDenied(let reason): reason
        case .cleanupFailed: L("The previous audio or capture owner has not stopped cleanly.")
        case .cancelled: L("The operation was cancelled.")
        case .staleCommand: L("The meeting changed before this action completed.")
        }
    }
}

struct MeetingSessionSnapshot: Equatable {
    var phase: NativeDesktopMeetingPhase = .idle
    var connectionIdentity: MeetingConnectionIdentity?
    var intent = MeetingMediaIntent()
    var effective = MeetingEffectiveMedia()
    var permissions = MeetingMediaPermission()
    var capabilities = MeetingSessionCapabilities.telemost
    var participants: [NativeDesktopParticipant] = []
    var lastError: String?
    var endedByOrganizer = false
    var recoveryExecutor: RecoveryExecutorKind = .nativeAdapterSupervisor

    var externalSnapshot: NativeDesktopExternalSnapshot {
        NativeDesktopExternalSnapshot(phase: phase, microphoneOn: effective.microphoneOn,
            cameraOn: effective.cameraOn, playoutOn: effective.playoutOn, sharing: effective.sharing,
            participants: participants, lastError: lastError, microphoneLevel: effective.microphoneLevel,
            endedByOrganizer: endedByOrganizer)
    }
}

struct MeetingFrameCadenceSnapshot: Equatable, Sendable {
    var complete: Bool
    var frames: Int
    var fps: Double
    var maximumGap: Double
    var endFrameAge: Double?
}

struct MeetingCompanionDiagnosticsSnapshot {
    var hasDesiredIntent = false
    var desiredAudioMuted: Bool?
    var desiredVideoMuted: Bool?
    var appliedAudioMuted: Bool?
    var appliedVideoMuted: Bool?
    var appliedPlayoutEnabled: Bool?
    var canShareMicrophone = false
    var canShareCamera = false
    var connectionCount: UInt64 = 0
    var engineSessionID: String?
    var remoteParticipants = 0
    var remoteVideoTrackCount = 0
    var receivedAudioSamples = 0
    var receivedAudioEnergy: Double = 0
    var receivedAudioRMS: Double = 0
    var mediaConnected = false
    var rawVideoCallbacks = 0
    var renderedVideoFrames = 0
    var cameraPresent = false
    var cameraFrames = 0
    var cameraPTS = 0
    var cameraWidth = 0
    var cameraHeight = 0
    var systemAudioSnapshot: [String: Any]?
    var evidence: [String: Any] = [:]
    var decodedCadence: MeetingFrameCadenceSnapshot?
}
