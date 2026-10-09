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
    private static var sessions: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private static var sources: [ObjectIdentifier: Source] = [:]
    struct Source { let device: AVCaptureDevice; let generation: UUID; let requestedFPS: Int }
    private static var fpsLimit = 30
    private static var energySubscription: AnyCancellable?
    private static let configurationQueue = DispatchQueue(label: "dev.vsmirn0v.capture-energy")
    @MainActor static func prepare() {
        _ = installed
        guard energySubscription == nil else { return }
        energySubscription = MediaEnergyBudget.shared.$pressure.removeDuplicates().sink { pressure in
            let limit = pressure == .normal ? 30 : pressure == .constrained ? 15 : 10
            lock.lock(); fpsLimit = limit; let current = sources; lock.unlock()
            configurationQueue.async {
                for (key, source) in current {
                    lock.lock()
                    let active = sources[key]?.generation == source.generation && capturers.allObjects.contains {
                        ObjectIdentifier($0) == key && $0.captureSession.isRunning
                    }
                    lock.unlock()
                    guard active else { continue }
                    let device = source.device
                    let rate = supportedFPS(min(source.requestedFPS, limit), format: device.activeFormat)
                    do {
                        try device.lockForConfiguration(); defer { device.unlockForConfiguration() }
                        device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(rate))
                        device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(rate))
                    } catch { /* Retain the SDK's working capture settings. */ }
                }
            }
        }
    }
    private static func supportedFPS(_ requested: Int, format: AVCaptureDevice.Format) -> Int {
        let ranges = format.videoSupportedFrameRateRanges
        let minimum = Int(ceil(ranges.map(\.minFrameRate).min() ?? 1))
        let maximum = Int(floor(ranges.map(\.maxFrameRate).max() ?? Double(requested)))
        return max(1, min(maximum, max(minimum, requested)))
    }

    private static func register(_ capturer: RTCCameraVideoCapturer, device: AVCaptureDevice, requestedFPS: Int) {
        lock.lock()
        capturers.add(capturer)
        let key = ObjectIdentifier(capturer)
        sources[key] = Source(device: device, generation: UUID(), requestedFPS: requestedFPS)
        if sessions[key] == nil {
            sessions[key] = capturer.captureSession.observe(\.isRunning, options: [.new]) { _, _ in notify() }
        }
        // Bound observation lifetime without retaining capturers or old sessions.
        let alive = Set(capturers.allObjects.map(ObjectIdentifier.init))
        sessions = sessions.filter { alive.contains($0.key) }
        sources = sources.filter { alive.contains($0.key) }
        lock.unlock()
        notify()
    }
    private static func notify() {
        DispatchQueue.main.async { NotificationCenter.default.post(name: changed, object: nil) }
    }
    private static func unregister(_ capturer: RTCCameraVideoCapturer) {
        lock.lock(); capturers.remove(capturer)
        sessions.removeValue(forKey: ObjectIdentifier(capturer)); sources.removeValue(forKey: ObjectIdentifier(capturer))
        lock.unlock()
        notify()
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
            register(capturer, device: device, requestedFPS: fps)
            lock.lock(); let limit = fpsLimit; lock.unlock()
            let observed: Completion = { error in notify(); completion?(error) }
            original(capturer, selector, device, format, supportedFPS(min(fps, limit), format: format), observed)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        let stopSelector = #selector(RTCCameraVideoCapturer.stopCapture(completionHandler:))
        if let stopMethod = class_getInstanceMethod(RTCCameraVideoCapturer.self, stopSelector) {
            typealias StopCompletion = @convention(block) () -> Void
            typealias Stop = @convention(c) (RTCCameraVideoCapturer, Selector, StopCompletion?) -> Void
            let stopOriginal = unsafeBitCast(method_getImplementation(stopMethod), to: Stop.self)
            let stopForward: @convention(block) (RTCCameraVideoCapturer, StopCompletion?) -> Void = { capturer, completion in
                unregister(capturer)
                stopOriginal(capturer, stopSelector, completion)
            }
            method_setImplementation(stopMethod, imp_implementationWithBlock(stopForward))
        }
        // The three-argument public overload calls the completion overload in this SDK.
        return true
    }()
}
