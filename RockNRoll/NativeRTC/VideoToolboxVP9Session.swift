import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// Framework-independent, hardware-only VP9 session. The RTC adapter serializes
/// calls and output delivery, preserving its receiver's callback lifetime.
final class VideoToolboxVP9Session {
    enum Output { case frame(CVPixelBuffer?), waitingForKeyFrame, failure }
    static let available: Bool = {
        #if targetEnvironment(simulator)
        return false
        #else
        guard #available(iOS 17.0, macOS 12.0, *) else { return false }
        if #available(iOS 26.2, macOS 12.0, *) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9) }
        return VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)
        #endif
    }()
    private var session: VTDecompressionSession?
    private var format: VP9VideoFormat?
    private var formatDescription: CMVideoFormatDescription?
    var verifiedHardwareSession: Bool { session != nil }
    deinit { retire() }

    func decode(_ data: Data, keyFrame: Bool, timestamp: UInt32) -> Output {
        guard !data.isEmpty, data.count <= 16_777_216 else { return .waitingForKeyFrame }
        if keyFrame {
            guard let next = VP9VideoFormat.keyFrame(data) else { return .waitingForKeyFrame }
            if next != format {
                retire()
                guard configure(next) else { return .failure }
            }
        }
        guard let session, let description = formatDescription else { return .waitingForKeyFrame }
        guard let sample = makeSample(data, timestamp: timestamp, description: description) else { return .failure }
        let outcome = DecodeOutcome()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in
            outcome.store(status: status, buffer: buffer)
        }
        guard status == noErr, outcome.status == noErr else { return .failure }
        return .frame(outcome.buffer)
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
    func retire() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil; format = nil; formatDescription = nil
    }
    private func makeSample(_ data: Data, timestamp: UInt32, description: CMVideoFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: data.count,
            flags: 0, blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes.count)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?, size = data.count
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(timestamp), timescale: 90_000), decodeTimeStamp: .invalid)
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
