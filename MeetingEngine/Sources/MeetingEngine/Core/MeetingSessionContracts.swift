import ConferenceCore
import Foundation

public typealias MeetingSessionID = UUID

/// Monotonic generation token for one connection lifecycle within a session.
public struct ConnectionGeneration: Hashable, Sendable {
    public let id: UUID
    public let epoch: UInt64

    public init(id: UUID = UUID(), epoch: UInt64 = 0) {
        self.id = id
        self.epoch = epoch
    }

    public func next() -> Self {
        Self(id: UUID(), epoch: epoch &+ 1)
    }
}

/// Monotonic revision token for fencing overlapping user/SDK media commands.
public struct CommandRevision: Comparable, Hashable, Sendable {
    public private(set) var rawValue: UInt64

    public init(_ rawValue: UInt64 = 0) {
        self.rawValue = rawValue
    }

    public mutating func advance() -> Self {
        rawValue &+= 1
        return self
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Stable identity for an active provider connection, used to fence Assistant/Participation
/// privacy state and voice gates without relying on raw native pointer identities.
public struct MeetingConnectionIdentity: Hashable, Sendable {
    public let sessionID: MeetingSessionID
    public let provider: MeetingEngineKind
    public let generation: UUID
    public let providerScope: String

    public init(sessionID: MeetingSessionID, provider: MeetingEngineKind, generation: UUID, providerScope: String = "") {
        self.sessionID = sessionID
        self.provider = provider
        self.generation = generation
        self.providerScope = providerScope
    }
}

public struct MeetingMediaIntent: Equatable, Sendable {
    public var microphoneOn = false
    public var cameraOn = false
    public var playoutOn = true
    public var sharing = false
    public var playoutVolume: Double = 1

    public init(microphoneOn: Bool = false, cameraOn: Bool = false, playoutOn: Bool = true,
                sharing: Bool = false, playoutVolume: Double = 1) {
        self.microphoneOn = microphoneOn
        self.cameraOn = cameraOn
        self.playoutOn = playoutOn
        self.sharing = sharing
        self.playoutVolume = playoutVolume
    }
}

public struct MeetingEffectiveMedia: Equatable, Sendable {
    public var microphoneOn = false
    public var cameraOn = false
    public var playoutOn = true
    public var sharing = false
    public var microphoneLevel: Float?
    public var physicallyMuted = true

    public init(microphoneOn: Bool = false, cameraOn: Bool = false, playoutOn: Bool = true,
                sharing: Bool = false, microphoneLevel: Float? = nil, physicallyMuted: Bool = true) {
        self.microphoneOn = microphoneOn
        self.cameraOn = cameraOn
        self.playoutOn = playoutOn
        self.sharing = sharing
        self.microphoneLevel = microphoneLevel
        self.physicallyMuted = physicallyMuted
    }
}

public struct MeetingMediaPermission: Equatable, Sendable {
    public var canShareMicrophone = true
    public var canShareCamera = true
    public var canShareScreen = true
    public var microphoneRestriction: String?

    public init(canShareMicrophone: Bool = true, canShareCamera: Bool = true,
                canShareScreen: Bool = true, microphoneRestriction: String? = nil) {
        self.canShareMicrophone = canShareMicrophone
        self.canShareCamera = canShareCamera
        self.canShareScreen = canShareScreen
        self.microphoneRestriction = microphoneRestriction
    }
}

/// Capabilities exposed uniformly to the shell/UI/Assistant without provider type checks.
public struct MeetingSessionCapabilities: Equatable, Sendable {
    public var supportsChatRead: Bool
    public var supportsChatSend: Bool
    public var supportsChatHistory: Bool
    public var supportsApprovedChatCorrelation: Bool
    public var supportsReactions: Bool
    public var supportsProviderTranscript: Bool
    public var supportsLocalTranscription: Bool
    /// Manual/approved voice reply on the shared input mixer (supported across all 4 providers).
    public var supportsVoiceReply: Bool
    /// Autonomous participation voice replies (currently strictly Guest room scope + verified permissions).
    public var supportsAutonomousParticipation: Bool
    public var supportsParticipantVolume: Bool
    public var supportsScreenOnlyVideo: Bool
    public var supportsIndependentCameraAndShare: Bool
    public var supportsScreenShareVP9: Bool
    public var supportsPreJoinReadiness: Bool = false

    public init(supportsChatRead: Bool, supportsChatSend: Bool, supportsChatHistory: Bool,
                supportsApprovedChatCorrelation: Bool, supportsReactions: Bool,
                supportsProviderTranscript: Bool, supportsLocalTranscription: Bool,
                supportsVoiceReply: Bool, supportsAutonomousParticipation: Bool,
                supportsParticipantVolume: Bool, supportsScreenOnlyVideo: Bool,
                supportsIndependentCameraAndShare: Bool, supportsScreenShareVP9: Bool,
                supportsPreJoinReadiness: Bool = false) {
        self.supportsChatRead = supportsChatRead
        self.supportsChatSend = supportsChatSend
        self.supportsChatHistory = supportsChatHistory
        self.supportsApprovedChatCorrelation = supportsApprovedChatCorrelation
        self.supportsReactions = supportsReactions
        self.supportsProviderTranscript = supportsProviderTranscript
        self.supportsLocalTranscription = supportsLocalTranscription
        self.supportsVoiceReply = supportsVoiceReply
        self.supportsAutonomousParticipation = supportsAutonomousParticipation
        self.supportsParticipantVolume = supportsParticipantVolume
        self.supportsScreenOnlyVideo = supportsScreenOnlyVideo
        self.supportsIndependentCameraAndShare = supportsIndependentCameraAndShare
        self.supportsScreenShareVP9 = supportsScreenShareVP9
        self.supportsPreJoinReadiness = supportsPreJoinReadiness
    }

    public static func guest(canViewChat: Bool = false, canSendChat: Bool = false, canReact: Bool = false,
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

    public static let telemost = Self(
        supportsChatRead: true, supportsChatSend: false, supportsChatHistory: false,
        supportsApprovedChatCorrelation: false, supportsReactions: false, supportsProviderTranscript: false,
        supportsLocalTranscription: true, supportsVoiceReply: GuestSystemAudio.voiceRepliesEnabled,
        supportsAutonomousParticipation: false, supportsParticipantVolume: false, supportsScreenOnlyVideo: true,
        supportsIndependentCameraAndShare: true, supportsScreenShareVP9: false
    )

    public static let trueconf = Self(
        supportsChatRead: false, supportsChatSend: false, supportsChatHistory: false,
        supportsApprovedChatCorrelation: false, supportsReactions: false, supportsProviderTranscript: false,
        supportsLocalTranscription: true, supportsVoiceReply: GuestSystemAudio.voiceRepliesEnabled,
        supportsAutonomousParticipation: false, supportsParticipantVolume: false, supportsScreenOnlyVideo: false,
        supportsIndependentCameraAndShare: false, supportsScreenShareVP9: false
    )

    public static func rock(supportsMicrophone: Bool = true) -> Self {
        Self(supportsChatRead: true, supportsChatSend: true, supportsChatHistory: false,
             supportsApprovedChatCorrelation: true, supportsReactions: false, supportsProviderTranscript: false,
             supportsLocalTranscription: true,
             supportsVoiceReply: supportsMicrophone && GuestSystemAudio.voiceRepliesEnabled,
             supportsAutonomousParticipation: false, supportsParticipantVolume: true, supportsScreenOnlyVideo: true,
             supportsIndependentCameraAndShare: true, supportsScreenShareVP9: false)
    }
}

public enum RecoveryExecutorKind: String, Sendable {
    case guestSession = "guest-session"
    case nativeAdapterSupervisor = "native-adapter-supervisor"
    case liveKitSDK = "livekit-sdk"
}

public enum MeetingCommandOutcome<Value> {
    case applied(Value)
    case superseded
    case unavailable(String)
    case rejected(String)
}

extension MeetingCommandOutcome: Equatable where Value: Equatable {}
extension MeetingCommandOutcome: Sendable where Value: Sendable {}

public enum MeetingSessionError: LocalizedError, Equatable {
    case notConnected
    case unavailable(String)
    case permissionDenied(String)
    case cleanupFailed
    case cancelled
    case staleCommand

    public var errorDescription: String? {
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

public struct MeetingSessionSnapshot: Equatable {
    public var phase: NativeDesktopMeetingPhase = .idle
    public var connectionIdentity: MeetingConnectionIdentity?
    public var intent = MeetingMediaIntent()
    public var effective = MeetingEffectiveMedia()
    public var permissions = MeetingMediaPermission()
    public var capabilities = MeetingSessionCapabilities.telemost
    public var participants: [NativeDesktopParticipant] = []
    public var lastError: String?
    public var endedByOrganizer = false
    public var recoveryExecutor: RecoveryExecutorKind = .nativeAdapterSupervisor

    public init(phase: NativeDesktopMeetingPhase = .idle,
                connectionIdentity: MeetingConnectionIdentity? = nil,
                intent: MeetingMediaIntent = MeetingMediaIntent(),
                effective: MeetingEffectiveMedia = MeetingEffectiveMedia(),
                permissions: MeetingMediaPermission = MeetingMediaPermission(),
                capabilities: MeetingSessionCapabilities = .telemost,
                participants: [NativeDesktopParticipant] = [],
                lastError: String? = nil,
                endedByOrganizer: Bool = false,
                recoveryExecutor: RecoveryExecutorKind = .nativeAdapterSupervisor) {
        self.phase = phase
        self.connectionIdentity = connectionIdentity
        self.intent = intent
        self.effective = effective
        self.permissions = permissions
        self.capabilities = capabilities
        self.participants = participants
        self.lastError = lastError
        self.endedByOrganizer = endedByOrganizer
        self.recoveryExecutor = recoveryExecutor
    }

    public var externalSnapshot: NativeDesktopExternalSnapshot {
        NativeDesktopExternalSnapshot(phase: phase, microphoneOn: effective.microphoneOn,
            cameraOn: effective.cameraOn, playoutOn: effective.playoutOn, sharing: effective.sharing,
            participants: participants, lastError: lastError, microphoneLevel: effective.microphoneLevel,
            endedByOrganizer: endedByOrganizer)
    }
}

public struct MeetingFrameCadenceSnapshot: Equatable, Sendable {
    public var complete: Bool
    public var frames: Int
    public var fps: Double
    public var maximumGap: Double
    public var endFrameAge: Double?

    public init(complete: Bool, frames: Int, fps: Double, maximumGap: Double, endFrameAge: Double? = nil) {
        self.complete = complete
        self.frames = frames
        self.fps = fps
        self.maximumGap = maximumGap
        self.endFrameAge = endFrameAge
    }
}

public struct MeetingCompanionDiagnosticsSnapshot {
    public var hasDesiredIntent = false
    public var desiredAudioMuted: Bool?
    public var desiredVideoMuted: Bool?
    public var appliedAudioMuted: Bool?
    public var appliedVideoMuted: Bool?
    public var appliedPlayoutEnabled: Bool?
    public var canShareMicrophone = false
    public var canShareCamera = false
    public var connectionCount: UInt64 = 0
    public var engineSessionID: String?
    public var remoteParticipants = 0
    public var remoteVideoTrackCount = 0
    public var receivedAudioSamples = 0
    public var receivedAudioEnergy: Double = 0
    public var receivedAudioRMS: Double = 0
    public var mediaConnected = false
    public var rawVideoCallbacks = 0
    public var renderedVideoFrames = 0
    public var cameraPresent = false
    public var cameraFrames = 0
    public var cameraPTS = 0
    public var cameraWidth = 0
    public var cameraHeight = 0
    public var systemAudioSnapshot: [String: Any]?
    public var evidence: [String: Any] = [:]
    public var decodedCadence: MeetingFrameCadenceSnapshot?

    public init(hasDesiredIntent: Bool = false, desiredAudioMuted: Bool? = nil, desiredVideoMuted: Bool? = nil,
                appliedAudioMuted: Bool? = nil, appliedVideoMuted: Bool? = nil, appliedPlayoutEnabled: Bool? = nil,
                canShareMicrophone: Bool = false, canShareCamera: Bool = false, connectionCount: UInt64 = 0,
                engineSessionID: String? = nil, remoteParticipants: Int = 0, remoteVideoTrackCount: Int = 0,
                receivedAudioSamples: Int = 0, receivedAudioEnergy: Double = 0, receivedAudioRMS: Double = 0,
                mediaConnected: Bool = false, rawVideoCallbacks: Int = 0, renderedVideoFrames: Int = 0,
                cameraPresent: Bool = false, cameraFrames: Int = 0, cameraPTS: Int = 0, cameraWidth: Int = 0,
                cameraHeight: Int = 0, systemAudioSnapshot: [String: Any]? = nil,
                evidence: [String: Any] = [:], decodedCadence: MeetingFrameCadenceSnapshot? = nil) {
        self.hasDesiredIntent = hasDesiredIntent
        self.desiredAudioMuted = desiredAudioMuted
        self.desiredVideoMuted = desiredVideoMuted
        self.appliedAudioMuted = appliedAudioMuted
        self.appliedVideoMuted = appliedVideoMuted
        self.appliedPlayoutEnabled = appliedPlayoutEnabled
        self.canShareMicrophone = canShareMicrophone
        self.canShareCamera = canShareCamera
        self.connectionCount = connectionCount
        self.engineSessionID = engineSessionID
        self.remoteParticipants = remoteParticipants
        self.remoteVideoTrackCount = remoteVideoTrackCount
        self.receivedAudioSamples = receivedAudioSamples
        self.receivedAudioEnergy = receivedAudioEnergy
        self.receivedAudioRMS = receivedAudioRMS
        self.mediaConnected = mediaConnected
        self.rawVideoCallbacks = rawVideoCallbacks
        self.renderedVideoFrames = renderedVideoFrames
        self.cameraPresent = cameraPresent
        self.cameraFrames = cameraFrames
        self.cameraPTS = cameraPTS
        self.cameraWidth = cameraWidth
        self.cameraHeight = cameraHeight
        self.systemAudioSnapshot = systemAudioSnapshot
        self.evidence = evidence
        self.decodedCadence = decodedCadence
    }
}
