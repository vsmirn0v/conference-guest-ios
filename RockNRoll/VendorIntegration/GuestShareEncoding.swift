import Foundation
import WebRTC
import ConferenceCore

extension GuestMicrophoneProbe {
    /// One bounded stats query for the identified content sender. No timer or
    /// frame work is installed by opening the Share configuration.
    static func shareEncoding(trackID: String) async -> ShareEncodingReport? {
        for peer in GuestPeerRegistry.snapshot() where peer.connectionState == .connected {
            guard let sender = peer.senders.first(where: { $0.track?.trackId == trackID }),
                  let mid = peer.transceivers.first(where: { $0.sender.senderId == sender.senderId })?.mid else { continue }
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics(for: sender) { completion.resume(returning: $0) }
            }
            guard peer.connectionState == .connected, sender.track?.trackId == trackID,
                  peer.transceivers.first(where: { $0.mid == mid })?.sender.senderId == sender.senderId else { return nil }
            guard let outbound = report.statistics.values.first(where: {
                $0.type == "outbound-rtp" && $0.values["mid"] as? String == mid &&
                (($0.values["framesEncoded"] as? NSNumber)?.intValue ?? 0) > 0
            }), let codecID = outbound.values["codecId"] as? String,
                  let mime = report.statistics[codecID]?.values["mimeType"] as? String,
                  mime.lowercased().hasPrefix("video/") else { return nil }
            return .measured(codec: String(mime.dropFirst(6)), powerEfficient: outbound.values["powerEfficientEncoder"] as? Bool,
                             encoder: outbound.values["encoderImplementation"] as? String)
        }
        return nil
    }
}
