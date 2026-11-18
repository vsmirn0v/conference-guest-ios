import CoreMedia
import Foundation
import LiveKitWebRTC

/// The guest publisher registers its own screen source. Relay the prepared
/// canvas into that source without creating another camera or screen capture.
public final class NativeDesktopRelayCapture: NSObject, GuestCameraCapture, LKRTCVideoRenderer, @unchecked Sendable {
    private let track: LKRTCVideoTrack
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "RockNRoll.presenter.relay", qos: .userInitiated)
    private var active = false, started = false, stopped = false, queued = false
    private var initialFrame: LKRTCVideoFrame?
    private var latest: LKRTCVideoFrame?
    private var count = 0
    private var width = 0, height = 0
    private var completion: GuestCompletion<GuestCameraInfo>?
    public init(track: LKRTCVideoTrack, source: LKRTCVideoSource, initialFrame: LKRTCVideoFrame? = nil) {
        self.track = track; self.source = source; self.initialFrame = initialFrame
        capturer = LKRTCVideoCapturer(delegate: source)
    }
    private func locked<T>(_ action: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try action() }
    public func start() async throws -> GuestCameraInfo {
        let done = GuestCompletion<GuestCameraInfo>()
        try locked {
            guard !started, !stopped else { throw GuestCameraError.alreadyStarted }
            started = true; active = true; completion = done
        }
        return try await withTaskCancellationHandler(operation: {
            do {
                try locked {
                    guard active else { throw CancellationError() }
                    track.add(self)
                    if let seed = initialFrame, latest == nil {
                        latest = seed
                        initialFrame = nil
                        if !queued {
                            queued = true
                            queue.async { [weak self] in self?.forward() }
                        }
                    }
                }
                try Task.checkCancellation()
                return try await withCheckedThrowingContinuation { done.install($0, timeout: 10) }
            } catch { cancel(); track.remove(self); throw error }
        }, onCancel: { [weak self] in self?.cancel() })
    }
    public func setSize(_ size: CGSize) {}
    public func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let enqueue = locked { () -> Bool in
            guard active else { return false }; initialFrame = nil; latest = frame
            guard !queued else { return false }; queued = true; return true
        }
        if enqueue { queue.async { [weak self] in self?.forward() } }
    }
    private func forward() {
        let result: (GuestCompletion<GuestCameraInfo>?, GuestCameraInfo)? = locked {
            queued = false
            guard active, let frame = latest else { return nil }; latest = nil
            let rotated = frame.rotation == ._90 || frame.rotation == ._270
            width = Int(rotated ? frame.height : frame.width); height = Int(rotated ? frame.width : frame.height)
            source.adaptOutputFormat(toWidth: Int32(width), height: Int32(height), fps: 30)
            source.capturer(capturer, didCapture: frame); count += 1
            return (completion, GuestCameraInfo(deviceName: "Presenter canvas", width: Int32(width), height: Int32(height), fps: 30,
                requestedWidth: Int32(width), requestedHeight: Int32(height), requestedFPS: 30,
                sessionPreset: "Private canvas relay", minimumFrameDuration: CMTime(value: 1, timescale: 30),
                maximumFrameDuration: CMTime(value: 1, timescale: 30), pixelFormat: kCVPixelFormatType_32BGRA, mirrored: false, rotationDegrees: 0))
        }
        if let (completion, info) = result { completion?.finish(.success(info)) }
    }
    public func cancel() {
        let done = locked { active = false; stopped = true; initialFrame = nil; latest = nil; return completion }
        done?.finish(.failure(CancellationError()))
    }
    public func stop() async throws {
        cancel(); track.remove(self)
        try await guestAwait(timeout: 5) { done in self.queue.async { done(.success(())) } }
    }
    public func snapshot() -> GuestCameraSnapshot {
        locked { .init(frames: count, advancingPTS: count, dropped: 0, width: width, height: height,
            pixelFormat: kCVPixelFormatType_32BGRA, systemBackgroundSelected: nil, systemBackgroundActive: nil, observedReaction: false) }
    }
    public func performReaction() async -> Bool { false }
}
