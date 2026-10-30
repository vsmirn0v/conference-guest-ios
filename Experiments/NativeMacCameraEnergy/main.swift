import AppKit
import AVFoundation
import Darwin

// Matched camera-capture energy profiles for the native Mac app. Each phase
// opens a fresh session exactly like a meeting activation, warms up, then
// measures process and system-wide CPU time while frames are delivered.
// Video only: no microphone, network, preview or saved images.

struct Phase {
    let name: String
    let width: Int32
    let height: Int32
    let fps: Int32
    let lockAcrossStart: Bool
}

let phases: [Phase] = {
    let a = Phase(name: "legacy-preset720-unlocked", width: 1280, height: 720, fps: 30, lockAcrossStart: false)
    let b = Phase(name: "locked-720p30", width: 1280, height: 720, fps: 30, lockAcrossStart: true)
    let c = Phase(name: "locked-720p24", width: 1280, height: 720, fps: 24, lockAcrossStart: true)
    let d = Phase(name: "locked-1080p30", width: 1920, height: 1080, fps: 30, lockAcrossStart: true)
    return [a, b, c, d, d, c, b, a]
}()
let warmupSeconds = Double(ProcessInfo.processInfo.environment["ENERGY_WARMUP"] ?? "") ?? 8
let measureSeconds = Double(ProcessInfo.processInfo.environment["ENERGY_MEASURE"] ?? "") ?? 30
let restSeconds = 5.0
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)

func emit(_ event: String, _ fields: [String: Any] = [:]) {
    var row = fields
    row["event"] = event; row["uptime"] = ProcessInfo.processInfo.systemUptime; row["wall"] = Date().timeIntervalSince1970
    guard var data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
    data.append(10)
    let file = output.appendingPathComponent("probe.jsonl")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: file) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close() }
}

func processCPUSeconds() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

/// Cumulative CPU seconds of every process, read through ps (no privileges).
func systemCPU() -> [String: Double] {
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "pid=,time=,comm="]
    let pipe = Pipe(); task.standardOutput = pipe
    try? task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    var result: [String: Double] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3 else { continue }
        // time= is [[dd-]hh:]mm:ss.ss
        var seconds = 0.0
        for component in parts[1].replacingOccurrences(of: "-", with: ":").split(separator: ":") {
            seconds = seconds * 60 + (Double(component) ?? 0)
        }
        result["\(parts[0]) \((parts[2] as NSString).lastPathComponent)"] = seconds
    }
    return result
}

final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0, width = 0, height = 0
    private var firstPTS: Double?, lastPTS: Double?
    func reset() { lock.lock(); frames = 0; firstPTS = nil; lastPTS = nil; lock.unlock() }
    func read() -> (frames: Int, width: Int, height: Int, fps: Double) {
        lock.lock(); defer { lock.unlock() }
        let span = (lastPTS ?? 0) - (firstPTS ?? 0)
        return (frames, width, height, span > 0 ? Double(frames - 1) / span : 0)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
        lock.lock()
        frames += 1; width = CVPixelBufferGetWidth(pixels); height = CVPixelBufferGetHeight(pixels)
        if firstPTS == nil { firstPTS = pts }; lastPTS = pts
        lock.unlock()
    }
}

