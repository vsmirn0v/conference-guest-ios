import AppKit
import CoreImage
import CoreMedia
import Foundation
import LiveKitWebRTC

/// One-use native capture. All producer inputs are newest-value slots; only the
/// media queue owns rendering, and a synchronous gate fences final delivery.
final class NativeDesktopShareCapture: GuestCameraCapture, @unchecked Sendable {
    private enum Phase { case idle, starting, running, stopped }
    private let source: LKRTCVideoSource?
    private let capturer: LKRTCVideoCapturer?
    private let queue = DispatchQueue(label: "RockNRoll.desktop.share", qos: .userInitiated)
    private let lock = NSLock()
    private var phase: Phase = .idle
    private var generation: UInt64 = 0
    private var queued = false
    private var latest: CMSampleBuffer?
    private var latestScene: PresenterScene?
    private var latestCamera: CVPixelBuffer?
    private var cameraRevision: UInt64 = 0
    private var cameraPrivacyEpoch: UInt64 = 0
    private var count = 0
    private var dimensions = CGSize.zero
    private var started: GuestCompletion<GuestCameraInfo>?
    private var stopping: Task<Void, Error>?
    private var endHandler: (@Sendable (Error?) -> Void)?
    private var dimensionHandler: (@Sendable (CGSize) -> Void)?
    private var overlayHandler: (@Sendable (Bool) -> Void)?
    private var systemOverlay = false
    @MainActor private var bridge: MacScreenCaptureBridge?
    // Media-queue confinement starts here.
    private var timer: DispatchSourceTimer?
    private lazy var compositor = PresenterCompositor()
    private var blank: CVPixelBuffer?
    private let canvasOnly: Bool
    private var selectionMode: MacScreenCaptureSelectionMode = .automatic
    #if DEBUG
    var beforePickerForTesting: (@Sendable () async -> Void)?
    var beforeDeliveryForTesting: (@Sendable () -> Void)?
    private var testConsumer: (@Sendable (LKRTCVideoFrame) -> Void)?
    private var syntheticScreenSample: CMSampleBuffer?
    private var stopPasses = 0
    var stopPassesForTesting: Int { locked { stopPasses } }
    #endif

    var onDimensions: (@Sendable (CGSize) -> Void)? {
        get { locked { dimensionHandler } } set { locked { dimensionHandler = newValue } }
    }
    var onOverlay: (@Sendable (Bool) -> Void)? {
        get { locked { overlayHandler } } set { locked { overlayHandler = newValue } }
    }
    var onEnd: (@Sendable (Error?) -> Void)? {
        get { locked { endHandler } } set { locked { endHandler = newValue } }
    }
    init(source: LKRTCVideoSource, canvasOnly: Bool = false) {
        self.source = source; capturer = LKRTCVideoCapturer(delegate: source); self.canvasOnly = canvasOnly
    }
    #if DEBUG
    init(canvasForTesting: Bool, consumer: @escaping @Sendable (LKRTCVideoFrame) -> Void) {
        source = nil; capturer = nil; canvasOnly = canvasForTesting; testConsumer = consumer
    }
    init(screenForTesting sample: CMSampleBuffer, consumer: @escaping @Sendable (LKRTCVideoFrame) -> Void) {
        source = nil; capturer = nil; canvasOnly = false; testConsumer = consumer; syntheticScreenSample = sample
    }
    #endif
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    private func isActive(_ token: UInt64) -> Bool { locked { generation == token && (phase == .starting || phase == .running) } }
    func setScene(_ scene: PresenterScene?) { locked { if phase != .stopped { latestScene = scene } }; schedule() }
    func setSelectionMode(_ mode: MacScreenCaptureSelectionMode) { locked { if phase == .idle { selectionMode = mode } } }
    func setCamera(_ pixels: CVPixelBuffer?) {
        locked { if phase != .stopped {
            if pixels == nil { cameraPrivacyEpoch &+= 1 }
            latestCamera = pixels; cameraRevision &+= 1
        } }
        schedule()
    }

