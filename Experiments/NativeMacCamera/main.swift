import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Darwin

let probeRoot = Bundle.main.bundleURL.deletingLastPathComponent()
let backgroundOnly = Bundle.main.object(forInfoDictionaryKey: "RockCameraProbeMode") as? String != "reaction"

final class EvidenceLog: @unchecked Sendable {
    let run: URL
    let started = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    init() {
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        run = probeRoot.appendingPathComponent("evidence/\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        save(["run": run.path, "log": run.appendingPathComponent("log.jsonl").path,
              "bundle": Bundle.main.bundlePath, "pid": ProcessInfo.processInfo.processIdentifier,
              "isIOSAppOnMac": ProcessInfo.processInfo.isiOSAppOnMac,
              "os": ProcessInfo.processInfo.operatingSystemVersionString], to: probeRoot.appendingPathComponent("latest-run.json"))
        event("startup", ["nativeMacProcess": !ProcessInfo.processInfo.isiOSAppOnMac])
    }
    func save(_ fields: [String: Any], to file: URL) {
        guard let data = try? JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: file, options: .atomic)
    }
    func event(_ name: String, _ fields: [String: Any] = [:]) {
        var row = fields
        row["event"] = name; row["elapsed"] = ProcessInfo.processInfo.systemUptime - started
        guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        data.append(10)
        lock.lock(); defer { lock.unlock() }
        let file = run.appendingPathComponent("log.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
        if let handle = try? FileHandle(forWritingTo: file) {
            do { try handle.seekToEnd(); try handle.write(contentsOf: data); try handle.close() } catch { try? handle.close() }
        }
    }
}

final class SampleSink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let log: EvidenceLog
    var onComplete: (() -> Void)?
    private let lock = NSLock()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var count = 0
    private var lastPTS: Double?
    private var advancing = 0
    private var firstFrameAt: Double?
    private var evidenceBegan: Double?
    private var reactionObserved = false
    private var images = 0
    init(log: EvidenceLog) { self.log = log }
    var progress: (frames: Int, advancing: Int, images: Int, effect: Bool, warmup: Double) {
        lock.lock(); defer { lock.unlock() }
        return (count, advancing, images, reactionObserved, firstFrameAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0)
    }
    func beginEvidence(at time: Double, anchor: String) {
        lock.lock()
        guard evidenceBegan == nil else { lock.unlock(); return }
        evidenceBegan = time
        lock.unlock()
        log.event("evidence-began", ["anchor": anchor, "targetOffsetsSeconds": [0.5, 1.5, 2.5, 3.5]])
    }
    func markReactionObserved() {
        lock.lock(); reactionObserved = true; lock.unlock()
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        lock.lock()
        count += 1
        if firstFrameAt == nil { firstFrameAt = now }
        if pts.isFinite, lastPTS == nil || pts > lastPTS! { advancing += 1 }
        lastPTS = pts.isFinite ? pts : nil
        let number = count, index = images, observed = reactionObserved
        let elapsed = evidenceBegan.map { now - $0 }
        let wanted = elapsed.map { $0 >= 0.50 + Double(index) && index < 4 } ?? false
        lock.unlock()
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        if number == 1 {
            log.event("first-frame", ["width": CVPixelBufferGetWidth(pixels), "height": CVPixelBufferGetHeight(pixels),
                "pixelFormat": CVPixelBufferGetPixelFormatType(pixels), "pts": pts.isFinite ? pts : -1])
        }
        guard wanted else { return }
        autoreleasepool {
            let input = CIImage(cvPixelBuffer: pixels)
            guard let image = context.createCGImage(input, from: input.extent) else { log.event("png-error"); return }
            let file = log.run.appendingPathComponent(String(format: "frame-%02d.png", index + 1))
            guard let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { log.event("png-error"); return }
            log.event("evidence-frame", ["file": file.lastPathComponent, "width": image.width, "height": image.height,
                "frame": number, "pts": pts.isFinite ? pts : -1, "reactionObserved": observed,
                "secondsAfterEvidenceAnchor": elapsed ?? -1])
            lock.lock(); images += 1; let complete = images == 4; lock.unlock()
            if complete { DispatchQueue.main.async { [weak self] in self?.onComplete?() } }
        }
    }
}

