#if DEBUG
import AVFoundation
import CoreMedia
import QuartzCore
import UIKit

/// An early-launch rendering probe without a conference, capture device or network.
/// Audio category/activation is a separate opt-in diagnostic, never audio capture.
@MainActor
final class RendererResetProbeViewController: UIViewController {
    private let summary = UILabel()
    private let stack = UIStackView()
    private var panels: [RendererResetProbePanel] = []
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var pools: [RendererResetProbeMode: CVPixelBufferPool] = [:]
    private var frames = 0
    private var dropped = 0
    private var resets = 0
    private var losses = 0
    private var stopped = false
    private var lastLogTime: CFTimeInterval = 0
    private var logData = Data()
    private var phase = "baseline"
    private var phaseStep = 0
    private var phaseDeadline: CFTimeInterval = 0
    private var completedFlushes = 0
    private let launchID = UUID().uuidString
    private let width = 256, height = 144
    private let audioEnabled = ProcessInfo.processInfo.environment["CONFERENCE_TEST_RENDERER_PROBE_AUDIO"] == "1"
    private var audioLease: AudioSessionLease?
    private var audioState = "off"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        summary.textColor = .white
        summary.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        summary.numberOfLines = 3
        summary.accessibilityIdentifier = "renderer-probe.summary"
        summary.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(summary)
        stack.axis = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            summary.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            summary.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            summary.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            stack.topAnchor.constraint(equalTo: summary.bottomAnchor, constant: 8),
            stack.leadingAnchor.constraint(equalTo: summary.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: summary.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4)
        ])
        let requested = ProcessInfo.processInfo.environment["CONFERENCE_TEST_RENDERER_PROBE_MODE"]
        let modes = requested.flatMap(RendererResetProbeMode.init(rawValue:)).map { [$0] }
            ?? RendererResetProbeMode.nativeModes
        for mode in modes {
            let panel = RendererResetProbePanel(mode: mode)
            panels.append(panel)
            stack.addArrangedSubview(panel)
            panel.recreate(epoch: 0)
        }
        makePool()
        // Initialize notification delivery without activating or configuring audio.
        _ = AVAudioSession.sharedInstance()
        let center = NotificationCenter.default
        for name in [AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated { self?.servicesChanged(note.name) }
            })
        }
        let timer = Timer(timeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshLabels()
        record("started")
        configureAudio(reason: "startup")
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        retireAudio()
        timer?.invalidate(); timer = nil
        observers.forEach(NotificationCenter.default.removeObserver); observers.removeAll()
        panels.forEach { $0.stop() }
        pools.removeAll()
    }

    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        audioLease?.invalidate()
        if audioLease != nil { AudioSessionWorker.shared.deactivate() }
    }

    private func servicesChanged(_ name: Notification.Name) {
        guard !stopped else { return }
        if name == AVAudioSession.mediaServicesWereLostNotification {
            losses += 1
            audioLease?.invalidate()
            if audioEnabled { audioState = "lost" }
            record("services-lost")
        } else {
            // Capture orphaned state before retiring it, then compare fresh resources.
            resets += 1
            phase = "reset-recreated"; phaseStep = 0; completedFlushes = 0
            record("before-recreation")
            pools.removeAll()
            panels.forEach { $0.recreate(epoch: resets) }
            makePool()
            record("after-recreation-before-enqueue")
            configureAudio(reason: "media-services-reset")
        }
        refreshLabels()
    }

    private func configureAudio(reason: String) {
        guard audioEnabled, !stopped else { return }
        audioLease?.invalidate()
        let lease = AudioSessionLease(), operation = UUID()
        audioLease = lease; audioState = "configuring"
        let emit: @Sendable (RendererResetProbeAudioEvent) -> Void = { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped else { return }
                self.record("audio-" + event.step, extra: ["audioOperation": operation.uuidString,
                    "audioReason": reason, "audioRetired": self.audioLease !== lease || !lease.isActive,
                    "audio": event.values])
            }
        }
        AudioSessionWorker.shared.enqueue(lease: lease, operation: {
            let session = AVAudioSession.sharedInstance()
            var step = "configure"
            do {
                emit(.init(step: "before-configure", session: session))
                try session.setCategory(.playAndRecord, mode: .voiceChat,
                    options: [.mixWithOthers, .allowBluetoothHFP, .allowBluetoothA2DP])
                emit(.init(step: "after-configure", session: session))
                try lease.check()
                step = "activate"
                emit(.init(step: "before-activate", session: session))
                try session.setActive(true)
                emit(.init(step: "after-activate", session: session))
            } catch {
                emit(.init(step: step + "-error", session: session, error: error))
                throw error
            }
        }, completion: { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, !self.stopped, self.audioLease === lease, lease.isActive else { return }
                switch result {
                case .success: self.audioState = "active"
                case .failure: self.audioState = "failed"
                }
                self.record("audio-operation-complete", extra: ["audioOperation": operation.uuidString,
                    "audioReason": reason])
            }
        })
    }

    private func retireAudio() {
        guard let lease = audioLease else { return }
        lease.invalidate(); audioLease = nil; audioState = "stopped"
        // The worker orders this behind any already-entered activation.
        AudioSessionWorker.shared.deactivate()
    }

    private func makePool() {
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        for mode in panels.map(\.mode) {
            var pool: CVPixelBufferPool?
            let result = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
            if let pool { pools[mode] = pool }
            if result != kCVReturnSuccess { record("pool-error", extra: ["mode": mode.rawValue, "code": result]) }
        }
    }

    private func tick() {
        guard !stopped else { return }
        advanceRecovery()
        let timestamp = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000)
        for panel in panels {
            // A stalled renderer cannot exhaust another panel's buffer pool.
            guard let pool = pools[panel.mode], let pixels = makePixels(pool) else { dropped += 1; continue }
            if let sample = makeSample(pixels, timestamp: timestamp, immediate: panel.mode != .receiver) {
                panel.enqueue(sample)
            }
        }
        frames += 1
        if frames % 5 == 0 { refreshLabels() }
        if CACurrentMediaTime() - lastLogTime >= 1 {
            lastLogTime = CACurrentMediaTime()
            record("sample")
        }
    }

    private func advanceRecovery() {
        guard resets > 0, UIApplication.shared.applicationState == .active, view.window != nil else { return }
        let now = CACurrentMediaTime()
        switch phaseStep {
        case 0:
            // Leave the notification stack and allow foreground layout to settle.
            phaseStep = 1; phase = "foreground-settling"; phaseDeadline = now + 0.25
            record("foreground-settling")
        case 1 where now >= phaseDeadline:
            phaseStep = 2; phaseDeadline = now + 3
            flushPanels(phase: "foreground-flush")
        case 2 where now >= phaseDeadline:
            phase = "delayed-recreated"
            record("before-delayed-recreation")
            pools.removeAll()
            panels.forEach { $0.recreate(epoch: resets) }
            makePool()
            phaseStep = 3; phaseDeadline = now + 0.25
            record("after-delayed-recreation-before-enqueue")
        case 3 where now >= phaseDeadline:
            phaseStep = 4; phaseDeadline = now + 4
            flushPanels(phase: "delayed-flush")
        case 4 where completedFlushes == panels.count || now >= phaseDeadline:
            phaseStep = 5
            phase = completedFlushes == panels.count ? "finished" : "flush-timeout"
            record("recovery-phases-finished")
        default: break
        }
    }

    private func flushPanels(phase: String) {
        self.phase = phase; completedFlushes = 0
        let reset = resets, step = phaseStep
        record("flush-start")
        for panel in panels {
            panel.flush { [weak self] evidence in
                guard let self, !self.stopped, self.resets == reset, self.phaseStep == step else { return }
                self.completedFlushes += 1
                self.record("flush-completed", extra: ["flush": evidence])
                self.refreshLabels()
            }
        }
    }

    private func makePixels(_ pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &pixelBuffer)
                == kCVReturnSuccess, let pixelBuffer else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        if let y = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
           let uv = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
            let x = (frames * 7) % (width - 32), band = (frames * 3) % (height - 16)
            for row in 0..<height {
                let line = y.advanced(by: row * stride)
                memset(line, (band..<(band + 16)).contains(row) ? 160 : 48, stride)
                memset(line.advanced(by: x), 235, 32)
            }
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * height / 2)
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        CVBufferSetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        return pixelBuffer
    }

    private func makeSample(_ pixels: CVPixelBuffer, timestamp: CMTime, immediate: Bool) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixels, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 20),
            presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if immediate, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    private func refreshLabels() {
        summary.text = "Renderer reset probe · resets=\(resets) lost=\(losses)\nphase=\(phase) flushes=\(completedFlushes)/\(panels.count)\nframes=\(frames) dropped=\(dropped) · generated NV12 · 20 fps"
        panels.forEach { $0.refreshLabel() }
    }

    private func record(_ event: String, extra: [String: Any] = [:]) {
        var entry: [String: Any] = ["event": event, "time": Date().timeIntervalSince1970,
            "launch": launchID, "resets": resets, "losses": losses, "frames": frames,
            "phase": phase, "completedFlushes": completedFlushes,
            "audioEnabled": audioEnabled, "audioState": audioState,
            "dropped": dropped, "appState": UIApplication.shared.applicationState.rawValue,
            "panels": panels.map { $0.evidence }]
        entry.merge(extra) { _, value in value }
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]),
              let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        line.append(10)
        if logData.count + line.count > 196_608 { logData.removeAll(keepingCapacity: true) }
        logData.append(line)
        try? logData.write(to: directory.appendingPathComponent("renderer-reset-probe.jsonl"), options: .atomic)
    }
}

