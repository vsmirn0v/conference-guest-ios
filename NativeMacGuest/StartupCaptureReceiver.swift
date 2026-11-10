#if DEBUG
import AppKit
import Darwin
import Foundation
import LiveKitWebRTC

private struct StartupCaptureChannel {
    let id: String
    let directory: URL
    var telemetry: URL { directory.appendingPathComponent("telemetry.json") }
    var stop: URL { directory.appendingPathComponent("stop.json") }
    var statsRequest: URL { directory.appendingPathComponent("stats-request.json") }
    var stats: URL { directory.appendingPathComponent("stats.json") }
    var startupStatsRequest: URL { directory.appendingPathComponent("startup-stats-request.json") }
    var startupStats: URL { directory.appendingPathComponent("startup-stats.json") }
    var windowRequest: URL { directory.appendingPathComponent("window-request.json") }
    init() throws {
        guard let raw = ProcessInfo.processInfo.environment["ROCK_STARTUP_CHANNEL"], let uuid = UUID(uuidString: raw),
              let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw StartupCaptureIPCError("A unique ROCK_STARTUP_CHANNEL UUID is required")
        }
        id = uuid.uuidString
        directory = support.appendingPathComponent("StartupCapture", isDirectory: true).appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
private struct StartupCaptureIPCError: Error { let message: String; init(_ value: String) { message = value } }
private struct StartupAudioStageRequest: Codable {
    let id: String, actionID: String, cycle: Int, actionStart: Double?, phase: String
}

enum StartupAudioStageStatistics {
    static func audio(_ value: GuestAudioSnapshot) -> [String: Any] {
        ["samples": value.samples, "callbacks": value.callbacks, "nonSilentCallbacks": value.nonSilentCallbacks,
         "energy": value.energy, "rms": value.rms,
         "firstCallbackUptime": value.firstCallbackUptime as Any? ?? NSNull(),
         "lastCallbackUptime": value.lastCallbackUptime as Any? ?? NSNull(),
         "firstNonSilentUptime": value.firstNonSilentUptime as Any? ?? NSNull(),
         "lastNonSilentUptime": value.lastNonSilentUptime as Any? ?? NSNull()]
    }
    static func summary(_ rows: [[String: Any]]?, publisher: Bool) -> [String: Any] {
        guard let rows else { return ["statsAvailable": false] }
        let rtpType = publisher ? "outbound-rtp" : "inbound-rtp"
        let rtp = rows.filter { $0["type"] as? String == rtpType && $0["kind"] as? String == "audio" }
        let selectedPairs = Set(rows.filter { $0["type"] as? String == "transport" }.compactMap { $0["selectedCandidatePairId"] as? String })
        let selected = rows.filter { row in
            let type = row["type"] as? String ?? ""
            if type == "transport" { return true }
            if type == "candidate-pair" { return selectedPairs.contains(row["id"] as? String ?? "") }
            return row["kind"] as? String == "audio" && [rtpType, "media-source", "remote-inbound-rtp"].contains(type)
        }
        func sum(_ key: String, in selected: [[String: Any]]) -> Double {
            selected.reduce(0) { $0 + (($1[key] as? NSNumber)?.doubleValue ?? 0) }
        }
        let source = publisher ? rows.filter { $0["type"] as? String == "media-source" && $0["kind"] as? String == "audio" } : rtp
        return ["statsAvailable": true, "streamIDs": rtp.compactMap { $0["id"] as? String }.sorted(),
            "packets": sum(publisher ? "packetsSent" : "packetsReceived", in: rtp),
            "bytes": sum(publisher ? "bytesSent" : "bytesReceived", in: rtp),
            "totalAudioEnergy": sum("totalAudioEnergy", in: source), "totalSamplesDuration": sum("totalSamplesDuration", in: source),
            "rows": selected, "packetProgressIsSpeechProof": false]
    }
}
private struct StartupReceiverAudio: Codable {
    var samples = 0, callbacks = 0, nonSilentCallbacks = 0
    var energy = 0.0
    var firstCallbackUptime: Double?, lastCallbackUptime: Double?, firstNonSilentUptime: Double?, lastNonSilentUptime: Double?
    init(_ value: GuestAudioSnapshot = .init()) {
        samples = value.samples; energy = value.energy; callbacks = value.callbacks; nonSilentCallbacks = value.nonSilentCallbacks
        firstCallbackUptime = value.firstCallbackUptime; lastCallbackUptime = value.lastCallbackUptime
        firstNonSilentUptime = value.firstNonSilentUptime; lastNonSilentUptime = value.lastNonSilentUptime
    }
    var snapshot: GuestAudioSnapshot {
        .init(samples: samples, energy: energy, callbacks: callbacks, nonSilentCallbacks: nonSilentCallbacks,
            firstCallbackUptime: firstCallbackUptime, lastCallbackUptime: lastCallbackUptime,
            firstNonSilentUptime: firstNonSilentUptime, lastNonSilentUptime: lastNonSilentUptime)
    }
}
private struct StartupReceiverWindow: Codable {
    let start: Double, end: Double
    let complete: Bool, seconds: Double, frames: Int, maximumGap: Double
    let endFrameAge: Double?, maximumGapStart: Double?, maximumGapEnd: Double?
    init(_ value: GuestFrameWindow, from start: Double, to end: Double) {
        self.start = start; self.end = end; complete = value.complete; seconds = value.seconds; frames = value.frames
        maximumGap = value.maximumGap; endFrameAge = value.endFrameAge
        maximumGapStart = value.maximumGapStart; maximumGapEnd = value.maximumGapEnd
    }
    var snapshot: GuestFrameWindow {
        .init(complete: complete, seconds: seconds, frames: frames, maximumGap: maximumGap, endFrameAge: endFrameAge,
            maximumGapStart: maximumGapStart, maximumGapEnd: maximumGapEnd)
    }
}
private struct StartupReceiverWindowRequest: Codable { let id: String, start: Double, end: Double }
private struct StartupPublisherReadiness: Codable {
    let sampleUptime: Double, elapsedSeconds: Double
    let iceState: String, dtlsState: String
    let audioPackets: Double, audioBytes: Double, packetDelta: Double, byteDelta: Double
    let progressWindowSeconds: Double
    let confirmed: Bool
}
private struct StartupReceiverRequestTiming: Codable {
    let kind: String, id: String?
    let startedUptime: Double
    var completedUptime: Double?
}
private struct StartupReceiverPublicationTiming: Codable {
    let sequence: Int
    let mediaRefreshed: Bool, ready: Bool
    let sampleStartedUptime: Double, sampleCompletedUptime: Double
    let previousSampleStartedUptime: Double?, previousWriteCompletedUptime: Double?
    let previousWriteSeconds: Double?
    let activeRequest: StartupReceiverRequestTiming?, lastCompletedRequest: StartupReceiverRequestTiming?
    var intervalSeconds: Double { previousSampleStartedUptime.map { sampleStartedUptime - $0 } ?? 0 }
}
private struct StartupReceiverTelemetry: Codable {
    let channel: String, pid: Int32
    var sequence = 0, uptime = 0.0
    var invitationURL: String?, ready = false, connected = false, failed = false, stopped = false
    var error: String?
    var audio = StartupReceiverAudio()
    var frames = 0, advancingFrames = 0
    var firstFrameUptime: Double?, lastFrameUptime: Double?, trackID: String?
    var presentedFrames = 0
    var gpu = StartupReceiverWindow(.invalid, from: 0, to: 0)
    var requestedWindowID: String?, requestedWindow: StartupReceiverWindow?
    var publisherReadiness: StartupPublisherReadiness?
    var publication: StartupReceiverPublicationTiming?, maximumPublicationInterval: StartupReceiverPublicationTiming?
}

/// Separate synthetic-ADM process: never creates a desktop model or physical audio owner.
@MainActor final class NativeStartupReceiver {
    private static var owner: NativeStartupReceiver?
    private let channel: StartupCaptureChannel
    private var telemetry: StartupReceiverTelemetry
    private var engine: NativeGuestEngine?
    private var window: NSWindow?
    private var tile: CompanionVideoTile?
    private var trackID: String?
    private var statsRequestID: String?
    private var startupStatsRequestID: String?
    private var acoustic: AcousticFixtureControl?
    private var activeRequest: StartupReceiverRequestTiming?, lastCompletedRequest: StartupReceiverRequestTiming?
    private var lastWriteCompletedUptime: Double?, lastWriteSeconds: Double?
    private let startupStagesEnabled = ProcessInfo.processInfo.environment["ROCK_MIC_STARTUP_STAGES"] == "1"

