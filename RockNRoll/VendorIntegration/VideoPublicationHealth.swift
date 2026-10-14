import Foundation

/// A freshly resumed active encoder may report zero before its first frame.
/// Require stable, repeated evidence rather than treating one sample as failure.
struct VideoPublicationStartup {
    struct Sample { let stream: String; let encoded: Int64; var bandwidthLimited = false }
    enum Result: Equatable { case waiting, working, stalled }
    private var zeroStream: String?
    private var zeroSince: TimeInterval?
    mutating func reset() { zeroStream = nil; zeroSince = nil }
    mutating func observe(_ sample: Sample, at now: TimeInterval) -> Result {
        guard now.isFinite, sample.encoded >= 0, !sample.stream.isEmpty else { reset(); return .waiting }
        if sample.encoded > 0 { reset(); return .working }
        if sample.bandwidthLimited { reset(); return .waiting }
        guard zeroStream == sample.stream, let previous = zeroSince, now >= previous else {
            zeroStream = sample.stream; zeroSince = now
            return .waiting
        }
        return now - previous >= 4 ? .stalled : .waiting
    }
}

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
