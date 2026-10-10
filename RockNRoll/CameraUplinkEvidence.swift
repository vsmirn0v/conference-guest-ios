/// Qualifies transport samples independently of wall-clock policy hysteresis.
/// Missing or replayed samples break continuity without forgetting replay history.
struct CameraUplinkEvidence {
    private var identity: String?
    private var timestamp: Double?
    private var poorCount = 0

    mutating func reset() {
        identity = nil; timestamp = nil; poorCount = 0
    }

    /// `changed` identifies a new source/transport, including its first sample.
    /// It remains true for a replacement whose timestamp is invalid.
    mutating func consume(_ sample: CameraUplinkSample?) -> (network: CameraQualityPolicy.Network, changed: Bool) {
        guard let sample else { poorCount = 0; return (.unknown, false) }
        let changed = identity != sample.identity
        if changed {
            identity = sample.identity; timestamp = nil; poorCount = 0
        }
        guard sample.timestamp.isFinite,
              timestamp.map({ sample.timestamp > $0 }) ?? true else {
            poorCount = 0
            return (.unknown, changed)
        }
        timestamp = sample.timestamp
        poorCount = sample.network == .poor ? min(2, poorCount + 1) : 0
        return (sample.network == .poor && poorCount < 2 ? .ordinary : sample.network, changed)
    }
}
