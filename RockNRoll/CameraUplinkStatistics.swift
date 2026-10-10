import Foundation
import LiveKit

/// Typed RTP/ICE evidence. Only the camera's outbound IDs enter this adapter.
enum CameraUplinkStatistics {
    struct Record { let id: String; let type: String; let timestamp: Double; let values: [String: NSObject] }
    static func sample(records: [Record], cameraMID: String) -> CameraUplinkSample? {
        let outbound = records.filter {
            $0.type == "outbound-rtp" && $0.values["kind"] as? String == "video" &&
                $0.values["mid"] as? String == cameraMID &&
                (($0.values["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 0
        }
        guard !outbound.isEmpty else { return nil }
        let transports = Set(outbound.compactMap { $0.values["transportId"] as? String })
        let pairs = Set(records.filter { transports.contains($0.id) }.compactMap { $0.values["selectedCandidatePairId"] as? String })
        let pair = records.filter { $0.type == "candidate-pair" && pairs.contains($0.id) }
        let outboundIDs = Set(outbound.map(\.id))
        let feedback = records.filter { $0.type == "remote-inbound-rtp" && outboundIDs.contains($0.values["localId"] as? String ?? "") }
        let limited = outbound.contains { ["bandwidth", "cpu"].contains($0.values["qualityLimitationReason"] as? String ?? "") }
        let network = CameraUplinkSample.classify(limited: limited,
            roundTrip: pair.compactMap { ($0.values["currentRoundTripTime"] as? NSNumber)?.doubleValue }.max(),
            availableBitrate: pair.compactMap { ($0.values["availableOutgoingBitrate"] as? NSNumber)?.doubleValue }.min(),
            loss: feedback.compactMap { ($0.values["fractionLost"] as? NSNumber)?.doubleValue }.max())
        return CameraUplinkSample(identity: (outbound.map(\.id) + pair.map(\.id)).sorted().joined(separator: ","),
            timestamp: outbound.map(\.timestamp).max() ?? 0, network: network)
    }
    static func sample(_ stats: TrackStatistics) -> CameraUplinkSample? {
        let outbound = stats.outboundRtpStream.filter { ($0.framesEncoded ?? 0) > 0 }
        guard !outbound.isEmpty else { return nil }
        let pair = stats.iceCandidatePair.filter { $0.id == stats.transportStats?.selectedCandidatePairId }
        let ids = Set(outbound.map(\.id))
        let network = CameraUplinkSample.classify(
            limited: outbound.contains { $0.qualityLimitationReason == .bandwidth || $0.qualityLimitationReason == .cpu },
            roundTrip: pair.compactMap(\.currentRoundTripTime).max(),
            availableBitrate: pair.compactMap(\.availableOutgoingBitrate).min(),
            loss: stats.remoteInboundRtpStream.filter { ids.contains($0.localId ?? "") }.compactMap(\.fractionLost).max())
        return CameraUplinkSample(identity: (outbound.map(\.id) + pair.map(\.id)).sorted().joined(separator: ","),
            timestamp: outbound.map(\.timestamp).max() ?? 0, network: network)
    }
}
