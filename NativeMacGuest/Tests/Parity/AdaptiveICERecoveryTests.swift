import AVFoundation
import ConferenceCore
import LiveKitWebRTC
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

final class AdaptiveICERecoveryTests: XCTestCase {
    func testOutputCallbackRetainsRecoveredPauseAcrossSubsequentBuffers() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        var callback = GuestStartupAudioCallback()
        for time in [1.0, 1.1, 1.8, 1.9] {
            callback.recordDelivery(frames: 4800, format: .init(format.streamDescription.pointee), at: time)
        }
        XCTAssertEqual(callback.count, 4)
        XCTAssertEqual(callback.lastGapEnd, 1.8)
        XCTAssertEqual(callback.lastGapSeconds, 0.7, accuracy: 0.001)
    }

    @MainActor func testConnectedSubscriberLogsReceptionWithoutARelayCandidate() async throws {
        let shared = SharedAudioEngine.live(manualRenderingForTesting: true)
        let audio = try await SharedGuestMeetingAudio.attach(to: shared)
        let engine = NativeGuestEngine(label: "offline observation", systemAudio: audio)
        engine.configureStartupPlayback(sound: true)
        _ = try await engine.prepareJoinForTesting()
        let sub = try await engine.prepareSubscriberForTesting()
        var polls = 0
        sub.statsOverrideForTesting = { polls += 1; return [] }
        sub.peerConnection(sub.connection, didChange: LKRTCIceConnectionState.connected)
        sub.peerConnection(sub.connection, didChange: LKRTCPeerConnectionState.connected)
        engine.startTransportObservationForTesting()
        let deadline = ProcessInfo.processInfo.systemUptime + 6
        func reception() -> String? {
            probeLogHistory().last { $0.contains("\"event\":\"guest-audio-reception\"") && $0.contains(sub.diagnosticID) }
        }
        while reception() == nil && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        let line = reception()
        let clean = await engine.leave(sendLeave: false)
        XCTAssertTrue(clean)
        XCTAssertGreaterThan(polls, 0)
        XCTAssertTrue(try XCTUnwrap(line).contains("\"transportConnected\":true"))
    }

    func testQuietMicrophoneWithAnotherReceivingStreamDoesNotTripRelayFallback() throws {
        let quiet = inbound("quiet", track: "remote-audio", kind: "audio", progress: 100)
        func window(_ time: Int, otherPackets: Int, lost: Int = 0) throws -> GuestICETransportSample {
            var first = quiet
            first["packetsLost"] = lost
            var rows = report(time: time, relayProtocol: "udp", streams: [
                first, inbound("other", track: "other-audio", kind: "audio", progress: otherPackets)])
            rows[1]["requestsSent"] = time
            return try sample(rows, tracks: ["remote-audio", "other-audio"])
        }
        let old = try window(10, otherPackets: 100)
        let next = try window(12, otherPackets: 120)
        XCTAssertTrue(next.mediaDelta(since: old).stalledStreams.isEmpty)
        XCTAssertTrue(try window(14, otherPackets: 140).mediaDelta(since: next).stalledStreams.isEmpty)
        XCTAssertEqual(try window(14, otherPackets: 140, lost: 3).mediaDelta(since: next).stalledStreams, ["quiet"])
        XCTAssertEqual(try window(14, otherPackets: 120).mediaDelta(since: next).stalledStreams, ["quiet", "other"])

        func videoWindow(_ time: Int, packets: Int) throws -> GuestICETransportSample {
            var video = inbound("camera", track: "remote-video", kind: "video", progress: time)
            video["packetsReceived"] = packets
            var rows = report(time: time, relayProtocol: "udp", streams: [quiet, video])
            rows[1]["requestsSent"] = time
            return try sample(rows)
        }
        let camera = try videoWindow(10, packets: 50)
        XCTAssertTrue(try videoWindow(12, packets: 60).mediaDelta(since: camera).stalledStreams.isEmpty)
        XCTAssertEqual(try videoWindow(12, packets: 50).mediaDelta(since: camera).stalledStreams, ["quiet"],
                       "Decoding buffered video frames provides no new evidence that packets are arriving")
    }

    func testAudioReceptionSeparatesLocalCallbackGapsFromPerStreamLoss() throws {
        var monitor = GuestAudioReceptionDiagnostics()
        func observe(_ time: Int, packets: Int, lost: Int, unhealthy: Bool = false) throws -> [String: Any] {
            var row = inbound("private-id", track: "private-track", kind: "audio", progress: packets, lost: lost)
            row["nativeTimestampUS"] = time * 1_000_000
            row["concealedSamples"] = lost * 480
            var output = GuestStartupAudioCallback(count: UInt64(time), uptime: Double(time))
            if unhealthy { output.lastGapEnd = Double(time) - 0.1; output.lastGapSeconds = 0.7 }
            let fields = try XCTUnwrap(monitor.observe(at: Double(time), rows: [row], audibleTracks: ["private-track"],
                connected: true, soundOn: true, gateOpen: true, expectsAudio: true, speakingTracks: ["private-track"],
                decoded: .init(callbacks: time, nonSilentCallbacks: time), output: output, outputNonSilent: time))
            XCTAssertFalse(String(describing: fields).contains("private-"))
            XCTAssertTrue(JSONSerialization.isValidJSONObject(fields))
            return fields
        }
        XCTAssertEqual(try observe(10, packets: 200, lost: 9)["rtp"] as? String, "baseline")
        let impaired = try observe(12, packets: 230, lost: 12)
        XCTAssertEqual(impaired["packetsLostIncrease"] as? Int64, 3)
        XCTAssertEqual(impaired["concealedSamples"] as? Int64, 1440)
        XCTAssertEqual(impaired["outputTap"] as? String, "callbacks-current")
        let stalled = try observe(14, packets: 260, lost: 12, unhealthy: true)
        XCTAssertEqual(stalled["rtp"] as? String, "receiving")
        XCTAssertEqual(stalled["outputTap"] as? String, "callback-gap")
        let quiet = try observe(16, packets: 260, lost: 12)
        XCTAssertEqual(quiet["rtp"] as? String, "no-packet-progress")
        XCTAssertEqual(quiet["speakingStreamsWithoutPackets"] as? Int, 1)
        let lossDetail = try XCTUnwrap((impaired["streamDetails"] as? [[String: Int64]])?.first)
        let quietDetail = try XCTUnwrap((quiet["streamDetails"] as? [[String: Int64]])?.first)
        XCTAssertEqual(lossDetail["packetsLostIncrease"], 3)
        XCTAssertEqual(quietDetail["stream"], lossDetail["stream"])
        let reset = try observe(18, packets: 2, lost: 0)
        XCTAssertNil(reset["packetsLostIncrease"])
    }

    func testUnavailableStatsAndIntentionalSilenceStayDistinct() throws {
        var monitor = GuestAudioReceptionDiagnostics()
        func observe(_ time: Double, rows: [[String: Any]]?, sound: Bool = true, expected: Bool = true) -> [String: Any]? {
            monitor.observe(at: time, rows: rows, audibleTracks: [], connected: true, soundOn: sound,
                gateOpen: true, expectsAudio: expected, speakingTracks: [], decoded: .init(),
                output: .init(count: 10, uptime: time - 1), outputNonSilent: nil)
        }
        let missing = try XCTUnwrap(observe(10, rows: nil))
        XCTAssertEqual(missing["rtp"] as? String, "stats-unavailable")
        XCTAssertEqual(missing["outputTap"] as? String, "callback-stale")
        XCTAssertNil(missing["packetsReceived"])
        XCTAssertEqual(observe(12, rows: [], sound: false)?["rtp"] as? String, "sound-off")
        XCTAssertEqual(observe(14, rows: [], expected: false)?["rtp"] as? String, "no-audible-publication")
        XCTAssertNil(observe(16, rows: [], expected: false))
        XCTAssertNotNil(observe(46, rows: [], expected: false))
    }

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

    func testWithdrawnTCPRelayClearsOnlyThatPeerAndDoesNotResetItsBudget() {
        var recovery = GuestRelayRecovery()
        XCTAssertTrue(recovery.schedule(.subscriber))
        XCTAssertTrue(recovery.schedule(.publisher))
        XCTAssertEqual(recovery.beginAttempt(), [.subscriber, .publisher])
        XCTAssertTrue(recovery.verify(.subscriber))
        XCTAssertTrue(recovery.verify(.publisher))
        XCTAssertTrue(recovery.discard(.subscriber))
        XCTAssertFalse(recovery.discard(.subscriber))
        XCTAssertEqual(recovery.beginAttempt(), [.publisher])
        XCTAssertFalse(recovery.schedule(.subscriber))
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

    func testQuietAudioMayRecoverOnTCPBeforeMediaProgress() throws {
        let muted = inbound("a", track: "remote-audio", kind: "audio", progress: 5)
        let before = try sample(report(time: 10, relayProtocol: "tls", streams: [muted]))
        let after = try sample(report(time: 12, relayProtocol: "tls", streams: [muted]))
        let delta = after.mediaDelta(since: before)
        XCTAssertTrue(delta.progressing.isEmpty)
        XCTAssertTrue(delta.stalledStreams.isEmpty)
        let quiet = GuestICETransportSample.RecoveryEvidence(route: after.route, audioProgress: false, videoProgress: false)
        XCTAssertTrue(quiet.allowsRecovery(requiresVideo: false))
        XCTAssertFalse(quiet.mediaVerified)
        XCTAssertFalse(quiet.allowsRecovery(requiresVideo: true))
        let udp = GuestICETransportSample.RecoveryEvidence(route: .udp, audioProgress: true, videoProgress: true)
        XCTAssertFalse(udp.allowsRecovery(requiresVideo: false))
    }

    func testHealthyVideoCannotHideAnotherDemandedVideoStall() throws {
        let tracks: Set<String> = ["video-a", "video-b"]
        let oldA = inbound("a", track: "video-a", kind: "video", progress: 10)
        let oldB = inbound("b", track: "video-b", kind: "video", progress: 10)
        let previous = try sample(report(time: 10, relayProtocol: "tcp", streams: [oldA, oldB]), tracks: tracks)
        let advancingA = inbound("a", track: "video-a", kind: "video", progress: 20)
        let stalledB = inbound("b", track: "video-b", kind: "video", progress: 10, lost: 15)
        let mixed = try sample(report(time: 12, relayProtocol: "tcp", streams: [advancingA, stalledB]), tracks: tracks)
        let delta = mixed.mediaDelta(since: previous)
        XCTAssertEqual(delta.stalledStreams, ["b"])
        XCTAssertFalse(delta.confirmsMedia([.video], videoTracks: tracks))
        let missing = try sample(report(time: 12, relayProtocol: "tcp", streams: [advancingA]), tracks: tracks)
        XCTAssertFalse(missing.mediaDelta(since: previous).confirmsMedia([.video], videoTracks: tracks))
        let advancingB = inbound("b", track: "video-b", kind: "video", progress: 25)
        let healthy = try sample(report(time: 12, relayProtocol: "tcp", streams: [advancingA, advancingB]), tracks: tracks)
        XCTAssertTrue(healthy.mediaDelta(since: previous).confirmsMedia([.video], videoTracks: tracks))
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

    func testPeerReflexiveRelayCandidatePreservesExplicitRelayProtocol() throws {
        func localRow(type: String, proto: String, relayProtocol: String?) -> [String: Any] {
            var local: [String: Any] = ["id": "local", "type": "local-candidate", "candidateType": type, "protocol": proto]
            if let relayProtocol { local["relayProtocol"] = relayProtocol }
            return local
        }
        func sampleFor(type: String, proto: String, relayProtocol: String?) throws -> GuestICETransportSample {
            let rows: [[String: Any]] = [
                ["id": "media", "type": "transport", "dtlsState": "connected", "selectedCandidatePairId": "selected",
                 "sampleUptime": 10, "nativeTimestampUS": 10_000_000],
                ["id": "selected", "type": "candidate-pair", "state": "succeeded", "localCandidateId": "local",
                 "remoteCandidateId": "remote", "requestsSent": 3, "responsesReceived": 3],
                localRow(type: type, proto: proto, relayProtocol: relayProtocol)
            ]
            return try XCTUnwrap(GuestICETransportSample(rows, target: .subscriber, demandedTracks: []))
        }
        XCTAssertEqual(try sampleFor(type: "prflx", proto: "udp", relayProtocol: "tcp").route, .tcp)
        XCTAssertEqual(try sampleFor(type: "prflx", proto: "udp", relayProtocol: "tls").route, .tls)
        XCTAssertEqual(try sampleFor(type: "prflx", proto: "udp", relayProtocol: "udp").route, .udp)
        XCTAssertEqual(try sampleFor(type: "prflx", proto: "udp", relayProtocol: nil).route, .udp)
        XCTAssertEqual(try sampleFor(type: "prflx", proto: "udp", relayProtocol: "").route, .udp)

        let tcpPrflx = try sampleFor(type: "prflx", proto: "tcp", relayProtocol: nil)
        XCTAssertEqual(tcpPrflx.route, .other)
        XCTAssertFalse(tcpPrflx.isTCPRelay)

        let hostWithRelayField = try sampleFor(type: "host", proto: "udp", relayProtocol: "tcp")
        XCTAssertEqual(hostWithRelayField.route, .udp)
        XCTAssertFalse(hostWithRelayField.isTCPRelay)

        func candidate(_ target: String, type: String, relayProtocol: String?) -> [String: Any] {
            var row: [String: Any] = ["type": "local-candidate", "target": target, "candidateType": type, "protocol": "udp"]
            if let relayProtocol { row["relayProtocol"] = relayProtocol }
            return row
        }
        let accepted: [String: Any] = ["icePolicy": "tcp-relay", "subscriberStatsFresh": true, "publisherStatsFresh": true,
            "stats": [candidate("PUBLISHER", type: "prflx", relayProtocol: "tcp"),
                      candidate("SUBSCRIBER", type: "prflx", relayProtocol: "tls")]]
        XCTAssertTrue(GuestDuplexAcceptance.transport(accepted))

        var rejectedUDP = accepted
        rejectedUDP["stats"] = [candidate("PUBLISHER", type: "prflx", relayProtocol: "tcp"),
                                candidate("SUBSCRIBER", type: "prflx", relayProtocol: "udp")]
        XCTAssertFalse(GuestDuplexAcceptance.transport(rejectedUDP))

        var rejectedNil = accepted
        rejectedNil["stats"] = [candidate("PUBLISHER", type: "prflx", relayProtocol: "tcp"),
                                candidate("SUBSCRIBER", type: "prflx", relayProtocol: nil)]
        XCTAssertFalse(GuestDuplexAcceptance.transport(rejectedNil))
    }

    @MainActor func testTCPRelayVerificationCompletesPromptlyOnPeerReflexiveVideoRoute() async throws {
        let engine = NativeGuestEngine(label: "Fast prflx TCP recovery", icePolicy: .automatic)
        engine.tcpRelayTargets = [.subscriber]
        var confirmed: [GuestPeerTarget] = []
        engine.confirmTCPRelay = { confirmed.append($0) }
        engine.mediaNotifyForTesting = { _ in }
        _ = try await engine.prepareJoinForTesting()
        let sub = try await engine.prepareSubscriberForTesting()

        let receiver = try XCTUnwrap(sub.connection.addTransceiver(of: .video)?.receiver)
        let videoTrackID = try XCTUnwrap((receiver.track as? LKRTCVideoTrack)?.trackId)
        let stream = sub.factory.mediaStream(withStreamId: "PA_remote|TR_video")
        await withCheckedContinuation { done in
            sub.receiverEventFinishedForTesting = { sub.receiverEventFinishedForTesting = nil; done.resume() }
            sub.peerConnection(sub.connection, didAdd: receiver, streams: [stream])
        }
        try await engine.processEventForTesting(["event": "media-out", "payload": [
            "method": "rtc:participants:update", "update": ["participants": [[
                "sid": "PA_remote", "identity": "remote", "version": 1, "state": "ACTIVE", "tracks": [
                    ["sid": "TR_video", "type": "VIDEO", "source": "CAMERA", "muted": false]]]]]]])

        var sampleTime = 10.0
        var frames = 5
        sub.statsOverrideForTesting = {
            sampleTime += 0.25
            frames += 5
            return [
                ["id": "media", "type": "transport", "dtlsState": "connected", "selectedCandidatePairId": "selected",
                 "sampleUptime": sampleTime, "nativeTimestampUS": Int(sampleTime * 1_000_000)],
                ["id": "selected", "type": "candidate-pair", "state": "succeeded", "localCandidateId": "local",
                 "remoteCandidateId": "remote", "requestsSent": 3, "responsesReceived": 3],
                ["id": "local", "type": "local-candidate", "candidateType": "prflx", "protocol": "udp", "relayProtocol": "tcp"],
                ["id": "v", "type": "inbound-rtp", "transportId": "media", "kind": "video",
                 "trackIdentifier": videoTrackID, "framesDecoded": frames, "packetsLost": 0]
            ]
        }

        await withCheckedContinuation { done in
            sub.iceEventFinishedForTesting = { sub.iceEventFinishedForTesting = nil; done.resume() }
            sub.peerConnection(sub.connection, didChange: LKRTCIceConnectionState.connected)
        }
        await withCheckedContinuation { done in
            sub.transportEventFinishedForTesting = { sub.transportEventFinishedForTesting = nil; done.resume() }
            sub.peerConnection(sub.connection, didChange: LKRTCPeerConnectionState.connected)
        }

        let started = ProcessInfo.processInfo.systemUptime
        engine.startTransportObservationForTesting()
        try await engine.waitForTransportRecovery()
        let elapsed = ProcessInfo.processInfo.systemUptime - started

        XCTAssertEqual(confirmed, [.subscriber])
        XCTAssertLessThan(elapsed, 2.0)
        let clean = await engine.leave(sendLeave: false)
        XCTAssertTrue(clean)
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
