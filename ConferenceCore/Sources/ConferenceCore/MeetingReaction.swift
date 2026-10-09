import Foundation

public enum MeetingReaction: String, CaseIterable, Codable, Sendable {
    case heart, like, smile, applause, fire, wave, handshake, thanks, thinking, sad, dislike, surprise
}

/// A reaction is transient: throttle it now rather than queueing it for later.
public struct ReactionSendGate {
    public enum Source { case manual, camera }
    private var lastSend: TimeInterval?
    private var seen = Set<String>()
    private var order: [String] = []
    public init() {}

    public mutating func accept(source: Source, now: TimeInterval, effectID: String? = nil) -> Bool {
        guard now.isFinite else { return false }
        if source == .camera {
            guard let effectID, !effectID.isEmpty, seen.insert(effectID).inserted else { return false }
            order.append(effectID)
            if order.count > 64 { seen.remove(order.removeFirst()) }
        }
        let interval = source == .manual ? 0.35 : 3.0
        guard lastSend.map({ now - $0 >= interval }) ?? true else { return false }
        lastSend = now
        return true
    }
}
