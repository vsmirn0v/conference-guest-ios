import Foundation

/// Counts available-audio time, including when the app's timer is suspended.
public struct CallMediaRecoveryBudget {
    private var remaining: TimeInterval
    private var availableSince: TimeInterval?

    public init(seconds: TimeInterval) {
        precondition(seconds.isFinite && seconds >= 0)
        remaining = seconds
    }

    public mutating func setAvailable(_ available: Bool, at now: TimeInterval) {
        remaining = secondsRemaining(at: now)
        availableSince = available ? now : nil
    }

    public func secondsRemaining(at now: TimeInterval) -> TimeInterval {
        max(0, remaining - (availableSince.map { max(0, now - $0) } ?? 0))
    }
}
