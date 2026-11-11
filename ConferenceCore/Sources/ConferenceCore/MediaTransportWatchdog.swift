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

/// A join callback can arrive while ICE is still checking. Confirm a continuous
/// run of connected samples and fresh traffic before resetting the retry budget.
public struct MediaTransportRecoveryConfirmation {
    public struct Pair: Hashable {
        public let peer: UUID
        public let pair: String

        public init(peer: UUID, pair: String) {
            self.peer = peer
            self.pair = pair
        }
    }

    private var connectedSince: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var baseline: [Pair: Int64]?
    private var previous: [Pair: Int64] = [:]

    public init() {}

    /// Empty input means at least one open peer lacks a connected, selected pair.
    public mutating func observe(_ selectedPairs: [Pair: Int64], at now: TimeInterval) -> Bool {
        guard !selectedPairs.isEmpty else {
            self = Self()
            return false
        }
        if let lastSampleAt, now < lastSampleAt || now - lastSampleAt > 6 ||
            previous.count != selectedPairs.count || selectedPairs.contains(where: { pair, inbound in
                previous[pair].map { inbound < $0 } ?? true
            }) {
            self = Self()
        }
        lastSampleAt = now
        previous = selectedPairs
        guard let connectedSince, let baseline else {
            self.connectedSince = now
            self.baseline = selectedPairs
            return false
        }
        return now - connectedSince >= 4 && selectedPairs.allSatisfy { pair, inbound in
            baseline[pair].map { inbound > $0 } ?? false
        }
    }
}
