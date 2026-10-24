import Foundation
import LiveKitWebRTC
import CoreVideo
import CoreMedia

/// Drives public wire envelopes through the engine's DEBUG adapter. No join, peer, device or network is opened.
@main @MainActor struct EngineTests {
    static func main() async throws {
        let watchdog = DispatchWorkItem { fatalError("Engine state tests exceeded 25 seconds") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: watchdog)
        defer { watchdog.cancel() }
        try await participantVersions()
        try await emptyViewportRetiresAllVideo()
        try await remoteGenerationLifecycle()
        try await permissionRevocation()
        try await forcedMuteOrdering(adminFirst: true, video: false)
        try await forcedMuteOrdering(adminFirst: false, video: false)
        try await forcedMuteOrdering(adminFirst: true, video: true)
        try await forcedMuteOrdering(adminFirst: false, video: true)
        try await startupIntentAndSuppression()
        try await idempotentLeave()
        for action in UnmuteInterruption.allCases { try await gatedUnmute(action) }
        try await receiverIdentityLifecycle()
        try await receiverPublicationReassociation()
        try await mutedCameraPublicationAndDeniedKinds()
        try await cameraPrivacyLifecycle()
        try await cancelledCameraStart()
        try await statsReadValidity()
        try await codecRepairNegotiation()
        try await iceCheckingRecovery()
        try await iceGatheringDiagnostics()
        failedChecklistPrivacy()
        try await relayPolicy()
        sdpDiagnostics()
        frozenFrameCadence()
        duplexHardwareEvidence()
        try liveProbeAcceptance()
        print("PASS: engine versions, permissions, admin ordering, startup mute, leave; empty viewport retires camera/screen video while retaining audio; actual unmute gate control/mute/revoke/leave; receiver identity lifecycle and authoritative publication reassociation; bounded numeric ICE diagnostics")
    }

    private static func iceCheckingRecovery() async throws {
        for action in ["timeout", "connected", "closed", "rechecking"] {
            let audio = GuestSyntheticAudio(); defer { precondition(audio.terminateDevice()) }
            let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
            let peer = try GuestPeer(target: .subscriber, factory: factory); defer { peer.close() }
            var delays: [UInt64] = [], releases: [() -> Void] = [], failures = 0, finished = 0
            var diagnostics: [[String: Any]] = []
            peer.iceDiagnosticForTesting = { event, fields in
                if event == "ice-failure-diagnostics" { diagnostics.append(fields) }
            }
            peer.iceWaitForTesting = { duration in
                try await guestAwait { done in
                    delays.append(duration); releases.append { done(.success(())) }
                }
            }
            peer.onFailure = { _ in failures += 1 }
            peer.iceTimerFinishedForTesting = { finished += 1 }
            func signal(_ state: LKRTCIceConnectionState) async throws {
                try await guestAwait { done in
                    peer.iceEventFinishedForTesting = { done(.success(())) }
                    peer.peerConnection(peer.connection, didChange: state)
                }
            }
            func drain(until condition: () -> Bool) async {
                for _ in 0..<1000 { if condition() { return }; await Task.yield() }
                preconditionFailure("ICE timer task did not progress")
            }
            try await signal(.checking); await drain { releases.count == 1 }
            try await signal(.checking)
            precondition(delays == [10_000_000_000], "Duplicate checking cannot extend the deadline")
            if action == "connected" || action == "rechecking" { try await signal(.connected) }
            if action == "closed" { peer.close() }
            if action == "rechecking" {
                try await signal(.checking); await drain { releases.count == 2 }
                releases[0](); await drain { finished >= 1 }
                precondition(failures == 0, "Retired timer must not fail a newer checking epoch")
                releases[1](); await drain { finished == 2 }
                precondition(failures == 1)
            } else {
                releases[0](); await drain { finished == 1 }
                precondition(failures == (action == "timeout" ? 1 : 0))
            }
            precondition(diagnostics.count == failures, "Only the current failed timer emits ICE evidence")
            if let diagnostic = diagnostics.first {
                precondition(diagnostic["reason"] as? String == "deadline" && diagnostic["state"] as? Int == 1)
                precondition(diagnostic["target"] as? String == "SUBSCRIBER" && diagnostic["peerID"] as? String == peer.diagnosticID)
                precondition(diagnostic["generatedCandidates"] as? Int == 0 && diagnostic["pendingRemoteCandidates"] as? Int == 0)
            }
        }
    }

    private final class ICEErrorFixture: LKRTCIceCandidateErrorEvent {
        override var errorCode: Int32 { 701 }
        override var address: String { preconditionFailure("Diagnostics read the local address") }
        override var url: String { preconditionFailure("Diagnostics read the server URL") }
        override var errorText: String { preconditionFailure("Diagnostics read implementation text") }
    }

