import AVFoundation
import Combine
import ObjectiveC
import WebRTC

/// A compatibility boundary for the pinned capture implementation. All original
/// calls and completions are forwarded. Power pressure caps camera cadence;
/// resolution, microphone configuration and the selected device are preserved.
enum GuestCaptureDeviceObserver {
    static let changed = Notification.Name("dev.vsmirn0v.capture-device-changed")
    private static let lock = NSLock()
    private static let capturers = NSHashTable<RTCCameraVideoCapturer>.weakObjects()
    private static let revisions = NSMapTable<RTCCameraVideoCapturer, NSNumber>(keyOptions: .weakMemory, valueOptions: .strongMemory)
    private static func revision(_ capturer: RTCCameraVideoCapturer) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        return revisions.object(forKey: capturer)?.uint64Value ?? 0
    }
    private static var sessions: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private static var sources: [ObjectIdentifier: Source] = [:]
    private static var frameDelegates: [ObjectIdentifier: GuestCameraFrameDelegate] = [:]
    static func rawCaptureProgress(trackID: String) -> GuestCameraFrameDelegate.Progress? {
        lock.lock(); let proxies = Array(frameDelegates.values); lock.unlock()
        let matches = proxies.compactMap { $0.progress(trackID: trackID) }
        return matches.count == 1 ? matches[0] : nil
    }
    struct Source { let device: AVCaptureDevice; let generation: UUID; let requestedFPS: Int }
    private static var preferredDeviceID: String?
    static func setPreferredDevice(_ device: AVCaptureDevice?) {
        lock.lock(); preferredDeviceID = device?.uniqueID; lock.unlock()
    }
    /// Switch the existing source instead of rebuilding the SDK track/renderers.
    /// Await stop before start; a failed device restores the last working camera.
    private static func activeCapturers() -> [RTCCameraVideoCapturer] {
        lock.lock(); defer { lock.unlock() }
        return capturers.allObjects.filter { $0.captureSession.isRunning }
    }
    @MainActor static func selectCurrentDevice(_ device: AVCaptureDevice) async throws {
        let active = activeCapturers()
        guard active.count == 1, let capturer = active.first,
              let old = currentDevice() else { throw CocoaError(.featureUnsupported) }
        guard old.uniqueID != device.uniqueID else { setPreferredDevice(device); return }
        let previousFormat = old.activeFormat
        let requested = currentSource()?.requestedFPS ?? 30
        guard let format = matchingFormat(device, requested: previousFormat) else { throw CocoaError(.featureUnsupported) }
        let expected = revision(capturer) &+ 1
        await withCheckedContinuation { continuation in capturer.stopCapture { continuation.resume() } }
        try Task.checkCancellation()
        guard revision(capturer) == expected else { throw CancellationError() }
        setPreferredDevice(device)
        do {
            try await start(capturer, device: device, format: format, fps: requested)
        } catch {
            if !Task.isCancelled, revision(capturer) == expected &+ 1 {
                setPreferredDevice(old)
                try? await start(capturer, device: old, format: previousFormat, fps: requested)
            }
            throw error
        }
        guard !Task.isCancelled, revision(capturer) == expected &+ 1 else { throw CancellationError() }
    }
    private static func start(_ camera: RTCCameraVideoCapturer, device: AVCaptureDevice,
                              format: AVCaptureDevice.Format, fps: Int) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            camera.startCapture(with: device, format: format, fps: fps) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
    }
    private static func matchingFormat(_ device: AVCaptureDevice, requested: AVCaptureDevice.Format) -> AVCaptureDevice.Format? {
        let target = CMVideoFormatDescriptionGetDimensions(requested.formatDescription)
        return RTCCameraVideoCapturer.supportedFormats(for: device).min {
            let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
            return abs(a.width - target.width) + abs(a.height - target.height) <
                abs(b.width - target.width) + abs(b.height - target.height)
        }
    }
    private static var fpsLimit = 30
    private static var energySubscription: AnyCancellable?
    private static let configurationQueue = DispatchQueue(label: "dev.vsmirn0v.capture-energy")
    @MainActor static func prepare() {
        GuestCameraTrackBinding.prepare(); _ = installed
        guard energySubscription == nil else { return }
        energySubscription = MediaEnergyBudget.shared.$pressure.removeDuplicates().sink { pressure in
            let limit = pressure == .normal ? 30 : pressure == .constrained ? 15 : 10
            lock.lock(); fpsLimit = limit; lock.unlock()
        }
    }
    private static func supportedFPS(_ requested: Int, format: AVCaptureDevice.Format) -> Int {
        CameraCaptureRate.supported(requested, ranges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }) ?? max(1, requested)
    }
    static func setCadence(_ camera: RTCCameraVideoCapturer, fps: Int) {
        let key = ObjectIdentifier(camera)
        lock.lock(); let source = sources[key]; lock.unlock()
        guard let source else { return }
        configurationQueue.async { [weak camera] in
            guard let camera else { return }
            lock.lock(); let current = sources[key]?.generation == source.generation; lock.unlock()
            guard current, camera.captureSession.isRunning else { return }
            let device = source.device
            let rate = supportedFPS(min(source.requestedFPS, fps), format: device.activeFormat)
            do {
                try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(rate))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(rate))
            } catch { /* Retain the working cadence. Source output remains capped. */ }
        }
    }

    private static func register(_ capturer: RTCCameraVideoCapturer, device: AVCaptureDevice, requestedFPS: Int) {
        let key = ObjectIdentifier(capturer)
        // Instance-scoped native frame forwarding preserves visual orientation.
        let downstream = (capturer.delegate as? GuestCameraFrameDelegate)?.originalDelegate ?? capturer.delegate
        if let downstream {
            lock.lock(); let previous = frameDelegates.removeValue(forKey: key); lock.unlock()
            previous?.deactivate()
            let proxy = GuestCameraFrameDelegate(camera: capturer, device: device,
                                                 downstream: downstream)
            lock.lock(); frameDelegates[key] = proxy; lock.unlock()
            capturer.delegate = proxy
        }
        lock.lock()
        revisions.setObject(NSNumber(value: (revisions.object(forKey: capturer)?.uint64Value ?? 0) &+ 1), forKey: capturer)
        capturers.add(capturer)
        sources[key] = Source(device: device, generation: UUID(), requestedFPS: requestedFPS)
        if sessions[key] == nil {
            sessions[key] = capturer.captureSession.observe(\.isRunning, options: [.new]) { _, _ in notify() }
        }
        // Bound observation lifetime without retaining capturers or old sessions.
        let alive = Set(capturers.allObjects.map(ObjectIdentifier.init))
        sessions = sessions.filter { alive.contains($0.key) }
        sources = sources.filter { alive.contains($0.key) }
        frameDelegates = frameDelegates.filter { alive.contains($0.key) }
        lock.unlock()
        notify()
    }
    private static func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }
    private static func unregister(_ capturer: RTCCameraVideoCapturer) -> GuestCameraFrameDelegate? {
        lock.lock(); capturers.remove(capturer)
        revisions.setObject(NSNumber(value: (revisions.object(forKey: capturer)?.uint64Value ?? 0) &+ 1), forKey: capturer)
        let proxy = frameDelegates.removeValue(forKey: ObjectIdentifier(capturer))
        sessions.removeValue(forKey: ObjectIdentifier(capturer)); sources.removeValue(forKey: ObjectIdentifier(capturer))
        lock.unlock()
        proxy?.deactivate()
        notify()
        return proxy
    }
    static func currentDevice() -> AVCaptureDevice? {
        currentSource()?.device
    }
    static func currentSource() -> Source? {
        lock.lock(); let all = capturers.allObjects; let registered = sources; lock.unlock()
        let active = all.filter { $0.captureSession.isRunning }
        guard active.count == 1 else { return nil }
        let inputs = active[0].captureSession.inputs.compactMap { $0 as? AVCaptureDeviceInput }
            .filter { $0.device.hasMediaType(.video) }
        guard inputs.count == 1, let source = registered[ObjectIdentifier(active[0])],
              inputs[0].device.uniqueID == source.device.uniqueID else { return nil }
        return source
    }
    private static let installed: Bool = {
        let selector = #selector(RTCCameraVideoCapturer.startCapture(with:format:fps:completionHandler:))
        guard let method = class_getInstanceMethod(RTCCameraVideoCapturer.self, selector) else { return false }
        typealias Completion = @convention(block) (NSError?) -> Void
        typealias Start = @convention(c) (RTCCameraVideoCapturer, Selector, AVCaptureDevice, AVCaptureDevice.Format, Int, Completion?) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Start.self)
        let forward: @convention(block) (RTCCameraVideoCapturer, AVCaptureDevice, AVCaptureDevice.Format, Int, Completion?) -> Void = { capturer, device, format, fps, completion in
            lock.lock(); let preferred = preferredDeviceID; let limit = fpsLimit; lock.unlock()
            let selected = preferred.flatMap { id in CameraDevices.available().first { $0.uniqueID == id } } ?? device
            let plan = MacCameraCapturePlan.resolve(device: selected,
                formats: RTCCameraVideoCapturer.supportedFormats(for: selected), fps: fps)
            guard let selectedFormat = plan?.format ?? (selected.uniqueID == device.uniqueID ? format : matchingFormat(selected, requested: format)) else {
                completion?(CocoaError(.featureUnsupported) as NSError); return
            }
            register(capturer, device: selected, requestedFPS: fps)
            let expectedRevision = revision(capturer)
            CameraBackgroundAccess.configure(capturer.captureSession)
            let observed: Completion = { error in
                if error == nil, revision(capturer) == expectedRevision {
                    // Frame forwarding adapts the actual oriented camera dimensions.
                    // Screen-share/Presenter sources never enter this capturer hook.
                    if let proxy = capturer.delegate as? GuestCameraFrameDelegate {
                        setCadence(capturer, fps: proxy.requestedCadence)
                    }
                }
                notify(); completion?(error)
            }
            original(capturer, selector, selected, selectedFormat, supportedFPS(min(fps, limit), format: selectedFormat), observed)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        let stopSelector = #selector(RTCCameraVideoCapturer.stopCapture(completionHandler:))
        if let stopMethod = class_getInstanceMethod(RTCCameraVideoCapturer.self, stopSelector) {
            typealias StopCompletion = @convention(block) () -> Void
            typealias Stop = @convention(c) (RTCCameraVideoCapturer, Selector, StopCompletion?) -> Void
            let stopOriginal = unsafeBitCast(method_getImplementation(stopMethod), to: Stop.self)
            let stopForward: @convention(block) (RTCCameraVideoCapturer, StopCompletion?) -> Void = { capturer, completion in
                let proxy = unregister(capturer)
                let stopped: StopCompletion = { proxy?.restore(); completion?() }
                stopOriginal(capturer, stopSelector, stopped)
            }
            method_setImplementation(stopMethod, imp_implementationWithBlock(stopForward))
        }
        // The three-argument public overload calls the completion overload in this SDK.
        return true
    }()
}
