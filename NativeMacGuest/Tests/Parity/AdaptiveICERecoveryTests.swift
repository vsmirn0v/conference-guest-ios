import XCTest
@testable import RockNativeDesktop

final class AdaptiveICERecoveryTests: XCTestCase {
    func testTCPTrialIsBoundedPerPeerAndOnlyVerifiedTrialsPersist() {
        var recovery = GuestRelayRecovery()
        XCTAssertTrue(recovery.beginAttempt().isEmpty)

        XCTAssertTrue(recovery.schedule(.subscriber))
        XCTAssertFalse(recovery.schedule(.subscriber))
        XCTAssertEqual(recovery.beginAttempt(), [.subscriber])
        XCTAssertEqual(recovery.verifying, [.subscriber])
        XCTAssertFalse(recovery.verify(.publisher), "Only the trial peer can confirm")

        XCTAssertTrue(recovery.beginAttempt().isEmpty, "Failed trial falls back to regular recovery")
        XCTAssertFalse(recovery.verify(.subscriber), "A retired trial cannot pin a route")
        XCTAssertFalse(recovery.schedule(.subscriber))
        XCTAssertTrue(recovery.schedule(.publisher))
        XCTAssertEqual(recovery.beginAttempt(), [.publisher])
        XCTAssertTrue(recovery.verify(.publisher))
        XCTAssertEqual(recovery.beginAttempt(), [.publisher])
        XCTAssertTrue(recovery.verifying.isEmpty)
        XCTAssertTrue(GuestRelayRecovery().confirmed.isEmpty, "TCP success is scoped to one meeting")
    }

    func testOnlySelectedLocalRelayAndItsExplicitRelayProtocolCount() throws {
        let rows = report(time: 10, relayProtocol: "tls", streams: [])
        XCTAssertEqual(try sample(rows).route, .tls)
        XCTAssertEqual(try sample(report(time: 10, relayProtocol: "tcp", streams: [])).route, .tcp)
        XCTAssertEqual(try sample(report(time: 10, relayProtocol: "udp", streams: [])).route, .udp)
        XCTAssertEqual(try sample(report(time: 10, relayProtocol: nil, streams: [])).route, .other)
        XCTAssertNil(GuestICETransportSample(rows.filter { $0["id"] as? String != "selected" },
                                             target: .subscriber, demandedTracks: []))
        var wrongDTLS = rows
        wrongDTLS[0]["dtlsState"] = "connecting"
        XCTAssertNil(GuestICETransportSample(wrongDTLS, target: .subscriber, demandedTracks: []))
    }

    func testMediaNeedsCurrentTransportTrackAndFreshReports() throws {
        let old = try sample(report(time: 10, relayProtocol: "tcp", streams: [
            inbound("a", track: "remote-audio", kind: "audio", progress: 5),
            inbound("v", track: "remote-video", kind: "video", progress: 6)
        ]))
        let rows = [inbound("a", track: "remote-audio", kind: "audio", progress: 10),
                    inbound("v", track: "remote-video", kind: "video", progress: 20)]
        let fresh = try sample(report(time: 12, relayProtocol: "tcp", streams: rows))
        XCTAssertEqual(fresh.mediaDelta(since: old).progressing, [.audio, .video])
        let stale = try sample(report(time: 19, relayProtocol: "tcp", streams: rows))
        XCTAssertTrue(stale.mediaDelta(since: old).progressing.isEmpty)

        var changedPair = report(time: 12, relayProtocol: "tcp", streams: rows)
        changedPair[1]["remoteCandidateId"] = "new-remote"
        XCTAssertTrue(try sample(changedPair).mediaDelta(since: old).progressing.isEmpty)
        var wrongTransport = report(time: 12, relayProtocol: "tcp", streams: rows)
        wrongTransport[wrongTransport.count - 1]["transportId"] = "other"
        let incomplete = try sample(wrongTransport)
        XCTAssertEqual(incomplete.reportedTracks, ["remote-audio"])
        XCTAssertTrue(incomplete.mediaDelta(since: old).progressing.isEmpty)
    }

