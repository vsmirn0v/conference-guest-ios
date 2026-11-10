#if DEBUG
import Foundation

/// Diagnostic admission only. Connected transports are required before a
/// microphone action can measure delivery to the independent receiver.
enum StartupTransportReadiness {
    /// Query brackets bound observation, not the native report's own age.
    static func queryBracketsConfirmed(publisherStarted: Double, publisherCompleted: Double,
                                      receiverStarted: Double, receiverCompleted: Double,
                                      baselineCompleted: Double) -> Bool {
        let times = [publisherStarted, publisherCompleted, receiverStarted, receiverCompleted, baselineCompleted]
        return times.allSatisfy { $0.isFinite && $0 > 0 } &&
            zip(times, times.dropFirst()).allSatisfy { $0 <= $1 } &&
            baselineCompleted - publisherStarted < 0.25 &&
            baselineCompleted - receiverStarted < 0.25
    }

    static func confirmed(_ summary: [String: Any]) -> Bool {
        guard summary["statsAvailable"] as? Bool == true,
              let rows = summary["rows"] as? [[String: Any]] else { return false }
        let transports = rows.filter { $0["type"] as? String == "transport" }
        let pairs = Set(rows.filter { $0["type"] as? String == "candidate-pair" }
            .compactMap { $0["id"] as? String })
        return !transports.isEmpty && transports.allSatisfy { transport in
            guard transport["dtlsState"] as? String == "connected",
                  let ice = transport["iceState"] as? String,
                  ice == "connected" || ice == "completed",
                  let pair = transport["selectedCandidatePairId"] as? String,
                  !pair.isEmpty, pairs.contains(pair),
                  let bytes = transport["bytesReceived"] as? NSNumber,
                  bytes.doubleValue.isFinite, bytes.doubleValue > 0 else { return false }
            return true
        }
    }
}
#endif