private struct RendererResetProbeAudioEvent: Sendable {
    let step: String
    private let capturedAt: TimeInterval
    private let category: String, mode: String
    private let options: UInt
    private let outputs: [String]
    private let sampleRate: Double
    private let errorDomain: String?, errorCode: Int?, errorDescription: String?
    init(step: String, session: AVAudioSession, error: Error? = nil) {
        self.step = step; capturedAt = Date().timeIntervalSince1970
        category = session.category.rawValue; mode = session.mode.rawValue
        options = session.categoryOptions.rawValue
        outputs = session.currentRoute.outputs.map { $0.portType.rawValue }
        sampleRate = session.sampleRate
        let error = error as NSError?
        errorDomain = error?.domain; errorCode = error?.code; errorDescription = error?.localizedDescription
    }
    var values: [String: Any] {
        var result: [String: Any] = ["capturedAt": capturedAt, "category": category, "mode": mode,
            "options": options, "outputs": outputs, "sampleRate": sampleRate]
        if let errorDomain { result["errorDomain"] = errorDomain }
        if let errorCode { result["errorCode"] = errorCode }
        if let errorDescription { result["errorDescription"] = errorDescription }
        return result
    }
}

private enum RendererResetProbeMode: String, CaseIterable {
    case legacy, renderer, receiver, wrapper
    static let nativeModes: [Self] = [.legacy, .renderer, .receiver]
}

