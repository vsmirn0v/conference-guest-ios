import Foundation

/// Exactly one physical ADM. The other endpoint generates and measures PCM without hardware.
/// Quiet-window return energy is diagnostic only; it cannot qualify near-end speech or double talk.
@MainActor enum GuestDuplexProbe {
    static func run(_ invitation: GuestInvitation, seconds: UInt64, codec: String, compareProcessing: Bool = false, reconnectCycles: Int = 1, soakSeconds: Int = 0, icePolicy: GuestICEPolicy = .automatic) async throws {
        let local = GuestSession(makeEngine: {
            let audio = try await GuestSystemAudio.create(microphoneEnabled: true, playoutEnabled: true)
            return NativeGuestEngine(label: "Native duplex Mac", systemAudio: audio, icePolicy: icePolicy)
        })
        let remote = GuestSession(makeEngine: { NativeGuestEngine(label: "Native duplex synthetic peer", icePolicy: icePolicy) })
        probeLog("duplex-policy", ["icePolicy": icePolicy.rawValue, "soakSeconds": soakSeconds])
        do {
            try await local.connect(invitation, publish: true, codec: codec, camera: false)
            try await remote.connect(invitation, publish: true, codec: codec, camera: false)
            try await waitForMedia(local, remote)
            try await Task.sleep(nanoseconds: 4_000_000_000)
            let normal = try await window(local, remote, phase: "duplex-active", seconds: min(seconds, 15))
            let comparison = compareProcessing ? try await compare(local, remote, normal: normal, seconds: min(seconds, 15)) : nil
            var qualityPassed = true
            if soakSeconds > 0 { qualityPassed = try await soak(local, remote, phase: "before-reconnect", seconds: soakSeconds / 2) }
            for cycle in 1...3 {
                let before = try await hardware(local)
                try await local.mute(true)
                try await Task.sleep(nanoseconds: 1_000_000_000)
                try await window(local, remote, phase: "mic-muted-\(cycle)", seconds: 3, muted: true)
                try await local.mute(false)
                try await window(local, remote, phase: "mic-resumed-\(cycle)", seconds: 3)
                let after = try await hardware(local)
                guard count(before, "engineStarts") == count(after, "engineStarts"),
                      count(before, "engineStops") == count(after, "engineStops") else { throw GuestEngineError.mediaMissing }
            }
            guard let audio = local.engine?.systemAudio, await audio.setPlayoutEnabled(false) else { throw GuestEngineError.disconnected }
            try await window(local, remote, phase: "playout-disabled", seconds: 3, playing: false)
            guard await audio.setPlayoutEnabled(true) else { throw GuestEngineError.disconnected }
            try await window(local, remote, phase: "playout-restored", seconds: 4)

            for cycle in 1...reconnectCycles {
                try await local.mute(true)
                probeLog("duplex-reconnect-begin", ["side": "remote", "cycle": cycle, "attemptsUsed": remote.recoveryAttempts])
                try await remote.reconnectForTesting()
                try await waitForMedia(local, remote)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await window(local, remote, phase: "remote-reconnected-\(cycle)", seconds: 4, muted: true)
                probeLog("duplex-reconnect-begin", ["side": "physical", "cycle": cycle, "attemptsUsed": local.recoveryAttempts])
                try await local.reconnectForTesting()
                try await waitForMedia(local, remote)
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await window(local, remote, phase: "physical-reconnected-muted-\(cycle)", seconds: 4, muted: true)
                try await local.mute(false)
                try await window(local, remote, phase: "physical-reconnected-resumed-\(cycle)", seconds: 4)
            }
            if soakSeconds > 0 {
                let afterQuality = try await soak(local, remote, phase: "after-reconnect", seconds: soakSeconds / 2)
                qualityPassed = qualityPassed && afterQuality
            }
            if compareProcessing {
                guard let freshAudio = local.engine?.systemAudio,
                      await freshAudio.setVoiceProcessingBypassedForTesting(true) else { throw GuestEngineError.disconnected }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                try await window(local, remote, phase: "physical-reconnected-acoustic-control", seconds: 4,
                    bypassed: true, requireMicrophoneReturn: true)
                guard await freshAudio.setVoiceProcessingBypassedForTesting(false) else { throw GuestEngineError.disconnected }
                try await Task.sleep(nanoseconds: 4_000_000_000)
                try await window(local, remote, phase: "physical-reconnected-normal-restored", seconds: 4)
            }
            probeLog("duplex-reconnect-evidence", ["localConnections": local.connectionCount,
                "remoteConnections": remote.connectionCount, "localAttempts": local.recoveryAttempts,
                "remoteAttempts": remote.recoveryAttempts])
            let localStopped = await local.leave(), remoteStopped = await remote.leave()
            guard localStopped && remoteStopped else { throw GuestEngineError.disconnected }
            try GuestDuplexAcceptance.requireSoakQuality(qualityPassed, seconds: soakSeconds)
            probeLog("duplex-pass", ["normalPlatformAEC": true, "physicalADMs": 1,
                "comparisonBypassUsed": compareProcessing, "reconnectCycles": reconnectCycles,
                "soakSeconds": soakSeconds, "soakQualityPassed": soakSeconds > 0 ? qualityPassed as Any : NSNull(),
                "processingComparison": comparison as Any? ?? NSNull(),
                "nearEndSpeechQualified": false, "doubleTalkQualified": false])
        } catch {
            // Suppress publication synchronously before any diagnostic/native await,
            // especially if a diagnostic failure occurs while processing is bypassed.
            local.engine?.suppressOutgoingMedia()
            remote.engine?.suppressOutgoingMedia()
            if let engine = local.engine { probeLog("duplex-failure-local", await engine.evidence()) }
            if let engine = remote.engine { probeLog("duplex-failure-remote", await engine.evidence()) }
            _ = await local.leave(); _ = await remote.leave()
            throw error
        }
    }

