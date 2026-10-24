import AppKit
import Darwin
import Foundation
import LiveKitWebRTC

@MainActor private final class Study: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var tiles: [String: CompanionVideoTile] = [:]
    private var stack: NSStackView!
    private var pulse: DispatchSourceTimer?
    private let latency = QueueLatency()
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { probeLog("incoming-study-failed", ["type": String(describing: type(of: error))]); Darwin.exit(1) }
        }
    }
    private func run() async throws {
        Darwin.signal(SIGALRM, SIG_DFL); Darwin.alarm(150)
        let args = CommandLine.arguments
        guard args.count == 4, let policy = GuestICEPolicy(rawValue: args[2]), ["on","off"].contains(args[3]) else { throw GuestCompanionPeerError.invalidControl }
        let verifyPixels = args[3] == "on"
        let invitation = try GuestInvitation.parse(String(contentsOfFile: args[1], encoding: .utf8))
        window = NSWindow(contentRect: NSRect(x:0,y:0,width:900,height:620), styleMask:[.titled,.closable,.resizable], backing:.buffered, defer:false)
        window.title = "Native incoming video study — synthetic content"
        stack = NSStackView(); stack.orientation = .vertical; stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:window.contentView!.leadingAnchor),stack.trailingAnchor.constraint(equalTo:window.contentView!.trailingAnchor),stack.topAnchor.constraint(equalTo:window.contentView!.topAnchor),stack.bottomAnchor.constraint(equalTo:window.contentView!.bottomAnchor)])
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        let timer = DispatchSource.makeTimerSource(queue: .global(qos:.userInitiated))
        timer.schedule(deadline:.now(), repeating:.milliseconds(100)); timer.setEventHandler { [latency] in latency.tick() }; timer.resume(); pulse = timer
        defer { pulse?.cancel(); pulse = nil; window.close() }
        let session = GuestSession(makeEngine: {
            let owner = try await GuestSystemAudio.create(microphoneEnabled:false, playoutEnabled:true)
            return NativeGuestEngine(label:"Native receive study",systemAudio:owner,icePolicy:policy,verifyReceivedPixels:verifyPixels)
        })
        session.onEngineChange = { [weak self] engine in
            guard let self else { return }
            engine?.onIncomingVideoChange = { [weak self] streams in self?.update(streams) }
        }
        do {
            try await session.connect(invitation,publish:true,codec:"h264",camera:true,initialAudioMuted:true,initialVideoMuted:true)
            guard let engine = session.engine else { throw GuestEngineError.disconnected }
            let deadline = ProcessInfo.processInfo.systemUptime+30
            while (engine.mediaSnapshot.render["advancingFrames"] as? Int ?? 0)<15 || tiles.values.reduce(0,{$0+$1.sink.frames})<15 {
                guard ProcessInfo.processInfo.systemUptime<deadline, session.failure == nil else { throw GuestEngineError.mediaMissing }
                try await Task.sleep(nanoseconds:100_000_000)
            }
            for index in 0..<12 {
                let before = await engine.evidence()
                let expected = Set(tiles.keys), generation = engine.remoteMediaGeneration
                guard expected.count == 1, engine.connectedRemoteParticipants.count == 1 else { throw GuestEngineError.mediaMissing }
                let audioBefore = engine.mediaSnapshot.audio
                let start = ProcessInfo.processInfo.systemUptime
                try await Task.sleep(nanoseconds:5_000_000_000)
                let end = ProcessInfo.processInfo.systemUptime
                let decoded = engine.subscriber!.renderer.window(from:start,to:end)
                let gpu = tiles.values.map { $0.sink.presentationWindow(from:start,to:end) }
                let receivedAudio = engine.mediaSnapshot.audio.since(audioBefore)
                let callbackSnapshotUptime = ProcessInfo.processInfo.systemUptime
                let after = await engine.evidence()
                let statsCompletedUptime = ProcessInfo.processInfo.systemUptime
                let stable = session.engine === engine && session.failure == nil && generation == engine.remoteMediaGeneration && Set(tiles.keys) == expected
                let fresh = before["subscriberStatsFresh"] as? Bool == true && after["subscriberStatsFresh"] as? Bool == true
                let physical = after["physicalAudio"] as? [String:Any] ?? [:]
                let audioAge = statsCompletedUptime - (physical["snapshotUptime"] as? Double ?? 0)
                let audioQualified = after["physicalAudioSnapshotFresh"] as? Bool == true &&
                    physical["outputRunning"] as? Bool == true && physical["playing"] as? Bool == true &&
                    physical["inputAvailable"] as? Bool == false && physical["microphoneMuted"] as? Bool == true &&
                    (physical["outputSampleRate"] as? Double ?? 0) >= 44_100 && (0...5).contains(audioAge) &&
                    receivedAudio.samples > 150_000 && receivedAudio.rms > 0.001
                let foreground = NSApp.isActive && window.occlusionState.contains(.visible)
                let row: [String:Any] = ["window":index,"policy":policy.rawValue,"pixelVerification":verifyPixels,
                    "start":start,"end":end,"callbackSnapshotUptime":callbackSnapshotUptime,"statsCompletedUptime":statsCompletedUptime,
                    "stableSource":stable,"foreground":foreground,"audioQualified":audioQualified,
                    "receivedAudioSamples":receivedAudio.samples,"receivedAudioRMS":receivedAudio.rms,"decoded":decoded.evidence,"gpu":gpu.map(\.evidence),
                    "mainQueueMaxDelay":latency.maximum(from:start,to:end),"before":before,"after":after,
                    "cadencePass":stable && fresh && foreground && audioQualified && decoded.smooth && gpu.count == 1 && gpu.allSatisfy(\.smooth)]
                probeLog("native-incoming-window",row)
                guard stable, fresh else { throw GuestEngineError.mediaMissing }
            }
            update([])
            guard await session.leave() else { throw GuestEngineError.disconnected }
            probeLog("native-incoming-study-complete",["windows":12])
        } catch { update([]); _ = await session.leave(); throw error }
    }
    private func update(_ streams:[GuestRemoteVideo]) {
        let ids = Set(streams.map(\.id))
        for key in tiles.keys.filter({!ids.contains($0)}) {
            if let tile = tiles.removeValue(forKey:key) { tile.detach(); stack.removeArrangedSubview(tile); tile.removeFromSuperview() }
        }
        for stream in streams where tiles[stream.id] == nil {
            let tile = CompanionVideoTile(track:stream.track,title:"Synthetic publisher")
            tiles[stream.id] = tile; stack.addArrangedSubview(tile)
        }
    }
}
private final class QueueLatency: @unchecked Sendable {
    private let lock = NSLock()
    private var values:[(Double,Double)] = []
    func tick() {
        let sent = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}; let now = ProcessInfo.processInfo.systemUptime
            self.lock.lock(); self.values.append((now,now-sent)); if self.values.count>2048 {self.values.removeFirst(1024)}; self.lock.unlock()
        }
    }
    func maximum(from start:Double,to end:Double)->Double {
        lock.lock(); defer {lock.unlock()}
        return values.filter {$0.0>=start && $0.0<=end}.map(\.1).max() ?? -1
    }
}
@main private struct IncomingVideoStudy {
    static func main() {
        let app = NSApplication.shared, delegate = Study()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