@MainActor
private protocol RendererResetProbeBackend: AnyObject {
    var evidence: [String: Any] { get }
    func install(in view: UIView)
    func layout(in bounds: CGRect)
    func detach()
    func enqueue(_ sample: CMSampleBuffer) -> Bool
    func flush(completion: @escaping @MainActor () -> Void)
    func stop()
}

@MainActor
private protocol RendererResetProbeLayerBackend: RendererResetProbeBackend {
    var layer: AVSampleBufferDisplayLayer { get }
}

private extension RendererResetProbeLayerBackend {
    func install(in view: UIView) { view.layer.addSublayer(layer) }
    func layout(in bounds: CGRect) { layer.frame = bounds }
    func detach() { layer.removeFromSuperlayer() }
}

@MainActor
private final class RendererResetProbePanel: UIView {
    let mode: RendererResetProbeMode
    private let title = UILabel(), status = UILabel(), video = UIView()
    private var backend: (any RendererResetProbeBackend)?
    private var attempts = 0, accepted = 0, epoch = 0
    private var before: [String: Any] = [:]
    private var latest: CMSampleBuffer?
    private var flushing = false
    private var generation = UUID()

    init(mode: RendererResetProbeMode) {
        self.mode = mode
        super.init(frame: .zero)
        backgroundColor = UIColor(white: 0.08, alpha: 1)
        title.textColor = .white; title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.text = ["legacy": "Layer only", "renderer": "iOS 17 renderer",
                      "receiver": "iOS 27 Receiver + synchronizer", "wrapper": "Production guest sample-buffer view"][mode.rawValue]
        status.textColor = .white; status.numberOfLines = 3
        status.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        status.accessibilityIdentifier = "renderer-probe.\(mode.rawValue).status"
        video.backgroundColor = .black
        video.isAccessibilityElement = true
        video.accessibilityLabel = "\(mode.rawValue) generated video"
        video.accessibilityIdentifier = "renderer-probe.\(mode.rawValue).video"
        addSubview(title); addSubview(video); addSubview(status)
    }
    required init?(coder: NSCoder) { nil }

