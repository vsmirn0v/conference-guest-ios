import Foundation

/// Recovery follows transport changes, never participant mute state or audio silence.
public struct CallNetworkRecovery {
    public enum Action: Equatable { case restart, giveUp }
    private enum Reason { case path, sdk }
    public private(set) var isNetworkAvailable = true
    public private(set) var hasConnected = false
    public private(set) var hasAttemptInFlight = false
    public var requiresRecovery: Bool { reason != nil }
    private var receivedPath = false
    private var reason: Reason?
    private var due: TimeInterval?
    private var attempts = 0
    private var revision: UInt64 = 0
    private var attemptRevision: UInt64 = 0

    public init() {}
    public mutating func connected() { hasConnected = true }

    public mutating func pathChanged(available: Bool, changed: Bool, at now: TimeInterval) {
        let interrupted = !available || (receivedPath && (!isNetworkAvailable || changed))
        receivedPath = true
        isNetworkAvailable = available
        guard hasConnected, interrupted else { return }
        revision &+= 1
        reason = .path
        due = available ? now + 2 : nil
    }

    public mutating func sdkReconnecting(at now: TimeInterval) {
        guard hasConnected, reason == nil else { return }
        reason = .sdk
        due = now + 8 // Give the SDK's own reconnection a chance first.
    }

    public mutating func sdkMediaRestored() {
        guard !hasAttemptInFlight, reason == .sdk else { return }
        reason = nil; due = nil; attempts = 0
    }

    public func canAttempt(at now: TimeInterval, blocked: Bool) -> Bool {
        requiresRecovery && isNetworkAvailable && !blocked && !hasAttemptInFlight &&
            due.map { now >= $0 } == true
    }

    public mutating func nextAction(at now: TimeInterval, blocked: Bool,
                                    serviceReachable: Bool = true) -> Action? {
        guard serviceReachable, canAttempt(at: now, blocked: blocked) else { return nil }
        guard attempts < 3 else { return .giveUp }
        attempts += 1
        attemptRevision = revision
        hasAttemptInFlight = true
        return .restart
    }

    public mutating func attemptFinished(succeeded: Bool, at now: TimeInterval) {
        guard hasAttemptInFlight else { return }
        hasAttemptInFlight = false
        if succeeded {
            attempts = 0
            if revision == attemptRevision {
                reason = nil; due = nil
            } else {
                due = isNetworkAvailable ? now + 2 : nil
            }
        } else {
            due = isNetworkAvailable ? now + min(pow(2, Double(attempts)), 8) : nil
        }
    }
}
