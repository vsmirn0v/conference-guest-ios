import AVFoundation
import ConferenceCore
import CoreMedia
import CoreVideo
import Foundation
import LiveKitWebRTC
import MeetingEngine

/// iOS camera capture backend conforming to `GuestCameraCapture` for all
/// `MeetingEngine` providers that consume `GuestCamera.defaultFactory`.
final class IOSCameraCapture: NSObject, GuestCameraCapture, LKRTCVideoCapturerDelegate, @unchecked Sendable {
    #if DEBUG
    /// Enables deterministic frame injection without opening `AVCaptureDevice` on Simulator.
    nonisolated(unsafe) static var syntheticModeForTesting = false
    @MainActor private(set) static weak var activeForTesting: IOSCameraCapture?
    #endif

    @MainActor private(set) static var current: IOSCameraCapture? {
        didSet {
            for observer in currentObservers.values {
                observer(current)
            }
        }
    }
    @MainActor private static var currentObservers: [UUID: (IOSCameraCapture?) -> Void] = [:]
    @MainActor private static var reactionObservers: [UUID: (MeetingReaction, String) -> Void] = [:]

    @MainActor
    static func addObserver(id: UUID,
                            onCurrentChanged: @escaping (IOSCameraCapture?) -> Void,
                            onObservedReaction: @escaping (MeetingReaction, String) -> Void) {
        currentObservers[id] = onCurrentChanged
        reactionObservers[id] = onObservedReaction
        onCurrentChanged(current)
    }

    @MainActor
    static func removeObserver(id: UUID) {
        currentObservers.removeValue(forKey: id)
        reactionObservers.removeValue(forKey: id)
    }

