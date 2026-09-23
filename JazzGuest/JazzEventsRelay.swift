import Foundation
import JazzSDK

enum JazzEvent {
    case joining
    case joined
    case failed
    case canceled
    case left
    case evicted
}

final class JazzEventsRelay: JazzEventsListener {
    var onEvent: ((JazzEvent) -> Void)?

    private func deliver(_ event: JazzEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    func onStartJoiningConference() { deliver(.joining) }
    func onConferenceJoined(room: JazzRoom) { deliver(.joined) }
    func onConferenceFailed() { deliver(.failed) }
    func onConferenceCanceled() { deliver(.canceled) }
    func onConferenceLeft() { deliver(.left) }
    func onEvicted(reason: JazzConferenceEvictionReason) { deliver(.evicted) }
}