    func recreate(epoch: Int) {
        before = evidence
        stop()
        self.epoch = epoch; attempts = 0; accepted = 0
        switch mode {
        case .legacy: backend = RendererResetProbeLegacy()
        case .renderer:
            if #available(iOS 17.0, *) { backend = RendererResetProbeModern() }
        case .receiver:
            if #available(iOS 27.0, *) { backend = RendererResetProbeReceiver() }
        case .wrapper: backend = RendererResetProbeWrapper()
        }
        backend?.install(in: video)
        setNeedsLayout(); layoutIfNeeded(); refreshLabel()
    }
    func stop() {
        generation = UUID(); latest = nil; flushing = false
        let old = backend; backend = nil
        old?.stop(); old?.detach()
    }
    func enqueue(_ sample: CMSampleBuffer) {
        guard let backend else { return }
        latest = sample
        attempts += 1
        guard !flushing else { return }
        if backend.enqueue(sample) { accepted += 1 }
    }
    func flush(completion: @escaping @MainActor ([String: Any]) -> Void) {
        guard let backend else { completion(["mode": mode.rawValue, "unavailable": true]); return }
        let expected = generation, before = evidence
        flushing = true
        backend.flush { [weak self, weak backend] in
            guard let self, let backend, self.generation == expected, self.backend === backend else { return }
            self.flushing = false
            let afterFlush = self.evidence
            // Legacy/17 backends admit by status, not a possibly retained old error.
            // Receiver supplies its typed enqueue result. No repeated flush loop.
            if let latest = self.latest {
                self.attempts += 1
                if backend.enqueue(latest) { self.accepted += 1 }
            }
            self.refreshLabel()
            completion(["mode": self.mode.rawValue, "before": before,
                        "afterFlush": afterFlush, "afterReplay": self.evidence])
        }
    }
    var evidence: [String: Any] {
        var result: [String: Any] = ["mode": mode.rawValue, "epoch": epoch, "attempts": attempts, "accepted": accepted,
                                   "generation": generation.uuidString, "flushing": flushing]
        result.merge(backend?.evidence ?? ["status": "unavailable"]) { _, value in value }
        return result
    }
    func refreshLabel() {
        let state = evidence
        let error = (state["errorDomain"] as? String).map { " \($0):\(state["errorCode"] ?? "?")" } ?? ""
        let attempts = state["attempts"] ?? self.attempts, accepted = state["accepted"] ?? self.accepted
        status.text = "epoch=\(epoch) attempts=\(attempts) accepted=\(accepted)\nstatus=\(state["status"] ?? "?")\(error)\nbefore: accepted=\(before["accepted"] ?? 0) status=\(before["status"] ?? "none")"
        video.accessibilityValue = "epoch=\(epoch) accepted=\(accepted)"
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        title.frame = CGRect(x: 8, y: 2, width: max(0, bounds.width - 16), height: 20)
        status.frame = CGRect(x: 8, y: max(24, bounds.height - 46), width: max(0, bounds.width - 16), height: 44)
        video.frame = CGRect(x: 8, y: 24, width: max(0, bounds.width - 16), height: max(1, bounds.height - 74))
        CATransaction.begin(); CATransaction.setDisableActions(true)
        backend?.layout(in: video.bounds)
        CATransaction.commit()
    }
}

