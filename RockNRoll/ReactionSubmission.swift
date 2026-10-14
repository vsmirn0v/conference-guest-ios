import ConferenceCore
import Foundation

/// Submission enters history first; visual feedback waits for transport
/// acceptance. Session invalidation drops every outstanding completion.
@MainActor
final class ReactionSubmission {
    var onAccepted: ((MeetingReaction, String) -> Void)?
    var onTransmitted: ((MeetingReaction, String) -> Void)?
    var onFailed: ((String) -> Void)?
    private struct Pending { let kind: MeetingReaction; var submitted = false; var result: Bool? }
    private var pending: [String: Pending] = [:]
    private var stopped = false
    private let valid: () -> Bool
    init(valid: @escaping () -> Bool) { self.valid = valid }

    func send(_ kind: MeetingReaction, using submit: (@escaping (Bool) -> Void) -> Bool) -> Bool {
        guard !stopped, valid() else { return false }
        let id = UUID().uuidString
        pending[id] = Pending(kind: kind)
        guard submit({ [weak self] result in self?.complete(id, result: result) }), !stopped, valid() else {
            pending.removeValue(forKey: id); return false
        }
        onAccepted?(kind, id)
        guard var entry = pending[id] else { return true }
        entry.submitted = true; pending[id] = entry
        if let result = entry.result { complete(id, result: result) }
        return true
    }
    private func complete(_ id: String, result: Bool) {
        guard !stopped, valid(), var entry = pending[id] else { pending.removeValue(forKey: id); return }
        guard entry.submitted else { entry.result = result; pending[id] = entry; return }
        pending.removeValue(forKey: id)
        if result { onTransmitted?(entry.kind, id) } else { onFailed?(id) }
    }
    func stop() { stopped = true; pending = [:]; onAccepted = nil; onTransmitted = nil; onFailed = nil }
}
