#if DEBUG
import CoreMedia
import CoreVideo
import Foundation
import WebRTC

/// Synchronous, hardware-only VP9 decoding on WebRTC's decoder thread. No
/// outstanding decode callbacks survive release or a format/session change.
final class GuestVP9HardwareDecoder: NSObject, RTCVideoDecoder {
    static var available: Bool { VideoToolboxVP9Session.available }
    private let lock = NSRecursiveLock()
    private let onFailure: () -> Void
    private var callback: ((RTCVideoFrame) -> Void)?
    private let core = VideoToolboxVP9Session()
    private var started = false
    private var failed = false
    #if DEBUG
    private var hardwareFrames = 0
    var evidenceForTesting: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["hardwareFrames": hardwareFrames, "verifiedHardwareSession": core.verifiedHardwareSession, "failed": failed]
    }
    func failForTesting() {
        lock.lock()
        guard started, core.verifiedHardwareSession, !failed else { lock.unlock(); return }
        _ = fail()
    }
    #endif

    init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }
    func implementationName() -> String { "VideoToolbox VP9" }
    func setCallback(_ callback: @escaping (RTCVideoFrame) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        core.retire(); failed = false; started = true; return 0
    }
    func release() -> Int {
        lock.lock(); defer { lock.unlock() }
        started = false; callback = nil; core.retire(); return 0
    }

    func decode(_ image: RTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        lock.lock()
        guard started, !failed, !image.buffer.isEmpty, image.buffer.count <= 16_777_216 else { lock.unlock(); return -1 }
        let pixels: CVPixelBuffer?
        switch core.decode(image.buffer, keyFrame: image.frameType == .videoFrameKey, timestamp: image.timeStamp) {
        case .waitingForKeyFrame: lock.unlock(); return -1
        case .failure: return fail()
        case let .frame(buffer): pixels = buffer
        }
        let callback = self.callback
        let output = pixels.map { buffer -> RTCVideoFrame in
            let frame = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: buffer), rotation: image.rotation,
                timeStampNs: image.captureTimeMs * 1_000_000)
            frame.timeStamp = Int32(bitPattern: image.timeStamp); return frame
        }
        #if DEBUG
        if output != nil { hardwareFrames += 1 }
        #endif
        // Release must wait for delivery too: WebRTC owns the callback's C++
        // receiver. Recursive locking permits reentrant release from a sink.
        if let output { callback?(output) }
        lock.unlock()
        return 0
    }

    // Called with the lock held. Notify after unlocking to allow recovery to
    // release this decoder without deadlocking. Only one fallback per instance.
    private func fail() -> Int {
        failed = true; core.retire(); lock.unlock(); onFailure(); return -1
    }
}
#endif
