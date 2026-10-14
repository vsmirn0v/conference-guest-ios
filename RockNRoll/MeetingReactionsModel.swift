import Combine
import ConferenceCore
import Foundation

extension MeetingReaction {
    var emoji: String {
        switch self {
        case .like: return "👍"; case .dislike: return "👎"
        case .applause: return "🎉"; case .smile: return "😂"; case .surprise: return "😱"
        case .heart: return "❤️"; case .fire: return "🔥"; case .wave: return "👋"
        case .handshake: return "🤝"; case .thanks: return "🙏"; case .thinking: return "🤔"; case .sad: return "😢"
        }
    }
    var title: String {
        switch self {
        case .like: return L("Like"); case .dislike: return L("Dislike")
        case .applause: return L("Celebrate"); case .smile: return L("Laugh"); case .surprise: return L("Surprise")
        case .heart: return L("Heart"); case .fire: return L("Fire"); case .wave: return L("Wave")
        case .handshake: return L("Handshake"); case .thanks: return L("Thanks")
        case .thinking: return L("Thinking"); case .sad: return L("Sad")
        }
    }
}

@MainActor
final class MeetingReactionsModel: ObservableObject {
    enum CameraStatus: Equatable {
        case off, unavailable, systemDisabled, ready, paused
        var title: String {
            switch self {
            case .off: return L("Turn on video to use")
            case .unavailable: return L("Unavailable with this camera")
            case .systemDisabled: return L("Enable Reactions in system camera controls")
            case .ready: return L("Ready")
            case .paused: return L("Camera reactions paused")
            }
        }
    }
    @Published private(set) var active = true
    @Published var available = false
    @Published var ready = false
    @Published var supportedReactions = MeetingReaction.allCases
    @Published var cameraStatus: CameraStatus = .off
    @Published private(set) var generation = UUID()
    @Published var shareCameraReactions: Bool {
        didSet { preferences?.set(shareCameraReactions, forKey: Self.preferenceKey); onPreferenceChanged?() }
    }
    @Published private(set) var submitted: MeetingReaction?
    enum Feedback: Equatable {
        case queued(MeetingReaction), transmitted(MeetingReaction), failed(MeetingReaction)
        var title: String {
            switch self {
            case .queued(let kind): return L("Sending %@…", kind.title)
            case .transmitted(let kind): return L("Sent %@", kind.title)
            case .failed(let kind): return L("Could not send %@", kind.title)
            }
        }
    }
    @Published private(set) var feedback: Feedback?
    private var latestSubmission: (id: String, kind: MeetingReaction)?
    var onViewHistory: (() -> Void)?
    var sender: ((MeetingReaction) -> Bool)?
    var onPreferenceChanged: (() -> Void)?
    private let preferences: UserDefaults?
    private let clock: () -> TimeInterval
    private var gate = ReactionSendGate()
    private static let preferenceKey = "meeting.share-camera-reactions"
    var canSend: Bool { active && available && ready && sender != nil }

    init(preferences: UserDefaults? = nil, clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.preferences = preferences; self.clock = clock
        shareCameraReactions = preferences?.bool(forKey: Self.preferenceKey) ?? false
    }
    func setForwarding(_ enabled: Bool) {
        shareCameraReactions = enabled
    }
    @discardableResult func send(_ reaction: MeetingReaction, source: ReactionSendGate.Source = .manual,
                                 effectID: String? = nil) -> Bool {
        guard canSend, supportedReactions.contains(reaction),
              source == .manual || (shareCameraReactions && (cameraStatus == .ready || cameraStatus == .systemDisabled)) else { return false }
        // Mark camera events even when throttled; extending an effect must not replay it.
        guard gate.accept(source: source, now: clock(), effectID: effectID) else { return false }
        let previousID = latestSubmission?.id
        guard sender?(reaction) == true else { return false }
        if previousID == latestSubmission?.id { trackSubmission(reaction, id: UUID().uuidString) }
        submitted = reaction
        return true
    }
    func trackSubmission(_ kind: MeetingReaction, id: String) {
        latestSubmission = (id, kind); feedback = .queued(kind)
    }
    func finishSubmission(id: String, succeeded: Bool) {
        guard active, let latestSubmission, latestSubmission.id == id else { return }
        feedback = succeeded ? .transmitted(latestSubmission.kind) : .failed(latestSubmission.kind)
    }
    func begin() {
        generation = UUID(); active = true; available = false; ready = false
        gate = ReactionSendGate(); submitted = nil; feedback = nil; latestSubmission = nil; cameraStatus = .off; sender = nil
    }
    func end() {
        generation = UUID(); active = false; available = false; ready = false
        sender = nil; onPreferenceChanged = nil; onViewHistory = nil; gate = ReactionSendGate(); cameraStatus = .paused
        feedback = nil; latestSubmission = nil
    }
}
