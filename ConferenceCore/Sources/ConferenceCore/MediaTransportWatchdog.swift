import Foundation

/// Detects a media transport that died while signalling still reports the meeting active,
/// as happens when a phone moves between cell towers. It watches transport liveness only:
/// ICE state and inbound transport progress (packets and connectivity-check responses,
/// which keep arriving every few seconds even when nobody speaks), never audio silence.
public struct MediaTransportWatchdog {
    public enum ICE: Equatable, Sendable { case connected, checking, disconnected, failed, other }
    public enum Stall: String, Equatable, Sendable {
        case iceFailed = "ice-failed", iceDisconnected = "ice-disconnected", noInbound = "no-inbound"
    }
    public struct Sample: Equatable, Sendable {
        /// Open peer connections of the current media attempt.
        public var transports: Int
        /// The worst ICE state among them.
        public var ice: ICE
        /// Monotonic per transport: received bytes plus connectivity checks, summed.
        public var inbound: Int64
        public init(transports: Int, ice: ICE, inbound: Int64) {
            self.transports = transports; self.ice = ice; self.inbound = inbound
        }
    }

    public let silenceLimit: TimeInterval
    public let disconnectLimit: TimeInterval
    /// A longer gap between samples means the process was suspended; start over.
    public let sampleGapLimit: TimeInterval
    private var lastSampleAt: TimeInterval?
    private var lastInbound: Int64?
    private var lastAdvanceAt: TimeInterval?
    private var disconnectedSince: TimeInterval?
    private var reported = false

    public init(silenceLimit: TimeInterval = 10, disconnectLimit: TimeInterval = 8, sampleGapLimit: TimeInterval = 6) {
        self.silenceLimit = silenceLimit; self.disconnectLimit = disconnectLimit; self.sampleGapLimit = sampleGapLimit
    }

    /// Call whenever the transport is not expected to be live (joining, rebuilding, on hold).
    public mutating func reset() {
        lastSampleAt = nil; lastInbound = nil; lastAdvanceAt = nil; disconnectedSince = nil; reported = false
    }

    /// Reports a stall once; `reset()` re-arms it.
    public mutating func observe(_ sample: Sample, at now: TimeInterval) -> Stall? {
        guard sample.transports > 0 else { reset(); return nil }
        if let last = lastSampleAt, now - last > sampleGapLimit { reset() }
        lastSampleAt = now
        guard !reported else { return nil }
        // Any change counts as progress: a replaced transport restarts its counters.
        if sample.inbound != lastInbound { lastAdvanceAt = now }
        lastInbound = sample.inbound
        switch sample.ice {
        case .failed:
            return report(.iceFailed)
        case .disconnected:
            let since = disconnectedSince ?? now
            disconnectedSince = since
            if now - since >= disconnectLimit { return report(.iceDisconnected) }
        default:
            disconnectedSince = nil
        }
        if let advanced = lastAdvanceAt, now - advanced >= silenceLimit { return report(.noInbound) }
        return nil
    }

    private mutating func report(_ stall: Stall) -> Stall { reported = true; return stall }
}