    func start() async throws -> GuestCameraInfo {
        let completion = GuestCompletion<GuestCameraInfo>()
        let token: UInt64 = try locked {
            guard phase == .idle else { throw GuestCameraError.alreadyStarted }
            generation &+= 1; phase = .starting; started = completion; return generation
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                try Task.checkCancellation()
                queue.async { [weak self] in
                    guard let self, isActive(token) else { return }
                    let heartbeat = DispatchSource.makeTimerSource(queue: queue)
                    heartbeat.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(10))
                    heartbeat.setEventHandler { [weak self] in self?.forward(token) }
                    timer = heartbeat; heartbeat.resume()
                    if canvasOnly { forward(token) }
                }
                if !canvasOnly {
                    #if DEBUG
                    if let sample = syntheticScreenSample { accept(sample, token: token) }
                    else { await beforePickerForTesting?(); try await presentPicker(token) }
                    #else
                    try await presentPicker(token)
                    #endif
                }
                return try await withCheckedThrowingContinuation { continuation in completion.install(continuation, timeout: 120) }
            } catch {
                cancel()
                // A startup error still owns any picker/stream already created.
                // Do not hide an unconfirmed teardown behind the original error.
                try await stop()
                throw error
            }
        }, onCancel: { [weak self] in self?.cancel() })
    }
    private func presentPicker(_ token: UInt64) async throws {
                    try await MainActor.run {
                        guard self.isActive(token), !Task.isCancelled else { throw CancellationError() }
                        guard MacScreenCaptureBridge.isSupported() else {
                            throw NativeDesktopError.unavailable("Screen and window selection requires macOS 14 or newer.")
                        }
                        let bridge = MacScreenCaptureBridge(); bridge.preserveDetail = true
                        bridge.selectionMode = self.locked { self.selectionMode }; self.bridge = bridge
                        bridge.onFrame = { [weak self] sample in self?.accept(sample, token: token) }
                        bridge.onEnd = { [weak self] error in self?.ended(error, token: token) }
                        bridge.onEffect = { [weak self] enabled in
                            guard let self else { return }
                            let handler = self.locked { () -> (@Sendable (Bool) -> Void)? in
                                guard self.generation == token, self.phase != .stopped else { return nil }
                                self.systemOverlay = enabled; self.cameraPrivacyEpoch &+= 1
                                return self.overlayHandler
                            }
                            handler?(enabled); self.schedule()
                        }
                        try bridge.present()
                    }
    }
    private func accept(_ sample: CMSampleBuffer, token: UInt64) {
        guard sample.isValid else { return }
        let accept = locked { () -> Bool in
            guard generation == token, phase == .starting || phase == .running else { return false }
            latest = sample; return true
        }
        if accept { schedule() }
    }
    private func schedule() {
        let token: UInt64? = locked {
            guard (phase == .starting || phase == .running), !queued else { return nil }
            queued = true; return generation
        }
        if let token { queue.async { [weak self] in self?.forward(token) } }
    }
    private func forward(_ token: UInt64) {
        let input: (CMSampleBuffer?, PresenterScene?, CVPixelBuffer?, UInt64, UInt64)? = locked {
            queued = false
            guard generation == token, phase == .starting || phase == .running else { return nil }
            return (latest, latestScene, systemOverlay ? nil : latestCamera, cameraRevision, cameraPrivacyEpoch)
        }
        guard let (sample, scene, camera, cameraRevision, cameraPrivacyEpoch) = input,
              let screen = sample.flatMap(CMSampleBufferGetImageBuffer) ?? (canvasOnly ? blankCanvas() : nil) else { return }
        let size = CGSize(width: CVPixelBufferGetWidth(screen), height: CVPixelBufferGetHeight(screen))
        // A screen without app overlays already contains final, native pixels.
        // Preserve Retina text and avoid Core Image/copies in the common path.
        let compose = canvasOnly || camera != nil || !(scene?.strokes.isEmpty ?? true) || !(scene?.draftStroke.isEmpty ?? true)
        let outputSize = scene != nil && compose ? Self.compositionSize(size) : size
        let now = ProcessInfo.processInfo.systemUptime
        let output: CVPixelBuffer
        if let scene, compose {
            compositor.resize(to: outputSize)
            guard let composed = compositor.render(scene: scene, camera: camera, cameraRevision: cameraRevision,
                screen: canvasOnly ? nil : screen, time: CMTime(seconds: now, preferredTimescale: 1_000_000_000)),
                let pixels = CMSampleBufferGetImageBuffer(composed) else { return }
            output = pixels
        } else { output = screen }
        let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: output), rotation: ._0, timeStampNs: Int64(now * 1e9))
        #if DEBUG
        beforeDeliveryForTesting?()
        #endif
        // Cancellation may happen during composition. Once cancel() returns,
        // this shared gate guarantees that no new frame enters the RTC source.
        let delivered: (GuestCompletion<GuestCameraInfo>?, (@Sendable (CGSize) -> Void)?, Bool)? = locked {
            guard generation == token, phase == .starting || phase == .running,
                  self.cameraPrivacyEpoch == cameraPrivacyEpoch else { return nil }
            let resized = dimensions != outputSize
            if resized {
                dimensions = outputSize
                source?.adaptOutputFormat(toWidth: Int32(outputSize.width), height: Int32(outputSize.height), fps: 30)
            }
            if let source, let capturer { source.capturer(capturer, didCapture: frame) }
            #if DEBUG
            testConsumer?(frame)
            #endif
            count += 1; phase = .running
            return (started, dimensionHandler, resized)
        }
        guard let (completion, resize, resized) = delivered else { return }
        if resized { resize?(outputSize) }
        completion?.finish(.success(info(outputSize)))
    }
    static func compositionSize(_ size: CGSize) -> CGSize {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return CGSize(width: 2, height: 2) }
        let scale = min(1, 1920 / size.width, 1080 / size.height)
        return CGSize(width: max(2, floor(size.width * scale / 2) * 2), height: max(2, floor(size.height * scale / 2) * 2))
    }
    private func blankCanvas() -> CVPixelBuffer? {
        if let blank { return blank }
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 1920, 1080, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value) == kCVReturnSuccess else { return nil }
        if let value { CIContext().render(CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: 1920, height: 1080)), to: value) }
        blank = value; return value
    }
    private func info(_ size: CGSize) -> GuestCameraInfo {
        .init(deviceName: "Selected screen content", width: Int32(size.width), height: Int32(size.height), fps: 30,
            requestedWidth: Int32(size.width), requestedHeight: Int32(size.height), requestedFPS: 30,
            sessionPreset: "ScreenCaptureKit", minimumFrameDuration: CMTime(value: 1, timescale: 30),
            maximumFrameDuration: CMTime(value: 1, timescale: 30), pixelFormat: kCVPixelFormatType_32BGRA,
            mirrored: false, rotationDegrees: 0)
    }
    private func ended(_ error: Error?, token: UInt64) {
        let result: (GuestCompletion<GuestCameraInfo>?, (@Sendable (Error?) -> Void)?)? = locked {
            guard generation == token, phase == .starting || phase == .running else { return nil }
            phase = .stopped; generation &+= 1; latest = nil; latestCamera = nil
            return (started, endHandler)
        }
        guard let (completion, handler) = result else { return }
        completion?.finish(.failure(error ?? CancellationError())); handler?(error)
    }
    func cancel() {
        let completion = locked { () -> GuestCompletion<GuestCameraInfo>? in
            phase = .stopped; generation &+= 1; latest = nil; latestCamera = nil; return started
        }
        completion?.finish(.failure(CancellationError()))
    }
    func stop() async throws {
        cancel()
        let task = locked { () -> Task<Void, Error> in
            if let stopping { return stopping }
            let value = Task { try await self.performStop() }; stopping = value; return value
        }
        try await task.value
    }
    private func performStop() async throws {
        #if DEBUG
        locked { stopPasses += 1 }
        #endif
        // Retire producers and drain queued work even if the system stream fails
        // to stop. The failure is retained by the coalesced stop task for callers.
        var failure: Error?
        let value = await MainActor.run { () -> MacScreenCaptureBridge? in
            let old = bridge; bridge = nil; old?.onFrame = nil; old?.onEnd = nil; return old
        }
        if let value {
            do { try await guestAwait(timeout: 10) { done in
                Task { @MainActor in value.stop { error in done(error.map { .failure($0) } ?? .success(())) } }
            } } catch { failure = error }
        }
        do { try await guestAwait(timeout: 5) { done in self.queue.async {
            self.timer?.cancel(); self.timer = nil; self.blank = nil
            self.locked { self.latest = nil; self.latestCamera = nil; self.latestScene = nil; self.queued = false }
            done(.success(()))
        } } } catch { if failure == nil { failure = error } }
        if let failure { throw failure }
    }
    func snapshot() -> GuestCameraSnapshot {
        locked { .init(frames: count, advancingPTS: count, dropped: 0, width: Int(dimensions.width), height: Int(dimensions.height),
            pixelFormat: kCVPixelFormatType_32BGRA, systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false) }
    }
    func performReaction() async -> Bool { false }
}

