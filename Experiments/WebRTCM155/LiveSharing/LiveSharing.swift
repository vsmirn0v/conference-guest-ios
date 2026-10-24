import AppKit
import CoreImage
import CoreMedia
import Darwin
import LiveKitWebRTC
import ScreenCaptureKit

private enum ShareProbeError: Error { case arguments, permission, missingWindow, noFrame, failedGate, stopped }
private enum Fixture {
    static let initial = CGSize(width: 1600, height: 1000)
    static let resized = CGSize(width: 1200, height: 800)
    static let profile = GuestVideoProfile(width: 1600, height: 1000, fps: 10, maximumBitrate: 3_000_000)
    static let text = "M155 SCREEN DETAIL 0123456789"
    static let nonce = (0..<8).map { _ in UInt8.random(in: 0...255) }
}

/// Compact counters sampled during a phase; no payload, SDP, addresses or ICE strings.
@MainActor private final class PhaseDiagnostics {
    var samples: [[String: Any]] = []

    static func shouldSample(tick: Int, start: Double, now: Double) -> Bool {
        tick >= 1 && tick <= 3 && now < start + 4 && now <= start + Double(tick) + 0.2
    }

    static func summary(_ statistics: [[String: Any]]?, target: String) -> [String: Any] {
        guard let statistics else { return ["statsAvailable": false, "videoPresent": false,
                                            "transportPresent": false, "pairPresent": false] }
        let type = target == "PUBLISHER" ? "outbound-rtp" : "inbound-rtp"
        let video = statistics.first { $0["type"] as? String == type && $0["target"] as? String == target && $0["kind"] as? String == "video" } ?? [:]
        let transport = statistics.first { $0["type"] as? String == "transport" && $0["target"] as? String == target } ?? [:]
        let pairID = transport["selectedCandidatePairId"] as? String
        let pair = statistics.first { $0["type"] as? String == "candidate-pair" && $0["target"] as? String == target && $0["id"] as? String == pairID } ?? [:]
        let localID = pair["localCandidateId"] as? String
        let local = statistics.first { $0["type"] as? String == "local-candidate" && $0["target"] as? String == target && $0["id"] as? String == localID } ?? [:]
        var value: [String: Any] = ["statsAvailable": true, "videoPresent": !video.isEmpty,
                                    "transportPresent": !transport.isEmpty, "pairPresent": !pair.isEmpty]
        for key in ["sampleUptime", "nativeTimestampUS"] {
            if let number = video[key] as? NSNumber { value[key] = number }
        }
        for key in ["framesEncoded", "framesSent", "framesReceived", "framesDecoded", "framesDropped",
                    "bytesSent", "bytesReceived", "headerBytesSent", "headerBytesReceived", "retransmittedBytesSent",
                    "packetsSent", "packetsReceived", "packetsLost", "nackCount", "pliCount",
                    "keyFramesEncoded", "keyFramesDecoded", "retransmittedPacketsSent", "retransmittedPacketsReceived"] {
            if let number = video[key] as? NSNumber { value[key] = number }
        }
        for key in ["currentRoundTripTime", "availableOutgoingBitrate"] {
            if let number = pair[key] as? NSNumber { value[key] = number }
        }
        if let protocolName = local["relayProtocol"] as? String, ["udp", "tcp", "tls"].contains(protocolName) {
            value["relayProtocol"] = protocolName
        }
        return value
    }

    static func summary(_ evidence: [String: Any], target: String) -> [String: Any] {
        summary(evidence["stats"] as? [[String: Any]], target: target)
    }
}

/// Only this app-created window is eligible for the direct SCK selector.
@MainActor private final class DetailChart: NSView {
    var marker = "P00"
    var phase: UInt8 = 0
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        let large: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 35, weight: .bold), .foregroundColor: NSColor.black]
        ((Fixture.text + " " + marker) as NSString).draw(at: CGPoint(x: 32, y: 40), withAttributes: large)
        let payload = SharingPixelAcceptance.payload(nonce: Fixture.nonce, phase: phase)
        for cell in SharingPixelAcceptance.markerCells(payload: payload, width: Int(bounds.width)) {
            (cell.black ? NSColor.black : NSColor.white).setFill(); cell.rect.fill()
        }
        let detail: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 19, weight: .regular), .foregroundColor: NSColor.black]
        for line in 0..<22 {
            ("ROW \(String(format: "%02d", line)) abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789" as NSString)
                .draw(at: CGPoint(x: 32, y: 105 + line * 25), withAttributes: detail)
        }
        for index in 0..<10 {
            let value = CGFloat(index) / 9
            NSColor(calibratedRed: value, green: 0.2, blue: 1 - value, alpha: 1).setFill()
            CGRect(x: 32 + index * 70, y: Int(bounds.height) - 130, width: 70, height: 70).fill()
        }
        NSColor.black.setFill()
        for x in stride(from: 32, to: min(1100, Int(bounds.width) - 20), by: 4) {
            CGRect(x: x, y: Int(bounds.height) - 40, width: 2, height: 20).fill()
        }
    }
}

