import Foundation

/// Recovery follows transport changes, never participant mute state or audio silence.
public struct CallNetworkRecovery {
    public enum Action: Equatable { case restart, giveUp }
    public private(set) var isNetworkAvailable = true
    public private(set) var hasConnected = false
    public private(set) var hasAttemptInFlight = false
    public private(set) var requiresRecovery = false
    public var awaitingTransport: Bool {
        requiresRecovery && isNetworkAvailable && !hasAttemptInFlight
    }
    private var due: TimeInterval?
    private var attempts = 0
    private var retryNotBefore: TimeInterval = 0

    public init() {}
    public mutating func connected() { hasConnected = true }

    public mutating func pathChanged(available: Bool, at now: TimeInterval) {
        // A satisfied path's interface set can change while ICE continues to
        // carry the meeting. The transport watchdog handles a real stall.
        guard available != isNetworkAvailable else { return }
        isNetworkAvailable = available
        guard hasConnected else { return }
        requiresRecovery = true
        // Give the SDK time to migrate its existing transport, including time
        // to verify progress on the new route before considering a rebuild.
        due = available ? now + 8 : nil
    }

    public mutating func sdkReconnecting(at now: TimeInterval) {
        guard hasConnected, !requiresRecovery else { return }
        requiresRecovery = true
        due = now + 8 // Give the SDK's own reconnection a chance first.
    }

    /// The media transport stopped while signalling still looked active. The SDK has
    /// already had its chance (the stall limits), so the rebuild is due immediately.
    public mutating func mediaStalled(at now: TimeInterval) {
        guard hasConnected, !requiresRecovery else { return }
        requiresRecovery = true
        due = now
    }

    public mutating func transportRestored() {
        guard awaitingTransport else { return }
        clearRecovery()
    }

    private mutating func clearRecovery() {
        requiresRecovery = false
        due = nil
        attempts = 0
        retryNotBefore = 0
    }

    public func canAttempt(at now: TimeInterval, blocked: Bool) -> Bool {
        requiresRecovery && isNetworkAvailable && !blocked && !hasAttemptInFlight && now >= retryNotBefore &&
            due.map { now >= $0 } == true
    }

    public mutating func nextAction(at now: TimeInterval, blocked: Bool,
                                    serviceReachable: Bool = true) -> Action? {
        guard serviceReachable, canAttempt(at: now, blocked: blocked) else { return nil }
        guard attempts < 3 else { return .giveUp }
        attempts += 1
        hasAttemptInFlight = true
        return .restart
    }

    public mutating func attemptFinished(succeeded: Bool, at now: TimeInterval) {
        guard hasAttemptInFlight else { return }
        hasAttemptInFlight = false
        if succeeded && isNetworkAvailable {
            clearRecovery()
        } else if !succeeded {
            retryNotBefore = now + min(pow(2, Double(attempts)), 8)
        }
    }
}
