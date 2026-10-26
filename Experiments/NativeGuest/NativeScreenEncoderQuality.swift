import Darwin
import Foundation
import LiveKitWebRTC
import ObjectiveC

/// All native Mac engines use this public factory boundary, including LiveKit's
/// internal factories. Keep capabilities and non-H264 encoders unchanged.
enum NativeScreenEncoderQuality {
    static func prepare() { _ = installed }
    private static let installed: Bool = {
        let selector = NSSelectorFromString("createEncoder:")
        guard let method = class_getInstanceMethod(LKRTCDefaultVideoEncoderFactory.self, selector) else { return false }
        typealias Create = @convention(c) (AnyObject, Selector, AnyObject) -> AnyObject?
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, AnyObject) -> AnyObject? = { factory, info in
            let result = original(factory, selector, info)
            guard let codec = info as? LKRTCVideoCodecInfo, codec.name == "H264",
                  let encoder = result as? any LKRTCVideoEncoder, !(encoder is NativeScreenH264Encoder) else { return result }
            return NativeScreenH264Encoder(base: encoder)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        return true
    }()
}

final class NativeScreenH264Encoder: NSObject, LKRTCVideoEncoder {
    typealias Configure = @convention(c) (UnsafeMutableRawPointer, Int32, Int32) -> Int32
    private static let configure: Configure? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "LKRTCConfigureScreenShareEncoderQuality") else { return nil }
        return unsafeBitCast(symbol, to: Configure.self)
    }()
    private static var detailPresetEnabled: Bool {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SCREEN_DETAIL_PRESET"] != "reference"
        #else
        return true
        #endif
    }
    let base: any LKRTCVideoEncoder
    private(set) var screenQualityConfigured = false
    init(base: any LKRTCVideoEncoder) { self.base = base }
    func setCallback(_ callback: LKRTCVideoEncoderCallback?) { base.setCallback(callback) }
    func startEncode(with settings: LKRTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        screenQualityConfigured = false
        let result = base.startEncode(with: settings, numberOfCores: numberOfCores)
        if result == 0, settings.mode == .screensharing, Self.detailPresetEnabled, let configure = Self.configure {
            // Match iOS-on-Mac: QP 24 under normal budget, quality over speed.
            // The native extension retains congestion-aware rate/QP handling.
            screenQualityConfigured = configure(Unmanaged.passUnretained(base as AnyObject).toOpaque(), 24, 0) == 1
        }
        #if DEBUG
        if result == 0 {
            print("NATIVE_H264 mode=\(settings.mode.rawValue) screenDetail=\(screenQualityConfigured) size=\(settings.width)x\(settings.height) fps=\(settings.maxFramerate)")
        }
        #endif
        return result
    }
    func encode(_ frame: LKRTCVideoFrame, codecSpecificInfo info: (any LKRTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        base.encode(frame, codecSpecificInfo: info, frameTypes: frameTypes)
    }
    func release() -> Int {
        screenQualityConfigured = false
        return base.release()
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { base.setBitrate(bitrateKbit, framerate: framerate) }
    func implementationName() -> String { base.implementationName() }
    func scalingSettings() -> LKRTCVideoEncoderQpThresholds? { base.scalingSettings() }
    var resolutionAlignment: Int { base.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { base.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { base.supportsNativeHandle }
}
