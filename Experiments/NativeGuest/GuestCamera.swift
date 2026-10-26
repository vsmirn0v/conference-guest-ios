import AVFoundation
import CoreVideo
import Foundation
import LiveKitWebRTC

enum GuestCameraError: Error {
    case permissionDenied, unavailable, unsupportedFormat, unsupportedConnection
    case alreadyStarted, configurationFailed, timedOut
}

struct GuestCameraInfo: Sendable {
    let deviceName: String
    // Device state read AFTER startRunning; delivered sample dimensions live in snapshot().
    let width: Int32
    let height: Int32
    let fps: Double
    let requestedWidth: Int32
    let requestedHeight: Int32
    let requestedFPS: Double
    let sessionPreset: String
    let minimumFrameDuration: CMTime
    let maximumFrameDuration: CMTime
    let pixelFormat: OSType
    let mirrored: Bool
    let rotationDegrees: Int
}

struct GuestCameraSnapshot: Sendable {
    let frames: Int
    let advancingPTS: Int
    let dropped: Int
    let width: Int
    let height: Int
    let pixelFormat: OSType?
    let systemBackgroundSelected: Bool?
    let systemBackgroundActive: Bool?
    let observedReaction: Bool
}

/// AVFoundation's duration bounds are rational numbers. Converting an exact
/// 1/30 boundary through Double produced 33333333/1e9 (slightly above 30 fps),
/// which raises an Objective-C exception in the device setter.
struct GuestCameraDurationRange {
    let shortest: CMTime
    let longest: CMTime
}

enum GuestCameraTiming {
    static func positive(_ value: CMTime) -> Bool {
        value.isValid && value.isNumeric && value.epoch == 0 && value.timescale > 0 && value.value > 0
    }
    static func valid(_ range: GuestCameraDurationRange) -> Bool {
        positive(range.shortest) && positive(range.longest) && CMTimeCompare(range.shortest, range.longest) <= 0
    }
    static func duration(in ranges: [GuestCameraDurationRange], maximumFPS: Int32 = 30) -> CMTime? {
        guard maximumFPS > 0 else { return nil }
        let target = CMTime(value: 1, timescale: maximumFPS)
        return ranges.compactMap { range -> CMTime? in
            guard valid(range) else { return nil }
            let selected = CMTimeCompare(target, range.shortest) < 0 ? range.shortest : target
            return CMTimeCompare(selected, range.longest) <= 0 ? selected : nil
        }.min { CMTimeCompare($0, $1) < 0 }
    }
    static func validProfile(minimum: CMTime, maximum: CMTime, ranges: [GuestCameraDurationRange]) -> Bool {
        guard positive(minimum), positive(maximum), CMTimeCompare(minimum, maximum) <= 0 else { return false }
        return ranges.contains { range in
            valid(range) && CMTimeCompare(minimum, range.shortest) >= 0 && CMTimeCompare(maximum, range.longest) <= 0
        }
    }
}

protocol GuestCameraCapture: AnyObject {
    func start() async throws -> GuestCameraInfo
    func cancel()
    func stop() async throws
    func snapshot() -> GuestCameraSnapshot
    func performReaction() async -> Bool
    func captureDevice() async -> AVCaptureDevice?
}
extension GuestCameraCapture { func captureDevice() async -> AVCaptureDevice? { nil } }

enum GuestCameraStopBudget {
    static func timeout(hasForwardedFrame: Bool) -> TimeInterval { hasForwardedFrame ? 3 : 15 }
}

