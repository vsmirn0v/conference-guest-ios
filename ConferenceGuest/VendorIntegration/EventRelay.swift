import Foundation
import JazzSDK

final class EventRelay: JazzEventsListener {
    var onEvent: ((CallEvent) -> Void)?

    private func deliver(_ event: CallEvent) {
        DispatchQueue.main.async { [weak self] in self?.onEvent?(event) }
    }

    func onStartJoiningConference() { deliver(.joining) }
    func onConferenceJoined(room: JazzRoom) { deliver(.joined) }
    func onConferenceFailed() { deliver(.failed) }
    func onConferenceCanceled() { deliver(.canceled) }
    func onConferenceLeft() { deliver(.left) }
    func onEvicted(reason: JazzConferenceEvictionReason) { deliver(.evicted) }
}
