import AVFoundation
import Combine
import ImageIO
import UIKit

@MainActor
protocol PresenterCameraSource: AnyObject { func stop() async }

/// One compositor job and one latest camera frame. Setup is private until Share.
@MainActor
final class PresenterModel: ObservableObject {
    /// Retained capture pixels are immutable while the worker reads them.
    private struct CameraFrame: @unchecked Sendable { let pixels: CVPixelBuffer? }
    @Published var scene = PresenterScene() {
        didSet {
            if scene.layout == .cutout && oldValue.layout != .cutout { cleanTransition = true }
            epoch = UUID(); latest = nil
            if timer != nil { render() }
        }
    }
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published private(set) var error: String?
    @Published private(set) var hasPreview = false
    @Published private(set) var hasCameraFrames = false
    @Published private(set) var cameraOn = false
    @Published var includeCamera = false { didSet { if includeCamera != oldValue { error = nil; invalidateCamera(); invalidateRender(); refresh() } } }
    var preparePrivateCamera: (() async -> Void)?
    var makePrivateCamera: (AVCaptureDevice.Position) -> PrivateCameraPreviewing = { PrivateCameraPreview(position: $0) }
    private var cameraPosition: AVCaptureDevice.Position = .front
    var canFlipCamera: Bool {
        guard !ProcessInfo.processInfo.isiOSAppOnMac else { return false }
        let positions = Set(AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera], mediaType: .video,
            position: .unspecified).devices.map(\.position))
        return positions.contains(.front) && positions.contains(.back) && !cameraOn
    }
    var cameraDevice: AVCaptureDevice? { ownedCamera?.device }
    @Published private(set) var available = false
    let preview = GuestSampleBufferView()
    var makeCameraSource: ((@escaping (CVPixelBuffer, Int) -> Void) -> PresenterCameraSource?)?
    var startSharing: ((CMSampleBuffer) async throws -> Void)? { didSet { available = startSharing != nil } }
    var sendSample: ((CMSampleBuffer) -> Void)?
    var stopSharing: (() async -> Void)?
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.presenter", qos: .userInitiated)
    private var compositor: PresenterCompositor?
    private var cameraSource: PresenterCameraSource?
    private var ownedCamera: PrivateCameraPreviewing?
    private var cameraTask: Task<Void, Never>?
    private var cameraStop: Task<Void, Never>?
    private var cameraFrame: CVPixelBuffer?
    private var rotation = 0
    private var cameraTime: TimeInterval = 0
    private var busy = false
    private var epoch = UUID()
    private var shareEpoch = UUID()
    private var latest: CMSampleBuffer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var presented = false
    private var active = true
    private var held = false
    private var foreground = true
    private var cameraEpoch = UUID()
    private var cleanTransition = false
    private var timerInterval: TimeInterval = 0

    init(observeLifecycle: Bool = true) {
        if observeLifecycle {
            foreground = UIApplication.shared.applicationState != .background
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setForeground(false) } })
            observers.append(NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.setForeground(true) } })
        }
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    func open() {
        if !presented && !running && cameraOn { includeCamera = true }
        presented = true; error = nil; refresh()
    }
    func close() { presented = false; refresh() }
    func flipCamera() {
        guard includeCamera, canFlipCamera else { return }
        cameraPosition = cameraPosition == .front ? .back : .front
        invalidateCamera(); invalidateRender(); refresh()
    }
    func showCameraEffects() {
        #if !targetEnvironment(simulator)
        guard active, foreground, !held, includeCamera, cameraOn || cameraDevice != nil else { return }
        AVCaptureDevice.showSystemUserInterface(.videoEffects)
        #endif
    }
    func update(cameraOn: Bool, held: Bool) {
        if self.cameraOn != cameraOn || self.held != held {
            self.cameraOn = cameraOn; self.held = held
            // Do not retain or publish a last frame after camera-off or a call hold.
            invalidateCamera()
            invalidateRender()
            if held { stop() }
            refresh()
        }
    }
    private func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            // App-owned GPU/camera composition is a foreground feature. A native
            // ReplayKit whole-screen broadcast remains the multitasking option.
            if running || starting { error = L("Presenter stopped when the app moved to the background."); stop() }
            invalidateRender(); invalidateCamera()
        }
        refresh()
    }
    private func invalidateCamera() {
        cameraEpoch = UUID()
        let pending = cameraTask; pending?.cancel(); cameraTask = nil
        let source = cameraSource, camera = ownedCamera, previous = cameraStop
        cameraSource = nil; ownedCamera = nil; cameraFrame = nil
        hasCameraFrames = false
        cameraStop = Task { await previous?.value; await pending?.value; await source?.stop(); await camera?.stop() }
    }
    func releaseCamera() async { invalidateCamera(); await cameraStop?.value }
    private func invalidateRender() { epoch = UUID(); latest = nil; hasPreview = false; preview.clear() }

    private func refresh() {
        let wanted = active && !held && foreground && (presented || running || starting)
        if !wanted {
            timer?.invalidate(); timer = nil; invalidateCamera(); invalidateRender()
            // Keep CIContext teardown on its owning queue, after any active render.
            let retired = compositor; compositor = nil
            queue.async { withExtendedLifetime(retired) {} }
            return
        }
        if includeCamera && cameraSource == nil && ownedCamera == nil && cameraTask == nil {
            let attempt = cameraEpoch
            let onFrame: @MainActor (CVPixelBuffer, Int) -> Void = { [weak self] buffer, rotation in
                guard let self, self.cameraEpoch == attempt, self.cameraOn, !self.held else { return }
                self.cameraFrame = buffer; self.rotation = rotation
                self.cameraTime = ProcessInfo.processInfo.systemUptime
                if !self.hasCameraFrames { self.hasCameraFrames = true }
            }
            if cameraOn { cameraSource = makeCameraSource?(onFrame) }
            else {
                let previousStop = cameraStop
                cameraTask = Task { @MainActor [weak self] in
                    guard let self else { return }
                    await previousStop?.value
                    await self.preparePrivateCamera?()
                    guard !Task.isCancelled, self.cameraEpoch == attempt else { return }
                    let capture = self.makePrivateCamera(self.cameraPosition)
                    do {
                        try await capture.startFrames { [weak self] buffer, rotation in
                            guard let self, self.cameraEpoch == attempt, self.includeCamera, !self.held else { return }
                            self.cameraFrame = buffer; self.rotation = rotation
                            self.cameraTime = ProcessInfo.processInfo.systemUptime
                            if !self.hasCameraFrames { self.hasCameraFrames = true }
                        }
                        guard !Task.isCancelled, self.cameraEpoch == attempt else { await capture.stop(); return }
                        self.ownedCamera = capture; self.cameraTask = nil
                    } catch {
                        await capture.stop()
                        guard self.cameraEpoch == attempt else { return }
                        self.cameraTask = nil; self.includeCamera = false; self.error = error.localizedDescription
                    }
                }
            }
        }
        if compositor == nil { compositor = PresenterCompositor() }
        let interval = includeCamera ? 1.0 / 12 : 1.0
        if timer == nil || timerInterval != interval {
            timer?.invalidate(); timerInterval = interval
            // Still canvases need a low-rate heartbeat, not twelve GPU passes/sec.
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.render() }
            }
            render()
        }
    }
    private func render() {
        guard !busy, let compositor, active, foreground, !held else { return }
        busy = true
        let attempt = epoch
        let settings = scene
        let now = ProcessInfo.processInfo.systemUptime
        let clean = cleanTransition
        let frame = CameraFrame(pixels: !clean && includeCamera && now - cameraTime < 0.5 ? cameraFrame : nil)
        let angle = rotation
        let time = CMTime(seconds: now, preferredTimescale: 1_000_000_000)
        queue.async { [weak self] in
            let sample = autoreleasepool { compositor.render(scene: settings, camera: frame.pixels, rotation: angle, time: time) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                guard self.epoch == attempt, self.active, self.foreground, !self.held, let sample else { return }
                if clean { self.cleanTransition = false }
                self.latest = sample
                if !self.hasPreview { self.hasPreview = true }
                if self.presented { self.preview.enqueue(sample, rotation: 0) }
                if self.running { self.sendSample?(sample) }
            }
        }
    }

    func start() async {
        guard active, !held, foreground, !running, !starting, !stopping, let latest, let startSharing else { return }
        error = nil; starting = true
        let attempt = shareEpoch
        let stopSharing = self.stopSharing
        do {
            try await startSharing(latest)
            guard active, foreground, !held, shareEpoch == attempt else { await stopSharing?(); return }
            running = true
        } catch { if active && shareEpoch == attempt { self.error = error.localizedDescription } }
        guard shareEpoch == attempt else { return }
        starting = false; refresh()
    }
    func stop() {
        let wasSharing = running || starting
        shareEpoch = UUID()
        running = false; starting = false
        invalidateRender()
        if wasSharing, !stopping, let stopSharing {
            stopping = true
            Task { await stopSharing(); stopping = false; refresh() }
        }
        refresh()
    }
    /// Called when an engine stops/retires its share sender; does not recurse.
    func sharingEnded() { shareEpoch = UUID(); running = false; starting = false; invalidateRender(); refresh() }
    func end() {
        active = false; presented = false
        stop(); refresh()
        scene = PresenterScene(); includeCamera = false
        startSharing = nil; sendSample = nil; stopSharing = nil; makeCameraSource = nil; preparePrivateCamera = nil
    }
    func importImage(_ data: Data) {
        guard data.count <= 25_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920,
                kCGImageSourceCreateThumbnailWithTransform: true
              ] as CFDictionary) else { error = L("Choose an image smaller than 25 MB."); return }
        scene.image = image
    }
    func appendAnnotation(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        if scene.strokes.count == 32 { scene.strokes.removeFirst() }
        scene.strokes.append(Array(points.prefix(512)).map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) })
    }
}