    func testLossCorroboratesDemandedMediaStarvationButSilenceDoesNot() throws {
        let frames = inbound("v", track: "remote-video", kind: "video", progress: 6, lost: 4)
        let old = try sample(report(time: 10, relayProtocol: "udp", streams: [frames]))
        let quiet = try sample(report(time: 12, relayProtocol: "udp", streams: [frames]))
        XCTAssertTrue(quiet.mediaDelta(since: old).stalledStreams.isEmpty)
        let loss = inbound("v", track: "remote-video", kind: "video", progress: 6, lost: 8)
        let stalled = try sample(report(time: 12, relayProtocol: "udp", streams: [loss]))
        XCTAssertEqual(stalled.mediaDelta(since: old).stalledStreams, ["v"])
        let noDemand = try sample(report(time: 12, relayProtocol: "udp", streams: [loss]), tracks: [])
        XCTAssertTrue(noDemand.mediaDelta(since: old).stalledStreams.isEmpty)
    }

    func testPublisherRequiresFreshFeedbackBoundToTheSameRTPStream() throws {
        let source: [String: Any] = ["id": "audio-source", "type": "media-source", "trackIdentifier": "local-audio"]
        func outbound(_ count: Int) -> [String: Any] {
            ["id": "sender", "type": "outbound-rtp", "kind": "audio", "transportId": "media",
             "mediaSourceId": "audio-source", "packetsSent": count]
        }
        func feedback(localID: String = "sender", time: Int, lost: Double = 0) -> [String: Any] {
            ["id": "feedback", "type": "remote-inbound-rtp", "kind": "audio", "transportId": "media",
             "localId": localID, "nativeTimestampUS": time * 1_000_000, "fractionLost": lost]
        }
        func publisher(time: Int, sent: Int, feedback: [String: Any]) throws -> GuestICETransportSample {
            try XCTUnwrap(GuestICETransportSample(report(time: time, relayProtocol: "tcp", streams: [source, outbound(sent), feedback]),
                                                target: .publisher, demandedTracks: ["local-audio"]))
        }
        let old = try publisher(time: 10, sent: 5, feedback: feedback(time: 9))
        XCTAssertTrue(try publisher(time: 12, sent: 10, feedback: feedback(time: 9)).mediaDelta(since: old).progressing.isEmpty)
        XCTAssertTrue(try publisher(time: 12, sent: 10, feedback: feedback(localID: "other", time: 11)).mediaDelta(since: old).progressing.isEmpty)
        XCTAssertEqual(try publisher(time: 12, sent: 10, feedback: feedback(time: 11)).mediaDelta(since: old).progressing, [.audio])
        XCTAssertEqual(try publisher(time: 12, sent: 10, feedback: feedback(time: 11, lost: 0.98)).mediaDelta(since: old).stalledStreams, ["sender"])
    }

    private func sample(_ rows: [[String: Any]], tracks: Set<String> = ["remote-audio", "remote-video"]) throws -> GuestICETransportSample {
        try XCTUnwrap(GuestICETransportSample(rows, target: .subscriber, demandedTracks: tracks))
    }

    private func inbound(_ id: String, track: String, kind: String, progress: Int, lost: Int = 0) -> [String: Any] {
        ["id": id, "type": "inbound-rtp", "transportId": "media", "kind": kind,
         "trackIdentifier": track, kind == "video" ? "framesDecoded" : "packetsReceived": progress, "packetsLost": lost]
    }

    private func report(time: Int, relayProtocol: String?, streams: [[String: Any]]) -> [[String: Any]] {
        var local: [String: Any] = ["id": "local", "type": "local-candidate", "candidateType": "relay", "protocol": "udp"]
        local["relayProtocol"] = relayProtocol
        return [["id": "media", "type": "transport", "dtlsState": "connected", "selectedCandidatePairId": "selected",
                 "sampleUptime": time, "nativeTimestampUS": time * 1_000_000],
                ["id": "selected", "type": "candidate-pair", "state": "succeeded", "localCandidateId": "local",
                 "remoteCandidateId": "remote", "requestsSent": 3, "responsesReceived": 3],
                ["id": "alternative", "type": "candidate-pair", "state": "succeeded", "localCandidateId": "other"],
                ["id": "other", "type": "local-candidate", "candidateType": "relay", "protocol": "udp", "relayProtocol": "tcp"],
                local] + streams
    }
}