/// Opt-in native Mac camera input, isolated from the shipping meeting engine.
/// Capture/session/device operations never run on the main queue. Call stop()
/// before releasing the peer source. No microphone or custom effects are used.
final class GuestCamera: GuestCameraCapture, @unchecked Sendable {
    private let queue = DispatchQueue(label: "native-guest.camera.session")
    private let frames = DispatchQueue(label: "native-guest.camera.frames")
    private let deadline = DispatchQueue(label: "native-guest.camera.deadline")
    private let stateLock = NSLock()
    private var requested = false
    private var hasStarted = false
    private var cancelled = false
    private let firstFrame: Completion<Void>
    private let sink: Sink
    private let preferredDeviceID: String?
    // Remaining mutable state belongs exclusively to queue.
    private var session: AVCaptureSession?
    private var output: AVCaptureVideoDataOutput?
    private var device: AVCaptureDevice?
    private var original: (AVCaptureDevice.Format, CMTime, CMTime)?
    private var cleanupFailure: Error?
    private var effectTimer: DispatchSourceTimer?
    private var reactionObservation: NSKeyValueObservation?
    private var reactionRequested = false
    private var initialReactionIDs = Set<ReactionID>()
    private struct ReactionID: Hashable, Sendable {
        let type: String
        let value: Int64
        let timescale: Int32
        let epoch: Int64
    }
    private struct ReactionInterval: Sendable {
        let id: ReactionID
        let active: Bool
    }

    init(source: LKRTCVideoSource, deviceID: String? = nil) {
        let firstFrame = Completion<Void>()
        self.firstFrame = firstFrame
        sink = Sink(source: source, firstFrame: firstFrame); preferredDeviceID = deviceID
    }

    func snapshot() -> GuestCameraSnapshot { sink.snapshot() }

