import LiveKitWebRTC
import ObjectiveC
import VideoToolbox

// The server offers Baseline (42001f), whereas the default factory advertises
// Constrained Baseline (42e034). Keep this interoperability trial out of policy
// until both receiving and publishing have real frames and hardware evidence.
let serverBaseline = LKRTCVideoCodecInfo(name: "H264", parameters: [
    "profile-level-id": "42001f", "packetization-mode": "1", "level-asymmetry-allowed": "1"
])
final class ServerEncoderFactory: NSObject, LKRTCVideoEncoderFactory {
    private let base = LKRTCDefaultVideoEncoderFactory()
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { [serverBaseline] + base.supportedCodecs() }
    func createEncoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoEncoder)? {
        info.parameters["profile-level-id"] == "42001f" ? LKRTCVideoEncoderH264(codecInfo: info) : base.createEncoder(info)
    }
}
final class ServerDecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base = LKRTCDefaultVideoDecoderFactory()
    func supportedCodecs() -> [LKRTCVideoCodecInfo] { [serverBaseline] + base.supportedCodecs() }
    func createDecoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        info.parameters["profile-level-id"] == "42001f" ? ObservedServerDecoder() : base.createDecoder(info)
    }
}

/// Disposable instrumentation of this exact WebRTC binary, never app code.
/// Read the upstream decoder's session on its serialized decode thread; query
/// VideoToolbox itself because this Objective-C bridge omits hardware stats.
final class ObservedServerDecoder: NSObject, LKRTCVideoDecoder {
    private let decoder = LKRTCVideoDecoderH264()
    private var reported = false
    func implementationName() -> String { decoder.implementationName() }
    func setCallback(_ callback: @escaping (LKRTCVideoFrame) -> Void) { decoder.setCallback(callback) }
    func startDecode(withNumberOfCores cores: Int32) -> Int { decoder.startDecode(withNumberOfCores: cores) }
    func release() -> Int { decoder.release() }
    func decode(_ image: LKRTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        let result = decoder.decode(image, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
        if !reported, let field = class_getInstanceVariable(LKRTCVideoDecoderH264.self, "_decompressionSession"),
           let encoding = ivar_getTypeEncoding(field), String(cString: encoding).hasPrefix("^"),
           let address = UnsafeRawPointer(Unmanaged.passUnretained(decoder).toOpaque()).advanced(by: ivar_getOffset(field)).load(as: UnsafeRawPointer?.self) {
            let session = Unmanaged<VTDecompressionSession>.fromOpaque(address).takeUnretainedValue()
            var property: Unmanaged<CFTypeRef>?
            let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &property)
            probeLog("h264-hardware-session", ["status": status, "hardware": (property?.takeRetainedValue() as? NSNumber)?.boolValue ?? false])
            reported = true
        }
        return result
    }
}
