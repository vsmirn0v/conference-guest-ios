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
    @Published private var undoStack: [PresenterCanvasEdit] = []
    @Published private var redoStack: [PresenterCanvasEdit] = []
    private var pendingEdit: PresenterCanvasEdit?
    var canUndoEdit: Bool { !undoStack.isEmpty }
    var canRedoEdit: Bool { !redoStack.isEmpty }
    var canCompose: Bool { source == .canvas || screenSelected }
    var onPreviewVisibilityChanged: ((Bool) -> Void)?
    /// Retained capture pixels are immutable while the worker reads them.
    private struct CameraFrame: @unchecked Sendable { let pixels: CVPixelBuffer?; let revision: UInt64? }
    @Published var scene = PresenterScene() {
        didSet {
            var previous = oldValue
            // Speech activity affects only the generated Stage backdrop.
            if scene.image != nil || scene.backdrop != .stage { previous.speaking = scene.speaking }
            guard scene != previous else { return }
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
    var openCameraEffects: (() -> Void)?
    @Published private(set) var hasPreview = false
    @Published private(set) var hasCameraFrames = false
    @Published private(set) var cameraOn = false
    @Published private(set) var screenSelected = false
    @Published private(set) var screenPicking = false
    @Published private(set) var nativeOverlay = false
    @Published private(set) var aspectRatio: CGFloat = 16 / 9
    @Published private(set) var cameraHiddenInBackground = false
    var makeScreenSource: ((@escaping (CMSampleBuffer) -> Void, @escaping (Bool) -> Void, @escaping () -> Void, @escaping (String?) -> Void) -> PresenterScreenSource)?
    var prepareScreenSource: (() async -> Void)?
    var shareOtherApps: (() -> Void)?
    private var screenSource: PresenterScreenSource?
    private var screenStop: Task<Void, Never>?
    private var screenSample: CMSampleBuffer?
    private var screenEpoch = UUID()
    private let preferences: UserDefaults
    private var pendingRender = false
    private var canvasSize = CGSize(width: 1280, height: 720)
    private var compositorSize = CGSize.zero
    @Published var includeCamera = false { didSet { if includeCamera != oldValue { error = nil; invalidateCamera(); invalidateRender(); refresh() } } }
    @Published var mirrorCamera = true {
        didSet {
            guard mirrorCamera != oldValue else { return }
            preferences.set(mirrorCamera, forKey: "presenter.mirror-camera.v1")
            requestRender()
        }
    }
    var preparePrivateCamera: (() async -> Void)?
    var makePrivateCamera: (AVCaptureDevice.Position) -> PrivateCameraPreviewing = { PrivateCameraPreview(position: $0, framesPerSecond: 15) }
    private var cameraPosition: AVCaptureDevice.Position = .front
    private var selectedCameraDevice: AVCaptureDevice?
    var canFlipCamera: Bool { active && !held && !cameraOn && CameraDevices.available().count > 1 }
    func selectPrivateCamera(_ device: AVCaptureDevice) {
        guard selectedCameraDevice?.uniqueID != device.uniqueID else { return }
        selectedCameraDevice = device
        cameraPosition = device.position
        if !cameraOn { invalidateCamera(); invalidateRender(); refresh() }
    }
    var cameraDevice: AVCaptureDevice? { ownedCamera?.device }
    var cameraGeneration: UUID { cameraEpoch }
    #if DEBUG
    var cameraEvidenceForTesting: [String: Any] {
        ["foreground": foreground, "presented": presented, "held": held, "active": active,
         "cameraOn": cameraOn, "includeCamera": includeCamera, "liveSource": cameraSource != nil,
         "privateSource": ownedCamera != nil, "startingPrivate": cameraTask != nil, "frames": hasCameraFrames]
    }
    #endif
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
    private var cameraRevision: UInt64 = 0
    private var busy = false
    private var epoch = UUID()
    private var shareEpoch = UUID()
    private var latest: CMSampleBuffer?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var energySubscription: AnyCancellable?
    private var presented = false
    private var active = true
    private var held = false
    private var foreground = true
    private var cameraEpoch = UUID()
    private var cleanTransition = false
    private var lastRenderTime: TimeInterval = -.infinity
    private var lastSentTime: TimeInterval = -.infinity
    private var retryAfter: TimeInterval = 0
    private(set) var compositionCount = 0
    private(set) var heartbeatCount = 0
    private var renderWanted: Bool { active && foreground && !held && (presented || running || starting) }
    private var canRender: Bool { renderWanted && canCompose && (!screenPicking || running) && (!screenSelected || screenSample != nil) }
    private var renderInterval: TimeInterval {
        let budget = MediaEnergyBudget.shared
        let preview = includeCamera && !nativeOverlay ? budget.previewFPS : budget.inlineFPS
        return 1.0 / Double(running ? min(preview, budget.sharingFPS) : preview)
    }

    init(observeLifecycle: Bool = true, preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if preferences.object(forKey: "presenter.mirror-camera.v1") != nil {
            mirrorCamera = preferences.bool(forKey: "presenter.mirror-camera.v1")
        }
        energySubscription = MediaEnergyBudget.shared.$pressure.dropFirst().sink { [weak self] _ in
            DispatchQueue.main.async { self?.pump() }
        }
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
        let devices = CameraDevices.available()
        let current = cameraDevice ?? selectedCameraDevice ?? CameraDevices.preferred(in: devices)
        guard let nextID = CameraDevices.nextID(in: devices.map(\.uniqueID), current: current?.uniqueID),
              let next = devices.first(where: { $0.uniqueID == nextID }) else { return }
        selectPrivateCamera(next)
    }
    func showCameraEffects() {
        #if !targetEnvironment(simulator)
        guard active, foreground, !held, includeCamera, cameraOn || cameraDevice != nil else { return }
        openCameraEffects?()
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
    func liveCameraChanged() {
        guard cameraOn else { return }
        invalidateCamera(); invalidateRender(); refresh()
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
    /// Publishing needs exclusive capture ownership, not removal of a live-track observer.
    func releasePrivateCamera() async {
        if ownedCamera != nil || cameraTask != nil { invalidateCamera() }
        await cameraStop?.value
    }
    private func invalidateRender() {
        epoch = UUID(); latest = nil; hasPreview = false; preview.clear()
        pendingRender = true; lastRenderTime = -.infinity; retryAfter = 0
        timer?.invalidate(); timer = nil
    }
    private func acceptCamera(_ buffer: CVPixelBuffer, rotation: Int) {
        cameraFrame = buffer; self.rotation = rotation; cameraRevision &+= 1
        cameraTime = ProcessInfo.processInfo.systemUptime
        if !hasCameraFrames { hasCameraFrames = true }
        requestRender()
    }

    private func refresh() {
        if !renderWanted {
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
                self.acceptCamera(buffer, rotation: rotation)
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
                    capture.selectDevice(self.selectedCameraDevice)
                    do {
                        try await capture.startFrames { [weak self] buffer, rotation in
                            guard let self, self.cameraEpoch == attempt, self.includeCamera, !self.held else { return }
                            self.acceptCamera(buffer, rotation: rotation)
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
        if latest == nil { pendingRender = true }
        pump()
    }
    private func requestRender() { pendingRender = true; pump() }

    /// One deadline for new pixels/edits, camera expiry and sender keep-alive.
    /// Private still previews have no idle timer or GPU work.
    private func pump() {
        timer?.invalidate(); timer = nil
        guard renderWanted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if hasCameraFrames && now - cameraTime >= 0.5 {
            hasCameraFrames = false; cameraFrame = nil; pendingRender = true
        }
        if !busy && pendingRender && canRender && now >= max(lastRenderTime + renderInterval, retryAfter) {
            render()
        } else if !busy && running && !pendingRender && now >= lastSentTime + 1,
                  let latest, let heartbeat = PresenterCompositor.retimed(latest,
                    time: CMTime(seconds: now, preferredTimescale: 1_000_000_000)) {
            lastSentTime = now; heartbeatCount += 1
            sendSample?(heartbeat)
        }
        scheduleWake()
    }
    private func scheduleWake() {
        guard renderWanted else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var deadlines: [TimeInterval] = []
        if !busy && pendingRender && canRender { deadlines.append(max(lastRenderTime + renderInterval, retryAfter)) }
        if hasCameraFrames { deadlines.append(cameraTime + 0.5) }
        if !busy && running && !pendingRender && latest != nil { deadlines.append(lastSentTime + 1) }
        guard let deadline = deadlines.min() else { return }
        timer = Timer(timeInterval: max(0.001, deadline - now), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.pump() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func render() {
        guard !busy, canRender else { return }
        var settings = scene
        settings.cameraMirrored = mirrorCamera
        let passThrough = screenSelected && (nativeOverlay || !includeCamera) && settings.strokes.isEmpty && settings.draftStroke.isEmpty
        // A plain screen needs neither a Vision request nor a compositor pool.
        if !passThrough && (compositor == nil || compositorSize != canvasSize) {
            let old = compositor
            compositor = PresenterCompositor(size: canvasSize); compositorSize = canvasSize
            queue.async { withExtendedLifetime(old) {} }
        }
        let compositor = compositor
        pendingRender = false; busy = true
        let attempt = epoch
        let now = ProcessInfo.processInfo.systemUptime
        let clean = cleanTransition
        lastRenderTime = now
        if !passThrough { compositionCount += 1 }
        let frame = CameraFrame(pixels: !clean && includeCamera && !nativeOverlay && now - cameraTime < 0.5 ? cameraFrame : nil,
                                revision: cameraRevision)
        let screen = CameraFrame(pixels: screenSelected ? screenSample.flatMap(CMSampleBufferGetImageBuffer) : nil, revision: nil)
        let sourceSample = screen.pixels.flatMap { PresenterCompositor.sample($0, time: CMTime(seconds: now, preferredTimescale: 1_000_000_000)) }
        let angle = rotation
        let time = CMTime(seconds: now, preferredTimescale: 1_000_000_000)
        queue.async { [weak self] in
            let sample = autoreleasepool { passThrough ? sourceSample : compositor?.render(scene: settings, camera: frame.pixels, cameraRevision: frame.revision, screen: screen.pixels, rotation: angle, time: time) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.busy = false
                defer { self.pump() }
                guard self.epoch == attempt, self.active, self.foreground, !self.held else { return }
                guard let sample else {
                    // Encoder-held pool buffers are temporary backpressure. Retry
                    // the latest scene at a low rate instead of losing a still edit.
                    self.pendingRender = true; self.retryAfter = ProcessInfo.processInfo.systemUptime + 0.25
                    return
                }
                self.retryAfter = 0
                if clean { self.cleanTransition = false; if self.cameraFrame != nil { self.pendingRender = true } }
                self.latest = sample
                if !self.hasPreview { self.hasPreview = true }
                if self.presented { self.preview.enqueue(sample, rotation: 0) }
                if self.running { self.lastSentTime = ProcessInfo.processInfo.systemUptime; self.sendSample?(sample) }
            }
        }
    }

    func start() async {
        guard active, !held, foreground, !running, !starting, !stopping, let latest, let startSharing else { return }
        error = nil; starting = true
        let attempt = shareEpoch
        let stopSharing = self.stopSharing
        do {
            let time = ProcessInfo.processInfo.systemUptime
            try await startSharing(PresenterCompositor.retimed(latest,
                time: CMTime(seconds: time, preferredTimescale: 1_000_000_000)) ?? latest)
            guard active, foreground, !held, shareEpoch == attempt else { await stopSharing?(); return }
            running = true; lastSentTime = ProcessInfo.processInfo.systemUptime
        } catch is CancellationError {
            // Holds/Leave/sender replacement are lifecycle transitions, not an
            // import failure. A valid scene remains available for another start.
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
        undoStack = []; redoStack = []; pendingEdit = nil
        startSharing = nil; sendSample = nil; stopSharing = nil; makeCameraSource = nil; preparePrivateCamera = nil
        makeScreenSource = nil; prepareScreenSource = nil; shareOtherApps = nil
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
        await self.prepareScreenSource?()
        guard self.active, self.screenEpoch == attempt, !self.held else { return }
        let source = makeScreenSource({ [weak self] sample in
            self?.acceptScreen(sample, epoch: attempt)
        }, { [weak self] enabled in
            guard let self, self.screenEpoch == attempt else { return }
            self.nativeOverlay = enabled; self.cameraFrame = nil; self.hasCameraFrames = false
            self.invalidateRender(); self.refresh()
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
        screenSample = sample
        if screenPicking { screenPicking = false }
        if !screenSelected { screenSelected = true; invalidateRender() }
        let width = CGFloat(CVPixelBufferGetWidth(pixels)), height = CGFloat(CVPixelBufferGetHeight(pixels))
        guard width > 0, height > 0 else { return }
        if aspectRatio != width / height { aspectRatio = width / height }
        let scale = min(1, 1920 / max(width, height))
        canvasSize = CGSize(width: max(2, (width * scale / 2).rounded(.down) * 2),
                            height: max(2, (height * scale / 2).rounded(.down) * 2))
        if !foreground {
            let now = ProcessInfo.processInfo.systemUptime
            if running, now - lastSentTime >= 1.0 / Double(MediaEnergyBudget.shared.sharingFPS),
               let stamped = PresenterCompositor.sample(pixels, time: CMTime(seconds: now, preferredTimescale: 1_000_000_000)) {
                lastSentTime = now; sendSample?(stamped)
            }
        } else { pendingRender = true; refresh() }
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
    func waitForScreenStop() async { await screenStop?.value }
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
    func loadImage(_ data: Data, framing: PresenterScene.ImageFraming = .fit) async {
        let result = await Task.detached(priority: .userInitiated) { DecodedImage(value: Self.decode(data)) }.value
        guard active, !Task.isCancelled else { return }
        applyImage(result.value, framing: framing)
    }
    func importImage(_ data: Data) { applyImage(Self.decode(data)) }
    private func applyImage(_ image: CGImage?, framing: PresenterScene.ImageFraming = .fit) {
        guard let image else { error = L("Choose an image smaller than 25 MB."); return }
        error = nil; selectCanvas(); scene.image = image; scene.imageFraming = framing
    }
    func appendAnnotation(_ points: [CGPoint]) {
        guard !points.isEmpty else { return }
        editCanvas {
            if $0.strokes.count == 32 { $0.strokes.removeFirst() }
            $0.strokes.append(Array(points.prefix(512)).map { CGPoint(x: min(1, max(0, $0.x)), y: min(1, max(0, $0.y))) })
        }
    }
    func beginCanvasEdit() { if pendingEdit == nil { pendingEdit = PresenterCanvasEdit(scene) } }
    func commitCanvasEdit() {
        guard let previous = pendingEdit else { return }
        pendingEdit = nil
        guard previous != PresenterCanvasEdit(scene) else { return }
        undoStack.append(previous)
        if undoStack.count > 32 { undoStack.removeFirst() }
        redoStack = []
        if previous.placement != scene.placement || previous.layout != scene.layout { savePlacement() }
    }
    func cancelCanvasEdit() {
        if let pendingEdit { pendingEdit.restore(into: &scene) }
        pendingEdit = nil; scene.draftStroke = []
    }
    func editCanvas(_ edit: (inout PresenterScene) -> Void) {
        beginCanvasEdit(); edit(&scene); commitCanvasEdit()
    }
    func undoCanvasEdit() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(PresenterCanvasEdit(scene)); previous.restore(into: &scene); savePlacement()
    }
    func redoCanvasEdit() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(PresenterCanvasEdit(scene)); next.restore(into: &scene); savePlacement()
    }
    func clearDrawings() {
        guard !scene.strokes.isEmpty else { return }
        editCanvas { $0.draftStroke = []; $0.strokes = [] }
    }
}
