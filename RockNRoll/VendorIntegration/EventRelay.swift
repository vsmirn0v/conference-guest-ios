import Foundation
import JazzSDK

/// The SDK's unqualified Left/Inactive callbacks also describe local transport
/// teardown. Only a typed room-end/rejection may overrule interruption recovery.
struct GuestTerminationContext {
    var established: Bool
    var leaving: Bool
    var rebuilding: Bool
    var recoveringNetwork: Bool
    var recoveringAudio: Bool

    enum Resolution: Equatable { case recover, ignore, finish(CallEvent) }

    func resolve(_ event: CallEvent,
                 reason: JazzConferenceConnectionStage.TerminationReason? = nil) -> Resolution {
        if leaving { return .finish(.left) }
        if let reason {
            switch reason {
            case .kickedFromConference(.callEnded), .network(.roomClosed): return .finish(.left)
            case .kickedFromConference: return .finish(.evicted)
            case .network(.rejectedDueToConnectionProblem):
                return rebuilding ? .ignore : (established ? .recover : .finish(.failed))
            case .userCanceled:
                // terminateActiveConference() is also used by our media rebuild.
                break
            default: return .finish(.failed)
            }
        }
        if event == .evicted { return .finish(.evicted) }
        if rebuilding { return .ignore }
        if established && (recoveringAudio || recoveringNetwork) { return .recover }
        return .finish(event)
    }
}

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