/// Serial SCK -> production PresenterCompositor -> M155 external video source.
/// A 10-fps fresh-PTS heartbeat retransmits a static source without requiring UI animation.
private final class WindowCapture: NSObject, GuestCameraCapture, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let windowID: CGWindowID
    private let ownerPID = ProcessInfo.processInfo.processIdentifier
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let queue = DispatchQueue(label: "m155.synthetic-window.frames")
    private let lock = NSLock()
    private var active = false, composed = false
    private var size: CGSize
    private var stream: SCStream?
    private var timer: DispatchSourceTimer?
    private var failure: Error?
    private var frames = 0, captures = 0, width = 0, height = 0
    private var samples = 0, completeSamples = 0, sampleWidth = 0, sampleHeight = 0, lastStatus = -1
    private var lastScreen: CVPixelBuffer?, lastForwarded: CVPixelBuffer?
    private let compositor = PresenterCompositor(size: Fixture.initial)
    private let camera: CVPixelBuffer
    init(windowID: CGWindowID, source: LKRTCVideoSource, size: CGSize, composed: Bool) throws {
        self.windowID = windowID; self.source = source; self.size = size; self.composed = composed
        capturer = LKRTCVideoCapturer(delegate: source)
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 240, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixels) == kCVReturnSuccess,
            let pixels else { throw ShareProbeError.noFrame }
        let image = CIImage(color: CIColor(red: 0.08, green: 0.8, blue: 0.28)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240))
        CIContext().render(image, to: pixels); camera = pixels
        super.init()
        compositor.resize(to: size)
    }
    private func configuration(_ size: CGSize) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.width = Int(size.width); config.height = Int(size.height)
        config.minimumFrameInterval = CMTime(value: 1, timescale: 10)
        config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 3
        config.showsCursor = false; config.capturesAudio = false
        config.ignoreShadowsSingleWindow = true
        return config
    }
    func start() async throws -> GuestCameraInfo {
        var selected: SCWindow?
        // AppKit ordering and WindowServer's SCK inventory are asynchronous.
        // Retry only the exact generated window, never another app or display.
        for _ in 0..<10 {
            let content: SCShareableContent = try await guestAwait(timeout: 15) { done in
                SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { value, error in
                    if let error { done(.failure(error)) }
                    else if let value { done(.success(value)) }
                    else { done(.failure(ShareProbeError.missingWindow)) }
                }
            }
            selected = content.windows.first { $0.windowID == windowID && $0.owningApplication?.processID == ownerPID }
            if selected != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let window = selected else { throw ShareProbeError.missingWindow }
        let value = SCStream(filter: SCContentFilter(desktopIndependentWindow: window), configuration: configuration(size), delegate: self)
        try value.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        source.adaptOutputFormat(toWidth: Int32(size.width), height: Int32(size.height), fps: 10)
        activate(value)
        try await guestAwait(timeout: 15) { done in value.startCapture { error in done(error.map { .failure($0) } ?? .success(())) } }
        let heartbeat = DispatchSource.makeTimerSource(queue: queue)
        heartbeat.schedule(deadline: .now(), repeating: .milliseconds(100))
        heartbeat.setEventHandler { [weak self] in self?.forward() }
        timer = heartbeat; heartbeat.resume()
        return GuestCameraInfo(deviceName: "synthetic-own-window", width: Int32(size.width), height: Int32(size.height), fps: 10,
            requestedWidth: Int32(size.width), requestedHeight: Int32(size.height), requestedFPS: 10, sessionPreset: "SCK-own-window",
            minimumFrameDuration: CMTime(value: 1, timescale: 10), maximumFrameDuration: CMTime(value: 1, timescale: 10),
            pixelFormat: kCVPixelFormatType_32BGRA, mirrored: false, rotationDegrees: 0)
    }
    func cancel() { lock.lock(); active = false; lock.unlock() }
    private func activate(_ value: SCStream) { lock.lock(); active = true; stream = value; lock.unlock() }
    func stop() async throws {
        cancel(); timer?.cancel(); timer = nil
        probeLog("window-capture-summary", evidence)
        if let stream {
            try await guestAwait(timeout: 15) { done in stream.stopCapture { error in done(error.map { .failure($0) } ?? .success(())) } }
            try stream.removeStreamOutput(self, type: .screen)
        }
        stream = nil
        try await guestAwait(timeout: 5) { done in self.queue.async { self.lastScreen = nil; done(.success(())) } }
    }
    func resize(_ next: CGSize) async throws {
        guard let stream else { throw ShareProbeError.stopped }
        try await guestAwait(timeout: 5) { done in self.queue.async {
            self.source.adaptOutputFormat(toWidth: Int32(next.width), height: Int32(next.height), fps: 10)
            self.compositor.resize(to: next); self.size = next; self.lastScreen = nil
            done(.success(()))
        } }
        try await guestAwait(timeout: 10) { done in stream.updateConfiguration(self.configuration(next)) { error in done(error.map { .failure($0) } ?? .success(())) } }
    }
    func setComposed(_ enabled: Bool) async throws {
        try await guestAwait(timeout: 5) { done in self.queue.async { self.composed = enabled; done(.success(())) } }
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.lock(); failure = error; active = false; lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let info = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let raw = (info?.first?[.status] as? NSNumber)?.intValue ?? -1
        let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        lock.lock()
        samples += 1; lastStatus = raw
        if raw == SCFrameStatus.complete.rawValue { completeSamples += 1 }
        sampleWidth = pixels.map(CVPixelBufferGetWidth) ?? 0; sampleHeight = pixels.map(CVPixelBufferGetHeight) ?? 0
        let first = samples <= 2
        lock.unlock()
        if first { probeLog("window-capture-sample", ["screen": type == .screen, "valid": sampleBuffer.isValid,
            "status": raw, "width": pixels.map(CVPixelBufferGetWidth) ?? 0, "height": pixels.map(CVPixelBufferGetHeight) ?? 0,
            "requestedWidth": size.width, "requestedHeight": size.height]) }
        guard type == .screen, sampleBuffer.isValid, raw == SCFrameStatus.complete.rawValue, let pixels,
            CVPixelBufferGetWidth(pixels) == Int(size.width), CVPixelBufferGetHeight(pixels) == Int(size.height) else { return }
        lastScreen = pixels
        lock.lock(); captures += 1; lock.unlock()
    }
    private func forward() {
        lock.lock(); let allowed = active; lock.unlock()
        guard allowed, let screen = lastScreen else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pixels: CVPixelBuffer
        if composed {
            var scene = PresenterScene(); scene.layout = .card
            scene.placement = .init(x: 0.77, y: 0.65, width: 0.20, height: 0.25)
            guard let sample = compositor.render(scene: scene, camera: camera, screen: screen, time: CMTime(seconds: now, preferredTimescale: 1_000_000_000)),
                let output = CMSampleBufferGetImageBuffer(sample) else { return }
            pixels = output
        } else { pixels = screen }
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: Int64(now * 1e9))
        source.capturer(capturer, didCapture: frame)
        lock.lock(); frames += 1; width = CVPixelBufferGetWidth(pixels); height = CVPixelBufferGetHeight(pixels); lastForwarded = pixels; lock.unlock()
    }
    func snapshot() -> GuestCameraSnapshot {
        lock.lock(); defer { lock.unlock() }
        return .init(frames: frames, advancingPTS: frames, dropped: 0, width: width, height: height, pixelFormat: kCVPixelFormatType_32BGRA,
            systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false)
    }
    var evidence: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["capturedFrames": captures, "forwardedFrames": frames, "width": width, "height": height, "active": active, "captureFailed": failure != nil,
            "rawSamples": samples, "completeSamples": completeSamples, "sampleWidth": sampleWidth, "sampleHeight": sampleHeight, "lastStatus": lastStatus]
    }
    func saveReference(_ url: URL) throws {
        lock.lock(); let pixels = lastForwarded; lock.unlock()
        guard let pixels else { throw ShareProbeError.noFrame }
        try CIContext().writePNGRepresentation(of: CIImage(cvPixelBuffer: pixels), to: url, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func performReaction() async -> Bool { false }
}

@MainActor private final class SharingRun: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var capture: WindowCapture?
    private var desiredSize = Fixture.initial
    private var composed = false
    private var report: [[String: Any]] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do { try await run(); Darwin.exit(0) }
            catch { probeLog("live-sharing-failed", ["errorType": String(describing: type(of: error)), "errorDomain": (error as NSError).domain,
                "errorCode": (error as NSError).code]); Darwin.exit(1) }
        }
    }
    private func run() async throws {
        var args = CommandLine.arguments
        if args.count == 1, let bundled = Bundle.main.object(forInfoDictionaryKey: "RockLiveSharingArguments") as? [String] {
            args += bundled
            if let log = Bundle.main.object(forInfoDictionaryKey: "RockLiveSharingLogPath") as? String {
                let fd = Darwin.open(log, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
                guard fd >= 0 else { throw ShareProbeError.arguments }
                dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); Darwin.close(fd)
            }
        }
        if args.count == 3, args[1] == "--capture-only" {
            try await captureOnly(output: URL(fileURLWithPath: args[2], isDirectory: true)); return
        }
        if args.count == 2, args[1] == "--diagnostic-self-test" {
            precondition(PhaseDiagnostics.shouldSample(tick: 1, start: 100, now: 101.1))
            precondition(!PhaseDiagnostics.shouldSample(tick: 1, start: 100, now: 101.3))
            precondition(!PhaseDiagnostics.shouldSample(tick: 2, start: 100, now: 102.4))
            precondition(PhaseDiagnostics.shouldSample(tick: 3, start: 100, now: 103.0))
            precondition(!PhaseDiagnostics.shouldSample(tick: 3, start: 100, now: 104.0))
            let shared = "same-native-id"
            let stats: [[String: Any]] = [
                ["type": "outbound-rtp", "target": "PUBLISHER", "kind": "video", "framesSent": 7,
                 "sampleUptime": 101.25, "nativeTimestampUS": 101_250_000],
                ["type": "transport", "target": "PUBLISHER", "selectedCandidatePairId": shared],
                ["type": "candidate-pair", "target": "SUBSCRIBER", "id": shared, "localCandidateId": shared],
                ["type": "local-candidate", "target": "SUBSCRIBER", "id": shared, "relayProtocol": "tls"]]
            let sender = PhaseDiagnostics.summary(stats, target: "PUBLISHER")
            precondition(sender["videoPresent"] as? Bool == true && sender["pairPresent"] as? Bool == false &&
                         sender["relayProtocol"] == nil && sender["framesSent"] as? Int == 7 &&
                         sender["sampleUptime"] as? Double == 101.25)
            let missing = PhaseDiagnostics.summary(stats, target: "SUBSCRIBER")
            precondition(missing["statsAvailable"] as? Bool == true && missing["videoPresent"] as? Bool == false)
            probeLog("sharing-diagnostic-self-test", ["passed": true]); return
        }
        if args.count == 4, args[1] == "--screen-control-h264" {
            try await lowResolutionH264Control(inviteFile: args[2], output: URL(fileURLWithPath: args[3], isDirectory: true)); return
        }
        guard (4...5).contains(args.count), ["h264", "vp8", "vp9"].contains(args[3]),
            let icePolicy = GuestICEPolicy(rawValue: args.count == 5 ? args[4] : "auto") else { throw ShareProbeError.arguments }
        let invitation = try GuestInvitation.parse(String(contentsOfFile: args[1], encoding: .utf8))
        let output = URL(fileURLWithPath: args[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard CGPreflightScreenCaptureAccess() else { throw ShareProbeError.permission }
        Darwin.signal(SIGALRM, SIG_DFL); Darwin.alarm(210)
        let codec = args[3]
        makeWindow()
        defer { window.orderOut(nil); window.close() }
        let receiver = GuestSession(makeEngine: {
            let engine = NativeGuestEngine(label: "M155 independent screen receiver", icePolicy: icePolicy)
            engine.diagnosticScreenShareProfileForTesting = Fixture.profile
            return engine
        })
        let sender = GuestSession(makeEngine: { [self] in
            let engine = NativeGuestEngine(label: "M155 synthetic screen sender", icePolicy: icePolicy)
            engine.diagnosticScreenShareProfileForTesting = Fixture.profile
            engine.cameraFactoryForTesting = { [self] source in
                let value = try! WindowCapture(windowID: CGWindowID(window.windowNumber), source: source, size: desiredSize, composed: composed)
                capture = value; return value
            }
            return engine
        })
        let startupTrace = Task { @MainActor [weak self] in
            for tick in 0..<60 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                if let engine = sender.engine {
                    probeLog("sharing-startup-stats", ["tick": tick, "capture": self?.capture?.evidence ?? [:], "sender": await engine.evidence()])
                }
            }
        }
        defer { startupTrace.cancel() }
        do {
            try await receiver.connect(invitation, publish: false, codec: codec, camera: false)
            try await sender.connect(invitation, publish: true, codec: codec, camera: true, initialAudioMuted: true)
            startupTrace.cancel()
            try await phase("screen-static", receiver: receiver, sender: sender, output: output)
            desiredSize = Fixture.resized; window.setContentSize(desiredSize); window.contentView?.needsDisplay = true
            try await capture?.resize(desiredSize)
            try await phase("screen-resized", receiver: receiver, sender: sender, output: output)
            composed = true; try await capture?.setComposed(true)
            try await phase("presenter-card", receiver: receiver, sender: sender, output: output)
            let identity = sender.engine?.publicationIdentity
            try await sender.mute(true, video: true)
            try await Task.sleep(nanoseconds: 1_000_000_000)
            guard let mutedReceiver = receiver.engine else { throw ShareProbeError.failedGate }
            let before = mutedReceiver.mediaSnapshot, receiverCount = receiver.connectionCount
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let after = mutedReceiver.mediaSnapshot
            let mutedPass = receiver.engine === mutedReceiver && receiver.connectionCount == receiverCount && receiver.state == .connected &&
                receiver.failure == nil && after.hasQuiescentVideo(since: before) && capture?.evidence["active"] as? Bool == false
            probeLog("live-sharing-muted", ["pass": mutedPass, "renderBefore": before.render, "renderAfter": after.render])
            guard mutedPass else { throw ShareProbeError.failedGate }
            try await sender.mute(false, video: true)
            guard sender.engine?.publicationIdentity == identity else { throw ShareProbeError.failedGate }
            try await phase("presenter-resumed", receiver: receiver, sender: sender, output: output)
            try await receiver.reconnectForTesting()
            try await phase("receiver-reconnected", receiver: receiver, sender: sender, output: output)
            try await sender.reconnectForTesting()
            try await phase("sender-reconnected", receiver: receiver, sender: sender, output: output)
            let senderStopped = await sender.leave(), receiverStopped = await receiver.leave()
            let success = senderStopped && receiverStopped && capture?.evidence["active"] as? Bool == false
            let result: [String: Any] = ["schema": 2, "passed": success, "imageVerification": SharingPixelAcceptance.method,
                "visionOCRStatus": "unavailable in retained live and offline controls; not used by this measurement",
                "codecRequested": codec, "icePolicy": icePolicy.rawValue, "source": "SCREEN_SHARE", "width": Fixture.profile.width,
                "scope": "SDK SCK own-window plus production PresenterCompositor buffer transport; app Presenter lifecycle and permission UI unqualified",
                "syntheticOnly": true, "physicalCamera": false, "physicalMicrophone": false, "mutePass": mutedPass,
                "cleanupPass": success, "phases": report]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"), options: .atomic)
            probeLog("live-sharing-complete", ["pass": success, "phases": report.count])
            guard success else { throw ShareProbeError.failedGate }
            Darwin.alarm(0)
        } catch {
            _ = await sender.leave(); _ = await receiver.leave()
            let result: [String: Any] = ["schema": 2, "passed": false, "imageVerification": SharingPixelAcceptance.method,
                "visionOCRStatus": "unavailable in retained live and offline controls; not used by this measurement", "codecRequested": codec,
                "errorType": String(describing: type(of: error)), "errorDomain": (error as NSError).domain, "errorCode": (error as NSError).code, "phases": report]
            try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"), options: .atomic)
            throw error
        }
    }
    private func makeWindow(size: CGSize = Fixture.initial) {
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "M155 synthetic sharing fixture"; window.contentView = DetailChart(frame: CGRect(origin: .zero, size: size))
        window.setFrameOrigin(CGPoint(x: 20, y: 40)); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    /// Separate diagnostic control; it cannot satisfy the full-resolution gates.
    private func lowResolutionH264Control(inviteFile: String, output: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ShareProbeError.permission }
        let invitation = try GuestInvitation.parse(String(contentsOfFile: inviteFile, encoding: .utf8))
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        Darwin.signal(SIGALRM, SIG_DFL); Darwin.alarm(90)
        let size = CGSize(width: 640, height: 400)
        let profile = GuestVideoProfile(width: 640, height: 400, fps: 10, maximumBitrate: 600_000)
        makeWindow(size: size); defer { window.orderOut(nil); window.close() }
        let receiver = GuestSession(makeEngine: {
            let value = NativeGuestEngine(label: "M155 lowres H264 screen receiver", icePolicy: .tcpRelay)
            value.diagnosticScreenShareProfileForTesting = profile; return value
        })
        let sender = GuestSession(makeEngine: { [self] in
            let value = NativeGuestEngine(label: "M155 lowres H264 screen sender", icePolicy: .tcpRelay)
            value.diagnosticScreenShareProfileForTesting = profile
            value.cameraFactoryForTesting = { [self] source in
                let capture = try! WindowCapture(windowID: CGWindowID(window.windowNumber), source: source, size: size, composed: false)
                self.capture = capture; return capture
            }
            return value
        })
        let diagnostics = Task { @MainActor [weak self] in
            for tick in 0..<90 {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { return }
                guard !Task.isCancelled else { return }
                if let engine = sender.engine { probeLog("screen-control-startup", ["tick": tick, "capture": self?.capture?.evidence ?? [:], "sender": await engine.evidence()]) }
            }
        }
        defer { diagnostics.cancel() }
        do {
            try await receiver.connect(invitation, publish: false, codec: "h264", camera: false)
            try await sender.connect(invitation, publish: true, codec: "h264", camera: true, initialAudioMuted: true)
            let deadline = ProcessInfo.processInfo.systemUptime + 20
            while (receiver.engine?.mediaSnapshot.render["advancingFrames"] as? Int ?? 0) < 20 {
                guard ProcessInfo.processInfo.systemUptime < deadline, receiver.failure == nil, sender.failure == nil else { throw ShareProbeError.noFrame }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let rx = receiver.engine, let tx = sender.engine else { throw ShareProbeError.noFrame }
            let received = await rx.evidence(), sent = await tx.evidence(), render = rx.mediaSnapshot.render
            let mediaPass = (render["width"] as? NSNumber)?.intValue == 640 && (render["height"] as? NSNumber)?.intValue == 400 &&
                (render["lastFrameAge"] as? Double ?? 99) < 0.8 && rx.incomingVideo.compactMap(\.source) == ["SCREEN_SHARE"] &&
                received["subscriberStatsFresh"] as? Bool == true && sent["publisherStatsFresh"] as? Bool == true
            let senderStopped = await sender.leave(), receiverStopped = await receiver.leave()
            let pass = mediaPass && senderStopped && receiverStopped && capture?.evidence["active"] as? Bool == false
            let result: [String: Any] = ["pass": pass, "scope": "640x400 H264 SCREEN_SHARE control only; not full-resolution acceptance", "sender": sent, "receiver": received,
                "capture": capture?.evidence ?? [:]]
            try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("h264-lowres-control.json"), options: .atomic)
            probeLog("screen-control-complete", result)
            guard pass else { throw ShareProbeError.failedGate }
        } catch { _ = await sender.leave(); _ = await receiver.leave(); throw error }
        Darwin.alarm(0)
    }
    private func captureOnly(output: URL) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw ShareProbeError.permission }
        Darwin.signal(SIGALRM, SIG_DFL); Darwin.alarm(35)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        makeWindow(); defer { window.orderOut(nil); window.close() }
        _ = LKRTCInitializeSSL()
        let audio = GuestSyntheticAudio()
        let factory = LKRTCPeerConnectionFactory(encoderFactory: LKRTCDefaultVideoEncoderFactory(), decoderFactory: LKRTCDefaultVideoDecoderFactory(), audioDevice: audio)
        let capture = try WindowCapture(windowID: CGWindowID(window.windowNumber), source: factory.videoSource(forScreenCast: true), size: Fixture.initial, composed: false)
        do {
            _ = try await capture.start()
            try await Task.sleep(nanoseconds: 3_000_000_000)
            probeLog("capture-only-initial", capture.evidence)
            try capture.saveReference(output.appendingPathComponent("capture-only.png"))
            try await capture.stop()
            let pass = (capture.evidence["capturedFrames"] as? Int ?? 0) > 0 && (capture.evidence["forwardedFrames"] as? Int ?? 0) > 10
            probeLog("capture-only-complete", ["pass": pass, "capture": capture.evidence])
            guard pass else { throw ShareProbeError.failedGate }
        } catch { try? await capture.stop(); throw error }
        _ = audio.terminateDevice(); Darwin.alarm(0)
    }
    private func phase(_ name: String, receiver: GuestSession, sender: GuestSession, output: URL) async throws {
        let marker = String(format: "P%02d", report.count + 1)
        let captureBefore = capture?.evidence["capturedFrames"] as? Int ?? 0
        (window.contentView as? DetailChart)?.marker = marker
        (window.contentView as? DetailChart)?.phase = UInt8(report.count + 1)
        window.contentView?.needsDisplay = true; window.contentView?.displayIfNeeded()
        let deadline = ProcessInfo.processInfo.systemUptime + 20
        while true {
            guard receiver.failure == nil, sender.failure == nil else { throw ShareProbeError.failedGate }
            let render = receiver.engine?.mediaSnapshot.render ?? [:]
            if (render["width"] as? NSNumber)?.doubleValue == desiredSize.width, (render["height"] as? NSNumber)?.doubleValue == desiredSize.height,
                (render["lastFrameAge"] as? Double ?? 99) < 0.8,
                (capture?.evidence["capturedFrames"] as? Int ?? 0) > captureBefore { break }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ShareProbeError.noFrame }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let rx = receiver.engine, let tx = sender.engine, let counter = rx.subscriber?.renderer, let phaseCapture = capture else { throw ShareProbeError.noFrame }
        let receiverCount = receiver.connectionCount, senderCount = sender.connectionCount
        let remoteGeneration = rx.remoteMediaGeneration, receiverIDs = Set(rx.incomingVideo.map(\.id))
        let beforeSender = await tx.evidence(), beforeReceiver = await rx.evidence()
        let start = ProcessInfo.processInfo.systemUptime
        let diagnostics = PhaseDiagnostics()
        let sampleTask = Task { @MainActor in
            // One serial sampler, at most three samples. A slow statistics call
            // skips later ticks; it never extends the fixed media window.
            for tick in 1...3 {
                let delay = start + Double(tick) - ProcessInfo.processInfo.systemUptime
                if delay > 0 {
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
                    catch { return }
                }
                guard !Task.isCancelled else { return }
                guard PhaseDiagnostics.shouldSample(tick: tick, start: start,
                                                    now: ProcessInfo.processInfo.systemUptime) else { continue }
                let sampledAt = ProcessInfo.processInfo.systemUptime
                let outgoing = await tx.screenShareStatsForTesting(.publisher)
                guard !Task.isCancelled else { return }
                let incoming = await rx.screenShareStatsForTesting(.subscriber)
                guard !Task.isCancelled else { return }
                let sample: [String: Any] = ["phase": name, "tick": tick, "startedUptime": sampledAt,
                    "completedUptime": ProcessInfo.processInfo.systemUptime,
                    "sender": PhaseDiagnostics.summary(outgoing, target: "PUBLISHER"),
                    "receiver": PhaseDiagnostics.summary(incoming, target: "SUBSCRIBER"),
                    "receiverRender": rx.mediaSnapshot.render,
                    "capture": phaseCapture.evidence]
                diagnostics.samples.append(sample)
                probeLog("sharing-phase-sample", sample)
            }
        }
        defer { sampleTask.cancel() }
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let end = ProcessInfo.processInfo.systemUptime
        sampleTask.cancel()
        let timedSamples = diagnostics.samples
        let decoded = counter.window(from: start, to: end)
        let renderAtEnd = rx.mediaSnapshot.render, captureAtEnd = phaseCapture.evidence
        let captureHealthyAtWindowEnd = capture === phaseCapture && captureAtEnd["active"] as? Bool == true && captureAtEnd["captureFailed"] as? Bool == false
        let sources = rx.incomingVideo.compactMap(\.source)
        let afterSender = await tx.evidence(), afterReceiver = await rx.evidence()
        func currentSessions() -> Bool {
            receiver.engine === rx && sender.engine === tx && receiver.connectionCount == receiverCount && sender.connectionCount == senderCount &&
                receiver.state == .connected && sender.state == .connected && receiver.failure == nil && sender.failure == nil &&
                !rx.mediaSnapshot.failed && !tx.mediaSnapshot.failed && rx.mediaSnapshot.connected &&
                rx.remoteMediaGeneration == remoteGeneration && Set(rx.incomingVideo.map(\.id)) == receiverIDs && receiverIDs.count == 1
        }
        let stableAtWindowEnd = currentSessions()
        let dimensions = (renderAtEnd["width"] as? NSNumber)?.doubleValue == desiredSize.width &&
            (renderAtEnd["height"] as? NSNumber)?.doubleValue == desiredSize.height && (renderAtEnd["lastFrameAge"] as? Double ?? 99) < 0.8
        let fresh = beforeSender["publisherStatsFresh"] as? Bool == true && beforeReceiver["subscriberStatsFresh"] as? Bool == true &&
            afterSender["publisherStatsFresh"] as? Bool == true && afterReceiver["subscriberStatsFresh"] as? Bool == true
        let received = output.appendingPathComponent("decoded-\(name).png")
        let captureForImage = phaseCapture, sizeForImage = desiredSize
        let expectedPayload = SharingPixelAcceptance.payload(nonce: Fixture.nonce, phase: UInt8(report.count + 1))
        let expectedComposition = composed
        let imageValidationStarted = ProcessInfo.processInfo.systemUptime
        // Pixel conversion and file I/O stay away from MainActor signaling.
        let (pixelResult, rgba, green) = try await Task.detached(priority: .utility) {
            try counter.savePNG(received.path)
            try captureForImage.saveReference(output.appendingPathComponent("reference-\(name).png"))
            let referenceRaster = try SharingPixelAcceptance.Raster(url: output.appendingPathComponent("reference-\(name).png"))
            let decodedRaster = try SharingPixelAcceptance.Raster(url: received)
            guard referenceRaster.width == Int(sizeForImage.width), referenceRaster.height == Int(sizeForImage.height),
                  decodedRaster.width == Int(sizeForImage.width), decodedRaster.height == Int(sizeForImage.height) else { throw ShareProbeError.failedGate }
            let pixelResult = try SharingPixelAcceptance.assess(reference: referenceRaster,
                decoded: decodedRaster, expectedPayload: expectedPayload, composed: expectedComposition)
            // Exact synthetic fixture color at the center of the production card.
            var rgba = [UInt8](repeating: 0, count: 4)
            guard let decodedImage = CIImage(contentsOf: received) else { throw ShareProbeError.noFrame }
            let point = CGRect(x: sizeForImage.width * 0.87, y: sizeForImage.height * 0.225, width: 1, height: 1)
            CIContext().render(decodedImage, toBitmap: &rgba, rowBytes: 4, bounds: point, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
            let green = rgba[1] > 130 && Int(rgba[1]) > Int(rgba[0]) + 70 && Int(rgba[1]) > Int(rgba[2]) + 70
            return (pixelResult, rgba, green)
        }.value
        let imageValidationSeconds = ProcessInfo.processInfo.systemUptime - imageValidationStarted
        let compositionPass = (composed ? green : !green) && pixelResult.compositionPass
        let stableAfterImageValidation = currentSessions()
        let captureAfterImage = phaseCapture.evidence
        let captureHealthyAfterImage = capture === phaseCapture && captureAfterImage["active"] as? Bool == true && captureAfterImage["captureFailed"] as? Bool == false
        let freshCurrentRemoteAfterImage = (rx.mediaSnapshot.render["lastFrameAge"] as? Double ?? 99) < 0.8
        let stable = stableAtWindowEnd && stableAfterImageValidation
        let pass = stable && fresh && dimensions && captureHealthyAtWindowEnd && captureHealthyAfterImage && freshCurrentRemoteAfterImage &&
            decoded.complete && decoded.frames >= 24 && decoded.maximumGap < 1 && pixelResult.pass && compositionPass && sources == ["SCREEN_SHARE"]
        let row: [String: Any] = ["phase": name, "pass": pass, "composed": composed, "requestedWidth": desiredSize.width, "requestedHeight": desiredSize.height,
            "marker": marker, "windowStartUptime": start, "windowEndUptime": end, "imageValidationSeconds": imageValidationSeconds,
            "stableAtWindowEnd": stableAtWindowEnd, "stableAfterImageValidation": stableAfterImageValidation, "stableCurrentSessions": stable, "freshStats": fresh, "exactEndDimensions": dimensions,
            "captureHealthyAtWindowEnd": captureHealthyAtWindowEnd, "captureHealthyAfterImageValidation": captureHealthyAfterImage,
            "freshCurrentRemoteAfterImageValidation": freshCurrentRemoteAfterImage, "captureAfterImageValidation": captureAfterImage,
            "newSCKCaptureForMarker": (capture?.evidence["capturedFrames"] as? Int ?? 0) > captureBefore,
            "imageVerification": pixelResult.evidence, "detailRasterPass": pixelResult.textPass && pixelResult.headingPass && pixelResult.stripePass,
            "phaseMarkerPass": pixelResult.markerPass, "compositionCardPass": compositionPass, "cardRGBA": rgba,
            "receivedSources": sources, "decoded": decoded.evidence, "renderAtWindowEnd": renderAtEnd, "capture": captureAtEnd,
            "senderAtWindowStart": PhaseDiagnostics.summary(beforeSender, target: "PUBLISHER"),
            "receiverAtWindowStart": PhaseDiagnostics.summary(beforeReceiver, target: "SUBSCRIBER"),
            "senderStartStatsCompletedUptime": beforeSender["statisticsCompletedUptime"] ?? NSNull(),
            "receiverStartStatsCompletedUptime": beforeReceiver["statisticsCompletedUptime"] ?? NSNull(),
            "timedSamples": timedSamples, "sender": afterSender, "receiver": afterReceiver]
        report.append(row); probeLog("live-sharing-phase", row)
        guard pass else { throw ShareProbeError.failedGate }
    }
}

@main private struct LiveSharing {
    static func main() {
        let app = NSApplication.shared, delegate = SharingRun()
        app.setActivationPolicy(.regular); app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