    @MainActor
    var cameraReactionStatus: MeetingReactionsModel.CameraStatus {
        guard let currentDevice = locked({ device }) else { return .off }
        if #available(iOS 17.0, *) {
            guard currentDevice.canPerformReactionEffects, !currentDevice.availableReactionTypes.isEmpty else {
                return .unavailable
            }
            return AVCaptureDevice.reactionEffectsEnabled ? .ready : .systemDisabled
        }
        return .unavailable
    }

    @MainActor
    static func installAsDefaultFactory() {
        UniversalMeetingEngine.defaultCameraCaptureFactory = { source in
            IOSCameraCapture(source: source)
        }
    }

    let previewFrames = CameraPreviewFrames()

    @MainActor var onReaction: ((MeetingReaction, String) -> Void)? {
        didSet { bindReactionCallback() }
    }

    private let source: LKRTCVideoSource
    private let syntheticCapturer: LKRTCVideoCapturer
    private let stateLock = NSLock()
    private let leaseOwnerID = UUID()
    private let useLease: Bool
    private let synthetic: Bool

    private var preferredDeviceID: String?
    private var position: AVCaptureDevice.Position
    private var active = false
    private var started = false
    private var stopped = false
    private var capturer: LKRTCCameraVideoCapturer?
    private var device: AVCaptureDevice?
    private var leaseToken: NativeDesktopCameraLease.Token?
    @MainActor private var reactionObserver: CameraReactionObserver?

    private var frameCount = 0
    private var advancingPTSCount = 0
    private var droppedCount = 0
    private var lastPTS: Int64 = -1
    private var currentWidth = 0
    private var currentHeight = 0
    private var adaptedWidth: Int32 = 0
    private var adaptedHeight: Int32 = 0
    private var currentFPS: Int32 = 30
    private var currentPixelFormat: OSType?
    private var observedReaction = false
    private var multitaskingActive = false

    init(source: LKRTCVideoSource,
         position: AVCaptureDevice.Position = .front,
         preferredDeviceID: String? = nil,
         synthetic: Bool? = nil,
         useLease: Bool = true) {
        self.source = source
        self.syntheticCapturer = LKRTCVideoCapturer(delegate: source)
        self.position = position
        self.preferredDeviceID = preferredDeviceID
        #if DEBUG
        self.synthetic = synthetic ?? Self.syntheticModeForTesting
        #else
        self.synthetic = synthetic ?? false
        #endif
        self.useLease = useLease
        super.init()
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }

    func start() async throws -> GuestCameraInfo {
        try locked {
            guard !started, !stopped else { throw GuestCameraError.alreadyStarted }
            started = true
            active = true
        }

        do {
            if useLease {
                let token = try await Self.acquireLiveLease(owner: leaseOwnerID) { [weak self] in
                    try? await self?.stop()
                }
                let stillActive = locked { () -> Bool in
                    guard active, !stopped else { return false }
                    leaseToken = token
                    return true
                }
                if !stillActive {
                    await releaseLeaseToken(token)
                    throw CancellationError()
                }
            }

            if synthetic {
                let pos = locked { position }
                let info = GuestCameraInfo(
                    deviceName: pos == .front ? "Synthetic Front Camera" : "Synthetic Back Camera",
                    width: 1280,
                    height: 720,
                    fps: 30,
                    requestedWidth: 1280,
                    requestedHeight: 720,
                    requestedFPS: 30,
                    sessionPreset: "synthetic-720p30",
                    minimumFrameDuration: CMTime(value: 1, timescale: 30),
                    maximumFrameDuration: CMTime(value: 1, timescale: 30),
                    pixelFormat: kCVPixelFormatType_32BGRA,
                    mirrored: pos == .front,
                    rotationDegrees: 0
                )
                locked {
                    currentWidth = 1280
                    currentHeight = 720
                    currentPixelFormat = kCVPixelFormatType_32BGRA
                }
                await MainActor.run {
                    Self.current = self
                    #if DEBUG
                    Self.activeForTesting = self
                    #endif
                }
                return info
            }

            guard try await GuestCaptureAuthorization.request(.video) else {
                throw GuestCameraError.permissionDenied
            }
            try Task.checkCancellation()

            let resolved = await MainActor.run { () -> (AVCaptureDevice?, Int) in
                let savedID = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")
                let wantedID = self.locked { self.preferredDeviceID } ?? savedID
                let pos = self.locked { self.position }
                let devices = CameraDevices.available()
                let matchByID = wantedID.flatMap { id in
                    id.isEmpty ? nil : devices.first { $0.uniqueID == id }
                }
                let matchByPosition = devices.first { $0.position == pos }
                let selected = matchByID ?? matchByPosition ?? devices.first
                let fpsBudget = min(Int(GuestCameraCadence.standardFPS), MediaEnergyBudget.shared.cameraFPS)
                return (selected, max(1, fpsBudget))
            }

            guard let selectedDevice = resolved.0,
                  let format = Self.preferredFormat(for: selectedDevice),
                  let fps = CameraCaptureRate.supported(
                      resolved.1,
                      ranges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
                  ) else {
                throw GuestCameraError.unavailable
            }

            let newCapturer = LKRTCCameraVideoCapturer(delegate: self)
            let multitasking = CameraBackgroundAccess.configure(newCapturer.captureSession)
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let clamped = Self.boundedDimensions(dimensions, maxWidth: 1280, maxHeight: 720)
            source.adaptOutputFormat(toWidth: clamped.width, height: clamped.height, fps: Int32(fps))

            locked {
                capturer = newCapturer
                device = selectedDevice
                position = selectedDevice.position
                currentFPS = Int32(fps)
                adaptedWidth = clamped.width
                adaptedHeight = clamped.height
                multitaskingActive = multitasking
            }

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                newCapturer.startCapture(with: selectedDevice, format: format, fps: fps) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }

            let stillRunning = locked { active && !stopped && capturer === newCapturer }
            guard stillRunning, !Task.isCancelled else {
                await stopCapturer(newCapturer)
                throw CancellationError()
            }

            await MainActor.run {
                let observer = CameraReactionObserver()
                observer.bind(selectedDevice, sourceID: selectedDevice.uniqueID)
                self.reactionObserver = observer
                self.bindReactionCallback()
                Self.current = self
            }

            let actualDimensions = CMVideoFormatDescriptionGetDimensions(selectedDevice.activeFormat.formatDescription)
            let duration = CMTime(value: 1, timescale: Int32(fps))
            return GuestCameraInfo(
                deviceName: selectedDevice.localizedName,
                width: actualDimensions.width,
                height: actualDimensions.height,
                fps: Double(fps),
                requestedWidth: 1280,
                requestedHeight: 720,
                requestedFPS: Double(fps),
                sessionPreset: "720p\(fps)",
                minimumFrameDuration: duration,
                maximumFrameDuration: duration,
                pixelFormat: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                mirrored: selectedDevice.position == .front,
                rotationDegrees: 0
            )
        } catch {
            cancel()
            throw error
        }
    }

    func flipCamera() async throws {
        let nextPosition: AVCaptureDevice.Position = locked {
            let next: AVCaptureDevice.Position = position == .front ? .back : .front
            position = next
            preferredDeviceID = nil
            return next
        }
        try await selectDevice(uniqueID: nil, position: nextPosition)
    }

    func selectDevice(uniqueID: String?, position explicitPosition: AVCaptureDevice.Position? = nil) async throws {
        let state = locked { () -> (isActive: Bool, isSynthetic: Bool, oldCapturer: LKRTCCameraVideoCapturer?, fps: Int32) in
            if let explicitPosition { position = explicitPosition }
            preferredDeviceID = uniqueID
            return (active && !stopped, synthetic, capturer, currentFPS)
        }
        guard state.isActive, !state.isSynthetic else { return }

        let targetPosition = locked { position }
        let selectedDevice = await MainActor.run { () -> AVCaptureDevice? in
            let devices = CameraDevices.available()
            if let uniqueID, !uniqueID.isEmpty, let matched = devices.first(where: { $0.uniqueID == uniqueID }) {
                return matched
            }
            return devices.first { $0.position == targetPosition } ?? devices.first
        }
        guard let selectedDevice,
              let format = Self.preferredFormat(for: selectedDevice),
              let fps = CameraCaptureRate.supported(
                  Int(state.fps),
                  ranges: format.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate }
              ) else {
            throw GuestCameraError.unavailable
        }

        if let old = state.oldCapturer {
            await stopCapturer(old)
        }
        guard locked({ active && !stopped }) else { throw CancellationError() }

        let newCapturer = LKRTCCameraVideoCapturer(delegate: self)
        let multitasking = CameraBackgroundAccess.configure(newCapturer.captureSession)
        let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
        let clamped = Self.boundedDimensions(dimensions, maxWidth: 1280, maxHeight: 720)
        source.adaptOutputFormat(toWidth: clamped.width, height: clamped.height, fps: Int32(fps))

        locked {
            capturer = newCapturer
            device = selectedDevice
            position = selectedDevice.position
            adaptedWidth = clamped.width
            adaptedHeight = clamped.height
            currentFPS = Int32(fps)
            multitaskingActive = multitasking
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            newCapturer.startCapture(with: selectedDevice, format: format, fps: fps) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        await MainActor.run {
            self.reactionObserver?.bind(selectedDevice, sourceID: selectedDevice.uniqueID)
        }
    }

    var currentPosition: AVCaptureDevice.Position {
        locked { position }
    }

    func cancel() {
        let state = locked { () -> (oldCapturer: LKRTCCameraVideoCapturer?, token: NativeDesktopCameraLease.Token?) in
            active = false
            stopped = true
            let cap = capturer
            capturer = nil
            device = nil
            let tok = leaseToken
            leaseToken = nil
            return (cap, tok)
        }
        Task { @MainActor in
            self.teardownReactionObserverOnMain()
        }
        if let cap = state.oldCapturer {
            cap.stopCapture {}
        }
        if let token = state.token {
            Task { await self.releaseLeaseToken(token) }
        }
    }

    func stop() async throws {
        let state = locked { () -> (oldCapturer: LKRTCCameraVideoCapturer?, token: NativeDesktopCameraLease.Token?) in
            active = false
            stopped = true
            let cap = capturer
            capturer = nil
            device = nil
            let tok = leaseToken
            leaseToken = nil
            return (cap, tok)
        }
        await MainActor.run {
            self.teardownReactionObserverOnMain()
        }
        if let cap = state.oldCapturer {
            await stopCapturer(cap)
        }
        if let token = state.token {
            await releaseLeaseToken(token)
        }
    }

    func snapshot() -> GuestCameraSnapshot {
        locked {
            GuestCameraSnapshot(
                frames: frameCount,
                advancingPTS: advancingPTSCount,
                dropped: droppedCount,
                width: currentWidth,
                height: currentHeight,
                pixelFormat: currentPixelFormat,
                systemBackgroundSelected: nil,
                systemBackgroundActive: multitaskingActive,
                observedReaction: observedReaction
            )
        }
    }

    func performReaction() async -> Bool {
        guard #available(iOS 17.0, *) else { return false }
        let targetDevice = locked { active && !stopped ? device : nil }
        guard let targetDevice else { return false }
        return await MainActor.run {
            guard targetDevice.canPerformReactionEffects,
                  targetDevice.availableReactionTypes.contains(.thumbsUp) else {
                return false
            }
            targetDevice.performEffect(for: .thumbsUp)
            return true
        }
    }

    func captureDevice() async -> AVCaptureDevice? {
        locked { active && !stopped ? device : nil }
    }

    func capturer(_ capturer: LKRTCVideoCapturer, didCapture frame: LKRTCVideoFrame) {
        forwardFrame(frame, from: capturer)
    }

    #if DEBUG
    func injectFrameForTesting(pixelBuffer: CVPixelBuffer,
                                rotation: LKRTCVideoRotation = ._0,
                                timestampNs: Int64) {
        let frame = LKRTCVideoFrame(
            buffer: LKRTCCVPixelBuffer(pixelBuffer: pixelBuffer),
            rotation: rotation,
            timeStampNs: timestampNs
        )
        forwardFrame(frame, from: syntheticCapturer)
    }
    #endif

    // MARK: - Helpers

    private func forwardFrame(_ frame: LKRTCVideoFrame, from origin: LKRTCVideoCapturer) {
        let rotated = frame.rotation == ._90 || frame.rotation == ._270
        let logicalWidth = Int32(rotated ? frame.height : frame.width)
        let logicalHeight = Int32(rotated ? frame.width : frame.height)
        guard logicalWidth > 0, logicalHeight > 0 else { return }

        var shouldAdapt = false
        var fps: Int32 = 30
        var pixelBufferForPreview: CVPixelBuffer?

        let shouldForward = locked { () -> Bool in
            guard active, !stopped else { return false }
            if adaptedWidth != logicalWidth || adaptedHeight != logicalHeight {
                adaptedWidth = logicalWidth
                adaptedHeight = logicalHeight
                shouldAdapt = true
            }
            fps = currentFPS
            frameCount += 1
            if frame.timeStampNs > lastPTS {
                advancingPTSCount += 1
                lastPTS = frame.timeStampNs
            }
            currentWidth = Int(logicalWidth)
            currentHeight = Int(logicalHeight)
            if let cvBuffer = frame.buffer as? LKRTCCVPixelBuffer {
                pixelBufferForPreview = cvBuffer.pixelBuffer
                currentPixelFormat = CVPixelBufferGetPixelFormatType(cvBuffer.pixelBuffer)
            }
            return true
        }

        guard shouldForward else { return }
        if shouldAdapt {
            source.adaptOutputFormat(toWidth: logicalWidth, height: logicalHeight, fps: fps)
        }
        source.capturer(origin, didCapture: frame)
        if previewFrames.hasSinks, let pixelBufferForPreview {
            previewFrames.render(pixelBufferForPreview, rotation: frame.rotation.rawValue)
        }
    }

    private func markObservedReaction() {
        locked { observedReaction = true }
    }

    @MainActor
    private func teardownReactionObserverOnMain() {
        reactionObserver?.stop()
        reactionObserver = nil
        if Self.current === self { Self.current = nil }
        #if DEBUG
        if Self.activeForTesting === self { Self.activeForTesting = nil }
        #endif
    }

    @MainActor
    private func bindReactionCallback() {
        reactionObserver?.onReaction = { [weak self] reaction, id in
            guard let self else { return }
            self.markObservedReaction()
            self.onReaction?(reaction, id)
            for callback in Self.reactionObservers.values {
                callback(reaction, id)
            }
        }
    }

    @MainActor
    private static func acquireLiveLease(owner: UUID, revoke: @escaping @MainActor () async throws -> Void) async throws -> NativeDesktopCameraLease.Token {
        try await NativeDesktopCameraLease.shared.acquireLive(owner: owner, revoke: revoke)
    }

    private func releaseLeaseToken(_ token: NativeDesktopCameraLease.Token) async {
        await MainActor.run {
            NativeDesktopCameraLease.shared.release(token)
        }
    }

    private func stopCapturer(_ cap: LKRTCCameraVideoCapturer) async {
        await withCheckedContinuation { continuation in
            cap.stopCapture {
                continuation.resume()
            }
        }
    }

    static func preferredFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let formats = LKRTCCameraVideoCapturer.supportedFormats(for: device)
        return formats.filter { format in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return max(dimensions.width, dimensions.height) <= 1280
                && min(dimensions.width, dimensions.height) <= 720
        }.max { lhs, rhs in
            let a = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let b = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return a.width * a.height < b.width * b.height
        } ?? formats.first
    }

    static func boundedDimensions(_ raw: CMVideoDimensions, maxWidth: Int32, maxHeight: Int32) -> (width: Int32, height: Int32) {
        let width = max(2, Int(raw.width))
        let height = max(2, Int(raw.height))
        let landscape = width >= height
        let capW = Double(landscape ? maxWidth : maxHeight)
        let capH = Double(landscape ? maxHeight : maxWidth)
        let scale = min(1.0, min(capW / Double(width), capH / Double(height)))
        let evenW = max(2, (Int(Double(width) * scale) / 2) * 2)
        let evenH = max(2, (Int(Double(height) * scale) / 2) * 2)
        return (Int32(evenW), Int32(evenH))
    }
}