final class CameraProbe: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private let log = EvidenceLog()
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "native-camera-probe.session")
    private let frameQueue = DispatchQueue(label: "native-camera-probe.frames")
    private let deadlineQueue = DispatchQueue(label: "native-camera-probe.deadline", qos: .userInteractive)
    private lazy var sink = SampleSink(log: log)
    private let preview = AVCaptureVideoPreviewLayer()
    private var window: NSWindow!
    private let label = NSTextField(labelWithString: "Native macOS camera orientation test — video only")
    private var device: AVCaptureDevice?
    private var original: (AVCaptureDevice.Format, CMTime, CMTime)?
    private var output: AVCaptureVideoDataOutput?
    private var observations: [NSObjectProtocol] = []
    private var reactionObservation: NSKeyValueObservation?
    private var timer: Timer?
    private var captureBegan: Double?
    private var requested = false
    private var requestedAt: Double?
    private var fallbackStarted = false
    private var initialReactions = Set<String>()
    private var stopping = false
    private var backgroundObserved = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 600),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Rock native camera background probe"
        let content = window.contentView!
        content.wantsLayer = true; content.layer?.backgroundColor = NSColor.black.cgColor
        preview.frame = CGRect(x: 0, y: 45, width: 960, height: 555); preview.videoGravity = .resizeAspect
        content.layer?.addSublayer(preview)
        label.textColor = .white; label.frame = NSRect(x: 15, y: 10, width: 930, height: 25); content.addSubview(label)
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        log.event("permission", ["status": AVCaptureDevice.authorizationStatus(for: .video).rawValue])
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] allowed in
                DispatchQueue.main.async { [weak self] in allowed ? self?.start() : self?.finish("camera-permission-denied") }
            }
        } else if AVCaptureDevice.authorizationStatus(for: .video) == .authorized { start() }
        else { finish("camera-permission-denied") }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ notification: Notification) { log.event("application-terminating") }

    private func start() {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { finish("unexpected-compatibility-process"); return }
        captureBegan = ProcessInfo.processInfo.systemUptime
        // Arm before the first capture/device getter. Neither exit path touches
        // AppKit, AVFoundation, the logger, or a queue used by capture setup.
        Darwin.signal(SIGALRM, SIG_DFL)
        Darwin.alarm(15)
        deadlineQueue.asyncAfter(deadline: .now() + 14.8) { Darwin._exit(124) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 14) { [weak self] in self?.finish("capture-deadline") }
        log.event("deadline-armed", ["hardExitSeconds": 14.8, "kernelAlarmSeconds": 15])
        sink.onComplete = { [weak self] in self?.finish("four-images-saved") }
        for name in [AVCaptureSession.runtimeErrorNotification, AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification, AVCaptureSession.didStartRunningNotification,
                     AVCaptureSession.didStopRunningNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { [weak self] note in
                self?.log.event(note.name.rawValue, ["error": (note.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.code ?? 0])
            })
        }
        captureQueue.async { [weak self] in self?.configureCapture() }
    }
    private func configureCapture() {
        log.event("discovery-begin")
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        guard let camera = devices.first else {
            DispatchQueue.main.async { [weak self] in self?.finish("built-in-camera-unavailable") }; return
        }
        device = camera
        log.event("device", ["name": camera.localizedName, "uniqueID": camera.uniqueID,
            "type": camera.deviceType.rawValue, "position": camera.position.rawValue, "builtInCount": devices.count,
            "class": NSStringFromClass(type(of: camera)), "sessionClass": NSStringFromClass(type(of: session))])
        log.event("formats-enumeration-begin")
        let formats = camera.formats
        log.event("formats-enumeration-end", ["count": formats.count])
        for (index, candidate) in formats.enumerated() {
            log.event("format-description-begin", ["index": index])
            let d = CMVideoFormatDescriptionGetDimensions(candidate.formatDescription)
            log.event("available-format", ["index": index, "width": d.width, "height": d.height])
        }
        guard let format = formats.min(by: { rank($0) < rank($1) }) else {
            DispatchQueue.main.async { [weak self] in self?.finish("no-video-format") }; return
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        log.event("frame-ranges-begin", ["width": dimensions.width, "height": dimensions.height])
        let ranges = format.videoSupportedFrameRateRanges
        let rate = ranges.map { max($0.minFrameRate, min(24, $0.maxFrameRate)) }.min { abs($0 - 24) < abs($1 - 24) } ?? 24
        log.event("format", ["width": dimensions.width, "height": dimensions.height, "fps": rate,
            "minFPS": ranges.map(\.minFrameRate).min() ?? 0, "maxFPS": ranges.map(\.maxFrameRate).max() ?? 0])
            do {
                log.event("input-construction-begin")
                let input = try AVCaptureDeviceInput(device: camera)
                let inputDevice = input.device
                device = inputDevice
                original = (inputDevice.activeFormat, inputDevice.activeVideoMinFrameDuration, inputDevice.activeVideoMaxFrameDuration)
                log.event("input-construction-end", ["sameDeviceObject": inputDevice === camera,
                    "uniqueID": inputDevice.uniqueID, "class": NSStringFromClass(type(of: inputDevice))])
                let output = AVCaptureVideoDataOutput(); output.alwaysDiscardsLateVideoFrames = true
                output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                do {
                    session.beginConfiguration(); defer { session.commitConfiguration() }
                    guard session.canAddInput(input), session.canAddOutput(output) else {
                        throw NSError(domain: "NativeProbe", code: 1)
                    }
                    session.addInput(input); session.addOutput(output)
                    // inputPriority is unavailable on native macOS. Use the
                    // supported preset so High cannot replace the 720p format.
                    if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
                    self.output = output; output.setSampleBufferDelegate(sink, queue: frameQueue)
                }
                DispatchQueue.main.async { [weak self] in self?.attachAndRun(camera: inputDevice, output: output, format: format, fps: rate) }
            } catch {
                log.event("configuration-error", ["error": error.localizedDescription])
                DispatchQueue.main.async { [weak self] in self?.finish("configuration-error") }
            }
    }
    private func rank(_ format: AVCaptureDevice.Format) -> Int64 {
        let d = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let distance = abs(Int64(d.width) - 1280) + abs(Int64(d.height) - 720)
        return distance
    }
    private func attachAndRun(camera: AVCaptureDevice, output: AVCaptureVideoDataOutput, format: AVCaptureDevice.Format, fps: Double) {
        guard !stopping, let connection = output.connection(with: .video) else { finish("missing-output-connection"); return }
        preview.session = session
        let reference = preview.connection
        let initial = connection.videoRotationAngle, angle = reference?.videoRotationAngle ?? initial
        if let reference, reference.isVideoMirroringSupported {
            reference.automaticallyAdjustsVideoMirroring = false; reference.isVideoMirrored = false
        }
        reactionObservation = camera.observe(\.reactionEffectsInProgress, options: [.initial, .new]) { [weak self] camera, _ in
            let states = camera.reactionEffectsInProgress
            DispatchQueue.main.async { [weak self] in self?.reactionsChanged(states) }
        }
        log.event("orientation-reference", ["initialAngle": initial, "referenceAngle": angle,
            "initialOrientation": connection.videoOrientation.rawValue, "referenceOrientation": reference?.videoOrientation.rawValue ?? 0])
        captureQueue.async { [weak self] in
            guard let self else { return }
            session.beginConfiguration()
            if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
            if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
            session.commitConfiguration()
            log.event("configured", ["angle": connection.videoRotationAngle, "orientation": connection.videoOrientation.rawValue,
                "mirrored": connection.isVideoMirrored, "audioInputs": session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.audio) }.count])
            do { try applyFormat(camera, format: format, fps: fps) } catch {
                log.event("format-error", ["error": error.localizedDescription])
                DispatchQueue.main.async { [weak self] in self?.finish("format-error") }; return
            }
            session.startRunning()
            do { try applyFormat(camera, format: format, fps: fps) } catch {
                log.event("running-format-error", ["error": error.localizedDescription])
                DispatchQueue.main.async { [weak self] in self?.finish("running-format-error") }; return
            }
            let active = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
            log.event("running-format", ["width": active.width, "height": active.height,
                "sessionPreset": session.sessionPreset.rawValue,
                "minFrameDuration": CMTimeGetSeconds(camera.activeVideoMinFrameDuration),
                "maxFrameDuration": CMTimeGetSeconds(camera.activeVideoMaxFrameDuration)])
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in self?.poll() }
    }
    private func applyFormat(_ camera: AVCaptureDevice, format: AVCaptureDevice.Format, fps: Double) throws {
        try camera.lockForConfiguration(); defer { camera.unlockForConfiguration() }
        if camera.activeFormat !== format { camera.activeFormat = format }
        let interval = CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000)
        camera.activeVideoMinFrameDuration = interval; camera.activeVideoMaxFrameDuration = interval
    }
    private func reactionID(_ state: AVCaptureReactionEffectState) -> String {
        "\(state.reactionType.rawValue):\(state.startTime.value)/\(state.startTime.timescale)"
    }
    private func reactionsChanged(_ states: [AVCaptureReactionEffectState]) {
        let ids = states.map(reactionID)
        log.event("reaction-state", ["count": states.count, "ids": ids])
        guard requested, states.contains(where: { $0.reactionType == .thumbsUp && !$0.endTime.isValid && !initialReactions.contains(reactionID($0)) }) else { return }
        sink.markReactionObserved()
    }
    private func poll() {
        guard !stopping, let camera = device, let began = captureBegan else { return }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        let progress = sink.progress
        if #available(macOS 15.0, *) {
            let active = camera.isBackgroundReplacementActive
            if active && !backgroundObserved {
                backgroundObserved = true
                log.event("background-active", ["selected": AVCaptureDevice.isBackgroundReplacementEnabled, "active": active])
            }
        }
        if backgroundOnly {
            if !fallbackStarted && progress.warmup >= 1 && progress.advancing >= 24 && backgroundObserved {
                fallbackStarted = true
                log.event("background-evidence-ready", ["frames": progress.frames, "backgroundActive": backgroundObserved])
                sink.beginEvidence(at: ProcessInfo.processInfo.systemUptime, anchor: "active-system-background")
            } else if elapsed >= 9 && !fallbackStarted {
                fallbackStarted = true
                log.event("background-not-active", ["frames": progress.frames])
                sink.beginEvidence(at: ProcessInfo.processInfo.systemUptime, anchor: "inactive-background-fallback")
            }
            return
        }
        if !requested, !fallbackStarted, progress.warmup >= 3, progress.advancing >= 36, camera.reactionEffectsInProgress.isEmpty,
           camera.canPerformReactionEffects, camera.availableReactionTypes.contains(.thumbsUp) {
            requested = true; requestedAt = elapsed; initialReactions = Set(camera.reactionEffectsInProgress.map(reactionID))
            let requestTime = ProcessInfo.processInfo.systemUptime
            log.event("reaction-request", ["canPerform": camera.canPerformReactionEffects, "frames": progress.frames,
                "advancingFrames": progress.advancing, "warmupSeconds": progress.warmup,
                "mainThread": Thread.isMainThread, "deviceUniqueID": camera.uniqueID])
            label.stringValue = "Native capture running — requesting thumbs-up; saves four local PNGs"
            sink.beginEvidence(at: requestTime, anchor: "reaction-request")
            camera.performEffect(for: .thumbsUp)
        }
        if elapsed >= 9 && !requested && !fallbackStarted {
            fallbackStarted = true
            log.event("reaction-unavailable", ["canPerform": camera.canPerformReactionEffects])
            sink.beginEvidence(at: ProcessInfo.processInfo.systemUptime, anchor: "unavailable-reaction-fallback")
        }
    }
    private func finish(_ reason: String) {
        guard !stopping else { return }; stopping = true; timer?.invalidate(); timer = nil
        label.stringValue = "Capture stopped: \(reason)"
        reactionObservation = nil
        captureQueue.async { [weak self] in
            guard let self else { return }
            session.stopRunning(); output?.setSampleBufferDelegate(nil, queue: nil)
            if let device, let original, (try? device.lockForConfiguration()) != nil {
                device.activeFormat = original.0
                device.activeVideoMinFrameDuration = original.1; device.activeVideoMaxFrameDuration = original.2
                device.unlockForConfiguration()
            }
            let progress = sink.progress
            let summary: [String: Any] = ["reason": reason, "frames": progress.frames, "advancingFrames": progress.advancing,
                "images": progress.images, "backgroundObserved": backgroundObserved, "reactionObserved": progress.effect, "reactionRequested": requested,
                "reactionEvidence": progress.effect ? "new-kvo-interval-observed; inspect-images" : "kvo-inconclusive; inspect-request-timed-images",
                "sessionRunningAfterStop": session.isRunning,
                "captureElapsed": captureBegan.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0]
            log.save(summary, to: log.run.appendingPathComponent("summary.json")); log.event("stopped", summary)
            DispatchQueue.main.async { [weak self] in
                self?.preview.session = nil
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { NSApp.terminate(nil) }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = CameraProbe()
app.delegate = delegate
app.run()
