import Combine
import ConferenceCore
import Foundation

extension MeetingReaction {
    var emoji: String {
        switch self { case .like: return "👍"; case .dislike: return "👎" }
    }
    var title: String {
        switch self { case .like: return L("Like"); case .dislike: return L("Dislike") }
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
    @Published var cameraStatus: CameraStatus = .off
    @Published private(set) var generation = UUID()
    @Published var shareCameraReactions: Bool {
        didSet { preferences?.set(shareCameraReactions, forKey: Self.preferenceKey); onPreferenceChanged?() }
    }
    @Published private(set) var submitted: MeetingReaction?
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
        guard canSend, source == .manual || (shareCameraReactions && (cameraStatus == .ready || cameraStatus == .systemDisabled)) else { return false }
        // Mark camera events even when throttled; extending an effect must not replay it.
        guard gate.accept(source: source, now: clock(), effectID: effectID), sender?(reaction) == true else { return false }
        submitted = reaction
        return true
    }
    func begin() {
        generation = UUID(); active = true; available = false; ready = false
        gate = ReactionSendGate(); submitted = nil; cameraStatus = .off; sender = nil
    }
    func end() {
        generation = UUID(); active = false; available = false; ready = false
        sender = nil; onPreferenceChanged = nil; gate = ReactionSendGate(); cameraStatus = .paused
    }
}