    static func startIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["ROCK_STARTUP_RECEIVER"] == "1" else { return false }
        do {
            let receiver = try Self(); owner = receiver
            Task { @MainActor in
                do { try await receiver.run() }
                catch { receiver.telemetry.error = String(describing: error); receiver.telemetry.failed = true }
                if let engine = receiver.engine { await receiver.acoustic?.cleanup(engine) }
                let stopped = await receiver.engine?.leave() ?? true
                let exported = await receiver.acoustic?.finishExports(stopped: stopped) ?? true
                receiver.tile?.detach(); receiver.tile = nil; receiver.window?.contentView = nil; receiver.window?.orderOut(nil)
                receiver.engine = nil; receiver.telemetry.ready = false; receiver.telemetry.stopped = stopped
                if !stopped { receiver.telemetry.error = "Receiver cleanup was not confirmed" }
                try? receiver.publish(refresh: false)
                print("STARTUP_RECEIVER_FINAL " + String(decoding: (try? JSONEncoder().encode(receiver.telemetry)) ?? Data(), as: UTF8.self))
                fflush(stdout); exit(stopped && exported && receiver.telemetry.error == nil ? 0 : 1)
            }
        } catch { print("STARTUP_RECEIVER_ERROR \(error)"); fflush(stdout); exit(2) }
        return true
    }
    private init() throws {
        channel = try StartupCaptureChannel()
        telemetry = StartupReceiverTelemetry(channel: channel.id, pid: getpid())
    }
    private func publish(refresh: Bool = true) throws {
        let now = ProcessInfo.processInfo.systemUptime
        if refresh, let engine {
            let media = engine.mediaSnapshot
            telemetry.audio = .init(media.audio); telemetry.connected = media.connected; telemetry.failed = media.failed
            telemetry.frames = media.render["frames"] as? Int ?? 0
            telemetry.advancingFrames = media.render["advancingFrames"] as? Int ?? 0
            telemetry.firstFrameUptime = media.render["firstFrameUptime"] as? Double
            telemetry.lastFrameUptime = media.render["lastFrameUptime"] as? Double
            telemetry.trackID = trackID; telemetry.presentedFrames = tile?.sink.frames ?? 0
            telemetry.gpu = .init(tile?.sink.presentationWindow(from: now - 5, to: now) ?? .invalid, from: now - 5, to: now)
        }
        let publication = StartupReceiverPublicationTiming(sequence: telemetry.sequence + 1,
            mediaRefreshed: refresh && engine != nil, ready: telemetry.ready,
            sampleStartedUptime: now,
            sampleCompletedUptime: ProcessInfo.processInfo.systemUptime,
            previousSampleStartedUptime: telemetry.sequence > 0 ? telemetry.uptime : nil,
            previousWriteCompletedUptime: lastWriteCompletedUptime, previousWriteSeconds: lastWriteSeconds,
            activeRequest: activeRequest, lastCompletedRequest: lastCompletedRequest)
        if publication.ready, publication.mediaRefreshed, telemetry.publication?.ready == true,
           publication.intervalSeconds > (telemetry.maximumPublicationInterval?.intervalSeconds ?? 0) {
            telemetry.maximumPublicationInterval = publication
        }
        telemetry.publication = publication
        telemetry.sequence += 1; telemetry.uptime = now
        let writeStarted = ProcessInfo.processInfo.systemUptime
        try JSONEncoder().encode(telemetry).write(to: channel.telemetry, options: .atomic)
        lastWriteCompletedUptime = ProcessInfo.processInfo.systemUptime
        lastWriteSeconds = lastWriteCompletedUptime.map { $0 - writeStarted }
    }
    private func run() async throws {
        // This synthetic peer has no physical audio I/O to prevent App Nap.
        // Keep fixture cadence reliable only for its bounded live-test lifetime.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Independent live media test fixture")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try publish()
        let invitation = try await GuestBootstrap.createDisposable(origin: URL(string: "https://salutejazz.ru")!)
        telemetry.invitationURL = invitation.invitationURL.absoluteString
        guard let policy = GuestICEPolicy(rawValue: ProcessInfo.processInfo.environment["ROCK_MIC_TEST_ICE_POLICY"] ?? "auto") else {
            throw StartupCaptureIPCError("Invalid diagnostic ICE policy")
        }
        let engine = NativeGuestEngine(label: "Independent startup receiver", icePolicy: policy, verifyReceivedPixels: false); self.engine = engine
        if ProcessInfo.processInfo.environment["ROCK_ACOUSTIC_VALIDATION"] == "1" { acoustic = try AcousticFixtureControl(engine: engine) }
        engine.onIncomingVideoChange = { [weak self] videos in
            guard let self, let video = videos.first(where: { $0.source != "SCREEN_SHARE" }), self.trackID != video.track.trackId else { return }
            self.tile?.detach(); self.trackID = video.track.trackId
            let tile = CompanionVideoTile(track: video.track, title: "Independent remote camera")
            let window = self.window ?? NSWindow(contentRect: NSRect(x: 30, y: 30, width: 640, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
            self.window = window; self.tile = tile; window.contentView = tile; window.title = "Independent SFU startup receiver"
            window.makeKeyAndOrderFront(nil)
        }
        try await engine.join(invitation)
        try await engine.publishPattern(codec: "h264", audioMuted: false, videoMuted: false)
        guard try await waitForPublisherTransmission(engine) else { return }
        telemetry.ready = true
        try publish()
        let ready = try JSONEncoder().encode(telemetry)
        guard ready.count <= 131_072 else { throw StartupCaptureIPCError("Receiver readiness exceeded diagnostic bound") }
        print("STARTUP_RECEIVER_READY_JSON " + String(decoding: ready, as: UTF8.self))
        print("STARTUP_RECEIVER_READY \(channel.id) \(getpid())"); fflush(stdout)
        let maximumLifetime = ProcessInfo.processInfo.systemUptime + (acoustic == nil ? 180 : 300)
        // Both children stay on MainActor. Awaited request callbacks cannot hold
        // the publication cadence; synchronous actor/file stalls remain visible.
        // The group cancels and drains before run returns and cleanup can begin.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                while true {
                    try Task.checkCancellation()
                    try self.publish()
                    try await Task.sleep(for: .milliseconds(50))
                }
            }
            group.addTask { @MainActor in
                try await self.serviceRequests(engine, maximumLifetime: maximumLifetime)
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    private func finishRequest() {
        activeRequest?.completedUptime = ProcessInfo.processInfo.systemUptime
        lastCompletedRequest = activeRequest; activeRequest = nil
    }
    private func serviceRequests(_ engine: NativeGuestEngine, maximumLifetime: Double) async throws {
        while !FileManager.default.fileExists(atPath: channel.stop.path) {
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < maximumLifetime else {
                throw StartupCaptureIPCError("Receiver lifetime expired; cleaning up disposable peer")
            }
            if let acoustic {
                activeRequest = .init(kind: "acousticPoll", id: nil, startedUptime: ProcessInfo.processInfo.systemUptime)
                try await acoustic.poll(engine)
                try Task.checkCancellation()
                finishRequest()
                if acoustic.stopRequested { return }
            }
            if let data = try? Data(contentsOf: channel.windowRequest), data.count <= 1024,
               let request = try? JSONDecoder().decode(StartupReceiverWindowRequest.self, from: data), request.id != telemetry.requestedWindowID {
                activeRequest = .init(kind: "presentationWindow", id: request.id, startedUptime: ProcessInfo.processInfo.systemUptime)
                telemetry.requestedWindowID = request.id
                telemetry.requestedWindow = .init(tile?.sink.presentationWindow(from: request.start, to: request.end) ?? .invalid,
                    from: request.start, to: request.end)
                finishRequest()
            }
            if let data = try? Data(contentsOf: channel.statsRequest), data.count <= 128,
               let request = String(data: data, encoding: .utf8), request != statsRequestID {
                statsRequestID = request
                activeRequest = .init(kind: "evidence", id: request, startedUptime: ProcessInfo.processInfo.systemUptime)
                let result: [String: Any] = ["requestID": request, "evidence": await engine.evidence()]
                try Task.checkCancellation()
                let encoded = try JSONSerialization.data(withJSONObject: result)
                guard encoded.count <= 524_288 else { throw StartupCaptureIPCError("Receiver stats exceeded diagnostic bound") }
                try encoded.write(to: channel.stats, options: .atomic)
                finishRequest()
            }
            if startupStagesEnabled, let data = try? Data(contentsOf: channel.startupStatsRequest), data.count <= 4096,
               let request = try? JSONDecoder().decode(StartupAudioStageRequest.self, from: data), request.id != startupStatsRequestID {
                startupStatsRequestID = request.id
                let started = ProcessInfo.processInfo.systemUptime
                activeRequest = .init(kind: "startupStage", id: request.id, startedUptime: started)
                let rows = await engine.screenShareStatsForTesting(.subscriber)
                try Task.checkCancellation()
                let completed = ProcessInfo.processInfo.systemUptime
                let result: [String: Any] = ["requestID": request.id, "actionID": request.actionID, "cycle": request.cycle,
                    "actionStart": request.actionStart as Any? ?? NSNull(), "phase": request.phase,
                    "sampleStartedUptime": started, "sampleCompletedUptime": completed,
                    "subscriber": StartupAudioStageStatistics.summary(rows, publisher: false),
                    "decodedPCM": StartupAudioStageStatistics.audio(engine.mediaSnapshot.audio),
                    "speechClassified": false]
                let encoded = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
                guard encoded.count <= 131_072 else { throw StartupCaptureIPCError("Startup stage stats exceeded diagnostic bound") }
                try encoded.write(to: channel.startupStats, options: .atomic)
                finishRequest()
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// This qualification ends before the primary process starts join timing.
    private func waitForPublisherTransmission(_ engine: NativeGuestEngine) async throws -> Bool {
        let began = ProcessInfo.processInfo.systemUptime, deadline = began + 18
        var baseline: (at: Double, packets: Double, bytes: Double, streamIDs: Set<String>)?
        while ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            if FileManager.default.fileExists(atPath: channel.stop.path) { return false }
            if let failure = engine.failure { throw failure }
            if let rows = await engine.screenShareStatsForTesting(.publisher) {
                let now = ProcessInfo.processInfo.systemUptime
                let transports = rows.filter { $0["type"] as? String == "transport" }
                let transport = transports.first { row in
                    ["connected", "completed"].contains(row["iceState"] as? String ?? "") &&
                        row["dtlsState"] as? String == "connected"
                }
                let audio = rows.filter { $0["type"] as? String == "outbound-rtp" && $0["kind"] as? String == "audio" }
                let packets = audio.reduce(0.0) { $0 + (($1["packetsSent"] as? NSNumber)?.doubleValue ?? 0) }
                let bytes = audio.reduce(0.0) { $0 + (($1["bytesSent"] as? NSNumber)?.doubleValue ?? 0) }
                let streamIDs = Set(audio.compactMap { $0["id"] as? String })
                let connected = transport != nil
                if !connected || packets <= 0 || bytes <= 0 || streamIDs.isEmpty ||
                    baseline?.streamIDs != streamIDs || baseline.map({ now - $0.at > 1 }) == true {
                    baseline = connected && packets > 0 && bytes > 0 ? (now, packets, bytes, streamIDs) : nil
                }
                let interval = baseline.map { now - $0.at } ?? 0
                let packetDelta = baseline.map { packets - $0.packets } ?? 0
                let byteDelta = baseline.map { bytes - $0.bytes } ?? 0
                let confirmed = connected && interval >= 0.2 && packetDelta > 0 && byteDelta > 0
                telemetry.publisherReadiness = .init(sampleUptime: now, elapsedSeconds: now - began,
                    iceState: (transport ?? transports.first)?["iceState"] as? String ?? "unavailable",
                    dtlsState: (transport ?? transports.first)?["dtlsState"] as? String ?? "unavailable",
                    audioPackets: packets, audioBytes: bytes, packetDelta: packetDelta, byteDelta: byteDelta,
                    progressWindowSeconds: interval, confirmed: confirmed)
                try publish()
                if confirmed { return true }
            } else { baseline = nil }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw StartupCaptureIPCError("Fixture publisher readiness deadline exceeded without connected ICE/DTLS and advancing audio RTP")
    }
}

/// Atomic file telemetry adds a nominal 50 ms producer interval plus client polling.
@MainActor final class NativeStartupReceiverProxy {
    var acousticRequest: Task<[String: Any], Error>?
    var acousticRequestID: UUID?
    var acousticTerminal = false
    private let channel: StartupCaptureChannel
    private var cached: StartupReceiverTelemetry?
    private var lastRead = 0.0
    private var statsInFlight = false
    private var startupStatsUnconfirmed = false
    init() throws { channel = try StartupCaptureChannel() }
    private func refresh(force: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastRead >= 0.01 else { return }; lastRead = now
        guard let data = try? Data(contentsOf: channel.telemetry), data.count <= 65_536,
              let value = try? JSONDecoder().decode(StartupReceiverTelemetry.self, from: data),
              value.channel == channel.id, value.pid != getpid(), cached == nil || value.pid == cached?.pid,
              value.sequence >= (cached?.sequence ?? 0), value.uptime >= (cached?.uptime ?? 0), value.uptime <= now + 0.1 else { return }
        cached = value
    }
    var mediaSnapshot: GuestMediaSnapshot {
        refresh()
        return .init(render: ["frames": cached?.frames ?? 0, "advancingFrames": cached?.advancingFrames ?? 0,
                "firstFrameUptime": cached?.firstFrameUptime as Any? ?? NSNull(),
                "lastFrameUptime": cached?.lastFrameUptime as Any? ?? NSNull()],
            audio: cached?.audio.snapshot ?? .init(), connected: cached?.connected == true,
            failed: cached?.failed == true || (cached.map { ProcessInfo.processInfo.systemUptime - $0.uptime > 2 } ?? false))
    }
    var presentedFrames: Int { refresh(); return cached?.presentedFrames ?? 0 }
    var trackID: String? { refresh(); return cached?.trackID }
    var telemetryUptime: Double { refresh(); return cached?.uptime ?? 0 }
    var recentGPUWindow: GuestFrameWindow { refresh(); return cached?.gpu.snapshot ?? .invalid }
    var ipcEvidence: [String: Any] {
        refresh()
        return ["channel": channel.id, "receiverPID": cached?.pid as Any? ?? NSNull(), "telemetryUptime": cached?.uptime ?? 0,
            "snapshotAgeSeconds": cached.map { ProcessInfo.processInfo.systemUptime - $0.uptime } as Any? ?? NSNull(),
            "producerCadenceSeconds": 0.05, "clientReadCadenceSeconds": 0.01, "readinessIncludesFileIPC": true,
            "publisherTransmissionConfirmed": cached?.publisherReadiness?.confirmed ?? false,
            "publisherReadinessSampleUptime": cached?.publisherReadiness?.sampleUptime as Any? ?? NSNull(),
            "publisherReadinessElapsedSeconds": cached?.publisherReadiness?.elapsedSeconds as Any? ?? NSNull(),
            "publisherICEState": cached?.publisherReadiness?.iceState ?? "unavailable",
            "publisherDTLSState": cached?.publisherReadiness?.dtlsState ?? "unavailable",
            "publisherAudioPacketDelta": cached?.publisherReadiness?.packetDelta ?? 0,
            "publisherAudioByteDelta": cached?.publisherReadiness?.byteDelta ?? 0,
            "publisherProgressWindowSeconds": cached?.publisherReadiness?.progressWindowSeconds ?? 0,
            "lastPresentedUptime": cached?.gpu.endFrameAge.map { (cached?.gpu.end ?? 0) - $0 } as Any? ?? NSNull(),
            "presentationWindowStart": cached?.gpu.start ?? 0, "presentationWindowEnd": cached?.gpu.end ?? 0]
    }
    func waitUntilReady(timeout: Double = 45) async throws -> URL {
        let end = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < end {
            refresh()
            if let error = cached?.error { throw StartupCaptureIPCError(error) }
            if cached?.ready == true, cached?.publisherReadiness?.confirmed == true,
               cached?.stopped == false, cached?.failed == false,
               ProcessInfo.processInfo.systemUptime - (cached?.uptime ?? 0) < 0.25,
               let raw = cached?.invitationURL, let url = URL(string: raw) { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw StartupCaptureIPCError("Independent receiver readiness timed out")
    }
    func presentationWindow(from start: Double, to end: Double) async -> GuestFrameWindow {
        let request = StartupReceiverWindowRequest(id: UUID().uuidString, start: start, end: end)
        guard let data = try? JSONEncoder().encode(request), (try? data.write(to: channel.windowRequest, options: .atomic)) != nil else { return .invalid }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while ProcessInfo.processInfo.systemUptime < deadline {
            refresh()
            if cached?.requestedWindowID == request.id { return cached?.requestedWindow?.snapshot ?? .invalid }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return .invalid
    }
    func evidence() async -> [String: Any] {
        // The stage sampler drains before final evidence; reject accidental
        // concurrent IPC requests rather than replacing an outstanding request.
        guard !statsInFlight, !startupStatsUnconfirmed else { return ["statsAvailable": false, "reason": "statsBusyOrUnconfirmed", "IPC": ipcEvidence] }
        statsInFlight = true
        defer { statsInFlight = false }
        let request = UUID().uuidString
        guard (try? Data(request.utf8).write(to: channel.statsRequest, options: .atomic)) != nil else { return ["statsAvailable": false, "IPC": ipcEvidence] }
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while ProcessInfo.processInfo.systemUptime < deadline {
            if let data = try? Data(contentsOf: channel.stats), data.count <= 524_288,
               let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["requestID"] as? String == request,
               var evidence = result["evidence"] as? [String: Any] {
                evidence["IPC"] = ipcEvidence; return evidence
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return ["statsAvailable": false, "IPC": ipcEvidence]
    }
    func startupStageEvidence(actionID: String, cycle: Int, actionStart: Double?, phase: String) async -> [String: Any] {
        guard !statsInFlight, !startupStatsUnconfirmed, !Task.isCancelled else { return ["statsAvailable": false, "cancelledOrBusy": true] }
        statsInFlight = true
        defer { statsInFlight = false }
        let request = StartupAudioStageRequest(id: UUID().uuidString, actionID: actionID, cycle: cycle,
            actionStart: actionStart, phase: phase)
        let began = ProcessInfo.processInfo.systemUptime
        guard let data = try? JSONEncoder().encode(request),
              (try? data.write(to: channel.startupStatsRequest, options: .atomic)) != nil else {
            return ["statsAvailable": false, "IPC": ipcEvidence]
        }
        // Drain an issued request even after cancellation. This bounded polling
        // does not call a worker or overlap the next stats request.
        while ProcessInfo.processInfo.systemUptime - began < 0.8 {
            if let data = try? Data(contentsOf: channel.startupStats), data.count <= 131_072,
               var result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               result["requestID"] as? String == request.id, result["actionID"] as? String == actionID {
                result["IPC"] = ipcEvidence
                result["observedUptime"] = ProcessInfo.processInfo.systemUptime
                result["requestBeganUptime"] = began
                return result
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { continuation.resume() }
            }
        }
        startupStatsUnconfirmed = true
        return ["statsAvailable": false, "timedOut": true, "receiverRequestUnconfirmed": true, "requestBeganUptime": began, "IPC": ipcEvidence]
    }
    func leave() async -> Bool {
        guard (try? Data("{}".utf8).write(to: channel.stop, options: .atomic)) != nil else { return false }
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while ProcessInfo.processInfo.systemUptime < deadline {
            refresh(force: true)
            if cached?.stopped == true { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}
#endif
