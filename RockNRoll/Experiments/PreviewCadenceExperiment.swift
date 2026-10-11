#if DEBUG
import AVFoundation
import Darwin
import UIKit

/// Camera-only laboratory fixture. No conference, network, microphone, sync or
/// second capturer/encoder. A separate signed test app preserves the beta install.
@MainActor
final class PreviewCadenceExperiment {
    let window: UIWindow
    private let controller = UIViewController()
    private let status = UILabel()
    private var surface: CameraCapturePreviewView?
    private var peer: NativeRTCPeer?
    private var pip: RockVideoPictureInPicture?
    private var task: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private let floating: Bool
    private let reversed: Bool
    private let duration: Double
    private let rates: [Int]
    private var started = false
    private var oldBrightness: CGFloat = 0
    private var oldIdleDisabled = false
    private var oldFloating = true
    private var oldBatteryMonitoring = false

    static func make(windowScene: UIWindowScene) -> PreviewCadenceExperiment? {
        guard ProcessInfo.processInfo.environment["ROCK_PREVIEW_EXPERIMENT"] == "1" else { return nil }
        return PreviewCadenceExperiment(windowScene: windowScene)
    }
    private init(windowScene: UIWindowScene) {
        let env = ProcessInfo.processInfo.environment
        floating = env["ROCK_PREVIEW_SURFACE"] == "pip"
        reversed = env["ROCK_PREVIEW_REVERSE"] == "1"
        rates = env["ROCK_PREVIEW_RATES"] == "30" ? [30] : [30, 60]
        duration = min(110, max(15, Double(env["ROCK_PREVIEW_SECONDS"] ?? "90") ?? 90))
        window = UIWindow(windowScene: windowScene)
        controller.view.backgroundColor = .black
        status.textColor = .white; status.textAlignment = .center
        status.numberOfLines = 0; status.accessibilityIdentifier = "preview.experiment.status"
        status.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(status)
        let begin = UIButton(type: .system)
        begin.setTitle("Begin measurement", for: .normal)
        begin.accessibilityIdentifier = "preview.experiment.begin"
        begin.addAction(UIAction { [weak self] _ in self?.begin() }, for: .touchUpInside)
        let stop = UIButton(type: .system)
        stop.setTitle("Stop", for: .normal); stop.accessibilityIdentifier = "preview.experiment.stop"
        stop.addAction(UIAction { [weak self] _ in self?.stop() }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [begin, stop]); buttons.spacing = 30
        buttons.translatesAutoresizingMaskIntoConstraints = false; controller.view.addSubview(buttons)
        NSLayoutConstraint.activate([
            status.topAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.topAnchor, constant: 8),
            status.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor, constant: 12),
            status.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor, constant: -12),
            buttons.centerXAnchor.constraint(equalTo: controller.view.centerXAnchor),
            buttons.bottomAnchor.constraint(equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        ])
        window.rootViewController = controller; window.makeKeyAndVisible()
    }
    func start() {
        oldBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
        UIDevice.current.isBatteryMonitoringEnabled = true
        oldBrightness = window.screen.brightness
        oldIdleDisabled = UIApplication.shared.isIdleTimerDisabled
        oldFloating = FloatingVideoPreference.enabled
        window.screen.brightness = 0.35
        UIApplication.shared.isIdleTimerDisabled = true
        FloatingVideoPreference.enabled = true
        status.text = "Preparing camera"
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 280_000_000_000) } catch { return }
            self?.stop()
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard await AVCaptureDevice.requestAccess(for: .video) else { throw CancellationError() }
                let peer = try NativeRTCPeer(target: "PREVIEW", factory: NativeRTCPeer.makeFactory(), ice: [])
                self.peer = peer
                try await peer.setCamera(true)
                guard !Task.isCancelled, let source = peer.cameraPreview else { throw CancellationError() }
                let surface = source.makeView(); surface.mirrored = true
                surface.translatesAutoresizingMaskIntoConstraints = false
                self.controller.view.insertSubview(surface, at: 0)
                NSLayoutConstraint.activate([
                    surface.leadingAnchor.constraint(equalTo: self.controller.view.leadingAnchor),
                    surface.trailingAnchor.constraint(equalTo: self.controller.view.trailingAnchor),
                    surface.topAnchor.constraint(equalTo: self.status.bottomAnchor, constant: 10),
                    surface.bottomAnchor.constraint(equalTo: self.controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -65)
                ])
                self.surface = surface
                let pip = RockVideoPictureInPicture(sourceView: surface)
                pip.onPresentationChanged = { [weak self] visible in
                    if visible, self?.floating == true { self?.begin() }
                }
                self.pip = pip
                pip.show(source: .cameraPreview(source), mirrored: true)
                self.status.text = "Ready · \(self.floating ? "PiP: press Home" : "Native: begin measurement")"
            } catch { self.status.text = "Error: \(error.localizedDescription)"; self.stop() }
        }
    }
    private func begin() {
        guard !started, peer != nil else { return }
        started = true
        let mode = floating ? "pip" : "native"
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let rates = self.reversed ? Array(self.rates.reversed()) : self.rates
                for fps in rates {
                    try Task.checkCancellation()
                    MediaEnergyBudget.shared.setExperimentalPreviewFPS(fps)
                    self.status.text = "Warm-up \(mode) · \(fps) fps"
                    try await Task.sleep(nanoseconds: 12_000_000_000)
                    self.status.text = "Measuring \(mode) · \(fps) fps"
                    let start = Date().timeIntervalSince1970
                    let cpu = Self.cpuTime()
                    let metrics = PreviewExperimentMetrics.begin()
                    try await Task.sleep(nanoseconds: UInt64(self.duration * 1e9))
                    var row = metrics.finish()
                    row["surface"] = mode; row["requested_fps"] = fps
                    row["wall_start_s"] = start; row["wall_end_s"] = Date().timeIntervalSince1970
                    row["cpu_seconds"] = Self.cpuTime() - cpu
                    row["brightness"] = Double(self.window.screen.brightness)
                    row["thermal_end"] = ProcessInfo.processInfo.thermalState.rawValue
                    row["low_power"] = ProcessInfo.processInfo.isLowPowerModeEnabled
                    row["battery_state"] = UIDevice.current.batteryState.rawValue
                    if let device = self.peer?.captureDevice {
                        let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                        row["capture_width"] = Int(size.width); row["capture_height"] = Int(size.height)
                        row["actual_sensor_fps"] = 1 / CMTimeGetSeconds(device.activeVideoMinFrameDuration)
                    }
                    try Self.append(row)
                }
                self.status.text = "Complete"
                self.stop()
            } catch { PreviewExperimentMetrics.cancel(); self.stop() }
        }
    }
    func stop() {
        task?.cancel(); task = nil
        watchdog?.cancel(); watchdog = nil
        PreviewExperimentMetrics.cancel()
        pip?.end(); pip = nil; surface?.stop(); surface = nil
        MediaEnergyBudget.shared.setExperimentalPreviewFPS(nil)
        window.screen.brightness = oldBrightness
        UIApplication.shared.isIdleTimerDisabled = oldIdleDisabled
        FloatingVideoPreference.enabled = oldFloating
        UIDevice.current.isBatteryMonitoringEnabled = oldBatteryMonitoring
        let retiring = peer; peer = nil
        Task { await retiring?.close() }
    }
    private static func cpuTime() -> Double {
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6
    }
    private static func append(_ row: [String: Any]) throws {
        let file = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("preview-experiment.jsonl")
        var content = (try? Data(contentsOf: file)) ?? Data()
        content.append(try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])); content.append(0x0a)
        try content.write(to: file, options: .atomic)
    }
}