private func rendererResetProbeError(_ error: Error?) -> [String: Any] {
    guard let error = error as NSError? else { return [:] }
    var result: [String: Any] = ["errorDomain": error.domain, "errorCode": error.code]
    if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
        result["underlyingDomain"] = underlying.domain; result["underlyingCode"] = underlying.code
    }
    return result
}

/// Exercises the production owner, including its source and flush barriers.
/// No layer or renderer API is called outside GuestSampleBufferView.
@MainActor
private final class RendererResetProbeWrapper: RendererResetProbeBackend {
    private let view = GuestSampleBufferView(frame: .zero)
    private var delivery: SampleBufferFrameDelivery?
    private var submitted = 0
    private var flushTask: Task<Void, Never>?
    private var flushToken: UUID?
    private var flushWaitTimedOut = false
    init() {
        view.contentMode = .scaleAspectFit
        // Gallery update/refresh retires an empty source more than once.
        view.clear(); view.clear()
        view.setFrameDeliverySuspended(true)
        view.setFrameDeliverySuspended(false)
        makeDelivery()
    }
    private func makeDelivery() {
        delivery = view.makeFrameDelivery { _, _ in }
        delivery?.setActive(true)
    }
    func install(in host: UIView) { host.addSubview(view) }
    func layout(in bounds: CGRect) { view.frame = bounds; view.setNeedsLayout(); view.layoutIfNeeded() }
    func detach() { view.removeFromSuperview() }
    var evidence: [String: Any] {
        let target = view.evidenceForTesting
        var result = target
        result["target"] = target
        result["submitted"] = submitted
        result["flushWaitTimedOut"] = flushWaitTimedOut
        result["wrapperFlushPending"] = flushToken != nil
        return result
    }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard let delivery else { return false }
        let before = view.evidenceForTesting["accepted"] as? Int ?? 0
        submitted += 1
        delivery.deliver(sample, rotation: 0)
        // The first geometry callback is asynchronous; target evidence includes
        // its accepted frame even when this immediate comparison cannot yet do so.
        return (view.evidenceForTesting["accepted"] as? Int ?? 0) > before
    }
    func flush(completion: @escaping @MainActor () -> Void) {
        flushTask?.cancel()
        let token = UUID(); flushToken = token; flushWaitTimedOut = false
        delivery?.invalidate(); delivery = nil
        view.clear()
        // Observe the production owner's barrier, never issue a second native
        // flush or mutate its backing to manufacture a successful probe result.
        flushTask = Task { @MainActor [weak self] in
            let deadline = ProcessInfo.processInfo.systemUptime + 12
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                guard let self, self.flushToken == token else { return }
                let state = self.view.evidenceForTesting
                let complete = state["flushing"] as? Bool == false
                let timedOut = ProcessInfo.processInfo.systemUptime >= deadline
                guard complete || timedOut else { continue }
                self.flushWaitTimedOut = !complete
                self.flushToken = nil; self.flushTask = nil
                self.makeDelivery()
                completion()
                return
            }
        }
    }
    func stop() {
        flushToken = nil; flushTask?.cancel(); flushTask = nil
        delivery?.invalidate(); delivery = nil
        view.clear()
    }
    deinit { flushTask?.cancel() }
}

