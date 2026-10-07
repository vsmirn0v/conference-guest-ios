import AVFoundation
import ConferenceCore

/// Observe system metadata on an explicitly owned capture device, never its frames.
@MainActor
final class CameraReactionObserver {
    private var observation: NSKeyValueObservation?
    private var device: AVCaptureDevice?
    private var sourceID: String?
    private var epoch = UUID()
    private var seen = Set<String>()
    var onReaction: ((MeetingReaction, String) -> Void)?

    func bind(_ device: AVCaptureDevice, sourceID: String) {
        guard self.sourceID != sourceID else { return }
        stop()
        guard #available(iOS 17.0, *) else { return }
        self.device = device
        self.sourceID = sourceID
        #if DEBUG
        GuestReactionFixtureActions.trace("Observe camera metadata")
        #endif
        let generation = epoch
        // Existing effects predate this publication/preference and are not new actions.
        seen = Set(device.reactionEffectsInProgress.compactMap { Self.identity($0, deviceID: device.uniqueID) })
        observation = device.observe(\.reactionEffectsInProgress, options: [.new]) { [weak self] device, change in
            let states = change.newValue ?? []
            #if DEBUG
            GuestReactionFixtureActions.trace("Metadata: \(states.map { "\($0.reactionType.rawValue) start=\($0.startTime.isValid) end=\($0.endTime.isValid)" })")
            #endif
            let events = states.compactMap { state -> (MeetingReaction, String)? in
                guard state.endTime.isValid == false,
                      let kind = Self.reaction(state.reactionType),
                      let id = Self.identity(state, deviceID: device.uniqueID) else { return nil }
                return (kind, id)
            }
            Task { @MainActor [weak self] in
                guard let self, self.epoch == generation else { return }
                for (kind, id) in events where self.seen.insert(id).inserted {
                    self.onReaction?(kind, "\(generation.uuidString):\(id)")
                }
                if self.seen.count > 128 {
                    self.seen = Set(events.map(\.1))
                }
            }
        }
    }
    @available(iOS 17.0, *)
    nonisolated static func reaction(_ type: AVCaptureReactionType) -> MeetingReaction? {
        switch type { case .thumbsUp: return .like; case .thumbsDown: return .dislike; default: return nil }
    }
    @available(iOS 17.0, *)
    nonisolated private static func identity(_ state: AVCaptureReactionEffectState, deviceID: String) -> String? {
        let time = state.startTime
        guard time.isValid, time.isNumeric else { return nil }
        return "\(deviceID):\(state.reactionType.rawValue):\(time.value)/\(time.timescale):\(time.epoch)"
    }
    func stop() {
        guard observation != nil || sourceID != nil || !seen.isEmpty else { return }
        #if DEBUG
        GuestReactionFixtureActions.trace("Retire camera metadata")
        #endif
        observation = nil; device = nil; sourceID = nil; epoch = UUID(); seen = []
    }
}
