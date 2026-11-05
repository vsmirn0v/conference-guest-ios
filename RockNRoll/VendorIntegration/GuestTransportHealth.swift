import ConferenceCore
import Foundation
import WebRTC

/// Reads transport liveness from the current attempt's peer connections for the
/// media transport watchdog, plus a small summary for saved diagnostics.
/// The summary holds states, counters and candidate kinds only, never addresses.
enum GuestTransportHealth {
    struct Result {
        var sample: MediaTransportWatchdog.Sample
        var summary: [[String: Any]]
    }

    static func sample(scope: GuestPeerRegistry.Scope) async -> Result {
        var result = Result(sample: .init(transports: 0, ice: .other, inbound: 0), summary: [])
        var states: [MediaTransportWatchdog.ICE] = []
        for peer in GuestPeerRegistry.peers(in: scope) {
            let report: RTCStatisticsReport = await withCheckedContinuation { completion in
                peer.statistics { completion.resume(returning: $0) }
            }
            guard peer.connectionState != .closed else { continue }
            let ice = map(peer.iceConnectionState)
            states.append(ice)
            var inbound: Int64 = 0
            var row: [String: Any] = ["ice": name(peer.iceConnectionState), "connection": peer.connectionState.rawValue]
            for entry in report.statistics.values {
                switch entry.type {
                case "candidate-pair":
                    inbound += number(entry, "bytesReceived") + number(entry, "responsesReceived") + number(entry, "requestsReceived")
                case "transport":
                    guard let pairID = entry.values["selectedCandidatePairId"] as? String,
                          let pair = report.statistics[pairID] else { continue }
                    row["rttMs"] = Int(((pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue ?? 0) * 1000)
                    row["pairReceivedBytes"] = number(pair, "bytesReceived")
                    row["consentResponses"] = number(pair, "responsesReceived")
                    if let localID = pair.values["localCandidateId"] as? String, let local = report.statistics[localID] {
                        for key in ["candidateType", "protocol", "networkType", "relayProtocol"] {
                            if let value = local.values[key] as? String { row["local." + key] = value }
                        }
                    }
                    if let remoteID = pair.values["remoteCandidateId"] as? String, let remote = report.statistics[remoteID],
                       let type = remote.values["candidateType"] as? String { row["remote.candidateType"] = type }
                case "inbound-rtp" where entry.values["kind"] as? String == "audio":
                    row["audioStreams"] = (row["audioStreams"] as? Int ?? 0) + 1
                    for key in ["packetsReceived", "packetsLost", "concealedSamples", "totalSamplesReceived"] {
                        row["audio." + key] = (row["audio." + key] as? Int64 ?? 0) + number(entry, key)
                    }
                default: break
                }
            }
            row["inbound"] = inbound
            result.sample.inbound += inbound
            result.summary.append(row)
        }
        result.sample.transports = states.count
        result.sample.ice = states.contains(.failed) ? .failed : states.contains(.disconnected) ? .disconnected :
            states.contains(.checking) ? .checking : states.contains(.connected) ? .connected : .other
        return result
    }

    private static func number(_ entry: RTCStatistics, _ key: String) -> Int64 {
        (entry.values[key] as? NSNumber)?.int64Value ?? 0
    }

    private static func map(_ state: RTCIceConnectionState) -> MediaTransportWatchdog.ICE {
        switch state {
        case .connected, .completed: .connected
        case .new, .checking: .checking
        case .disconnected: .disconnected
        case .failed: .failed
        default: .other
        }
    }

    private static func name(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        default: "unknown"
        }
    }
}
