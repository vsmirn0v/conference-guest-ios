import Foundation
import LiveKitWebRTC

/// Optional public Objective-C API supplied by our exact-source WebRTC patch.
/// Older frameworks retain their existing decoder path. No private native ABI,
/// factory swizzle, or access to compressed spatial-layer internals is used.
enum NativeVP9Hybrid {
    private static let selector = NSSelectorFromString("vp9DecoderWithHardwareDecoder:")
    static var available: Bool { LKRTCVideoDecoderVP9.responds(to: selector) }
    static func make(hardware: VP9HardwareDecoder) -> (any LKRTCVideoDecoder)? {
        guard available else { return nil }
        return LKRTCVideoDecoderVP9.perform(selector, with: hardware)?.takeUnretainedValue() as? any LKRTCVideoDecoder
    }
}
