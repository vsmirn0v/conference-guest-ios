import Foundation

/// One synthetic publisher/receiver. Its only remote sender is the installed
/// physical companion; a second synthetic publisher would invalidate evidence.
enum GuestCompanionPeerError: Error { case invalidControl }

@MainActor enum GuestCompanionPeer {
    private struct Command: Decodable {
        enum Operation: String, Decodable { case measure, reconnect, stop }
        var sequence: Int
        var operation: Operation
        var phase: String
        var audio: Bool
        var video: Bool
        var remoteParticipants: Int
        var requireSignal: Bool?
    }
    static func run(_ invitation: GuestInvitation, directory: URL, seconds: UInt64, icePolicy: GuestICEPolicy = .automatic, monitorSender: Bool = false) async throws {
        let session = GuestSession(makeEngine: { NativeGuestEngine(label: "Companion qualification peer", icePolicy: icePolicy) })
        var sequence = 0
        do {
            try await session.connect(invitation, publish: true, codec: "h264", camera: false)
            guard session.engine?.admittedParticipants == 1 else { throw GuestEngineError.mediaMissing }
            try write(["ready": true], to: directory.appendingPathComponent("ready.json"))
            probeLog("companion-peer-ready", ["initiallyAlone": true])
            let deadline = ProcessInfo.processInfo.systemUptime + Double(seconds)
            var stopped = false
            var nextSenderSample = 0.0
            while ProcessInfo.processInfo.systemUptime < deadline {
                if let failure = session.failure { throw failure }
                if monitorSender, ProcessInfo.processInfo.systemUptime >= nextSenderSample, let engine = session.engine {
                    let stats = await engine.evidence()
                    probeLog("companion-sender-sample", ["sampleUptime": ProcessInfo.processInfo.systemUptime,
                        "connections": session.connectionCount, "evidence": stats])
                    nextSenderSample = ProcessInfo.processInfo.systemUptime + 1
                }
                let url = directory.appendingPathComponent("command.json")
                if let bytes = try? Data(contentsOf: url), bytes.count <= 4096,
                   let command = try? JSONDecoder().decode(Command.self, from: bytes), command.sequence > sequence {
                    guard command.sequence == sequence + 1, command.phase.utf8.count <= 64 else { throw GuestCompanionPeerError.invalidControl }
                    sequence = command.sequence
                    var result: [String: Any] = ["sequence": sequence, "phase": command.phase]
                    switch command.operation {
                    case .measure:
                        result.merge(try await measure(session, audio: command.audio, video: command.video, remoteParticipants: command.remoteParticipants, requireSignal: command.requireSignal ?? true)) { _, new in new }
                    case .reconnect:
                        try await session.reconnectForTesting()
                        result["pass"] = session.engine?.admittedParticipants == 2
                        result["connections"] = session.connectionCount
                    case .stop:
                        result["pass"] = await session.leave(); stopped = true
                    }
                    probeLog("companion-peer-result", result)
                    try write(result, to: directory.appendingPathComponent("result.json"))
                    if stopped { break }
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard stopped, await session.leave() else { throw GuestEngineError.disconnected }
        } catch { _ = await session.leave(); throw error }
    }
    private static func measure(_ session: GuestSession, audio: Bool, video: Bool, remoteParticipants: Int, requireSignal: Bool) async throws -> [String: Any] {
        guard let waitingEngine = session.engine else { throw GuestEngineError.disconnected }
        let waitingConnection = session.connectionCount
        let departing = waitingEngine.connectedRemoteParticipants
        try await Task.sleep(nanoseconds: 2_000_000_000) // Drain pre-mute jitter/decoder data.
        let departureStarted = ProcessInfo.processInfo.systemUptime
        let quiescence = waitingEngine.mediaSnapshot
        var departureFrames = 0, departureRMS = 0.0
        if remoteParticipants == 0 {
            guard departing.count <= 1 else { throw GuestEngineError.mediaMissing }
            while true {
                let snapshot = waitingEngine.mediaSnapshot
                departureFrames = snapshot.advancingFrames(since: quiescence)
                departureRMS = snapshot.audio.since(quiescence.audio).rms
                guard session.engine === waitingEngine, session.connectionCount == waitingConnection,
                      session.failure == nil, waitingEngine.connectedRemoteParticipants.isSubset(of: departing),
                      departureFrames <= 2, departureRMS < 0.0002 else { throw GuestEngineError.mediaMissing }
                if waitingEngine.connectedRemoteParticipants.isEmpty { break }
                guard ProcessInfo.processInfo.systemUptime - departureStarted < 15 else {
                    probeLog("companion-peer-departure-timeout", ["remoteParticipants": waitingEngine.connectedRemoteParticipants.count])
                    throw GuestEngineError.mediaMissing
                }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        let departureWait = ProcessInfo.processInfo.systemUptime - departureStarted
        guard let engine = session.engine else { throw GuestEngineError.disconnected }
        let generation = session.connectionCount
        let participants = engine.connectedRemoteParticipants, mediaGeneration = engine.remoteMediaGeneration
        let first = engine.mediaSnapshot, firstStats = await engine.evidence()
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let last = engine.mediaSnapshot, lastStats = await engine.evidence()
        let pcm = last.audio.since(first.audio), frames = last.advancingFrames(since: first)
        let packets = audioPackets(lastStats) - audioPackets(firstStats)
        let width = (last.render["width"] as? NSNumber)?.intValue ?? 0
        let height = (last.render["height"] as? NSNumber)?.intValue ?? 0
        let checks = [
            "sameHealthyEngine": session.engine === engine && generation == session.connectionCount && session.failure == nil && !last.failed && last.connected,
            "exclusiveRemoteParticipant": (0...1).contains(remoteParticipants) && participants.count == remoteParticipants &&
                engine.connectedRemoteParticipants == participants && engine.remoteMediaGeneration == mediaGeneration && engine.admittedParticipants <= 2,
            "freshRTP": [firstStats, lastStats].allSatisfy { $0["subscriberStatsFresh"] as? Bool == true },
            "audio": audio ? pcm.samples > 150_000 && (!requireSignal || pcm.rms > 0.0002) && packets > 0 : pcm.rms < 0.0002,
            "video": video ? frames > 20 && width > 0 && height > 0 : frames <= 2
        ]
        return ["pass": checks.values.allSatisfy { $0 }, "checks": checks, "connections": generation,
                "samples": pcm.samples, "rms": pcm.rms, "audioPackets": packets, "videoFrames": frames,
                "videoPacketsBefore": videoCounter(firstStats, "packetsReceived"),
                "videoPacketsAfter": videoCounter(lastStats, "packetsReceived"),
                "videoDecodedBefore": videoCounter(firstStats, "framesDecoded"),
                "videoDecodedAfter": videoCounter(lastStats, "framesDecoded"),
                "width": width, "height": height, "audioExpected": audio, "videoExpected": video,
                "rosterWaitSeconds": departureWait, "departureWaitFrames": departureFrames, "departureWaitRMS": departureRMS, "remoteParticipantsBefore": participants.count,
                "remoteParticipantsAfter": engine.connectedRemoteParticipants.count,
                "mediaGenerationBefore": mediaGeneration, "mediaGenerationAfter": engine.remoteMediaGeneration,
                "strictAcoustic": requireSignal, "nonSilentObserved": audio && pcm.rms > 0.0002]
    }
    private static func audioPackets(_ evidence: [String: Any]) -> Int {
        (evidence["stats"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "audio"
        }.reduce(0) { $0 + (($1["packetsReceived"] as? NSNumber)?.intValue ?? 0) }
    }
    private static func videoCounter(_ evidence: [String: Any], _ key: String) -> Int {
        (evidence["stats"] as? [[String: Any]] ?? []).filter {
            $0["type"] as? String == "inbound-rtp" && $0["kind"] as? String == "video"
        }.reduce(0) { $0 + (($1[key] as? NSNumber)?.intValue ?? 0) }
    }
    private static func write(_ value: [String: Any], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