/// Pixel conversion and rotation never block a WebRTC decoder callback. One
/// newest RTC frame is retained, and retired taps cannot deliver to a new share.
final class NativeDesktopCameraTap: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let converter = NativeVideoPixelBuffer()
    private let queue = DispatchQueue(label: "RockNRoll.desktop.presenter-camera", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var pending = false
    private var latest: LKRTCVideoFrame?
    private var handler: (@Sendable (CVPixelBuffer?) -> Void)?
    private lazy var context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    var onFrame: (@Sendable (CVPixelBuffer?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return handler }
        set { lock.lock(); handler = newValue; lock.unlock() }
    }
    func setSize(_ size: CGSize) {}
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        lock.lock()
        guard active else { lock.unlock(); return }
        latest = frame; let enqueue = !pending; pending = true; lock.unlock()
        if enqueue { queue.async { [weak self] in self?.drain() } }
    }
    private func drain() {
        lock.lock(); let frame = active ? latest : nil; latest = nil; pending = false; lock.unlock()
        let pixels = frame.flatMap { normalized($0) }
        lock.lock(); defer { lock.unlock() }
        guard active else { return }; handler?(pixels)
    }
    private func normalized(_ frame: LKRTCVideoFrame) -> CVPixelBuffer? {
        guard let pixels = converter.convert(frame) else { return nil }
        guard frame.rotation.rawValue != 0 else { return pixels }
        var image = CIImage(cvPixelBuffer: pixels)
        switch frame.rotation.rawValue {
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: return pixels
        }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let size = image.extent.size
        if pool == nil || poolSize != size {
            poolSize = size
            let fields: [CFString: Any] = [kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, fields as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        var output: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &output) == kCVReturnSuccess, let output else { return nil }
        context.render(image, to: output); return output
    }
    func stop() { lock.lock(); active = false; latest = nil; handler = nil; lock.unlock() }
}
