import ConferenceCore
import Foundation
import WebRTC

/// Reads transport liveness from the current attempt's peer connections for the
/// media transport watchdog, plus a small summary for saved diagnostics.
/// The summary holds states, counters and candidate kinds only, never addresses.
enum GuestTransportHealth {
    struct Result {
        var samples: [MediaTransportWatchdog.Sample] = []
        var summary: [[String: Any]] = []
        var connectedPairs: [MediaTransportRecoveryConfirmation.Pair: Int64] = [:]
    }

    static func sample(scope: GuestPeerRegistry.Scope) async -> Result? {
        var result = Result()
        var allPeersConnected = true
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        let peers = GuestPeerRegistry.peers(in: scope)
        for (peerID, peer) in peers {
            guard let report = await statistics(of: peer, before: deadline) else { return nil }
            let state = peer.connectionState, iceState = peer.iceConnectionState
            guard state != .closed else { return nil }
            let ice: MediaTransportWatchdog.ICE = state == .failed ? .failed : map(iceState)
            var selectedPairs: [String: Int64] = [:]
            var row: [String: Any] = ["ice": name(iceState), "connection": state.rawValue]
            for entry in report.statistics.values {
                switch entry.type {
                case "transport":
                    guard let pairID = entry.values["selectedCandidatePairId"] as? String,
                          let pair = report.statistics[pairID], pair.type == "candidate-pair" else { continue }
                    if pair.values["state"] as? String == "succeeded" {
                        selectedPairs[pairID] = receivedProgress(pair)
                    }
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
            row["inbound"] = selectedPairs.values.reduce(0, +)
            result.summary.append(row)
            result.samples.append(.init(peer: peerID, ice: ice, selectedPairs: selectedPairs))
            if ice == .connected && state == .connected && !selectedPairs.isEmpty {
                for (pairID, inbound) in selectedPairs {
                    result.connectedPairs[.init(peer: peerID, pair: pairID)] = inbound
                }
            } else {
                allPeersConnected = false
            }
        }
        guard ProcessInfo.processInfo.systemUptime <= deadline,
              Set(peers.map(\.id)) == Set(GuestPeerRegistry.peers(in: scope).map(\.id)) else { return nil }
        if !allPeersConnected { result.connectedPairs.removeAll() }
        return result
    }

    private static func statistics(of peer: RTCPeerConnection, before deadline: TimeInterval) async -> RTCStatisticsReport? {
        let remaining = deadline - ProcessInfo.processInfo.systemUptime
        guard remaining > 0 else { return nil }
        let stream = AsyncStream<RTCStatisticsReport>(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let timeout = Task {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
                continuation.finish()
            }
            continuation.onTermination = { _ in timeout.cancel() }
            peer.statistics { report in
                continuation.yield(report)
                continuation.finish()
            }
        }
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    private static func receivedProgress(_ pair: RTCStatistics) -> Int64 {
        number(pair, "bytesReceived") + number(pair, "responsesReceived") + number(pair, "requestsReceived")
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
