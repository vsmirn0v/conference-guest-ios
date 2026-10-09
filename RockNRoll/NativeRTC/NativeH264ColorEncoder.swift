import Foundation
import LiveKitWebRTC
import ObjectiveC

/// One adapter per H.264 leaf, including LiveKit's simulcast factory.
/// Public Objective-C factory boundary; no native ABI or private VT session access.
final class NativeH264ColorEncoder: NSObject, LKRTCVideoEncoder {
    let base: any LKRTCVideoEncoder
    private let signalling = H264InputColorSignalling()
    private let qualifiedDefaultBGRA: Bool
    init(base: any LKRTCVideoEncoder) {
        self.base = base
        qualifiedDefaultBGRA = !ProcessInfo.processInfo.isiOSAppOnMac && base.implementationName() == "VideoToolbox"
        super.init()
    }
    static func prepare() { _ = installed }
    private static let installed: Bool = {
        let selector = NSSelectorFromString("createEncoder:")
        guard let method = class_getInstanceMethod(LKRTCDefaultVideoEncoderFactory.self, selector) else { return false }
        typealias Create = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, AnyObject) -> AnyObject? = { factory, info in
            let result = original(factory, selector, info)
            guard let codec = info as? LKRTCVideoCodecInfo, codec.name == "H264",
                  let encoder = result as? any LKRTCVideoEncoder, !(encoder is NativeH264ColorEncoder) else { return result }
            return NativeH264ColorEncoder(base: encoder)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        return true
    }()
    func setCallback(_ callback: LiveKitWebRTC.RTCVideoEncoderCallback?) {
        base.setCallback { [weak self] image, info in
            guard let self else { return false }
            let output = self.signalling.output(image.timeStamp, data: image.buffer, keyframe: image.frameType == .videoFrameKey)
            image.buffer = output.data
            let accepted = callback?(image, info) ?? false
            if accepted { self.signalling.accepted(output) }
            return accepted
        }
    }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        signalling.reset(); return base.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        let stamp = UInt32(bitPattern: frame.timeStamp)
        let changed = signalling.prepare(stamp, pixels: (frame.buffer as? LKRTCCVPixelBuffer)?.pixelBuffer, qualifyDefaultBGRA: qualifiedDefaultBGRA)
        let types = changed ? [NSNumber(value: LKRTCFrameType.videoFrameKey.rawValue)] : frameTypes
        let result = base.encode(frame, codecSpecificInfo: info, frameTypes: types)
        if result != 0 { signalling.discard(stamp) }
        return result
    }
    func release() -> Int { let result = base.release(); signalling.reset(); return result }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { base.setBitrate(bitrateKbit, framerate: framerate) }
    func implementationName() -> String { base.implementationName() }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { base.scalingSettings() }
    var resolutionAlignment: Int { base.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { base.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { base.supportsNativeHandle }
}
