import AVFoundation
import ObjectiveC
import WebRTC

/// A compatibility boundary for the pinned capture implementation. All original
/// calls and completions are forwarded. No capture/audio configuration is changed.
enum GuestCaptureDeviceObserver {
    static let changed = Notification.Name("dev.vsmirn0v.capture-device-changed")
    private static let lock = NSLock()
    private static let capturers = NSHashTable<RTCCameraVideoCapturer>.weakObjects()
    private static var sessions: [ObjectIdentifier: NSKeyValueObservation] = [:]
    private static var sources: [ObjectIdentifier: Source] = [:]
    struct Source { let device: AVCaptureDevice; let generation: UUID }
    static func prepare() { _ = installed }

    private static func register(_ capturer: RTCCameraVideoCapturer, device: AVCaptureDevice) {
        lock.lock()
        capturers.add(capturer)
        let key = ObjectIdentifier(capturer)
        sources[key] = Source(device: device, generation: UUID())
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
            register(capturer, device: device)
            let observed: Completion = { error in notify(); completion?(error) }
            original(capturer, selector, device, format, fps, observed)
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
