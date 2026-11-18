import LiveKitWebRTC
import VideoToolbox
#if DEBUG
import ObjectiveC
#endif

/// Standard Baseline complements the default factory's Constrained Baseline
/// and High profiles. Some composite servers offer only this exact profile.
public enum NativeH264Codec {
    public static var hardwareDecodingAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        VTIsHardwareDecodeSupported(kCMVideoCodecType_H264)
        #endif
    }
    public static let baseline = LKRTCVideoCodecInfo(name: "H264", parameters: [
        "profile-level-id": "42001f", "packetization-mode": "1", "level-asymmetry-allowed": "1"
    ])
    public static func supported(addingTo codecs: [LKRTCVideoCodecInfo]) -> [LKRTCVideoCodecInfo] {
        codecs.contains { $0.name == baseline.name && $0.parameters == baseline.parameters } ? codecs : codecs + [baseline]
    }
    public static func isBaseline(_ info: LKRTCVideoCodecInfo) -> Bool {
        info.name == "H264" && info.parameters["profile-level-id"] == "42001f" && info.parameters["packetization-mode"] == "1"
    }
}

public final class NativeH264DecoderFactory: NSObject, LKRTCVideoDecoderFactory {
    private let base: any LKRTCVideoDecoderFactory
    public init(base: any LKRTCVideoDecoderFactory = LKRTCDefaultVideoDecoderFactory()) { self.base = base }
    public func supportedCodecs() -> [LKRTCVideoCodecInfo] { NativeH264Codec.supported(addingTo: base.supportedCodecs()) }
    public func createDecoder(_ info: LKRTCVideoCodecInfo) -> (any LKRTCVideoDecoder)? {
        #if DEBUG && os(iOS)
        if info.name == "H264" { return ObservedH264Decoder() }
        #endif
        return NativeH264Codec.isBaseline(info) ? LKRTCVideoDecoderH264() : base.createDecoder(info)
    }
}

#if DEBUG && os(iOS)
/// Qualification of the pinned WebRTC bridge: its stats omit the hardware
/// property. Read its session on the decoder thread; never included in Release.
private final class ObservedH264Decoder: LKRTCVideoDecoderH264 {
    private var queried = false
    override func decode(_ image: LKRTCEncodedImage, missingFrames: Bool, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, renderTimeMs: Int64) -> Int {
        let result = super.decode(image, missingFrames: missingFrames, codecSpecificInfo: info, renderTimeMs: renderTimeMs)
        if !queried, #available(iOS 17.0, *), let field = class_getInstanceVariable(LKRTCVideoDecoderH264.self, "_decompressionSession"),
           let encoding = ivar_getTypeEncoding(field), String(cString: encoding).hasPrefix("^"),
           let address = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque()).advanced(by: ivar_getOffset(field)).load(as: UnsafeRawPointer?.self) {
            var value: Unmanaged<CFTypeRef>?
            let session = Unmanaged<VTDecompressionSession>.fromOpaque(address).takeUnretainedValue()
            let status = VTSessionCopyProperty(session, key: kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder, allocator: nil, valueOut: &value)
            print("NATIVE_H264_HARDWARE status=\(status) hardware=\((value?.takeRetainedValue() as? NSNumber)?.boolValue ?? false)")
            queried = true
        }
        return result
    }
}
#endif
