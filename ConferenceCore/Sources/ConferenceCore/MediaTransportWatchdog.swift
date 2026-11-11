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
        public let peer: UUID
        public let ice: ICE
        /// Received bytes and connectivity checks, keyed by selected candidate pair ID.
        public let selectedPairs: [String: Int64]

        public init(peer: UUID, ice: ICE, selectedPairs: [String: Int64]) {
            self.peer = peer
            self.ice = ice
            self.selectedPairs = selectedPairs
        }
    }

    private struct PairProgress {
        var inbound: Int64
        var lastAdvanceAt: TimeInterval
    }
    private struct PeerProgress {
        var disconnectedSince: TimeInterval?
        var pairs: [String: PairProgress] = [:]
    }

    public let silenceLimit: TimeInterval
    public let disconnectLimit: TimeInterval
    /// A longer gap between samples means the process was suspended; start over.
    public let sampleGapLimit: TimeInterval
    private var lastSampleAt: TimeInterval?
    private var peers: [UUID: PeerProgress] = [:]
    private var reported = false

    public init(silenceLimit: TimeInterval = 10, disconnectLimit: TimeInterval = 8, sampleGapLimit: TimeInterval = 6) {
        self.silenceLimit = silenceLimit; self.disconnectLimit = disconnectLimit; self.sampleGapLimit = sampleGapLimit
    }

    /// Call whenever the transport is not expected to be live (joining, rebuilding, on hold).
    public mutating func reset() {
        lastSampleAt = nil; peers.removeAll(); reported = false
    }

    /// Reports a stall once; `reset()` re-arms it.
    public mutating func observe(_ samples: [Sample], at now: TimeInterval) -> Stall? {
        guard !samples.isEmpty else { reset(); return nil }
        if let last = lastSampleAt, now < last || now - last > sampleGapLimit { reset() }
        lastSampleAt = now
        guard !reported else { return nil }
        if samples.contains(where: { $0.ice == .failed }) { return report(.iceFailed) }
        var currentPeers: [UUID: PeerProgress] = [:]
        for sample in samples {
            var peer = peers[sample.peer] ?? PeerProgress()
            if sample.ice == .disconnected {
                let since = peer.disconnectedSince ?? now
                peer.disconnectedSince = since
                if now - since >= disconnectLimit { return report(.iceDisconnected) }
            } else {
                peer.disconnectedSince = nil
            }
            var currentPairs: [String: PairProgress] = [:]
            if sample.ice == .connected {
                for (pairID, inbound) in sample.selectedPairs {
                    var pair = peer.pairs[pairID] ?? PairProgress(inbound: inbound, lastAdvanceAt: now)
                    if pair.inbound != inbound {
                        // A counter reset starts a fresh observation interval.
                        pair = PairProgress(inbound: inbound, lastAdvanceAt: now)
                    }
                    if now - pair.lastAdvanceAt >= silenceLimit { return report(.noInbound) }
                    currentPairs[pairID] = pair
                }
            }
            peer.pairs = currentPairs
            currentPeers[sample.peer] = peer
        }
        peers = currentPeers
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
