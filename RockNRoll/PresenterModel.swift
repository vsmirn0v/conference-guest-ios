import AVFoundation
import Combine
import ImageIO
import UIKit

@MainActor
protocol PresenterCameraSource: AnyObject { func stop() async }

@MainActor
protocol PresenterScreenSource: AnyObject {
    func start()
    func stop() async
}

/// One compositor job and one latest camera frame. Setup is private until Share.
@MainActor
final class PresenterModel: ObservableObject {
    enum Source { case screen, canvas }
    enum Tool: String { case move, crop, draw }
    @Published private(set) var source: Source = .screen
    @Published var tool: Tool = .move
    @Published private var undoStack: [[[CGPoint]]] = []
    @Published private var redoStack: [[[CGPoint]]] = []
    var canUndoDrawing: Bool { !undoStack.isEmpty }
    var canRedoDrawing: Bool { !redoStack.isEmpty }
    var canCompose: Bool { source == .canvas || screenSelected }
    var onPreviewVisibilityChanged: ((Bool) -> Void)?
    /// Retained capture pixels are immutable while the worker reads them.
    private struct CameraFrame: @unchecked Sendable { let pixels: CVPixelBuffer? }
    @Published var scene = PresenterScene() {
        didSet {
            if scene.layout != oldValue.layout { savePlacement() }
            if scene.layout == .cutout && oldValue.layout != .cutout {
                cleanTransition = true; invalidateRender()
            }
            requestRender()
        }
    }
    @Published private(set) var running = false
    @Published private(set) var starting = false
    @Published private(set) var stopping = false
    @Published private(set) var error: String?
    @Published private(set) var hasPreview = false
    @Published private(set) var hasCameraFrames = false
    @Published private(set) var cameraOn = false
    @Published private(set) var screenSelected = false
    @Published private(set) var screenPicking = false
    @Published private(set) var nativeOverlay = false
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var cameraHiddenInBackground = false
    var makeScreenSource: ((@escaping (CMSampleBuffer) -> Void, @escaping (Bool) -> Void, @escaping () -> Void, @escaping (String?) -> Void) -> PresenterScreenSource)?
    var shareOtherApps: (() -> Void)?
    private var screenSource: PresenterScreenSource?
    private var screenStop: Task<Void, Never>?
    private var screenSample: CMSampleBuffer?
    private var screenEpoch = UUID()
    private var screenDirty = false
    private let preferences: UserDefaults
    private var pendingRender = false
    private var canvasSize = CGSize(width: 1280, height: 720)
    private var compositorSize = CGSize.zero
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