    /// Reads the configured owner on its session queue. Discovery/default-device
    /// guesses cannot identify the camera actually delivering these frames.
    func captureDevice() async -> AVCaptureDevice? {
        try? await queued(timeout: 2, stopsCaptureOnInterruption: false) {
            guard self.isRequested(), self.session?.isRunning == true, self.cleanupFailure == nil else { return nil }
            return self.device
        }
    }
    #if DEBUG
    func selectedDeviceIDForTesting() async -> String? {
        try? await queued(timeout: 2, stopsCaptureOnInterruption: false) {
            guard self.isRequested(), self.session?.isRunning == true, self.cleanupFailure == nil else { return nil }
            return self.device?.uniqueID
        }
    }
    /// Exercises queue ownership without constructing a session or opening a device.
    func prepareMetadataQueueFixtureForTesting(blockedBy barrier: DispatchSemaphore) throws {
        try beginRequest(); sink.activate()
        queue.async { barrier.wait() }
    }
    var captureRequestedForTesting: Bool { isRequested() && !isCancelled() }
    func drainCaptureQueueForTesting() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }
    func prepareFrameReadinessForTesting() throws { try beginRequest(); sink.activate() }
    func waitForFirstFrameForTesting(timeout: TimeInterval = 15) async throws { try await waitForFirstFrame(timeout: timeout) }
    func forwardFrameForTesting(_ deliver: () -> Void) { sink.forward(deliver) }
    var stopTimeoutForTesting: TimeInterval { GuestCameraStopBudget.timeout(hasForwardedFrame: sink.hasForwardedFrame) }
    #endif

    func start() async throws -> GuestCameraInfo {
        try Task.checkCancellation()
        guard !isCancelled() else { throw CancellationError() }
        if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
            let completion = Completion<Bool>()
            let allowed = try await withTaskCancellationHandler(operation: {
                try await withCheckedThrowingContinuation { continuation in
                    completion.install(continuation)
                    deadline.asyncAfter(deadline: .now() + 30) {
                        completion.finish(.failure(GuestCameraError.timedOut))
                    }
                    AVCaptureDevice.requestAccess(for: .video) { completion.finish(.success($0)) }
                }
            }, onCancel: { completion.finish(.failure(CancellationError())) })
            guard allowed else { throw GuestCameraError.permissionDenied }
        }
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw GuestCameraError.permissionDenied
        }
        try Task.checkCancellation()
        try beginRequest()
        do {
            let info = try await queued(timeout: 8) {
                guard self.isRequested() else { throw CancellationError() }
                let profile = try self.configure()
                guard self.isRequested() else { try self.cleanup(); throw CancellationError() }
                self.sink.activate()
                self.session?.startRunning()
                guard self.isRequested(), self.session?.isRunning == true else {
                    try self.cleanup(); throw GuestCameraError.configurationFailed
                }
                self.observeSystemEffect()
                return try self.runningInfo(pixelFormat: profile.pixelFormat, requestedDuration: profile.duration)
            }
            // isRunning can precede macOS camera-effect warmup by seconds.
            // Keep that bounded wait separate from the SFU acknowledgement
            // budget; neither capture queue is blocked while frames initialize.
            try await waitForFirstFrame(timeout: 15)
            return info
        } catch {
            requestStop()
            queue.async { [self] in try? cleanup() }
            throw error
        }
    }

    private func waitForFirstFrame(timeout: TimeInterval) async throws {
        let deadlineWork = DispatchWorkItem { [firstFrame] in firstFrame.finish(.failure(GuestCameraError.timedOut)) }
        defer { deadlineWork.cancel() }
        do {
            try await withTaskCancellationHandler(operation: {
                try Task.checkCancellation()
                try await withCheckedThrowingContinuation { continuation in
                    firstFrame.install(continuation)
                    deadline.asyncAfter(deadline: .now() + timeout, execute: deadlineWork)
                }
                try Task.checkCancellation()
                guard isRequested(), !isCancelled() else { throw CancellationError() }
            }, onCancel: { [weak self] in self?.requestStop() })
        } catch { requestStop(); throw error }
    }

    /// Synchronous frame barrier, including cancellation during a permission prompt.
    /// Hardware cleanup is queued immediately even if signaling is suspended.
    func cancel() {
        requestStop()
        queue.async { [self] in try? cleanup() }
    }

    /// Prevents new frame delivery and drains an already accepted frame during
    /// cleanup. Session stop and original device-format restoration have a
    /// three-second completion deadline after the first forwarded frame. Cold
    /// camera-effect initialization may hold stopRunning; allow fifteen seconds
    /// while no frame delivery has completed. If AVFoundation or WebRTC
    /// stalls, timedOut is reported and queued cleanup continues; a timeout does
    /// not claim that the physical device has already been released.
    func stop() async throws {
        requestStop()
        let timeout = GuestCameraStopBudget.timeout(hasForwardedFrame: sink.hasForwardedFrame)
        try await queued(timeout: timeout, cancellable: false) { try self.cleanup() }
    }

    /// Explicit opt-in; true means the native request was issued. Rendering is
    /// confirmed separately by snapshot().observedReaction and received frames.
    func performReaction() async -> Bool {
        do {
            return try await queued(timeout: 3) {
                guard #available(macOS 14.0, *), self.isRequested(), self.session?.isRunning == true,
                      let camera = self.device, camera.canPerformReactionEffects,
                      camera.availableReactionTypes.contains(.thumbsUp) else { return false }
                self.initialReactionIDs = Set(camera.reactionEffectsInProgress.compactMap(Self.reactionID))
                self.reactionRequested = true
                self.sink.resetReaction()
                camera.performEffect(for: .thumbsUp)
                return true
            }
        } catch { return false }
    }

    private func beginRequest() throws {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !cancelled else { throw CancellationError() }
        guard !hasStarted else { throw GuestCameraError.alreadyStarted }
        requested = true; hasStarted = true
    }
    private func isRequested() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return requested
    }
    private func isCancelled() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }; return cancelled
    }
    private func requestStop() {
        stateLock.lock(); requested = false; cancelled = true; stateLock.unlock()
        sink.retire()
    }

    private func configure() throws -> (pixelFormat: OSType, duration: CMTime) {
        if session != nil { try cleanup() }
        let cameras = AVCaptureDevice.devices(for: .video)
        let discovered: AVCaptureDevice?
        if let preferredDeviceID { discovered = cameras.first { $0.uniqueID == preferredDeviceID } }
        else { discovered = cameras.first { $0.deviceType == .builtInWideAngleCamera } ?? cameras.first }
        guard let discovered else { throw GuestCameraError.unavailable }
        let choices = discovered.formats.compactMap { format -> (AVCaptureDevice.Format, CMTime)? in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard size.width > 0, size.height > 0 else { return nil }
            guard let duration = GuestCameraTiming.duration(in: durationRanges(format)) else { return nil }
            return (format, duration)
        }
        // Prefer a native 720p format; other cameras retain their complete aspect
        // ratio and WebRTC scales them within the same pixel budget.
        func score(_ format: AVCaptureDevice.Format) -> Double {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return abs(log(Double(size.width * size.height) / Double(1280 * 720)))
        }
        guard let (format, duration) = choices.min(by: {
            let a = score($0.0), b = score($1.0)
            return a == b ? CMTimeCompare($0.1, $1.1) < 0 : a < b
        }) else {
            throw GuestCameraError.unsupportedFormat
        }
        let input = try AVCaptureDeviceInput(device: discovered)
        let camera = input.device
        device = camera
        let saved = (camera.activeFormat, camera.activeVideoMinFrameDuration, camera.activeVideoMaxFrameDuration)
        guard GuestCameraTiming.validProfile(minimum: saved.1, maximum: saved.2, ranges: durationRanges(saved.0)) else {
            throw GuestCameraError.unsupportedFormat
        }
        original = saved
        let capture = AVCaptureSession()
        session = capture
        let video = AVCaptureVideoDataOutput()
        output = video
        video.alwaysDiscardsLateVideoFrames = true
        var pixelFormat: OSType = kCVPixelFormatType_32BGRA
        capture.beginConfiguration()
        do {
            defer { capture.commitConfiguration() }
            guard capture.canAddInput(input), capture.canAddOutput(video) else {
                throw GuestCameraError.configurationFailed
            }
            capture.addInput(input); capture.addOutput(video)
            // AVCaptureSession.Preset.inputPriority is explicitly unavailable
            // in native macOS SDKs. Use the supported preset and log the actual
            // post-start device format separately from WebRTC adaptation/sample size.
            if capture.canSetSessionPreset(.hd1280x720) { capture.sessionPreset = .hd1280x720 }
            else if capture.canSetSessionPreset(.high) { capture.sessionPreset = .high }
            guard let selected = [kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
                                  kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                  kCVPixelFormatType_32BGRA].first(where: { video.availableVideoPixelFormatTypes.contains($0) })
            else { throw GuestCameraError.unsupportedFormat }
            pixelFormat = selected
            video.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: selected]
            guard let connection = video.connection(with: .video) else {
                throw GuestCameraError.unsupportedConnection
            }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported { connection.isVideoMirrored = false }
            if #available(macOS 14.0, *) {
                guard connection.isVideoRotationAngleSupported(0) else { throw GuestCameraError.unsupportedConnection }
                connection.videoRotationAngle = 0
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .landscapeRight
            } else { throw GuestCameraError.unsupportedConnection }
            video.setSampleBufferDelegate(sink, queue: frames)
        }
        // Apply after committing the supported native macOS 720p preset, so a
        // session default cannot replace the chosen device format and cadence.
        try camera.lockForConfiguration()
        do {
            defer { camera.unlockForConfiguration() }
            try applyProfile(format: format, minimum: duration, maximum: duration, to: camera)
        }
        let rate = 1 / CMTimeGetSeconds(duration) // Reporting/adaptation only; never used for device setters.
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let scale = min(1, min(1280 / Double(dimensions.width), 720 / Double(dimensions.height)))
        sink.source.adaptOutputFormat(toWidth: Int32(Double(dimensions.width) * scale),
            height: Int32(Double(dimensions.height) * scale), fps: Int32(rate.rounded(.down)))
        return (pixelFormat, duration)
    }

    private func runningInfo(pixelFormat: OSType, requestedDuration: CMTime) throws -> GuestCameraInfo {
        guard let camera = device, let session else { throw GuestCameraError.unavailable }
        let size = CMVideoFormatDescriptionGetDimensions(camera.activeFormat.formatDescription)
        let minimum = camera.activeVideoMinFrameDuration, maximum = camera.activeVideoMaxFrameDuration
        let fps = GuestCameraTiming.positive(minimum) ? 1 / CMTimeGetSeconds(minimum) : 0
        return GuestCameraInfo(deviceName: camera.localizedName, width: size.width, height: size.height, fps: fps,
            requestedWidth: 1280, requestedHeight: 720, requestedFPS: 1 / CMTimeGetSeconds(requestedDuration),
            sessionPreset: session.sessionPreset.rawValue, minimumFrameDuration: minimum, maximumFrameDuration: maximum,
            pixelFormat: pixelFormat, mirrored: false, rotationDegrees: 0)
    }

    private func cleanup() throws {
        sink.retire()
        reactionObservation?.invalidate(); reactionObservation = nil; reactionRequested = false
        effectTimer?.cancel(); effectTimer = nil
        output?.setSampleBufferDelegate(nil, queue: nil)
        if session?.isRunning == true { session?.stopRunning() }
        frames.sync {} // Drain a callback already in progress before releasing capture objects.
        var restoreError: Error?
        if let device, let original {
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                try applyProfile(format: original.0, minimum: original.1, maximum: original.2, to: device)
            } catch { restoreError = error }
        }
        if let session {
            session.beginConfiguration()
            for input in session.inputs { session.removeInput(input) }
            for output in session.outputs { session.removeOutput(output) }
            session.commitConfiguration()
        }
        session = nil; output = nil; device = nil; original = nil
        if let restoreError { cleanupFailure = restoreError }
        if let cleanupFailure { throw cleanupFailure }
    }

    private func durationRanges(_ format: AVCaptureDevice.Format) -> [GuestCameraDurationRange] {
        format.videoSupportedFrameRateRanges.map { .init(shortest: $0.minFrameDuration, longest: $0.maxFrameDuration) }
    }

    /// Caller holds the configuration lock. Validate the saved/chosen profile
    /// before changing hardware, and preserve exact original rational durations.
    private func applyProfile(format: AVCaptureDevice.Format, minimum: CMTime, maximum: CMTime,
                              to camera: AVCaptureDevice) throws {
        guard GuestCameraTiming.validProfile(minimum: minimum, maximum: maximum, ranges: durationRanges(format)) else {
            throw GuestCameraError.unsupportedFormat
        }
        camera.activeFormat = format
        // Avoid a transient minimum > maximum while restoring a slower profile.
        if !GuestCameraTiming.positive(camera.activeVideoMaxFrameDuration) ||
            CMTimeCompare(minimum, camera.activeVideoMaxFrameDuration) > 0 {
            camera.activeVideoMaxFrameDuration = maximum
            camera.activeVideoMinFrameDuration = minimum
        } else {
            camera.activeVideoMinFrameDuration = minimum
            camera.activeVideoMaxFrameDuration = maximum
        }
    }

    private func observeSystemEffect() {
        if #available(macOS 14.0, *), let camera = device {
            initialReactionIDs = Set(camera.reactionEffectsInProgress.compactMap(Self.reactionID))
            reactionObservation = camera.observe(\.reactionEffectsInProgress, options: [.new]) { [weak self] _, change in
                // Snapshot interval values at notification time, since an SDK
                // state object's endTime can change before a queued read runs.
                let intervals = (change.newValue ?? []).compactMap { state -> ReactionInterval? in
                    guard let id = Self.reactionID(state) else { return nil }
                    return ReactionInterval(id: id, active: !state.endTime.isValid)
                }
                self?.queue.async { [weak self] in self?.observeReactions(intervals) }
            }
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            guard let self, let camera = self.device else { return }
            if #available(macOS 15.0, *) {
                self.sink.setBackground(selected: AVCaptureDevice.isBackgroundReplacementEnabled,
                                        active: camera.isBackgroundReplacementActive)
            }
        }
        effectTimer = timer
        timer.resume()
    }

    @available(macOS 14.0, *)
    private static func reactionID(_ state: AVCaptureReactionEffectState) -> ReactionID? {
        guard state.startTime.isValid, state.startTime.isNumeric else { return nil }
        return ReactionID(type: state.reactionType.rawValue, value: state.startTime.value,
                          timescale: state.startTime.timescale, epoch: state.startTime.epoch)
    }

    @available(macOS 14.0, *)
    private func observeReactions(_ intervals: [ReactionInterval]) {
        guard isRequested(), reactionRequested else { return }
        if intervals.contains(where: { $0.id.type == AVCaptureReactionType.thumbsUp.rawValue && $0.active &&
            !initialReactionIDs.contains($0.id) }) { sink.markReactionObserved() }
    }

    private func queued<Value>(timeout: TimeInterval, cancellable: Bool = true,
                               stopsCaptureOnInterruption: Bool = true,
                               _ work: @escaping () throws -> Value) async throws -> Value {
        let completion = Completion<Value>()
        func enqueue(_ continuation: CheckedContinuation<Value, Error>) {
            completion.install(continuation)
            deadline.asyncAfter(deadline: .now() + timeout) { [weak self] in
                if completion.finish(.failure(GuestCameraError.timedOut)), stopsCaptureOnInterruption {
                    self?.requestStop()
                }
            }
            queue.async { completion.finish(Result { try work() }) }
        }
        if !cancellable { return try await withCheckedThrowingContinuation(enqueue) }
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation(enqueue)
        }, onCancel: { [weak self] in
            completion.finish(.failure(CancellationError()))
            // Observation cancellation owns only its continuation. A slow or
            // superseded device lookup cannot revoke the live capture owner.
            if stopsCaptureOnInterruption { self?.requestStop() }
        })
    }

    private final class Completion<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Value, Error>?
        private var result: Result<Value, Error>?
        func install(_ continuation: CheckedContinuation<Value, Error>) {
            lock.lock()
            if let result { lock.unlock(); continuation.resume(with: result) }
            else { self.continuation = continuation; lock.unlock() }
        }
        @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
            lock.lock()
            guard self.result == nil else { lock.unlock(); return false }
            self.result = result
            let continuation = continuation; self.continuation = nil
            lock.unlock(); continuation?.resume(with: result); return true
        }
    }

    private final class Sink: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        let source: LKRTCVideoSource
        private let capturer: LKRTCVideoCapturer
        private let lock = NSLock()
        private var active = false
        private var count = 0, advancing = 0, dropped = 0, width = 0, height = 0
        private var lastPTS: Int64 = -1
        private var pixelFormat: OSType?
        private var backgroundSelected: Bool?, backgroundActive: Bool?
        private var observedReaction = false
        private var forwardedFrame = false
        private let firstFrame: Completion<Void>
        init(source: LKRTCVideoSource, firstFrame: Completion<Void>) {
            self.source = source; self.firstFrame = firstFrame; capturer = LKRTCVideoCapturer(delegate: source)
        }
        func activate() { lock.lock(); active = true; lock.unlock() }
        var hasForwardedFrame: Bool { lock.lock(); defer { lock.unlock() }; return forwardedFrame }
        func retire() {
            lock.lock(); active = false; lock.unlock()
            firstFrame.finish(.failure(CancellationError()))
        }
        func forward(_ deliver: () -> Void) {
            deliver()
            lock.lock(); defer { lock.unlock() }
            forwardedFrame = true
            if active { firstFrame.finish(.success(())) }
        }
        func resetReaction() { lock.lock(); observedReaction = false; lock.unlock() }
        func markReactionObserved() { lock.lock(); observedReaction = true; lock.unlock() }
        func setBackground(selected: Bool, active: Bool) {
            lock.lock(); backgroundSelected = selected; backgroundActive = active; lock.unlock()
        }
        func snapshot() -> GuestCameraSnapshot {
            lock.lock(); defer { lock.unlock() }
            return GuestCameraSnapshot(frames: count, advancingPTS: advancing, dropped: dropped, width: width, height: height,
                pixelFormat: pixelFormat, systemBackgroundSelected: backgroundSelected,
                systemBackgroundActive: backgroundActive, observedReaction: observedReaction)
        }
        func captureOutput(_ output: AVCaptureOutput, didDrop sample: CMSampleBuffer, from connection: AVCaptureConnection) {
            lock.lock(); dropped += 1; lock.unlock()
        }
        func captureOutput(_ output: AVCaptureOutput, didOutput sample: CMSampleBuffer, from connection: AVCaptureConnection) {
            guard sample.isValid, let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1e9 else { return }
            let timestamp = Int64(seconds * 1e9)
            lock.lock()
            guard active, timestamp > lastPTS else { lock.unlock(); return }
            count += 1; advancing += 1; lastPTS = timestamp
            width = CVPixelBufferGetWidth(pixels); height = CVPixelBufferGetHeight(pixels)
            pixelFormat = CVPixelBufferGetPixelFormatType(pixels)
            lock.unlock()
            // A native WebRTC call must never hold the state lock used by stop,
            // snapshots, and deadline handlers. Cleanup drains this frame queue.
            let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: timestamp)
            forward { source.capturer(capturer, didCapture: frame) }
        }
    }
}
