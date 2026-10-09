import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import VideoToolbox

private struct Fixture: Decodable {
    struct Packet: Decodable { let data: Data; let sha256: [String] }
    let width: Int32, height: Int32, av1C: Data, packets: [Packet]
}
private final class Result: @unchecked Sendable {
    private let lock = NSLock()
    private var hashes: [String] = []
    private var errors: [OSStatus] = []
    func record(_ status: OSStatus, _ buffer: CVPixelBuffer?) {
        lock.lock(); defer { lock.unlock() }
        guard status == noErr, let buffer else { errors.append(status); return }
        precondition(CVPixelBufferGetPlaneCount(buffer) == 2)
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        var digest = SHA256()
        let y = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)!, uv = CVPixelBufferGetBaseAddressOfPlane(buffer, 1)!
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        for row in 0..<height { digest.update(data: Data(bytes: y + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), count: width)) }
        for channel in 0..<2 { for row in 0..<height / 2 {
            let source = (uv + row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)).assumingMemoryBound(to: UInt8.self)
            digest.update(data: Data((0..<width / 2).map { source[$0 * 2 + channel] }))
        } }
        hashes.append(digest.finalize().map { String(format: "%02x", $0) }.joined())
    }
    func verify(_ expected: [String]) {
        lock.lock(); defer { lock.unlock() }
        precondition(errors.isEmpty && hashes == expected, "AV1 hardware output differs from dav1d")
    }
}

struct HardwareProbe {
    static func run(_ fixtureURL: URL) throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
        guard #available(macOS 14, iOS 17, *) else { fatalError("AV1 hardware platform required") }
        if #available(iOS 26.2, macOS 14, *) { VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_AV1) }
        precondition(VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
        var description: CMVideoFormatDescription?
        let extensions = [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String: ["av1C": fixture.av1C]] as CFDictionary
        precondition(CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_AV1, width: fixture.width, height: fixture.height, extensions: extensions, formatDescriptionOut: &description) == noErr)
        var session: VTDecompressionSession?
        let specification = [kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String: true] as CFDictionary
        let attributes = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        precondition(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: description!, decoderSpecification: specification, imageBufferAttributes: attributes, outputCallback: nil, decompressionSessionOut: &session) == noErr)
        defer { VTDecompressionSessionInvalidate(session!) }
        var hardware: Unmanaged<CFTypeRef>?
        precondition(VTSessionCopyProperty(session!, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: kCFAllocatorDefault, valueOut: &hardware) == noErr)
        precondition((hardware?.takeRetainedValue() as? NSNumber)?.boolValue == true)
        let result = Result()
        for (index, packet) in fixture.packets.enumerated() {
            var block: CMBlockBuffer?
            precondition(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: packet.data.count, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: packet.data.count, flags: 0, blockBufferOut: &block) == noErr)
            precondition(packet.data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: $0.count) } == noErr)
            var sample: CMSampleBuffer?, size = packet.data.count
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMTime(value: Int64(index), timescale: 10), decodeTimeStamp: .invalid)
            precondition(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block!, formatDescription: description!, sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr)
            precondition(VTDecompressionSessionDecodeFrame(session!, sampleBuffer: sample!, flags: [], infoFlagsOut: nil) { status, _, buffer, _, _ in result.record(status, buffer) } == noErr)
        }
        precondition(VTDecompressionSessionFinishDelayedFrames(session!) == noErr)
        precondition(VTDecompressionSessionWaitForAsynchronousFrames(session!) == noErr)
        result.verify(fixture.packets.flatMap(\.sha256))
        print("AV1_HARDWARE_VERIFIED frames=16 pixels=dav1d-exact width=\(fixture.width) height=\(fixture.height)")
    }
}

#if os(macOS)
@main struct AV1MacMain {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        try HardwareProbe.run(URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
#endif