    init(observeLifecycle: Bool = true, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: "presenter.placement.v1"),
           let placement = try? JSONDecoder().decode(PresenterPlacement.self, from: data) {
            scene.placement = placement; scene.placement.clamp()
        }
        if let value = preferences.string(forKey: "presenter.layout.v1"), let layout = PresenterScene.Layout(rawValue: value) { scene.layout = layout }
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
        if !presented && !running && cameraOn && canCompose { includeCamera = true }
        presented = true; onPreviewVisibilityChanged?(true); error = nil; refresh()
    }
    func close() { presented = false; onPreviewVisibilityChanged?(false); refresh() }
    func restorePreview() {
        guard presented, active, foreground, !held else { return }
        if let latest { preview.restore(latest, rotation: 0) }
        else { requestRender() }
    }
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
    func setForeground(_ value: Bool) {
        foreground = value
        if !value {
            // App-owned GPU/camera composition is a foreground feature. A native
            // ReplayKit whole-screen broadcast remains the multitasking option.
            if screenSelected {
                cameraHiddenInBackground = includeCamera && !nativeOverlay
                invalidateRender()
                if !nativeOverlay { invalidateCamera() }
                // Never use Core Image/Metal in a background UIKit process. The
                // screen continues unchanged, with no frozen app-owned camera.
            } else {
                if running || starting { error = L("Presenter stopped when the app moved to the background."); stop() }
                invalidateRender(); invalidateCamera()
            }
        }
        if value { cameraHiddenInBackground = false }
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
            timer?.invalidate(); timer = nil
            if !(screenSelected && running && nativeOverlay && !foreground) { invalidateCamera() }
            invalidateRender()
            if !running && !starting && !presented { releaseScreen() }
            // Keep CIContext teardown on its owning queue, after any active render.
            let retired = compositor; compositor = nil
            queue.async { withExtendedLifetime(retired) {} }
            return
        }
        if includeCamera && canCompose && !nativeOverlay && cameraSource == nil && ownedCamera == nil && cameraTask == nil {
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
        let interval = includeCamera && !nativeOverlay ? 1.0 / 15 : screenSelected ? 1.0 / 30 : 1.0
        if timer == nil || timerInterval != interval {
            timer?.invalidate(); timerInterval = interval
            // Still canvases need a low-rate heartbeat, not twelve GPU passes/sec.
            timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let ready = self.includeCamera && !self.nativeOverlay && ProcessInfo.processInfo.systemUptime - self.cameraTime < 0.5 && self.cameraFrame != nil
                    if self.hasCameraFrames != ready { self.hasCameraFrames = ready }
                    if !self.screenSelected || self.screenDirty || self.includeCamera && !self.nativeOverlay { self.requestRender() }
                }
            }
            requestRender()
        }
    }
    private func requestRender() {
        pendingRender = true
        if !busy { render() }
    }
    private func render() {
        guard !busy, active, foreground, !held, presented || running || starting,
              source == .canvas || screenSelected,
              !screenPicking || running,
              !screenSelected || screenSample != nil else { return }
        if compositor == nil || compositorSize != canvasSize {
            let old = compositor
            compositor = PresenterCompositor(size: canvasSize); compositorSize = canvasSize
            queue.async { withExtendedLifetime(old) {} }
        }
        guard let compositor else { return }
        pendingRender = false; screenDirty = false; busy = true
        let attempt = epoch
        let settings = scene
        let now = ProcessInfo.processInfo.systemUptime
        let clean = cleanTransition
        let frame = CameraFrame(pixels: !clean && includeCamera && !nativeOverlay && now - cameraTime < 0.5 ? cameraFrame : nil)
        let screen = CameraFrame(pixels: screenSelected ? screenSample.flatMap(CMSampleBufferGetImageBuffer) : nil)
        let passThrough = screenSelected && (nativeOverlay || !includeCamera) && settings.strokes.isEmpty && settings.draftStroke.isEmpty
        let sourceSample = screen.pixels.flatMap { PresenterCompositor.sample($0, time: CMTime(seconds: now, preferredTimescale: 1_000_000_000)) }
        let angle = rotation
        let time = CMTime(seconds: now, preferredTimescale: 1_000_000_000)
        queue.async { [weak self] in
            let sample = autoreleasepool { passThrough ? sourceSample : compositor.render(scene: settings, camera: frame.pixels, screen: screen.pixels, rotation: angle, time: time) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                defer { if self.pendingRender { self.render() } }
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
        invalidateRender(); releaseScreen()
        if wasSharing, !stopping, let stopSharing {
            stopping = true
            Task { await stopSharing(); stopping = false; refresh() }
        }
        refresh()
    }
    /// Called when an engine stops/retires its share sender; does not recurse.
    func sharingEnded() { shareEpoch = UUID(); running = false; starting = false; releaseScreen(); invalidateRender(); refresh() }
    func end() {
        active = false; presented = false
        onPreviewVisibilityChanged?(false); onPreviewVisibilityChanged = nil
        stop(); refresh()
        scene = PresenterScene(); includeCamera = false
        undoStack = []; redoStack = []
        startSharing = nil; sendSample = nil; stopSharing = nil; makeCameraSource = nil; preparePrivateCamera = nil
        makeScreenSource = nil; shareOtherApps = nil
    }
    func selectScreen() {
        guard active, !held, foreground, !screenPicking else { return }
        guard let makeScreenSource else {
            source = .screen
            invalidateCamera(); invalidateRender(); refresh()
            shareOtherApps?()
            return
        }
        let previousSource = source
        source = .screen
        screenPicking = true
        if !running { invalidateRender() }
        if let screenSource { screenSource.start(); return }
        // One capture source and one sender, including source changes mid-share.
        let attempt = screenEpoch
        let previousStop = screenStop
        Task { [weak self] in
        await previousStop?.value
        guard let self, self.active, self.screenEpoch == attempt, !self.held else { return }
        let source = makeScreenSource({ [weak self] sample in
            self?.acceptScreen(sample, epoch: attempt)
        }, { [weak self] enabled in
            guard let self, self.screenEpoch == attempt else { return }
            self.nativeOverlay = enabled; self.cameraFrame = nil; self.hasCameraFrames = false
            self.invalidateRender(); self.refresh(); self.requestRender()
        }, { [weak self] in
            guard let self, self.screenEpoch == attempt else { return }
            self.screenPicking = false
            if !self.screenSelected { self.source = previousSource }
            self.refresh(); self.requestRender()
        }, { [weak self] message in
            guard let self, self.screenEpoch == attempt else { return }
            self.error = message
            if self.screenSelected { self.stop() } else {
                self.source = previousSource; self.releaseScreen(); self.refresh(); self.requestRender()
            }
        })
        self.screenSource = source; source.start()
        }
    }
    func acceptScreen(_ sample: CMSampleBuffer, epoch attempt: UUID? = nil) {
        guard active, !held, attempt == nil || screenEpoch == attempt,
              let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        screenSample = sample; screenDirty = true
        if screenPicking { screenPicking = false }
        if !screenSelected { screenSelected = true; invalidateRender() }
        let width = CGFloat(CVPixelBufferGetWidth(pixels)), height = CGFloat(CVPixelBufferGetHeight(pixels))
        guard width > 0, height > 0 else { return }
        if aspectRatio != width / height { aspectRatio = width / height }
        let scale = min(1, 1920 / max(width, height))
        canvasSize = CGSize(width: max(2, (width * scale / 2).rounded(.down) * 2),
                            height: max(2, (height * scale / 2).rounded(.down) * 2))
        if !foreground {
            if running, let stamped = PresenterCompositor.sample(pixels,
                time: CMTime(seconds: ProcessInfo.processInfo.systemUptime, preferredTimescale: 1_000_000_000)) { sendSample?(stamped) }
        } else { refresh(); if !hasPreview { requestRender() } }
    }
    func selectCanvas(clearImage: Bool = false) {
        releaseScreen(); scene.draftStroke = []
        source = .canvas
        if clearImage { scene.image = nil }
        invalidateRender(); refresh()
    }
    private func releaseScreen() {
        screenEpoch = UUID(); screenSample = nil; screenSelected = false; screenPicking = false
        nativeOverlay = false; cameraHiddenInBackground = false; aspectRatio = 16 / 9
        canvasSize = CGSize(width: 1280, height: 720)
        let retired = screenSource; screenSource = nil
        let previous = screenStop
        if let retired { screenStop = Task { await previous?.value; await retired.stop() } }
    }
    func savePlacement() {
        guard active else { return }
        if let data = try? JSONEncoder().encode(scene.placement) { preferences.set(data, forKey: "presenter.placement.v1") }
        preferences.set(scene.layout.rawValue, forKey: "presenter.layout.v1")
    }
    func reportImportError(_ message: String) { error = message }
    private struct DecodedImage: @unchecked Sendable { let value: CGImage? }
    nonisolated private static func decode(_ data: Data) -> CGImage? {
        guard data.count <= 25_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1920,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary)
    }
    func loadImage(_ data: Data) async {
        let result = await Task.detached(priority: .userInitiated) { DecodedImage(value: Self.decode(data)) }.value
        guard active, !Task.isCancelled else { return }
        applyImage(result.value)
    }
    func importImage(_ data: Data) { applyImage(Self.decode(data)) }
    private func applyImage(_ image: CGImage?) {
        guard let image else { error = L("Choose an image smaller than 25 MB."); return }
        error = nil; selectCanvas(); scene.image = image
    }
    func appendAnnotation(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        saveDrawingUndo()
        if scene.strokes.count == 32 { scene.strokes.removeFirst() }
        scene.strokes.append(Array(points.prefix(512)).map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) })
    }
    private func saveDrawingUndo() {
        undoStack.append(scene.strokes)
        if undoStack.count > 32 { undoStack.removeFirst() }
        redoStack = []
    }
    func undoDrawing() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(scene.strokes); scene.draftStroke = []; scene.strokes = previous
    }
    func redoDrawing() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(scene.strokes); scene.draftStroke = []; scene.strokes = next
    }
    func clearDrawings() {
        guard !scene.strokes.isEmpty else { return }
        saveDrawingUndo(); scene.draftStroke = []; scene.strokes = []
    }
}
