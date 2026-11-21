import CoreImage
import Foundation
import LiveKit
import LiveKitWebRTC

public enum NativeDesktopRockError: LocalizedError {
    case notConnected, staleOperation, noScreenFrames, cameraUnavailable, microphoneAccessRequired, cleanupFailed, audioOwnerBusy, assistantGateBusy, sharedAudioInputUnavailable

    public var errorDescription: String? {
        switch self {
        case .notConnected: L("Join a jam before changing media.")
        case .staleOperation: L("The meeting changed before this action completed.")
        case .noScreenFrames: L("Screen capture did not provide a video frame.")
        case .cameraUnavailable: L("The selected camera is no longer available.")
        case .microphoneAccessRequired: L("Allow microphone access before enabling headset mute controls.")
        case .cleanupFailed: L("Microphone preparation could not stop. Quit and reopen the app before joining again.")
        case .audioOwnerBusy: L("Stop the private microphone check before joining a meeting.")
        case .assistantGateBusy: L("Wait for the assistant to release the microphone before joining this meeting.")
        case .sharedAudioInputUnavailable: L("You can listen and use chat in this jam. To use the microphone or assistant speech, reopen the app and join this jam first.")
        }
    }
}

#if DEBUG
struct NativeRockLiveMediaEvidence {
    let outbound: [[String: Any]]
    let cameraDeviceID: String?
}
#endif

/// SDK sink attachment/detachment stays off the UI executor and is serialized.
final class NativeRockVideoBridge: NSObject, LiveKit.VideoRenderer, @unchecked Sendable {
    let sdkTrack: VideoTrack
    let track: LKRTCVideoTrack
    private let source: LKRTCVideoSource
    private let capturer: LKRTCVideoCapturer
    private let queue = DispatchQueue(label: "native-rock-render-bridge", qos: .userInitiated)
    private let frameGate = NSLock()
    private var forwarding = true
    private var attached = false
    private var closed = false
    @MainActor var isAdaptiveStreamEnabled: Bool { false }
    @MainActor var adaptiveStreamSize: CGSize { .zero }

    init(track: VideoTrack, factory: LKRTCPeerConnectionFactory) {
        sdkTrack = track
        source = factory.videoSource(forScreenCast: track.source == .screenShareVideo)
        capturer = LKRTCVideoCapturer(delegate: source)
        self.track = factory.videoTrack(with: source, trackId: "native-rock-" + UUID().uuidString)
        super.init()
    }

    func attach() async {
        await withCheckedContinuation { continuation in
            queue.async {
                if !self.closed && !self.attached {
                    self.sdkTrack.add(videoRenderer: self)
                    self.attached = true
                }
                continuation.resume()
            }
        }
    }

    func detach() async {
        retire()
        await withCheckedContinuation { continuation in
            queue.async {
                self.closed = true
                if self.attached {
                    self.sdkTrack.remove(videoRenderer: self)
                    self.attached = false
                }
                continuation.resume()
            }
        }
    }

    func retire() {
        frameGate.lock()
        forwarding = false
        frameGate.unlock()
    }

    func render(frame: LiveKit.VideoFrame) {
        guard frameGate.try() else { return }
        defer { frameGate.unlock() }
        guard forwarding else { return }
        guard let buffer = frame.toCVPixelBuffer(),
              let rotation = LKRTCVideoRotation(rawValue: frame.rotation.rawValue) else { return }
        let native = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: rotation, timeStampNs: frame.timeStampNs)
        source.capturer(capturer, didCapture: native)
    }
}

final class NativeRockScreenBridge: NSObject, LKRTCVideoRenderer, @unchecked Sendable {
    private let track: LKRTCVideoTrack
    private var capturer: BufferCapturer?
    private let converter = NativeVideoPixelBuffer()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let queue = DispatchQueue(label: "native-rock-screen-bridge", qos: .userInitiated)
    private let lock = NSLock()
    private var active = true
    private var queued = false
    private var latest: LKRTCVideoFrame?
    // Conversion, attachment and continuation state belong to the media queue.
    private var attached = false
    private var firstDimensions: CGSize?
    private var dimensionWaiter: CheckedContinuation<CGSize, Error>?
    private var buffered: (CVPixelBuffer, Int64, LiveKit.VideoRotation)?
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero

