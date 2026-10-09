import Foundation

/// Require advancing input and a sustained encoding stall. Capture pauses,
/// bandwidth suspension, retired streams and counter resets are not failures.
struct VideoPublicationHealth {
    struct Sample {
        let stream: String
        let captured: Int64
        let encoded: Int64
        let bandwidthLimited: Bool
    }
    private var previous: Sample?
    private var stalledSince: TimeInterval?
    mutating func reset() { previous = nil; stalledSince = nil }
    mutating func stalled(_ sample: Sample, at now: TimeInterval) -> Bool {
        defer { previous = sample }
        guard let previous, previous.stream == sample.stream,
              sample.captured >= previous.captured, sample.encoded >= previous.encoded,
              !sample.bandwidthLimited, sample.captured > previous.captured,
              sample.encoded == previous.encoded else {
            stalledSince = nil; return false
        }
        if stalledSince == nil { stalledSince = now }
        return now - (stalledSince ?? now) >= 8
    }
}
