import CoreMedia
import CoreVideo
import Foundation
import LiveKitWebRTC
import VideoToolbox

/// Synchronous, hardware-only VP9 decoding on WebRTC's decoder thread. No
/// outstanding decode callbacks survive release or a format/session change.
final class VP9HardwareDecoder: NSObject, LKRTCVideoDecoder {
    static let available: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard #available(iOS 17.0, macOS 12.0, *) else { return false }
        if #available(iOS 26.2, macOS 12.0, *) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        #endif
    }()
    private let lock = NSRecursiveLock()
    private let onFailure: () -> Void
    private var callback: ((LKRTCVideoFrame) -> Void)?
    private var session: VTDecompressionSession?
    private var format: VP9VideoFormat?
    private var formatDescription: CMVideoFormatDescription?
    private var started = false
    private var failed = false
    #if DEBUG
    private var hardwareFrames = 0
    var evidenceForTesting: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["hardwareFrames": hardwareFrames, "verifiedHardwareSession": session != nil, "failed": failed]
    }
    func failForTesting() {
        lock.lock()
        guard started, session != nil, !failed else { lock.unlock(); return }
        _ = fail()
    }
    #endif

    init(onFailure: @escaping () -> Void) { self.onFailure = onFailure }
    func implementationName() -> String { "VideoToolbox VP9" }
    func setCallback(_ callback: @escaping (LKRTCVideoFrame) -> Void) {
        lock.lock(); self.callback = callback; lock.unlock()
    }
    func startDecode(withNumberOfCores numberOfCores: Int32) -> Int {
        lock.lock(); defer { lock.unlock() }
        retire(); failed = false; started = true; return 0
    }
    func release() -> Int {
        lock.lock(); defer { lock.unlock() }
        started = false; callback = nil; retire(); return 0
    }
    deinit { if let session { VTDecompressionSessionInvalidate(session) } }

    func decode(_ image: LKRTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        lock.lock()
        guard started, !failed, !image.buffer.isEmpty, image.buffer.count <= 16_777_216 else { lock.unlock(); return -1 }
        if image.frameType == .videoFrameKey {
            guard let next = VP9VideoFormat.keyFrame(image.buffer) else { lock.unlock(); return -1 }
            if next != format {
                retire()
                guard configure(next) else { return fail() }
            }
        }
        guard let session, let description = formatDescription else { lock.unlock(); return -1 }
        guard let sample = makeSample(image, description: description) else { return fail() }
        let outcome = DecodeOutcome()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            outcome.store(status: status, buffer: buffer)
        }
        guard status == noErr, outcome.status == noErr else { return fail() }
        let callback = self.callback
        let output = outcome.buffer.map { buffer -> LKRTCVideoFrame in
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

    private func configure(_ format: VP9VideoFormat) -> Bool {
        guard Self.available, #available(iOS 17.0, macOS 12.0, *), let description = format.description() else { return false }
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: format.fullRange ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
        var session: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description,
            decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: nil,
            decompressionSessionOut: &session) == noErr, let session else { return false }
        var hardware: Unmanaged<CFTypeRef>?
        let queried = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
            allocator: kCFAllocatorDefault, valueOut: &hardware)
        let hardwareValue = hardware?.takeRetainedValue()
        guard queried == noErr, (hardwareValue as? NSNumber)?.boolValue == true else {
            VTDecompressionSessionInvalidate(session); return false
        }
        VTSessionSetProperty(session, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        self.session = session; self.format = format; self.formatDescription = description
        return true
    }
    private func retire() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; formatDescription = nil
    }
    // Called with the lock held. Notify after unlocking to allow recovery to
    // release this decoder without deadlocking. Only one fallback per instance.
    private func fail() -> Int {
        failed = true; retire(); lock.unlock(); onFailure(); return -1
    }
    private func makeSample(_ image: LKRTCEncodedImage, description: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: image.buffer.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: image.buffer.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = image.buffer.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?, size = image.buffer.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(image.timeStamp), timescale: 90_000), decodeTimeStamp: .invalid)
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: description,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &sample) == noErr else { return nil }
        return sample
    }
    private final class DecodeOutcome {
        private let lock = NSLock()
        private var value: (OSStatus, CVPixelBuffer?) = (noErr, nil)
        var status: OSStatus { lock.lock(); defer { lock.unlock() }; return value.0 }
        var buffer: CVPixelBuffer? { lock.lock(); defer { lock.unlock() }; return value.1 }
        func store(status: OSStatus, buffer: CVPixelBuffer?) { lock.lock(); value = (status, buffer); lock.unlock() }
    }
}