    init(track: LKRTCVideoTrack) {
        self.track = track
    }

    private func locked<T>(_ operation: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return operation()
    }

    func attachAndWaitForDimensions() async throws -> CGSize {
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    guard self.locked({ self.active }) else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if !self.attached {
                        self.track.add(self)
                        self.attached = true
                    }
                    if let dimensions = self.firstDimensions {
                        continuation.resume(returning: dimensions)
                        return
                    }
                    guard self.dimensionWaiter == nil else {
                        continuation.resume(throwing: NativeDesktopRockError.staleOperation)
                        return
                    }
                    self.dimensionWaiter = continuation
                    self.queue.asyncAfter(deadline: .now() + 5) {
                        self.dimensionWaiter?.resume(throwing: NativeDesktopRockError.noScreenFrames)
                        self.dimensionWaiter = nil
                    }
                }
            }
        }, onCancel: { [weak self] in self?.cancel() })
    }

    func setCapturer(_ capturer: BufferCapturer) async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.locked {
                    if self.active {
                        self.capturer = capturer
                        if let (pixels, timestamp, rotation) = self.buffered {
                            capturer.capture(pixels, timeStampNs: timestamp, rotation: rotation)
                        }
                    }
                }
                continuation.resume()
            }
        }
    }

    private func cancel() {
        locked { active = false; latest = nil }
        queue.async {
            self.dimensionWaiter?.resume(throwing: CancellationError())
            self.dimensionWaiter = nil
        }
    }

    func detach() async {
        cancel()
        await withCheckedContinuation { continuation in
            queue.async {
                if self.attached {
                    self.track.remove(self)
                    self.attached = false
                }
                self.capturer = nil
                self.buffered = nil
                self.pool = nil
                continuation.resume()
            }
        }
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        let enqueue = locked { () -> Bool in
            guard active else { return false }
            latest = frame
            guard !queued else { return false }
            queued = true
            return true
        }
        if enqueue {
            queue.async { self.drain() }
        }
    }

    private func drain() {
        let frame = locked { () -> LKRTCVideoFrame? in
            queued = false
            defer { latest = nil }
            return active ? latest : nil
        }
        guard let frame,
              let input = converter.convert(frame),
              let buffer = fitted(input),
              let rotation = LiveKit.VideoRotation(rawValue: frame.rotation.rawValue) else { return }
        let dimensions = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        let waiterToResume: CheckedContinuation<CGSize, Error>? = locked { () -> CheckedContinuation<CGSize, Error>? in
            guard active else { return nil }
            buffered = (buffer, frame.timeStampNs, rotation)
            if firstDimensions == nil {
                firstDimensions = dimensions
                let waiter = dimensionWaiter
                dimensionWaiter = nil
                return waiter
            }
            return nil
        }
        let activeNow = locked { active }
        if activeNow {
            capturer?.capture(buffer, timeStampNs: frame.timeStampNs, rotation: rotation)
        }
        waiterToResume?.resume(returning: dimensions)
    }

    private func fitted(_ buffer: CVPixelBuffer) -> CVPixelBuffer? {
        let input = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
        guard let output = NativeRockScreenPolicy.dimensions(input) else { return nil }
        guard output != input else { return buffer }
        if pool == nil || poolSize != output {
            let fields: [CFString: Any] = [
                kCVPixelBufferWidthKey: Int(output.width),
                kCVPixelBufferHeightKey: Int(output.height),
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey: [:],
            ]
            guard CVPixelBufferPoolCreate(nil, nil, fields as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolSize = output
        }
        var resized: CVPixelBuffer?
        guard let pool,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool, [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary, &resized) == kCVReturnSuccess,
              let resized else { return nil }
        let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: output.width / input.width, y: output.height / input.height))
        context.render(image, to: resized)
        return resized
    }
}
