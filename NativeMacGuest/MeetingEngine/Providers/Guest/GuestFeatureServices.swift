import AVFoundation
import ConferenceCore
import Foundation

@MainActor final class GuestChatService: MeetingChatService {
    private weak var adapter: GuestAdapter?
    var onApprovedChatOutcome: ((String, MeetingWorkspaceEvent.Status) -> Void)?

    init(adapter: GuestAdapter) {
        self.adapter = adapter
    }

    var canRead: Bool { adapter?.guestSnapshot.permissions.canViewChat == true }
    var canSend: Bool { adapter.map { $0.guestSnapshot.permissions.canSendChat && $0.guestSnapshot.connected } ?? false }
    var supportsSending: Bool { true }
    var isReadyToSend: Bool { adapter?.currentNativeEngine != nil }
    var observesStoreCaptures: Bool { false }
    var supportsApprovedCorrelation: Bool { true }
    var unavailableReason: String? { canRead ? nil : L("Chat is unavailable in this meeting.") }

    func send(_ text: String) async throws {
        guard let native = adapter?.currentNativeEngine else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable before connecting."))
        }
        _ = try await native.sendChatMessage(text)
    }

    func send(_ text: String, permit: GuestChatDispatchPermit?, approvedID: String?) async throws -> MeetingWorkspaceEvent.Status {
        guard let native = adapter?.currentNativeEngine else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable before connecting."))
        }
        if let approvedID, let permit {
            try await native.sendAttributedChat(text, id: approvedID, permit: permit)
            return permit.didDispatch ? .accepted : .cancelled
        }
        _ = try await native.sendChatMessage(text)
        return .sent
    }

    func classifyError(_ error: Error, permit: GuestChatDispatchPermit?, currentStatus: MeetingWorkspaceEvent.Status?) -> MeetingWorkspaceEvent.Status {
        if let permit, !permit.didDispatch {
            return currentStatus == .cancelled ? .cancelled : .failed
        }
        if case GuestTransportError.server = error { return .failed }
        if case MeetingSessionError.unavailable = error { return .failed }
        return .unknown
    }

    func retry(entry: ChatEntry) async throws {
        try await send(entry.text)
    }

    func sendApproved(_ text: String, id: String, permit: GuestChatDispatchPermit?) async -> MeetingWorkspaceEvent.Status {
        do {
            return try await send(text, permit: permit, approvedID: id)
        } catch {
            return classifyError(error, permit: permit, currentStatus: nil)
        }
    }

    func loadChatHistory() async throws {
        guard let native = adapter?.currentNativeEngine else { return }
        do { try await native.loadChatHistory() }
        catch GuestHistoryError.busy {}
    }
}

@MainActor final class GuestReactionService: MeetingReactionService {
    private weak var adapter: GuestAdapter?

    init(adapter: GuestAdapter) {
        self.adapter = adapter
    }

    var canSendReactions: Bool {
        adapter.map { $0.snapshot.phase == .connected && $0.guestSnapshot.permissions.canSendReaction } ?? false
    }

    var supportsApprovedCorrelation: Bool { true }

    func sendReaction(_ kind: MeetingReaction, approvedID: String?) async throws {
        _ = approvedID
        guard let wire = GuestMeetingReaction.allCases.first(where: { $0.symbol == kind.emoji }) else { return }
        guard let native = adapter?.currentNativeEngine else {
            throw MeetingSessionError.unavailable(L("Reactions are unavailable before connecting."))
        }
        try await native.sendReaction(wire)
    }
}

@MainActor final class GuestTranscriptService: MeetingTranscriptService {
    private weak var adapter: GuestAdapter?

    init(adapter: GuestAdapter) {
        self.adapter = adapter
    }

    var status: GuestMeetingSnapshot.TranscriptionStatus { adapter?.guestSnapshot.transcriptionStatus ?? .unknown }
    var canView: Bool { adapter?.guestSnapshot.permissions.canViewTranscript == true }
    var canManage: Bool { adapter?.guestSnapshot.permissions.canManageTranscript == true }
    var messages: [GuestMeetingMessage] { adapter?.guestSnapshot.transcript ?? [] }

    func setEnabled(_ enabled: Bool) async throws {
        guard let native = adapter?.currentNativeEngine else {
            throw MeetingSessionError.unavailable(L("Live transcription controls are unavailable before connecting."))
        }
        try await native.setTranscriptionEnabled(enabled)
    }

    func loadTranscriptHistory() async throws {
        guard let native = adapter?.currentNativeEngine else { return }
        do { try await native.loadTranscriptHistory() }
        catch GuestHistoryError.busy {}
    }

    func retryInitialTranscriptHistory() {
        adapter?.retryInitialTranscriptHistory()
    }
}

@MainActor final class GuestParticipationService: MeetingParticipationService {
    private weak var adapter: GuestAdapter?

    init(adapter: GuestAdapter) {
        self.adapter = adapter
    }

    var connectionIdentity: MeetingConnectionIdentity? { adapter?.connectionIdentity }
    var roomScope: (room: String, group: String)? { adapter?.currentNativeEngine?.participationRoomScope }
    var voiceMicrophoneAuthorized: Bool { adapter?.participationVoiceMicrophoneAuthorized == true }
    var usesSharedOutput: Bool { adapter?.participationVoiceUsesSharedOutput == true }
    var senderPhysicallyMuted: Bool { adapter?.participationSenderPhysicallyMuted ?? true }
    var hasVoiceGraph: Bool { adapter?.hasParticipationVoiceGraph == true }

    func setVoiceGate(open: Bool) -> Bool {
        adapter?.setParticipationVoiceGate(open: open) == true
    }

    func prepareVoiceAudio(_ permit: GuestAutonomousVoicePlayback) async -> Bool {
        guard let native = adapter?.currentNativeEngine else { return false }
        return await native.prepareParticipationVoiceAudio(permit)
    }

    func borrowVoiceSender(_ permit: GuestAutonomousVoicePlayback) async -> Bool {
        guard let native = adapter?.currentNativeEngine else { return false }
        return await native.borrowParticipationVoiceSender(permit)
    }

    func restoreVoiceSender(_ permit: GuestAutonomousVoicePlayback) async -> Bool {
        guard let native = adapter?.currentNativeEngine else { return false }
        return await native.restoreParticipationVoiceSender(permit)
    }

    func playVoice(_ buffer: AVAudioPCMBuffer, permit: GuestAutonomousVoicePlayback,
                   canStart: @escaping @MainActor () -> Bool, localGain: @escaping @MainActor () -> Float?,
                   onStarted: @escaping @MainActor () -> Void) async -> GuestAutonomousVoicePlayback.Outcome {
        await adapter?.playParticipationVoice(buffer, permit: permit, canStart: canStart, localGain: localGain, onStarted: onStarted) ?? .notStarted
    }

    func sendAttributedChat(_ text: String, id: String, permit: GuestChatDispatchPermit) async throws {
        guard let native = adapter?.currentNativeEngine else {
            throw MeetingSessionError.unavailable(L("Chat is unavailable before connecting."))
        }
        try await native.sendAttributedChat(text, id: id, permit: permit)
    }
}
