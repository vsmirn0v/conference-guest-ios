import AVFoundation
import ConferenceCore
import Foundation

@MainActor protocol MeetingChatService: AnyObject {
    var canRead: Bool { get }
    var canSend: Bool { get }
    var supportsSending: Bool { get }
    var managesChatStoreSendCallbacks: Bool { get }
    var isReadyToSend: Bool { get }
    var observesStoreCaptures: Bool { get }
    var supportsApprovedCorrelation: Bool { get }
    var unavailableReason: String? { get }
    var onApprovedChatOutcome: ((String, MeetingWorkspaceEvent.Status) -> Void)? { get set }
    func send(_ text: String) async throws
    func send(_ text: String, permit: GuestChatDispatchPermit?, approvedID: String?) async throws -> MeetingWorkspaceEvent.Status
    func classifyError(_ error: Error, permit: GuestChatDispatchPermit?, currentStatus: MeetingWorkspaceEvent.Status?) -> MeetingWorkspaceEvent.Status
    func retry(entry: ChatEntry) async throws
    func setApprovedWorkspaceChatID(_ id: String?)
    func sendApproved(_ text: String, id: String, permit: GuestChatDispatchPermit?) async -> MeetingWorkspaceEvent.Status
    func cancelApprovedOutputs()
    func loadChatHistory() async throws
}

extension MeetingChatService {
    var canRead: Bool { false }
    var canSend: Bool { false }
    var supportsSending: Bool { false }
    var managesChatStoreSendCallbacks: Bool { false }
    var isReadyToSend: Bool { false }
    var observesStoreCaptures: Bool { true }
    var supportsApprovedCorrelation: Bool { false }
    var unavailableReason: String? { L("Chat is unavailable in this meeting.") }
    var onApprovedChatOutcome: ((String, MeetingWorkspaceEvent.Status) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
    func send(_ text: String) async throws { throw MeetingSessionError.unavailable(unavailableReason ?? L("Chat is unavailable in this meeting.")) }
    func send(_ text: String, permit: GuestChatDispatchPermit?, approvedID: String?) async throws -> MeetingWorkspaceEvent.Status {
        _ = (text, permit, approvedID)
        throw MeetingSessionError.unavailable(unavailableReason ?? L("Chat is unavailable in this meeting."))
    }
    func classifyError(_ error: Error, permit: GuestChatDispatchPermit?, currentStatus: MeetingWorkspaceEvent.Status?) -> MeetingWorkspaceEvent.Status {
        _ = (error, permit, currentStatus)
        return .failed
    }
    func retry(entry: ChatEntry) async throws { throw MeetingSessionError.unavailable(unavailableReason ?? L("Chat is unavailable in this meeting.")) }
    func setApprovedWorkspaceChatID(_ id: String?) { _ = id }
    func sendApproved(_ text: String, id: String, permit: GuestChatDispatchPermit?) async -> MeetingWorkspaceEvent.Status { .failed }
    func cancelApprovedOutputs() {}
    func loadChatHistory() async throws { throw MeetingSessionError.unavailable(unavailableReason ?? L("Chat is unavailable in this meeting.")) }
}

@MainActor protocol MeetingReactionService: AnyObject {
    var canSendReactions: Bool { get }
    var supportsApprovedCorrelation: Bool { get }
    func sendReaction(_ kind: MeetingReaction, approvedID: String?) async throws
}

extension MeetingReactionService {
    var canSendReactions: Bool { false }
    var supportsApprovedCorrelation: Bool { false }
    func sendReaction(_ kind: MeetingReaction, approvedID: String?) async throws {
        throw MeetingSessionError.unavailable(L("Reactions are unavailable in this meeting."))
    }
}

@MainActor protocol MeetingTranscriptService: AnyObject {
    var status: GuestMeetingSnapshot.TranscriptionStatus { get }
    var canView: Bool { get }
    var canManage: Bool { get }
    var messages: [GuestMeetingMessage] { get }
    func setEnabled(_ enabled: Bool) async throws
    func loadTranscriptHistory() async throws
    func retryInitialTranscriptHistory()
}

extension MeetingTranscriptService {
    var status: GuestMeetingSnapshot.TranscriptionStatus { .unknown }
    var canView: Bool { false }
    var canManage: Bool { false }
    var messages: [GuestMeetingMessage] { [] }
    func setEnabled(_ enabled: Bool) async throws {
        throw MeetingSessionError.unavailable(L("Live transcription controls are unavailable in this meeting."))
    }
    func loadTranscriptHistory() async throws {
        throw MeetingSessionError.unavailable(L("Transcript history is unavailable in this meeting."))
    }
    func retryInitialTranscriptHistory() {}
}

@MainActor protocol MeetingParticipationService: AnyObject {
    var connectionIdentity: MeetingConnectionIdentity? { get }
    var roomScope: (room: String, group: String)? { get }
    var voiceMicrophoneAuthorized: Bool { get }
    var usesSharedOutput: Bool { get }
    var senderPhysicallyMuted: Bool { get }
    var hasVoiceGraph: Bool { get }
    func setVoiceGate(open: Bool) -> Bool
    func prepareVoiceAudio(_ permit: GuestAutonomousVoicePlayback) async -> Bool
    func borrowVoiceSender(_ permit: GuestAutonomousVoicePlayback) async -> Bool
    func restoreVoiceSender(_ permit: GuestAutonomousVoicePlayback) async -> Bool
    func playVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                   canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                   onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome
    func sendAttributedChat(_ text: String, id: String, permit: GuestChatDispatchPermit) async throws
}

/// Default `.unavailable` feature service used when a provider does not expose an optional capability.
@MainActor final class UnavailableMeetingFeatureServices: MeetingChatService, MeetingReactionService, MeetingTranscriptService {
    let unavailableReason: String?
    var canSend: Bool { false }
    var canSendReactions: Bool { false }
    var supportsApprovedCorrelation: Bool { false }
    init(reason: String = L("This feature is unavailable in this meeting.")) {
        self.unavailableReason = reason
    }
}
