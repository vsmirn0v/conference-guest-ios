import Foundation
import JazzSDK

final class EventRelay: JazzEventsListener {
    private let lock = NSLock()
    private var callback: ((CallEvent, JazzRoom?) -> Void)?
    private var mediaCallback: (() -> Void)?
    var onMediaConnected: (() -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return mediaCallback }
        set { lock.lock(); mediaCallback = newValue; lock.unlock() }
    }
    var onEvent: ((CallEvent, JazzRoom?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }

    static func matches(_ room: JazzRoom, _ expected: JazzRoom) -> Bool { room == expected }

    func deliver(_ event: CallEvent, room: JazzRoom? = nil) {
        let destination = onEvent
        DispatchQueue.main.async { destination?(event, room) }
    }
    func onStartJoiningConference() { deliver(.joining) }
    func onConferenceJoined(room: JazzRoom) { deliver(.joined, room: room) }
    func onConferenceFailed() { deliver(.failed) }
    func onConferenceCanceled() { deliver(.canceled) }
    func onConferenceLeft() { deliver(.left) }
    func onMediaConnectionEstablished(timeInterval: TimeInterval) {
        let destination = onMediaConnected
        DispatchQueue.main.async { destination?() }
    }
    func onEvicted(reason: JazzConferenceEvictionReason) { deliver(.evicted) }
}