final class Probe: NSObject, NSApplicationDelegate {
    let queue = DispatchQueue(label: "camera-energy.session")
    let frames = DispatchQueue(label: "camera-energy.frames")
    let sink = Sink()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let start = {
            Darwin.alarm(UInt32(Double(phases.count) * (warmupSeconds + measureSeconds + restSeconds + 15) + 60))
            self.queue.async { self.runAll() }
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            emit("requesting-access")
            AVCaptureDevice.requestAccess(for: .video) { allowed in
                emit("access", ["allowed": allowed]); if allowed { start() } else { exit(3) }
            }
        default: emit("not-authorized", ["status": AVCaptureDevice.authorizationStatus(for: .video).rawValue]); exit(3)
        }
    }

    func runAll() {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified) else {
            emit("no-camera"); exit(4)
        }
        let original = (camera.activeFormat, camera.activeVideoMinFrameDuration, camera.activeVideoMaxFrameDuration)
        emit("device", ["name": camera.localizedName, "backgroundSelected": AVCaptureDevice.isBackgroundReplacementEnabled,
                        "centerStage": AVCaptureDevice.isCenterStageEnabled, "portrait": AVCaptureDevice.isPortraitEffectEnabled,
                        "studioLight": AVCaptureDevice.isStudioLightEnabled])
        Thread.sleep(forTimeInterval: restSeconds)
        let idleCPU = systemCPU(), idleBegan = ProcessInfo.processInfo.systemUptime, idleSelf = processCPUSeconds()
        Thread.sleep(forTimeInterval: measureSeconds / 2)
        report("idle", before: idleCPU, began: idleBegan, selfBefore: idleSelf, extra: [:])
        for (index, phase) in phases.enumerated() { run(phase, index: index, camera: camera) }
        if (try? camera.lockForConfiguration()) != nil {
            camera.activeFormat = original.0
            camera.activeVideoMinFrameDuration = original.1; camera.activeVideoMaxFrameDuration = original.2
            camera.unlockForConfiguration()
        }
        emit("done")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func run(_ phase: Phase, index: Int, camera: AVCaptureDevice) {
        guard let format = camera.formats.first(where: {
            let d = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            return d.width == phase.width && d.height == phase.height
        }) else { emit("missing-format", ["phase": phase.name]); return }
        let duration = CMTime(value: 1, timescale: phase.fps)
        let session = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            let video = AVCaptureVideoDataOutput(); video.alwaysDiscardsLateVideoFrames = true
            session.beginConfiguration()
            session.addInput(input); session.addOutput(video)
            if session.canSetSessionPreset(.hd1280x720) { session.sessionPreset = .hd1280x720 }
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
            video.setSampleBufferDelegate(sink, queue: frames)
            session.commitConfiguration()
            try camera.lockForConfiguration()
            camera.activeFormat = format
            camera.activeVideoMinFrameDuration = duration; camera.activeVideoMaxFrameDuration = duration
            if phase.lockAcrossStart {
                session.startRunning(); camera.unlockForConfiguration()
            } else {
                camera.unlockForConfiguration(); session.startRunning()
            }
        } catch { emit("configure-error", ["phase": phase.name, "error": "\(error)"]); return }
        sink.reset()
        Thread.sleep(forTimeInterval: warmupSeconds)
        sink.reset()
        let before = systemCPU(), began = ProcessInfo.processInfo.systemUptime, selfBefore = processCPUSeconds()
        Thread.sleep(forTimeInterval: measureSeconds)
        let delivered = sink.read()
        let active = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        report(phase.name, before: before, began: began, selfBefore: selfBefore, extra: [
            "index": index, "requested": "\(phase.width)x\(phase.height)@\(phase.fps)",
            "activeFormat": "\(active.width)x\(active.height)",
            "activeFPS": 1 / CMTimeGetSeconds(camera.activeVideoMinFrameDuration),
            "delivered": "\(delivered.width)x\(delivered.height)", "deliveredFPS": delivered.fps, "frames": delivered.frames,
            "backgroundActive": camera.isBackgroundReplacementActive, "centerStageActive": camera.isCenterStageActive])
        session.stopRunning()
        teardown(session)
        Thread.sleep(forTimeInterval: restSeconds)
    }

    func teardown(_ session: AVCaptureSession) {
        session.beginConfiguration()
        for output in session.outputs { (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil); session.removeOutput(output) }
        for input in session.inputs { session.removeInput(input) }
        session.commitConfiguration()
    }

    func report(_ name: String, before: [String: Double], began: Double, selfBefore: Double, extra: [String: Any]) {
        let after = systemCPU(), wall = ProcessInfo.processInfo.systemUptime - began
        var deltas: [(String, Double)] = []
        var total = 0.0
        for (key, value) in after { let delta = value - (before[key] ?? 0); if delta > 0 { total += delta; deltas.append((key, delta)) } }
        deltas.sort { $0.1 > $1.1 }
        var row = extra
        row["phase"] = name; row["wallSeconds"] = wall
        row["probeCPUPercent"] = (processCPUSeconds() - selfBefore) / wall * 100
        row["systemCPUPercent"] = total / wall * 100
        row["topProcesses"] = deltas.prefix(12).map { ["process": $0.0, "cpuPercent": $0.1 / wall * 100] }
        emit("window", row)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = Probe()
app.delegate = delegate
app.run()
