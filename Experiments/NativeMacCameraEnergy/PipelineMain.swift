import AppKit
import AVFoundation
import Darwin
import LiveKitWebRTC

// Production GuestCamera -> LKRTCVideoSource -> hardware H.264 (1280x720) energy window.
// Built twice (shipped and candidate GuestCamera.swift); one window per process.
// Video only: no network, microphone, preview or saved images.

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let label = ProcessInfo.processInfo.environment["PIPELINE_LABEL"] ?? "run"
let warmup = 8.0, measure = 30.0

func emit(_ fields: [String: Any]) {
    guard var data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) else { return }
    data.append(10)
    let file = output.appendingPathComponent("pipeline.jsonl")
    if !FileManager.default.fileExists(atPath: file.path) { FileManager.default.createFile(atPath: file.path, contents: nil) }
    if let handle = try? FileHandle(forWritingTo: file) { _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data); try? handle.close() }
}

func selfCPU() -> Double {
    var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6 + Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
}

func cameraServiceCPU() -> Double {
    let task = Process(); task.executableURL = URL(fileURLWithPath: "/bin/ps")
    task.arguments = ["-axo", "time=,comm="]
    let pipe = Pipe(); task.standardOutput = pipe
    try? task.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").reduce(0) { total, line in
        let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard parts.count == 2, parts[1].hasSuffix("cameracaptured") else { return total }
        return total + parts[0].replacingOccurrences(of: "-", with: ":").split(separator: ":").reduce(0.0) { $0 * 60 + (Double($1) ?? 0) }
    }
}

final class EncodingRenderer: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    let encoder: LKRTCVideoEncoderH264
    private let lock = NSLock()
    private var frames = 0, encoded = 0, bytes = 0, width = 0, height = 0, key = true
    init(encoder: LKRTCVideoEncoderH264) { self.encoder = encoder }
    func reset() { lock.lock(); frames = 0; encoded = 0; bytes = 0; lock.unlock() }
    func read() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["frames": frames, "encoded": encoded, "bytes": bytes, "adaptedWidth": width, "adaptedHeight": height]
    }
    func encodedImage(_ size: Int) { lock.lock(); encoded += 1; bytes += size; lock.unlock() }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.lock(); frames += 1; width = Int(frame.width); height = Int(frame.height)
        let type: LKRTCFrameType = key ? .videoFrameKey : .videoFrameDelta; key = false
        lock.unlock()
        _ = encoder.encode(frame, codecSpecificInfo: nil, frameTypes: [NSNumber(value: type.rawValue)])
    }
}

@MainActor final class Runner: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Darwin.alarm(UInt32(warmup + measure + 60))
        Task { await run(); NSApp.terminate(nil) }
    }

    func run() async {
        LKRTCInitializeSSL()
        let factory = LKRTCPeerConnectionFactory()
        let source = factory.videoSource()
        let track = factory.videoTrack(with: source, trackId: "camera")
        guard let info = LKRTCVideoEncoderH264.supportedCodecs().first else { emit(["label": label, "error": "no-h264"]); return }
        let encoder = LKRTCVideoEncoderH264(codecInfo: info)
        let renderer = EncodingRenderer(encoder: encoder)
        encoder.setCallback { image, _ in renderer.encodedImage(image.buffer.count); return true }
        let settings = LKRTCVideoEncoderSettings()
        settings.name = "H264"; settings.width = 1280; settings.height = 720
        settings.startBitrate = 1100; settings.maxBitrate = 1100; settings.minBitrate = 100
        settings.maxFramerate = 30; settings.mode = .realtimeVideo
        _ = encoder.startEncode(with: settings, numberOfCores: 8)
        track.add(renderer)
#if CANDIDATE_CAMERA
        let fps = Int32(ProcessInfo.processInfo.environment["PIPELINE_BACKGROUND_FPS"] ?? "") ?? GuestCameraCadence.backgroundReplacementFPS
        let camera = GuestCamera(source: source, existingAuthorizationOnly: true, backgroundReplacementFPS: fps)
#else
        let camera = GuestCamera(source: source, existingAuthorizationOnly: true)
#endif
        do {
            let started = try await camera.start()
            try await Task.sleep(for: .seconds(warmup))
            renderer.reset()
            let before = camera.snapshot()
            let cpu0 = selfCPU(), service0 = cameraServiceCPU(), t0 = ProcessInfo.processInfo.systemUptime
            try await Task.sleep(for: .seconds(measure))
            let cpu1 = selfCPU(), service1 = cameraServiceCPU(), wall = ProcessInfo.processInfo.systemUptime - t0
            let after = camera.snapshot()
            var row = renderer.read()
            row["label"] = label
            row["activeFormat"] = "\(started.width)x\(started.height)"
            row["activeFPS"] = started.fps
            row["delivered"] = "\(after.width)x\(after.height)"
            row["captureFPS"] = Double(after.advancingPTS - before.advancingPTS) / wall
            row["encodedFPS"] = Double(row["encoded"] as? Int ?? 0) / wall
            row["encodedKbps"] = Double(row["bytes"] as? Int ?? 0) * 8 / wall / 1000
            row["backgroundActive"] = after.systemBackgroundActive ?? false
            row["processCPUPercent"] = (cpu1 - cpu0) / wall * 100
            row["cameraServiceCPUPercent"] = (service1 - service0) / wall * 100
            row["startupMilliseconds"] = after.startupMilliseconds
            emit(row)
        } catch { emit(["label": label, "error": "\(error)"]) }
        try? await camera.stop()
        track.remove(renderer)
        _ = encoder.release()
    }
}

@main @MainActor enum PipelineProbe {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let runner = Runner()
        app.delegate = runner
        app.run()
    }
}