/// Numeric timing only: no camera images, names or meeting addresses are saved.
final class PreviewExperimentMetrics: @unchecked Sendable {
    private static let lock = NSLock()
    private static var active: PreviewExperimentMetrics?
    private var captures: [Double] = []
    private var captureAge: [Double] = []
    private var buffers: [UInt: (Double, Double)] = [:]
    private var deliveries: [Double] = []
    private var enqueueAge: [Double] = []
    private var queueAge: [Double] = []
    private var rejected = 0
    private var invalidTimestamps = 0

    static func begin() -> PreviewExperimentMetrics {
        lock.lock(); defer { lock.unlock() }
        let value = PreviewExperimentMetrics(); active = value
        return value
    }
    static func cancel() { lock.lock(); active = nil; lock.unlock() }
    static func capture(timestamp: Int64, pixels: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return }
        let now = ProcessInfo.processInfo.systemUptime, captured = Double(timestamp) / 1e9
        active.captures.append(now)
        if now >= captured, now - captured < 1 { active.captureAge.append((now - captured) * 1000) }
        else { active.invalidTimestamps += 1 }
        if let pixels {
            if active.buffers.count > 512 { active.buffers.removeAll(keepingCapacity: true) }
            active.buffers[UInt(bitPattern: Unmanaged.passUnretained(pixels).toOpaque())] = (captured, now)
        }
    }
    static func delivery(sample: CMSampleBuffer, enqueued: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let active else { return }
        guard enqueued else { active.rejected += 1; return }
        let now = ProcessInfo.processInfo.systemUptime
        active.deliveries.append(now)
        active.queueAge.append((now - CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))) * 1000)
        if let pixels = CMSampleBufferGetImageBuffer(sample),
           let captured = active.buffers[UInt(bitPattern: Unmanaged.passUnretained(pixels).toOpaque())]?.0,
           now >= captured, now - captured < 1 { active.enqueueAge.append((now - captured) * 1000) }
    }
    func finish() -> [String: Any] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        if Self.active === self { Self.active = nil }
        func summary(_ values: [Double]) -> [String: Any] {
            let sorted = values.sorted()
            guard !sorted.isEmpty else { return ["samples": 0] }
            func percentile(_ p: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * p))] }
            return ["samples": sorted.count, "median": percentile(0.5), "p95": percentile(0.95), "p99": percentile(0.99), "maximum": sorted.last!]
        }
        func intervals(_ times: [Double]) -> [Double] { zip(times.dropFirst(), times).map { ($0 - $1) * 1000 } }
        func fps(_ times: [Double]) -> Double { times.count > 1 ? Double(times.count - 1) / (times.last! - times.first!) : 0 }
        return ["capture_fps": fps(captures), "capture_interval_ms": summary(intervals(captures)),
                "capture_callback_age_ms": summary(captureAge), "invalid_capture_timestamps": invalidTimestamps,
                "pip_enqueue_fps": fps(deliveries), "pip_interval_ms": summary(intervals(deliveries)),
                "pip_capture_to_enqueue_ms": summary(enqueueAge), "pip_queue_ms": summary(queueAge),
                "pip_rejected": rejected]
    }
}
#endif
