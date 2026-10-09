import CoreVideo
import Foundation
import LiveKitWebRTC

/// Synchronous, hardware-only VP9 decoding on WebRTC's decoder thread. No
/// outstanding decode callbacks survive release or a format/session change.
final class VP9HardwareDecoder: NSObject, LKRTCVideoDecoder {
    static var available: Bool { VideoToolboxVP9Session.available }
    private let lock = NSRecursiveLock()
    private let onFailure: (() -> Void)?
    private var failureStatus: Int { onFailure == nil ? -13 : -1 }
    private var callback: ((LKRTCVideoFrame) -> Void)?
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
    /// Used only behind the matched framework's native fallback wrapper.
    /// A permanent hardware failure retries this stream in libvpx (-13).
    override init() { onFailure = nil; super.init() }
    func implementationName() -> String { "VideoToolbox VP9" }
    func setCallback(_ callback: @escaping (LKRTCVideoFrame) -> Void) {
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

    func decode(_ image: LKRTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        lock.lock()
        guard started else { lock.unlock(); return -1 }
        guard !failed else { let status = failureStatus; lock.unlock(); return status }
        guard !image.buffer.isEmpty, image.buffer.count <= 16_777_216 else { lock.unlock(); return -1 }
        let pixels: CVPixelBuffer?
        switch core.decode(image.buffer, keyFrame: image.frameType == .videoFrameKey, timestamp: image.timeStamp) {
        case .waitingForKeyFrame: lock.unlock(); return -1
        case .failure: return fail()
        case let .frame(buffer): pixels = buffer
        }
        let callback = self.callback
        let output = pixels.map { buffer -> LKRTCVideoFrame in
            let frame = LKRTCVideoFrame(buffer: LKRTCCVPixelBuffer(pixelBuffer: buffer), rotation: image.rotation,
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
        failed = true; core.retire(); let status = failureStatus
        lock.unlock(); onFailure?(); return status
    }
}