@MainActor
private final class RendererResetProbeLegacy: RendererResetProbeLayerBackend {
    let layer = AVSampleBufferDisplayLayer()
    private var submitted = 0
    init() { layer.videoGravity = .resizeAspect }
    var evidence: [String: Any] {
        var result: [String: Any] = ["status": layer.status.rawValue, "ready": layer.isReadyForMoreMediaData,
                                   "flushRequired": layer.requiresFlushToResumeDecoding, "submitted": submitted]
        result.merge(rendererResetProbeError(layer.error)) { _, value in value }; return result
    }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard layer.status != .failed, layer.isReadyForMoreMediaData else { return false }
        submitted += 1; layer.enqueue(sample); return layer.status != .failed
    }
    func stop() { layer.flushAndRemoveImage() }
    func flush(completion: @escaping @MainActor () -> Void) {
        layer.flushAndRemoveImage()
        DispatchQueue.main.async { completion() }
    }
}

@available(iOS 17.0, *)
@MainActor
private final class RendererResetProbeModern: RendererResetProbeLayerBackend {
    let layer: AVSampleBufferDisplayLayer
    private let renderer: AVSampleBufferVideoRenderer
    private var submitted = 0
    init() {
        let layer = AVSampleBufferDisplayLayer()
        self.layer = layer; renderer = layer.sampleBufferRenderer; layer.videoGravity = .resizeAspect
    }
    var evidence: [String: Any] {
        var result: [String: Any] = ["status": renderer.status.rawValue, "ready": renderer.isReadyForMoreMediaData,
                                   "flushRequired": renderer.requiresFlushToResumeDecoding, "submitted": submitted]
        result.merge(rendererResetProbeError(renderer.error)) { _, value in value }; return result
    }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard renderer.status != .failed, renderer.isReadyForMoreMediaData else { return false }
        submitted += 1; renderer.enqueue(sample); return renderer.status != .failed
    }
    func stop() { renderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    func flush(completion: @escaping @MainActor () -> Void) {
        renderer.flush(removingDisplayedImage: true) {
            DispatchQueue.main.async { completion() }
        }
    }
}

@available(iOS 27.0, *)
@MainActor
private final class RendererResetProbeReceiver: RendererResetProbeLayerBackend {
    let layer = AVSampleBufferDisplayLayer()
    private var synchronizer: AVSampleBufferRenderSynchronizer?
    private var receiver: AVSampleBufferVideoRenderer.Receiver?
    private var started = false
    private var result = "waiting"
    private var error: Error?
    private var submitted = 0
    private var flushTask: Task<Void, Never>?
    init() {
        layer.videoGravity = .resizeAspect
        let synchronizer = AVSampleBufferRenderSynchronizer()
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        self.synchronizer = synchronizer
    }
    var evidence: [String: Any] {
        var value: [String: Any] = ["status": result, "rate": synchronizer?.rate ?? 0, "submitted": submitted]
        value.merge(rendererResetProbeError(error)) { _, value in value }; return value
    }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard let receiver, let synchronizer else { return false }
        if !started {
            synchronizer.setRate(1, time: CMSampleBufferGetPresentationTimeStamp(sample))
            started = true
        }
        submitted += 1
        switch receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: sample)) {
        case .enqueued: result = "enqueued"; error = nil; return true
        case .enqueuedWithDecodeFailures(let errors): result = "decode-failures"; error = errors.first; return true
        case .cancelledDueToFlush: result = "cancelled-flush"; error = nil
        case .cancelledDueToFlushRequiredToResume(let failure): result = "requires-flush"; error = failure
        case .cancelledDueToError(let failure): result = "failed"; error = failure
        @unknown default: result = "unknown-result"
        }
        return false
    }
    func stop() {
        flushTask?.cancel(); flushTask = nil
        receiver?.flush(); synchronizer?.rate = 0
        receiver = nil; synchronizer = nil
    }
    func flush(completion: @escaping @MainActor () -> Void) {
        guard let receiver else { completion(); return }
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            await receiver.flush(removingDisplayedImage: true)
            guard !Task.isCancelled else { return }
            self?.result = "flush-completed-awaiting-enqueue"; self?.error = nil
            completion()
        }
    }
    deinit { flushTask?.cancel() }
}
#endif