    private static func waitForMedia(_ local: GuestSession, _ remote: GuestSession) async throws {
        let started = ProcessInfo.processInfo.systemUptime
        guard var macEngine = local.engine, var peerEngine = remote.engine else { throw GuestEngineError.disconnected }
        var readiness = GuestVideoReadiness(localID: ObjectIdentifier(macEngine), remoteID: ObjectIdentifier(peerEngine),
            local: macEngine.mediaSnapshot, remote: peerEngine.mediaSnapshot)
        while ProcessInfo.processInfo.systemUptime - started < 20 {
            if let failure = local.failure ?? remote.failure { throw failure }
            if let mac = local.engine, let peer = remote.engine {
                // The surviving renderer retains earlier frames. Only progress
                // after this wait began can demonstrate resumed delivery.
                let macNow = mac.mediaSnapshot, peerNow = peer.mediaSnapshot
                let ready = readiness.observe(localID: ObjectIdentifier(mac), remoteID: ObjectIdentifier(peer),
                    local: macNow, remote: peerNow)
                // Retain the old objects until observation so identities cannot
                // be reused between checks after teardown.
                macEngine = mac; peerEngine = peer
                if ready {
                    probeLog("duplex-media-ready", ["waitSeconds": ProcessInfo.processInfo.systemUptime - started,
                        "freshFramesToMac": macNow.advancingFrames(since: readiness.localBaseline),
                        "freshFramesToPeer": peerNow.advancingFrames(since: readiness.remoteBaseline)])
                    return
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        probeLog("duplex-media-timeout", ["mac": macEngine.mediaSnapshot.render,
            "peer": peerEngine.mediaSnapshot.render, "macBaseline": readiness.localBaseline.render,
            "peerBaseline": readiness.remoteBaseline.render])
        throw GuestTransportError.timedOut
    }

    static func hardware(_ session: GuestSession) async throws -> [String: Any] {
        guard let engine = session.engine, let audio = engine.systemAudio else { throw GuestEngineError.disconnected }
        let start = ProcessInfo.processInfo.systemUptime
        guard await audio.refreshSnapshot() else { throw GuestSystemAudioError.setupFailedOrTimedOut }
        let snapshot = audio.snapshot
        guard (snapshot["snapshotUptime"] as? Double ?? 0) >= start else { throw GuestSystemAudioError.setupFailedOrTimedOut }
        return snapshot
    }

    private static func count(_ snapshot: [String: Any], _ field: String) -> Int { snapshot[field] as? Int ?? 0 }

    struct Measurement {
        let incoming: GuestAudioSnapshot
        let returned: GuestAudioSnapshot
        let hardware: [String: Any]
        let environment: GuestAcousticEnvironment
        let localConnections: UInt64
        let remoteConnections: UInt64
        let smooth: Bool
    }

    @discardableResult private static func window(_ local: GuestSession, _ remote: GuestSession, phase: String,
                               seconds: UInt64, muted: Bool = false, playing: Bool = true,
                               bypassed: Bool = false, remoteAudio: Bool = true,
                               requireMicrophoneReturn: Bool = false) async throws -> Measurement {
        guard let mac = local.engine, let peer = remote.engine else { throw GuestEngineError.disconnected }
        let beforeMacRTP = await mac.evidence(), beforePeerRTP = await peer.evidence()
        let beforeLocal = mac.mediaSnapshot, beforeRemote = peer.mediaSnapshot
        let beforeHardware = try await hardware(local)
        let environment = GuestAcousticEnvironment.capture()
        guard GuestDuplexAcceptance.hardware(beforeHardware, muted: muted, playing: playing, bypassed: bypassed) else { throw GuestEngineError.mediaMissing }
        let windowStart = ProcessInfo.processInfo.systemUptime
        try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        let windowEnd = ProcessInfo.processInfo.systemUptime
        let macTiming = mac.subscriber?.renderer.window(from: windowStart, to: windowEnd) ?? .invalid
        let peerTiming = peer.subscriber?.renderer.window(from: windowStart, to: windowEnd) ?? .invalid
        let afterLocal = mac.mediaSnapshot, afterRemote = peer.mediaSnapshot
        let state = try await hardware(local)
        let afterMacRTP = await mac.evidence(), afterPeerRTP = await peer.evidence()
        let sentPackets = audioPackets(afterMacRTP, outbound: true) - audioPackets(beforeMacRTP, outbound: true)
        let receivedPackets = audioPackets(afterPeerRTP, outbound: false) - audioPackets(beforePeerRTP, outbound: false)
        let incoming = afterLocal.audio.since(beforeLocal.audio), returned = afterRemote.audio.since(beforeRemote.audio)
        let checks = [
            "sameHealthySessions": local.engine === mac && remote.engine === peer && local.failure == nil && remote.failure == nil,
            "videoToMac": afterLocal.hasFreshVideo(since: beforeLocal, expectation: .movingPattern),
            "videoToPeer": afterRemote.hasFreshVideo(since: beforeRemote, expectation: .movingPattern),
            // The native output source pulls the track PCM sink. Availability-off
            // can stop that pull, so require fresh incoming PCM again on restore.
            "incomingPCM": !playing || (remoteAudio ? incoming.samples >= Int(seconds) * 43_200 && incoming.rms > 0.001 : incoming.rms < 0.0002),
            "returnPCM": muted || returned.samples >= Int(seconds) * 43_200,
            "outgoingMicrophoneRTP": muted || sentPackets > 0,
            "microphoneControl": !requireMicrophoneReturn || (receivedPackets > 0 && returned.rms > 0.0002),
            "transportPolicy": [beforeMacRTP, afterMacRTP, beforePeerRTP, afterPeerRTP].allSatisfy(GuestDuplexAcceptance.transport),
            "senderStatsFresh": [beforeMacRTP, afterMacRTP].allSatisfy { $0["publisherStatsFresh"] as? Bool == true },
            "receiverStatsFresh": [beforePeerRTP, afterPeerRTP].allSatisfy { $0["subscriberStatsFresh"] as? Bool == true },
            "muteSilence": !muted || returned.rms < 0.0002,
            "hardware": GuestDuplexAcceptance.hardware(state, muted: muted, playing: playing, bypassed: bypassed),
            "noEngineStart": count(beforeHardware, "engineStarts") == count(state, "engineStarts"),
            "noEngineStop": count(beforeHardware, "engineStops") == count(state, "engineStops")]
        let pass = checks.values.allSatisfy { $0 }
        var result: [String: Any] = ["phase": phase, "pass": pass, "muted": muted, "playoutExpected": playing,
            "checks": checks, "videoFramesToMac": afterLocal.advancingFrames(since: beforeLocal),
            "videoFramesToPeer": afterRemote.advancingFrames(since: beforeRemote),
            "incomingSamples": incoming.samples, "incomingRMS": incoming.rms,
            "returnedSamples": returned.samples, "returnedRMS": returned.rms,
            "microphonePacketsSent": sentPackets, "microphonePacketsReceived": receivedPackets,
            "remoteMicrophoneTransportObserved": receivedPackets > 0,
            "returnObservation": returned.samples > 0 ? (muted ? "measured-silence" : "measured-pcm") : "no-receiver-audio",
            "hardware": state, "nearEndSpeechQualified": false]
        if returned.rms > 0, incoming.rms > 0 {
            result["returnToIncomingDB"] = 20 * log10(returned.rms / incoming.rms)
        }
        result["windowStart"] = windowStart; result["windowEnd"] = windowEnd
        result["timingToMac"] = macTiming.evidence; result["timingToPeer"] = peerTiming.evidence
        result["localVideoBefore"] = beforeMacRTP["localVideo"]
        result["localVideoAfter"] = afterMacRTP["localVideo"]
        result["remoteVideoBefore"] = beforePeerRTP["localVideo"]
        result["remoteVideoAfter"] = afterPeerRTP["localVideo"]
        result["videoBeforeMac"] = beforeLocal.render
        result["videoAfterMac"] = afterLocal.render
        result["videoBeforePeer"] = beforeRemote.render
        result["videoAfterPeer"] = afterRemote.render
        result["beforeMacStats"] = beforeMacRTP["stats"]
        result["afterMacStats"] = afterMacRTP["stats"]
        result["beforePeerStats"] = beforePeerRTP["stats"]
        result["afterPeerStats"] = afterPeerRTP["stats"]
        probeLog("duplex-window", result)
        guard pass else { throw GuestEngineError.mediaMissing }
        return Measurement(incoming: incoming, returned: returned, hardware: state,
            environment: environment == GuestAcousticEnvironment.capture() ? environment : .unavailable,
            localConnections: local.connectionCount, remoteConnections: remote.connectionCount, smooth: macTiming.smooth && peerTiming.smooth)
    }

    private static func soak(_ local: GuestSession, _ remote: GuestSession, phase: String, seconds: Int) async throws -> Bool {
        var smooth = true
        for interval in 1...(seconds / 10) {
            let sample = try await window(local, remote, phase: "soak-\(phase)-\(interval)", seconds: 10)
            smooth = sample.smooth && smooth
        }
        probeLog("duplex-soak-quality", ["phase": phase, "seconds": seconds, "passed": smooth,
            "minimumFPS": 12, "maximumGapExclusive": 1, "endAgeExclusive": 0.5])
        return smooth
    }

    private static func audioPackets(_ evidence: [String: Any], outbound: Bool) -> Int {
        (evidence["stats"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == (outbound ? "outbound-rtp" : "inbound-rtp") && $0["kind"] as? String == "audio"
        }.reduce(0) { $0 + (($1[outbound ? "packetsSent" : "packetsReceived"] as? NSNumber)?.intValue ?? 0) }
    }

    private static func compare(_ local: GuestSession, _ remote: GuestSession, normal: Measurement, seconds: UInt64) async throws -> [String: Any] {
        guard let audio = local.engine?.systemAudio else { throw GuestEngineError.disconnected }
        try await remote.mute(true)
        guard await audio.setVoiceProcessingBypassedForTesting(true) else { throw GuestEngineError.disconnected }
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let background = try await window(local, remote, phase: "comparison-bypass-background", seconds: seconds, bypassed: true, remoteAudio: false)
        try await remote.mute(false)
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let bypass = try await window(local, remote, phase: "comparison-bypass-tone", seconds: seconds,
            bypassed: true, requireMicrophoneReturn: true)
        guard await audio.setVoiceProcessingBypassedForTesting(false) else { throw GuestEngineError.disconnected }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let restored = try await window(local, remote, phase: "comparison-normal-restored", seconds: seconds)
        func decibels(_ a: Double, _ b: Double) -> Double { 20 * log10(max(a, 1e-9) / max(b, 1e-9)) }
        let couplingDB = decibels(bypass.returned.rms, background.returned.rms)
        let referenceDrift = max(abs(decibels(bypass.incoming.rms, normal.incoming.rms)), abs(decibels(bypass.incoming.rms, restored.incoming.rms)))
        let stable = [background, bypass, restored].allSatisfy { measurement in
            measurement.environment == normal.environment &&
            measurement.localConnections == normal.localConnections && measurement.remoteConnections == normal.remoteConnections &&
            ["enginesCreated", "engineStarts", "engineStops", "deviceUpdates"].allSatisfy { count(measurement.hardware, $0) == count(normal.hardware, $0) }
        }
        let valid = normal.environment.audibleOutputConfigured && stable && referenceDrift < 1 && couplingDB > 10 && bypass.returned.rms > 0.0002
        var result: [String: Any] = ["validMeasurement": valid,
            "bypassToneOverBackgroundDB": couplingDB, "referenceDriftDB": referenceDrift,
            "routeVolumeAndEngineStable": stable, "isolatedAECGain": false, "signal": "440Hz tone",
            "nearEndSpeechQualified": false, "normalProcessingRestored": true]
        if valid { result["normalProfileReturnAttenuationDB"] = decibels(bypass.returned.rms, max(normal.returned.rms, restored.returned.rms)) }
        probeLog("processing-comparison", result)
        return result
    }
}

enum GuestDuplexAcceptance {
    static func requireSoakQuality(_ passed: Bool, seconds: Int) throws {
        guard seconds == 0 || passed else { throw GuestEngineError.mediaMissing }
    }

    static func transport(_ evidence: [String: Any]) -> Bool {
        guard let name = evidence["icePolicy"] as? String, let policy = GuestICEPolicy(rawValue: name) else { return false }
        guard policy != .automatic else { return true }
        guard evidence["subscriberStatsFresh"] as? Bool == true, evidence["publisherStatsFresh"] as? Bool == true else { return false }
        let locals = (evidence["stats"] as? [[String: Any]] ?? []).filter { $0["type"] as? String == "local-candidate" }
        return Set(locals.compactMap { $0["target"] as? String }) == Set(["SUBSCRIBER", "PUBLISHER"]) &&
            locals.allSatisfy { candidate in
                guard let target = (candidate["target"] as? String).flatMap(GuestPeerTarget.init(rawValue:)) else { return false }
                return candidate["candidateType"] as? String == "relay" &&
                    (policy.forTarget(target) == .tcpRelay ? ["tcp", "tls"] : ["udp"]).contains(candidate["relayProtocol"] as? String ?? "")
            }
    }

    static func hardware(_ state: [String: Any], muted: Bool, playing: Bool, bypassed: Bool = false) -> Bool {
        state["engineRunning"] as? Bool == true && state["inputAvailable"] as? Bool == true &&
        state["inputRunning"] as? Bool == true && state["recording"] as? Bool == true &&
        // engineState.outputRunning and isPlaying report WebRTC demand; disabling
        // availability gates the path without clearing that demand. This checks
        // configured routing, not acoustic silence or measured speaker output.
        state["outputAvailable"] as? Bool == playing &&
        (!playing || (state["outputRunning"] as? Bool == true && state["playing"] as? Bool == true)) &&
        state["microphoneMuted"] as? Bool == muted && state["voiceProcessingActive"] as? Bool == true &&
        state["voiceProcessingBypassedActive"] as? Bool == bypassed && state["echoCancellationActive"] as? Bool == !bypassed &&
        (state["inputSampleRate"] as? Double ?? 0) >= 44_100 && (state["outputSampleRate"] as? Double ?? 0) >= 44_100
    }
}

extension GuestMediaSnapshot {
    /// After jitter drains, mute must stop frame delivery, including identical
    /// pixels and replayed timestamps. A reset/missing baseline is not silence.
    func hasQuiescentVideo(since before: Self) -> Bool {
        connected && !failed && ["frames", "advancingFrames", "pixelChanges"].allSatisfy { key in
            guard let first = before.render[key] as? Int, let last = render[key] as? Int,
                  first >= 0, last >= first else { return false }
            return last - first <= 2
        }
    }
}