    private static func iceGatheringDiagnostics() async throws {
        let audio = GuestSyntheticAudio(); defer { precondition(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let peer = try GuestPeer(target: .subscriber, factory: factory); defer { peer.close() }
        var observed: [(String, [String: Any])] = [], failures = 0
        peer.iceDiagnosticForTesting = { observed.append(($0, $1)) }
        peer.onFailure = { _ in failures += 1 }
        let candidate = LKRTCIceCandidate(sdp: "candidate:fixture 1 udp 1 192.0.2.1 9 typ host", sdpMLineIndex: 0, sdpMid: "0")
        func generated() async throws {
            try await guestAwait { done in
                peer.iceCandidateEventFinishedForTesting = { done(.success(())) }
                peer.peerConnection(peer.connection, didGenerate: candidate)
            }
        }
        func gatheringError() async throws {
            try await guestAwait { done in
                peer.iceGatherEventFinishedForTesting = { done(.success(())) }
                peer.peerConnection(peer.connection, didFailToGatherIceCandidate: ICEErrorFixture())
            }
        }
        for _ in 0..<3 { try await generated() }
        try await peer.addCandidates([["target": "SUBSCRIBER", "candidate": candidate.sdp,
                                       "sdpMLineIndex": 0, "sdpMid": "0"]])
        for _ in 0..<40 { try await gatheringError() }
        precondition(observed.count == 32 && failures == 0,
                     "Gathering errors only log the first 32 callbacks; they do not invoke recovery")
        for (event, fields) in observed {
            precondition(event == "ice-gather-error" && Set(fields.keys) == ["peerID", "target", "errorCode"])
            precondition(fields["peerID"] as? String == peer.diagnosticID && fields["target"] as? String == peer.target.rawValue)
            precondition((fields["errorCode"] as? NSNumber)?.intValue == 701)
        }
        try await guestAwait { done in
            peer.iceEventFinishedForTesting = { done(.success(())) }
            peer.peerConnection(peer.connection, didChange: LKRTCIceConnectionState.failed)
        }
        precondition(failures == 1 && observed.count == 33, "Existing ICE failed behavior remains unchanged")
        let (event, fields) = observed.last!
        precondition(event == "ice-failure-diagnostics" && Set(fields.keys) == [
            "peerID", "target", "reason", "state", "generatedCandidates", "gatheringErrors", "gatheringErrorsLogged",
            "queuedLocalCandidates", "sentLocalCandidates", "receivedRemoteCandidates", "bufferedRemoteCandidates",
            "addedRemoteCandidates", "pendingLocalCandidates", "pendingRemoteCandidates", "gatheringState"])
        precondition(fields["generatedCandidates"] as? Int == 3 && fields["gatheringErrors"] as? Int == 40 &&
                     fields["gatheringErrorsLogged"] as? Int == 32)
        precondition(fields["reason"] as? String == "native-failed" && fields["state"] as? Int == LKRTCIceConnectionState.failed.rawValue)
        precondition(fields["queuedLocalCandidates"] as? Int == 3 && fields["pendingLocalCandidates"] as? Int == 3 &&
                     fields["sentLocalCandidates"] as? Int == 0 && fields["receivedRemoteCandidates"] as? Int == 1 &&
                     fields["bufferedRemoteCandidates"] as? Int == 1 && fields["pendingRemoteCandidates"] as? Int == 1 &&
                     fields["addedRemoteCandidates"] as? Int == 0)
        peer.close()
        try await gatheringError(); try await generated()
        precondition(observed.count == 33 && failures == 1, "Late callbacks on retired peer add no diagnostics or failures")
    }

    private static func failedChecklistPrivacy() {
        let secret = "private.invalid/secret-token"
        var statistics: [[String: Any]] = [
            ["type": "transport", "selectedCandidatePairId": "pair-00", "url": secret],
            ["type": "local-candidate", "id": "local-00", "candidateType": "relay", "protocol": "udp",
             "relayProtocol": "tls", "address": secret, "username": secret],
            ["type": "remote-candidate", "id": "remote-00", "candidateType": "host", "protocol": "udp",
             "address": secret],
        ]
        for index in 0..<40 {
            statistics.append(["type": "candidate-pair", "id": String(format: "pair-%02d", index),
                "localCandidateId": "local-00", "remoteCandidateId": "remote-00",
                "state": index == 0 ? "failed" : "unexpected-\(secret)",
                "nominated": index == 0, "requestsSent": index == 0 ? 3 : 0,
                "responsesReceived": 0, "address": secret, "candidate": secret])
        }
        let summary = GuestPeer.failedChecklistSummary(statistics)
        precondition(summary["pairCount"] as? Int == 40 && summary["recordedPairs"] as? Int == 16)
        precondition(summary["localCandidateStats"] as? Int == 1 && summary["pairedRemoteCandidateStats"] as? Int == 1)
        let pairs = summary["pairs"] as! [[String: Any]]
        precondition(pairs.count == 16 && pairs[0]["state"] as? String == "failed" &&
                     pairs[0]["selected"] as? Bool == true && pairs[0]["requestsSent"] as? Int == 3 &&
                     pairs[0]["localRelayProtocol"] as? String == "tls" && pairs[1]["state"] as? String == "other")
        let data = try! JSONSerialization.data(withJSONObject: summary)
        precondition(!String(decoding: data, as: UTF8.self).contains(secret), "Candidate diagnostics leaked endpoint or credential text")
    }

    private static func relayPolicy() async throws {
        let valid = ["turn:relay.example:3478?transport=tcp", "turns:[2001:db8::1]:5349?transport=tcp"]
        let invalid = ["stun:relay.example", "turn:relay.example?transport=udp", "turn:relay.example", "turns:relay.example", "turn:?transport=tcp", "turn://relay.example?transport=tcp", "turn:relay.example?transport=tcp&x=1", "turn:relay.example?transport=tcp?transport=tcp", "turn:relay.example?transport=tcp#fragment", "turn: relay.example?transport=tcp"]
        for uri in valid { precondition(GuestICEPolicy.isExplicitTCPRelay(uri)) }
        for uri in invalid { precondition(!GuestICEPolicy.isExplicitTCPRelay(uri)) }
        let advertised: [[String: Any]] = [["urls": [invalid[1], valid[0]], "username": "fixture-user", "credential": "fixture-password"], ["urls": valid[1], "username": "fixture-user", "credential": "fixture-password"], ["urls": invalid[0]]]
        let filtered = try GuestICEPolicy.tcpRelay.servers(advertised)
        precondition(filtered.count == 2 && filtered[0]["urls"] as? [String] == [valid[0]])
        precondition(filtered[0]["username"] as? String == "fixture-user" && filtered[0]["credential"] as? String == "fixture-password")
        do { _ = try GuestICEPolicy.tcpRelay.servers([["urls": invalid]]); preconditionFailure("No eligible endpoint") }
        catch GuestICEPolicyError.noTCPRelay {}
        let audio = GuestSyntheticAudio(); defer { precondition(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let peer = try GuestPeer(target: .publisher, factory: factory, icePolicy: .tcpRelay)
        defer { peer.close() }
        try peer.configure(["iceServers": advertised, "iceTransportPolicy": "all"])
        precondition(peer.connection.configuration.iceTransportPolicy == .relay)
        precondition(peer.connection.configuration.iceServers.flatMap(\.urlStrings) == valid)
        precondition(GuestICEPolicy.udpReceive.forTarget(.publisher) == .tcpRelay)
        precondition(GuestICEPolicy.udpReceive.forTarget(.subscriber) == .udpRelay)
        precondition(GuestICEPolicy.udpPublish.forTarget(.publisher) == .udpRelay)
        precondition(GuestICEPolicy.udpPublish.forTarget(.subscriber) == .tcpRelay)
        let udpURL = "turn:relay.example:3478?transport=udp"
        let udp = try GuestPeer(target: .subscriber, factory: factory, icePolicy: .udpRelay)
        defer { udp.close() }
        try udp.configure(["iceServers": [["urls": [valid[0], udpURL], "username": "test", "credential": "test"]]])
        precondition(udp.connection.configuration.iceTransportPolicy == .relay)
        precondition(udp.connection.configuration.iceServers.flatMap(\.urlStrings) == [udpURL])
        precondition(!GuestICEPolicy.isExplicitRelay("turns:relay.example?transport=udp", transport: "udp"))
        do { _ = try GuestICEPolicy.udpRelay.servers([["urls": valid]]); preconditionFailure("No UDP endpoint") }
        catch GuestICEPolicyError.noUDPRelay {}
        let automatic = try GuestPeer(target: .publisher, factory: factory)
        defer { automatic.close() }
        try automatic.configure(["iceServers": [advertised[0]]])
        precondition(automatic.connection.configuration.iceServers.count == 1)
        try automatic.configure([:])
        precondition(automatic.connection.configuration.iceServers.count == 1)
        try automatic.configure(["iceServers": [] as [[String: Any]]])
        precondition(automatic.connection.configuration.iceServers.isEmpty)
        func candidate(_ target: String, _ protocolName: String) -> [String: Any] {
            ["type": "local-candidate", "target": target, "candidateType": "relay", "protocol": "udp", "relayProtocol": protocolName]
        }
        let report: [String: Any] = ["icePolicy": "tcp-relay", "subscriberStatsFresh": true, "publisherStatsFresh": true,
            "stats": [candidate("PUBLISHER", "tcp"), candidate("SUBSCRIBER", "tls")]]
        precondition(GuestDuplexAcceptance.transport(report))
        var bad = report; bad["stats"] = [candidate("PUBLISHER", "tcp"), candidate("SUBSCRIBER", "udp")]
        precondition(!GuestDuplexAcceptance.transport(bad))
        bad["stats"] = [candidate("PUBLISHER", "tcp")]; precondition(!GuestDuplexAcceptance.transport(bad))
        bad = report; bad["publisherStatsFresh"] = false; precondition(!GuestDuplexAcceptance.transport(bad))
    }

    private static func sdpDiagnostics() {
        let sdp = "m=audio 9 UDP/TLS/RTP/SAVPF 111\r\na=rtpmap:111 opus/48000\r\nm=video 9 UDP/TLS/RTP/SAVPF 96 97\r\na=rtpmap:96 H264/90000\r\na=rtpmap:97 rtx/90000\r\na=fmtp:97 apt=96\r\na=rtcp-fb:96 nack pli\r\na=rtcp-fb:* transport-cc\r\na=rtcp-rsize\r\na=ice-pwd:private-value\r\na=rtcp-fb:96 private-value\r\n"
        let sections = GuestSDPSummary.video(sdp)
        precondition(sections.count == 1)
        precondition(sections[0]["codecs"] as? [String: String] == ["96":"h264", "97":"rtx"])
        precondition(sections[0]["repairPayloads"] as? [String:Int] == ["97":96])
        precondition(sections[0]["feedback"] as? [String:[String]] == ["96":["nack pli"], "*":["transport-cc"]])
        let data = try! JSONSerialization.data(withJSONObject: sections)
        precondition(!String(data: data, encoding: .utf8)!.contains("private-value"))
    }

    private static func frozenFrameCadence() {
        var storage: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &storage) == kCVReturnSuccess)
        let buffer = LKRTCCVPixelBuffer(pixelBuffer: storage!)
        let counter = GuestFrameCounter(), start = ProcessInfo.processInfo.systemUptime
        for timestamp in 1...11 {
            counter.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: Int64(timestamp)))
        }
        for n in 0..<150 {
            counter.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: n % 2 == 0 ? 10 : 11))
        }
        let window = counter.window(from: start, to: start + 10)
        precondition(window.frames == 11 && !window.smooth && window.maximumGap > 9)
        precondition(counter.evidence["frames"] as? Int == 161)
        precondition(counter.evidence["advancingFrames"] as? Int == 11)
        let replacement = GuestTrackRenderer(counter: counter)
        replacement.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1))
        precondition(counter.evidence["advancingFrames"] as? Int == 12, "New native track has an independent timestamp domain")
        replacement.stop()
        replacement.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 2))
        precondition(counter.evidence["advancingFrames"] as? Int == 12, "Detached tracks must not contribute late callbacks")
    }

    private static func codecRepairNegotiation() async throws {
        let audio = GuestSyntheticAudio()
        defer { precondition(audio.terminateDevice()) }
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(),
            decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let peer = try GuestPeer(target: .publisher, factory: factory)
        defer { peer.close() }
        let track = peer.prepareVideo(cid: "codec-fixture")
        do {
            try peer.attach(track, codec: "not-a-codec")
            preconditionFailure("Repair codecs must not make an unsupported primary valid")
        } catch GuestPeerError.unsupportedCodec {}
        // A fresh peer avoids the intentionally rejected transceiver above.
        let valid = try GuestPeer(target: .publisher, factory: factory)
        defer { valid.close() }
        try valid.attach(valid.prepareVideo(cid: "repair-fixture"), codec: "h264")
        let encodings = valid.connection.transceivers.last!.sender.parameters.encodings
        precondition(encodings.count == 1 && encodings[0].rid == nil)
        precondition(encodings[0].maxBitrateBps?.intValue == GuestVideoProfile.pattern.maximumBitrate)
        precondition(encodings[0].maxFramerate?.intValue == Int(GuestVideoProfile.pattern.fps))
        precondition(encodings[0].scaleResolutionDownBy?.doubleValue == 1)
        precondition(!encodings[0].isActive, "Registration and attached encoding must start muted")
        precondition(GuestVideoProfile.pattern.layer["bitrate"] as? Int == encodings[0].maxBitrateBps?.intValue)
        let description = try await valid.makeOffer()
        let lines = (description["sdp"] as! String).components(separatedBy: .newlines)
        var video = false, offered = Set<String>(), codecs = [String: String](), apt = [String: String]()
        for line in lines {
            if line.hasPrefix("m=") {
                let fields = line.split(separator: " ").map(String.init)
                video = fields.first == "m=video"
                if video { offered.formUnion(fields.dropFirst(3)) }
            } else if video && line.hasPrefix("a=rtpmap:") {
                let fields = line.dropFirst(9).split(separator: " ")
                if fields.count == 2 { codecs[String(fields[0])] = fields[1].split(separator: "/")[0].lowercased() }
            } else if video && line.hasPrefix("a=fmtp:") {
                let fields = line.dropFirst(7).split(separator: " ", maxSplits: 1)
                if fields.count == 2 {
                    for parameter in fields[1].split(separator: ";") {
                        let parts = parameter.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                        if parts.count == 2 && parts[0] == "apt" { apt[String(fields[0])] = String(parts[1]) }
                    }
                }
            }
        }
        let primary = offered.filter { codecs[$0] == "h264" }, repair = offered.filter { codecs[$0] == "rtx" }
        precondition(!primary.isEmpty && !repair.isEmpty)
        precondition(offered.allSatisfy { primary.contains($0) || repair.contains($0) })
        precondition(repair.allSatisfy { apt[$0].map { primary.contains($0) } == true })
        print("PASS: native H264 offer retains RTX with matching apt; unsupported primary rejected")
    }

    private static func statsReadValidity() async throws {
        try await exercise("stats-read-validity") { engine in
            let peer = try await engine.prepareVideoUnmuteForTesting()
            let liveReport = await peer.stats()
            precondition(liveReport != nil, "A successful native report without network traffic must remain distinguishable from read failure")
            peer.close()
            let closedReport = await peer.stats()
            precondition(closedReport == nil, "Closed-peer statistics must not masquerade as a valid zero counter")
        }
    }

    private static func duplexHardwareEvidence() {
        let valid: [String: Any] = ["inputAvailable": true, "engineRunning": true,
            "inputRunning": true, "recording": true, "outputRunning": true,
            "outputAvailable": true,
            "playing": true, "microphoneMuted": false, "voiceProcessingActive": true,
            "voiceProcessingBypassedActive": false, "echoCancellationActive": true,
            "inputSampleRate": 48_000.0, "outputSampleRate": 44_100.0]
        precondition(GuestDuplexAcceptance.hardware(valid, muted: false, playing: true))
        for key in valid.keys {
            var missing = valid; missing.removeValue(forKey: key)
            precondition(!GuestDuplexAcceptance.hardware(missing, muted: false, playing: true))
        }
        for key in ["inputRunning", "recording", "outputRunning", "playing", "voiceProcessingActive", "echoCancellationActive"] {
            var inactive = valid; inactive[key] = false
            precondition(!GuestDuplexAcceptance.hardware(inactive, muted: false, playing: true))
        }
        var bypass = valid; bypass["voiceProcessingBypassedActive"] = true
        precondition(!GuestDuplexAcceptance.hardware(bypass, muted: false, playing: true))
        var muted = valid; muted["microphoneMuted"] = true
        precondition(GuestDuplexAcceptance.hardware(muted, muted: true, playing: true))
        precondition(!GuestDuplexAcceptance.hardware(muted, muted: false, playing: true))
        var outputOff = valid; outputOff["outputAvailable"] = false
        precondition(GuestDuplexAcceptance.hardware(outputOff, muted: false, playing: false))
        var narrowband = valid; narrowband["inputSampleRate"] = 8_000.0
        precondition(!GuestDuplexAcceptance.hardware(narrowband, muted: false, playing: true))
    }

    private static func liveProbeAcceptance() throws {
        try GuestDuplexAcceptance.requireSoakQuality(false, seconds: 0)
        try GuestDuplexAcceptance.requireSoakQuality(true, seconds: 40)
        do {
            try GuestDuplexAcceptance.requireSoakQuality(false, seconds: 40)
            preconditionFailure("A failed soak cannot report duplex-pass")
        } catch GuestEngineError.mediaMissing {}

        var storage: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_32BGRA, nil, &storage) == kCVReturnSuccess)
        CVPixelBufferLockBaseAddress(storage!, [])
        memset(CVPixelBufferGetBaseAddress(storage!), 0, CVPixelBufferGetDataSize(storage!))
        CVPixelBufferUnlockBaseAddress(storage!, [])
        let buffer = LKRTCCVPixelBuffer(pixelBuffer: storage!)
        for advancing in [false, true] {
            let counter = GuestFrameCounter()
            func snapshot() -> GuestMediaSnapshot {
                .init(render: counter.evidence, audio: .init(), connected: true, failed: false)
            }
            counter.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: 1))
            let baseline = snapshot()
            precondition(snapshot().hasQuiescentVideo(since: baseline))
            for index in 2...3 {
                counter.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: advancing ? Int64(index) : 1))
            }
            precondition(snapshot().hasQuiescentVideo(since: baseline), "Two residual frames remain allowed")
            for index in 4...20 {
                counter.renderFrame(LKRTCVideoFrame(buffer: buffer, rotation: ._0, timeStampNs: advancing ? Int64(index) : 1))
            }
            let continued = snapshot()
            precondition(continued.changes(since: baseline) == 0)
            precondition(!continued.hasQuiescentVideo(since: baseline), "Identical frames or timestamps must not pass mute")
            precondition(!baseline.hasQuiescentVideo(since: continued), "Counter reset must not pass mute")
            if advancing {
                precondition(continued.hasFreshVideo(since: baseline, expectation: .nativeCamera(capturedFrames: 19)))
                precondition(!continued.hasFreshVideo(since: baseline, expectation: .movingPattern))
            }
            for key in ["frames", "advancingFrames", "pixelChanges"] {
                var missing = baseline.render; missing.removeValue(forKey: key)
                let incomplete = GuestMediaSnapshot(render: missing, audio: .init(), connected: true, failed: false)
                precondition(!incomplete.hasQuiescentVideo(since: baseline))
                precondition(!baseline.hasQuiescentVideo(since: incomplete))
            }
        }
        print("PASS: failed soak rejects acceptance; mute rejects unchanged-frame delivery without rejecting static active cameras")
    }

    private static func exercise(_ name: String, _ body: (NativeGuestEngine) async throws -> Void) async throws {
        let engine = NativeGuestEngine(label: "Engine test \(name)")
        do { try await body(engine) }
        catch { _ = await engine.leave(sendLeave: false); throw error }
        let stopped = await engine.leave(sendLeave: false)
        precondition(stopped, "Synthetic cleanup failed")
    }

    private static func participant(_ engine: NativeGuestEngine, version: Int, muted: Bool, video: Bool = false) async throws {
        try await engine.processEventForTesting(media("rtc:participants:update", ["update": ["participants": [[
            "identity": "local", "sid": "participant-local", "version": version,
            "tracks": [["sid": video ? "test-video-sid" : "track-audio", "type": video ? "VIDEO" : "AUDIO", "muted": muted]]
        ]]]]))
    }

    private static func participantVersions() async throws {
        try await exercise("versions") { engine in
            engine.identifyForTesting("local")
            try await participant(engine, version: 3, muted: true)
            precondition(engine.stateForTesting.version == 3 && engine.stateForTesting.server["track-audio"] == true)
            try await participant(engine, version: 2, muted: false)
            try await participant(engine, version: 3, muted: false)
            precondition(engine.stateForTesting.version == 3 && engine.stateForTesting.server["track-audio"] == true,
                         "Old or duplicate unmute replaced authoritative mute")
            try await participant(engine, version: 4, muted: false)
            precondition(engine.stateForTesting.version == 4 && engine.stateForTesting.server["track-audio"] == false)
            try await participant(engine, version: 1, muted: true)
            try await participant(engine, version: 4, muted: true)
            precondition(engine.stateForTesting.version == 4 && engine.stateForTesting.server["track-audio"] == false,
                         "Old or duplicate mute replaced newer unmute")
        }
    }

    private static func emptyViewportRetiresAllVideo() async throws {
        try await exercise("empty-viewport") { engine in
            _ = try engine.prepareJoinForTesting()
            let peer = try engine.prepareSubscriberForTesting()
            guard let receiver = peer.connection.addTransceiver(of: .video)?.receiver else {
                preconditionFailure("Fixture screen receiver is missing")
            }
            let stream = peer.factory.mediaStream(withStreamId: "PA_8|TR_video8")
            var subscribed = Set<String>(), subscriptionChanges = 0
            engine.mediaNotifyForTesting = { command in
                guard let change = command["subscription"] as? [String: Any],
                      let ids = change["trackSids"] as? [String], let enabled = change["subscribe"] as? Bool else { return }
                subscriptionChanges += 1
                if enabled { subscribed.formUnion(ids) } else { subscribed.subtract(ids) }
            }
            func participant(_ index: Int, version: Int = 1, muted: Bool = false) -> [String: Any] {
                ["sid": "PA_\(index)", "identity": "remote\(index)", "version": version, "state": "ACTIVE", "tracks": [
                    ["sid": "TR_audio\(index)", "type": "AUDIO", "source": "MICROPHONE", "muted": false],
                    ["sid": "TR_video\(index)", "type": "VIDEO", "source": index >= 8 ? "SCREEN_SHARE" : "CAMERA", "muted": muted]]]
            }
            func update(_ people: [[String: Any]]) async throws {
                try await engine.processEventForTesting(media("rtc:participants:update", ["update": ["participants": people]]))
            }
            func videos() -> Set<String> { subscribed.filter { $0.hasPrefix("TR_video") } }
            func audio(_ count: Int) -> Set<String> { Set((1...count).map { "TR_audio\($0)" }) }
            try await update((1...8).map { participant($0) })
            precondition(videos().count == 6 && videos().contains("TR_video8"), "Unspecified viewport must discover a bounded gallery with screen priority")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [stream]) }
            precondition(engine.incomingVideo.count == 1 && engine.incomingVideo[0].source == "SCREEN_SHARE")
            try await engine.setVisibleParticipantIDs(["remote7"], preferredScreenParticipantID: "remote8")
            precondition(videos() == ["TR_video7", "TR_video8"], "A visible viewport preserves screen priority")
            try await engine.setVisibleParticipantIDs([], preferredScreenParticipantID: "remote8")
            precondition(subscribed == audio(8) && engine.incomingVideo.isEmpty, "Hidden or audio-only demand must retire screen and camera subscriptions and pixels, while audio continues")
            try await update([participant(9)])
            precondition(subscribed == audio(9), "A new screen cannot reopen video while the viewport is empty")
            let unchanged = subscriptionChanges
            try await engine.setVisibleParticipantIDs([])
            precondition(subscriptionChanges == unchanged, "Repeated empty demand must not send subscription changes")
            try await engine.setVisibleParticipantIDs(nil)
            precondition(videos().count == 6 && videos().isSuperset(of: ["TR_video8", "TR_video9"]) && engine.incomingVideo.count == 1,
                         "Restoring discovery must restore bounded video and the retained receiver")
            try await engine.setVisibleParticipantIDs(["remote7"], preferredScreenParticipantID: "remote8")
            try await update([participant(8, version: 2, muted: true)])
            precondition(videos().contains("TR_video8"), "Visible spare capacity may keep a muted screen warm")
            try await engine.setVisibleParticipantIDs([])
            precondition(subscribed == audio(9) && engine.incomingVideo.isEmpty, "Empty demand must also retire a warm muted screen")
        }
    }

    private static func remoteGenerationLifecycle() async throws {
        try await exercise("remote-generation") { engine in
            engine.identifyForTesting("local")
            func event(_ version: Int, track: String = "first", muted: Bool = true, disconnected: Bool = false) async throws {
                try await engine.processEventForTesting(media("rtc:participants:update", ["update": ["participants": [[
                    "identity": "remote", "sid": "remote-sid", "version": version,
                    "state": disconnected ? "DISCONNECTED" : "CONNECTED",
                    "tracks": [["sid": track, "type": "AUDIO", "muted": muted]]
                ]]]]))
            }
            let initial = engine.remoteMediaGeneration
            try await event(1)
            let joined = engine.remoteMediaGeneration
            precondition(joined > initial && engine.connectedRemoteParticipants == ["remote-sid"])
            try await event(2)
            precondition(engine.remoteMediaGeneration == joined, "Version-only snapshots do not replace tracks")
            try await event(3, track: "replacement")
            try await event(4)
            precondition(engine.remoteMediaGeneration == joined + 2, "Transient track replacement must remain observable")
            try await event(5, disconnected: true)
            precondition(engine.connectedRemoteParticipants.isEmpty)
            try await event(6)
            precondition(engine.remoteMediaGeneration == joined + 4 && engine.connectedRemoteParticipants == ["remote-sid"],
                         "A leave/rejoin returning to the original roster must invalidate the measurement")
        }
    }

    private static func permissionRevocation() async throws {
        try await exercise("permissions") { engine in
            var forced: [Bool] = []
            engine.onForcedMute = { forced.append($0) }
            engine.setLocalMuteIntent(false, video: false)
            engine.setLocalMuteIntent(false, video: true)
            engine.preparePublicationForTesting(cid: "pending-audio", video: false)
            try await engine.processEventForTesting(["event": "permissions-updated", "payload": ["canShareMicrophone": false]])
            precondition(engine.stateForTesting.intent[false] == true && engine.stateForTesting.intent[true] == false)
            precondition(forced == [false], "Microphone revocation did not force only microphone mute")
            try await engine.processEventForTesting(published(cid: "pending-audio", sid: "track-audio"))
            precondition(engine.stateForTesting.intent[false] == true, "Late publication acknowledgement cleared revoked microphone intent")
            try await engine.processEventForTesting(["event": "permissions-updated", "payload": ["canShareCamera": false]])
            precondition(engine.stateForTesting.intent[true] == true && engine.stateForTesting.intent[false] == true)
            precondition(forced.contains(true))
        }
    }

    private static func forcedMuteOrdering(adminFirst: Bool, video: Bool) async throws {
        try await exercise("admin-\(adminFirst)-\(video)") { engine in
            let cid = video ? "pending-video" : "pending-audio", sid = video ? "track-video" : "track-audio"
            engine.setLocalMuteIntent(false, video: video)
            engine.preparePublicationForTesting(cid: cid, video: video)
            var forced: [Bool] = []
            engine.onForcedMute = { forced.append($0) }
            if adminFirst {
                try await engine.processEventForTesting(adminMute(sid: sid, muted: true))
                precondition(engine.stateForTesting.intent[video] == false, "Unknown track prematurely muted a different publication")
                try await engine.processEventForTesting(published(cid: cid, sid: sid))
            } else {
                try await engine.processEventForTesting(published(cid: cid, sid: sid))
                precondition(engine.stateForTesting.intent[video] == false)
                try await engine.processEventForTesting(adminMute(sid: sid, muted: true))
            }
            precondition(engine.stateForTesting.intent[video] == true, "Administrator mute was lost around publication acknowledgement")
            precondition(forced == [video])
            // A server unmute event is not user consent to reopen capture/publication.
            try await engine.processEventForTesting(adminMute(sid: sid, muted: false))
            precondition(engine.stateForTesting.intent[video] == true)
        }
    }

    private static func startupIntentAndSuppression() async throws {
        try await exercise("startup") { engine in
            engine.identifyForTesting("local")
            for video in [false, true] {
                engine.setLocalMuteIntent(false, video: video)
                engine.preparePublicationForTesting(cid: "pending-\(video)", video: video)
                // The user mutes while startup is waiting for its publication acknowledgement.
                engine.setLocalMuteIntent(true, video: video)
                try await engine.processEventForTesting(published(cid: "pending-\(video)", sid: "track-\(video)"))
                precondition(engine.stateForTesting.intent[video] == true)
            }
            try await participant(engine, version: 1, muted: false)
            precondition(engine.stateForTesting.intent[false] == true, "Server confirmation overwrote a newer local mute")
            engine.setLocalMuteIntent(false, video: false)
            engine.setLocalMuteIntent(false, video: true)
            engine.suppressOutgoingMedia()
            // No await occurs between suppression and these assertions: privacy is synchronous.
            precondition(engine.stateForTesting.suppressed && engine.stateForTesting.intent[false] == true && engine.stateForTesting.intent[true] == true)
        }
    }

    private static func idempotentLeave() async throws {
        let engine = NativeGuestEngine(label: "Engine test leave")
        engine.setLocalMuteIntent(false, video: false)
        engine.setLocalMuteIntent(false, video: true)
        async let first = engine.leave(sendLeave: false)
        async let second = engine.leave(sendLeave: false)
        let results = await (first, second)
        precondition(results.0 && results.1)
        let repeated = await engine.leave()
        precondition(repeated)
        precondition(engine.stateForTesting.suppressed && engine.stateForTesting.intent[false] == true && engine.stateForTesting.intent[true] == true)
        precondition(engine.audio?.isInitialized == false && engine.audio?.isPlaying == false && engine.audio?.isRecording == false)
        do {
            try await engine.processEventForTesting(["event": "permissions-updated", "payload": ["canShareMicrophone": true]])
            preconditionFailure("Closed engine accepted a delayed event")
        } catch is CancellationError {}
    }

    private enum UnmuteInterruption: CaseIterable { case none, mute, revoke, leave }

    private static func gatedUnmute(_ action: UnmuteInterruption) async throws {
        try await exercise("unmute-\(action)") { engine in
            probeLog("test-unmute-phase", ["action": String(describing: action), "phase": "prepare"])
            let peer = try await engine.prepareVideoUnmuteForTesting()
            probeLog("test-unmute-phase", ["action": String(describing: action), "phase": "prepared"])
            guard let sender = peer.connection.senders.first(where: { $0.track?.kind == "video" }), let track = sender.track else {
                preconditionFailure("Fixture video sender is missing")
            }
            precondition(!track.isEnabled && !sender.parameters.encodings.isEmpty && sender.parameters.encodings.allSatisfy { !$0.isActive })
            let gate = NotifyGate()
            engine.mediaNotifyForTesting = { try await gate.notify($0) }
            engine.muteNotifyFinishedForTesting = { gate.finished.fire() }
            let unmute = Task { @MainActor in try await engine.mute(false, video: true) }
            await gate.entered.wait()
            probeLog("test-unmute-phase", ["action": String(describing: action), "phase": "notify-entered"])
            precondition(peer.videoEnableCallsForTesting == 0 && !track.isEnabled)
            switch action {
            case .none: break
            case .mute: engine.setLocalMuteIntent(true, video: true)
            case .revoke:
                try await engine.processEventForTesting(["event": "permissions-updated", "payload": ["canShareCamera": false]])
            case .leave:
                probeLog("test-unmute-phase", ["action": String(describing: action), "phase": "leaving"])
                let stopped = await engine.leave(sendLeave: false)
                precondition(stopped)
                probeLog("test-unmute-phase", ["action": String(describing: action), "phase": "left"])
            }
            gate.release()
            // This is the completion of the inner post-notify priming Task, which can
            // outlive the outer mute waiter when a privacy control supersedes it.
            await gate.finished.wait()
            probeLog("test-unmute-phase", ["action": String(describing: action), "phase": "notify-finished"])
            if action == .none {
                precondition(peer.videoEnableCallsForTesting == 1 && track.isEnabled && sender.parameters.encodings.allSatisfy { $0.isActive },
                             "Positive control did not execute the real video priming branch")
                try await engine.processEventForTesting(media("rtc:participants:update", ["update": ["participants": [[
                    "identity": "local", "sid": "participant-local", "version": 2,
                    "tracks": [["sid": "test-video-sid", "type": "VIDEO", "muted": false]]
                ]]]]))
                try await unmute.value
                precondition(peer.videoEnableCallsForTesting == 2 && track.isEnabled)
            } else {
                let outcome = await unmute.result
                if case .failure(let error) = outcome {
                    precondition(action == .leave && error is CancellationError, "Unexpected superseded-unmute error: \(error)")
                }
                precondition(peer.videoEnableCallsForTesting == 0, "Superseded unmute invoked video activation")
                precondition(!track.isEnabled && sender.parameters.encodings.allSatisfy { !$0.isActive },
                             "Superseded unmute reopened the track or encoding")
            }
            engine.mediaNotifyForTesting = nil; engine.muteNotifyFinishedForTesting = nil
        }
    }

    private final class MemoryCamera: GuestCameraCapture {
        var starts = 0, cancellations = 0, stops = 0
        var startGate: Signal?
        func start() async throws -> GuestCameraInfo {
            starts += 1
            await startGate?.wait()
            return .init(deviceName: "memory-only", width: 1280, height: 720, fps: 30,
                requestedWidth: 1280, requestedHeight: 720, requestedFPS: 30, sessionPreset: "fixture",
                minimumFrameDuration: CMTime(value: 1, timescale: 30), maximumFrameDuration: CMTime(value: 1, timescale: 30),
                pixelFormat: 0, mirrored: false, rotationDegrees: 0)
        }
        func cancel() { cancellations += 1 }
        func stop() async throws { stops += 1 }
        func snapshot() -> GuestCameraSnapshot {
            .init(frames: 0, advancingPTS: 0, dropped: 0, width: 0, height: 0, pixelFormat: nil,
                  systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false)
        }
        func performReaction() async -> Bool { false }
    }

    private static func mutedCameraPublicationAndDeniedKinds() async throws {
        for (microphone, camera) in [(true, true), (true, false), (false, true), (false, false)] {
            try await exercise("muted-publication-\(microphone)-\(camera)") { engine in
                let peer = try engine.prepareJoinForTesting(microphone: microphone, camera: camera)
                var captures = 0, kinds: [String] = []
                engine.cameraFactoryForTesting = { _ in captures += 1; return MemoryCamera() }
                engine.mediaNotifyForTesting = { payload in
                    if payload["method"] as? String == "rtc:track:add", let request = payload["addTrackRequest"] as? [String: Any],
                       let cid = request["cid"] as? String, let kind = request["type"] as? String {
                        kinds.append(kind)
                        try await engine.processEventForTesting(published(cid: cid, sid: "fixture-\(kind)"))
                    }
                }
                try await engine.publishPattern(codec: "h264", camera: true, audioMuted: true, videoMuted: true)
                precondition(captures == 0 && engine.localCameraTrack == nil, "Muted publication touched camera capture")
                precondition(kinds.contains("AUDIO") == microphone && kinds.contains("VIDEO") == camera,
                             "Only room-permitted muted kinds may be registered")
                precondition(peer.connection.senders.allSatisfy { $0.track?.isEnabled != true })
                if !microphone || !camera {
                    do {
                        try await engine.publishPattern(codec: "h264", camera: true)
                        preconditionFailure("Unmuted diagnostics must reject a denied publication kind")
                    } catch GuestEngineError.admissionDenied {}
                }
                engine.mediaNotifyForTesting = nil
            }
        }
    }

    private static func cameraPrivacyLifecycle() async throws {
        try await exercise("camera-privacy") { engine in
            let peer = try await engine.prepareVideoUnmuteForTesting(camera: true)
            let first = MemoryCamera(), second = MemoryCamera()
            var captures = [first, second], previews: [Bool] = []
            engine.cameraFactoryForTesting = { _ in captures.removeFirst() }
            engine.onLocalCameraTrackChange = { previews.append($0 != nil) }
            let gate = NotifyGate()
            engine.mediaNotifyForTesting = { try await gate.notify($0) }
            engine.muteNotifyFinishedForTesting = { gate.finished.fire() }
            let unmute = Task { try await engine.mute(false, video: true) }
            await gate.entered.wait()
            precondition(first.starts == 1 && peer.videoEnableCallsForTesting == 0 && engine.localCameraTrack != nil,
                         "Explicit video-on starts camera before SFU confirmation without sending RTP")
            engine.setLocalMuteIntent(true, video: true)
            precondition(first.cancellations > 0 && engine.localCameraTrack == nil && previews.last == false,
                         "Camera-off must synchronously cancel capture and clear local preview")
            gate.release(); await gate.finished.wait(); try await unmute.value
            try await engine.mute(true, video: true)
            precondition(first.stops == 1 && peer.videoEnableCallsForTesting == 0)
            engine.setLocalMuteIntent(false, video: true)
            engine.mediaNotifyForTesting = { _ in
                try await participant(engine, version: 2, muted: false, video: true)
            }
            try await engine.mute(false, video: true)
            precondition(second.starts == 1 && captures.isEmpty && engine.localCameraTrack != nil,
                         "Camera-on after stop creates a fresh capture owner")
            engine.suppressOutgoingMedia()
            precondition(second.cancellations > 0 && engine.localCameraTrack == nil)
            engine.mediaNotifyForTesting = nil; engine.muteNotifyFinishedForTesting = nil
        }
    }

    private static func cancelledCameraStart() async throws {
        try await exercise("camera-start-cancelled") { engine in
            let peer = try await engine.prepareVideoUnmuteForTesting(camera: true)
            let camera = MemoryCamera(), start = Signal()
            camera.startGate = start
            engine.cameraFactoryForTesting = { _ in camera }
            var notifications = 0
            engine.mediaNotifyForTesting = { _ in notifications += 1 }
            let unmute = Task { try await engine.mute(false, video: true) }
            for _ in 0..<1000 { if camera.starts > 0 { break }; await Task.yield() }
            precondition(camera.starts == 1)
            engine.setLocalMuteIntent(true, video: true)
            precondition(camera.cancellations > 0)
            start.fire(); try await unmute.value
            precondition(camera.stops == 1 && notifications == 0 && peer.videoEnableCallsForTesting == 0 && engine.localCameraTrack == nil,
                         "A delayed camera start cannot reopen publication after mute")
            engine.mediaNotifyForTesting = nil
        }
    }

    private static func receiverIdentityLifecycle() async throws {
        try await exercise("receiver-identity") { engine in
            let peer = try await engine.prepareVideoUnmuteForTesting()
            guard let video = peer.connection.transceivers.first?.receiver,
                  let additionalVideo = peer.connection.addTransceiver(of: .video)?.receiver,
                  let audio = peer.connection.addTransceiver(of: .audio)?.receiver else {
                preconditionFailure("Fixture receivers are missing")
            }
            var rendererSnapshots: [[GuestRemoteVideo]] = []
            peer.onIncomingVideoChange = { rendererSnapshots.append($0) }
            precondition(rendererSnapshots.count == 1 && rendererSnapshots[0].isEmpty)
            let firstRead = video.track!, secondRead = video.track!
            precondition(firstRead !== secondRead && firstRead.isEqual(secondRead), "Fixture must exercise new wrappers of the same native track")
            precondition(!firstRead.isEqual(additionalVideo.track!), "New receiver must have a distinct native track")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: video, streams: []) }
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: video, streams: []) }
            precondition(peer.receiverAttachmentsForTesting == 1 && peer.retainedReceiverTracksForTesting == 1)
            precondition(rendererSnapshots.count == 2 && rendererSnapshots.last?.count == 1)
            let firstID = rendererSnapshots.last!.first!.id
            precondition(rendererSnapshots.last!.first!.track.isEqual(firstRead))
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: additionalVideo, streams: []) }
            precondition(peer.receiverAttachmentsForTesting == 2 && peer.retainedReceiverTracksForTesting == 2)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didRemove: video) }
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didRemove: video) }
            precondition(peer.receiverDetachmentsForTesting == 1 && peer.retainedReceiverTracksForTesting == 1)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: video, streams: []) }
            precondition(peer.receiverAttachmentsForTesting == 3 && peer.retainedReceiverTracksForTesting == 2)
            precondition(peer.receivedVideo.last?.id != firstID, "Reattachment has a new renderer lifecycle identity")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didRemove: video) }
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didRemove: additionalVideo) }
            precondition(peer.receiverDetachmentsForTesting == 3 && peer.retainedReceiverTracksForTesting == 0)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: audio, streams: []) }
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: audio, streams: []) }
            precondition(peer.receiverAttachmentsForTesting == 4 && peer.retainedReceiverTracksForTesting == 1)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didRemove: audio) }
            precondition(peer.receiverDetachmentsForTesting == 4 && peer.retainedReceiverTracksForTesting == 0)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: video, streams: []) }
            precondition(peer.receivedVideo.count == 1)
            peer.close()
            precondition(rendererSnapshots.last?.isEmpty == true && peer.receivedVideo.isEmpty,
                         "Closing clears all native renderer references")
        }
    }

    private static func receiverPublicationReassociation() async throws {
        try await exercise("receiver-publication") { engine in
            let peer = try engine.prepareSubscriberForTesting()
            guard let receiver = peer.connection.addTransceiver(of: .video)?.receiver,
                  let nativeTrack = receiver.track as? LKRTCVideoTrack else {
                preconditionFailure("Fixture video receiver is missing")
            }
            let old = peer.factory.mediaStream(withStreamId: "PA_remote|TR_old")
            let replacement = peer.factory.mediaStream(withStreamId: "PA_remote|TR_new")
            let wrongOwner = peer.factory.mediaStream(withStreamId: "PA_other|TR_new")
            func snapshot(_ version: Int, replacement: Bool = false, disconnected: Bool = false, muted: Bool = false) async throws {
                var tracks: [[String: Any]] = [
                    ["sid": nativeTrack.trackId, "type": "VIDEO", "source": "CAMERA", "muted": muted],
                    ["sid": "TR_old", "type": "VIDEO", "source": "CAMERA", "muted": muted]
                ]
                if replacement { tracks.append(["sid": "TR_new", "type": "VIDEO", "source": "SCREEN_SHARE", "muted": muted]) }
                try await engine.processEventForTesting(media("rtc:participants:update", ["update": ["participants": [[
                    "identity": "remote", "sid": "PA_remote", "name": replacement ? "Replacement" : "Original",
                    "version": version, "state": disconnected ? "DISCONNECTED" : "CONNECTED", "tracks": tracks
                ]]]]))
            }
            var snapshots: [[GuestRemoteVideo]] = []
            engine.onIncomingVideoChange = { snapshots.append($0) }
            try await snapshot(1)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [old]) }
            let firstID = engine.incomingVideo.first!.id
            precondition(engine.incomingVideo.first?.source == "CAMERA")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [replacement]) }
            precondition(engine.incomingVideo.first?.source == nil,
                         "Replacement must wait for its authoritative metadata, not reuse the RTC track's old CAMERA source")
            precondition(engine.incomingVideo.first?.streamIDs == ["PA_remote|TR_new"] && engine.incomingVideo.first?.id == firstID)
            let beforeDuplicate = snapshots.count
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [replacement]) }
            precondition(snapshots.count == beforeDuplicate && peer.receiverAttachmentsForTesting == 1,
                         "Stream reassociation preserves one renderer; exact duplicate callbacks do not notify")
            try await snapshot(2, replacement: true)
            precondition(engine.incomingVideo.first?.source == "SCREEN_SHARE" && engine.incomingVideo.first?.participantName == "Replacement")
            precondition(engine.incomingVideo.first?.track.isEqual(nativeTrack) == true && engine.incomingVideo.first?.id == firstID)
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [wrongOwner]) }
            precondition(engine.incomingVideo.first?.source == nil, "A stream owner mismatch must not expose another participant's metadata")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [old, replacement]) }
            precondition(engine.incomingVideo.first?.source == nil, "Ambiguous publication references must fail closed")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: []) }
            precondition(engine.incomingVideo.first?.source == "CAMERA", "RTC track SID remains the fallback without a legacy publication SID")
            await receiverEvent(peer) { peer.peerConnection(peer.connection, didAdd: receiver, streams: [replacement]) }
            try await snapshot(3, replacement: true, muted: true)
            precondition(engine.incomingVideo.isEmpty && peer.receiverAttachmentsForTesting == 1 && peer.receiverDetachmentsForTesting == 0,
                         "A muted camera hides its stale frame without dropping the receiver")
            try await snapshot(4, replacement: true)
            precondition(engine.incomingVideo.first?.id == firstID,
                         "Unmuting restores the same receiver without a new track attachment")
            try await snapshot(1)
            precondition(engine.incomingVideo.first?.source == "SCREEN_SHARE", "Stale participant metadata must not undo reassociation")
            try await snapshot(5, disconnected: true)
            precondition(engine.incomingVideo.isEmpty && snapshots.last?.isEmpty == true,
                         "A departed publication must not expose a frozen orphan receiver")
            precondition(peer.receiverAttachmentsForTesting == 1 && peer.receiverDetachmentsForTesting == 0)
            try await snapshot(6, replacement: true)
            precondition(engine.incomingVideo.first?.id == firstID && engine.incomingVideo.first?.source == "SCREEN_SHARE",
                         "A fresh authoritative publication can reuse the retained receiver")
        }
    }

    private static func receiverEvent(_ peer: GuestPeer, _ callback: () -> Void) async {
        await withCheckedContinuation { finished in
            peer.receiverEventFinishedForTesting = {
                peer.receiverEventFinishedForTesting = nil
                finished.resume()
            }
            callback()
        }
    }

    @MainActor private final class Signal {
        private var fired = false
        private var waiter: CheckedContinuation<Void, Never>?
        func fire() { fired = true; waiter?.resume(); waiter = nil }
        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiter = $0 }
        }
    }

    @MainActor private final class NotifyGate {
        let entered = Signal(), finished = Signal()
        private var continuation: CheckedContinuation<Void, Never>?
        func notify(_ payload: [String: Any]) async throws {
            precondition(payload["method"] as? String == "rtc:track:muted")
            precondition((payload["mute"] as? [String: Any])?["muted"] as? Bool == false)
            entered.fire()
            await withCheckedContinuation { continuation = $0 }
        }
        func release() { let pending = continuation; continuation = nil; pending?.resume() }
    }

    private static func media(_ method: String, _ values: [String: Any]) -> [String: Any] {
        ["event": "media-out", "payload": values.merging(["method": method]) { _, new in new }]
    }
    private static func published(cid: String, sid: String) -> [String: Any] {
        media("rtc:track:published", ["trackPublishedResponse": ["cid": cid, "track": ["sid": sid]]])
    }
    private static func adminMute(sid: String, muted: Bool) -> [String: Any] {
        media("rtc:track:muted", ["mute": ["sid": sid, "muted": muted]])
    }
}
