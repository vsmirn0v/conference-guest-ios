import AVFoundation
import Foundation
import ObjectiveC
import WebRTC

/// Retain the pinned hardware encoder; supplement missing bitstream color tags
/// for qualified YUV input. Retain camera range across SDK I420 conversion.
final class GuestH264ColorEncoder: NSObject, RTCVideoEncoder {
    let base: any RTCVideoEncoder
    private let lock = NSLock()
    private var callback: RTCVideoEncoderCallback?
    private let signalling = H264InputColorSignalling()
    private let qualifiedDefaultBGRA: Bool
    #if DEBUG
    private static let evidenceLock = NSLock()
    private static let encoders = NSHashTable<GuestH264ColorEncoder>.weakObjects()
    private static var dropCallbacks = false
    static func dropCallbacksForTesting(_ value: Bool) {
        evidenceLock.lock(); dropCallbacks = value; evidenceLock.unlock()
    }
    private var taggedKeyframes = 0
    private var callbacks = 0
    private var knownInputs = 0
    private var totalInputs = 0
    private let evidenceID = UUID().uuidString
    private var keyframes = 0
    private var lastInputType = ""
    private var inputFormat: OSType = 0
    private var inputAttachments: [String: String] = [:]
    private var lastInputSize = CGSize.zero
    static func evidenceForTesting() -> [[String: Any]] {
        evidenceLock.lock(); let all = encoders.allObjects; evidenceLock.unlock()
        return all.map { encoder in
            encoder.lock.lock(); defer { encoder.lock.unlock() }
            return ["id": encoder.evidenceID, "inputs": encoder.totalInputs, "callbacks": encoder.callbacks, "taggedKeyframes": encoder.taggedKeyframes,
                    "inputWidth": encoder.lastInputSize.width, "inputHeight": encoder.lastInputSize.height,
                    "knownInputs": encoder.knownInputs, "keyframes": encoder.keyframes,
                    "inputType": encoder.lastInputType, "inputFormat": encoder.inputFormat, "colorAttachments": encoder.inputAttachments]
        }
    }
    #endif
    init(base: any RTCVideoEncoder) {
        self.base = base
        qualifiedDefaultBGRA = !ProcessInfo.processInfo.isiOSAppOnMac && base.implementationName() == "VideoToolbox"
        super.init()
        #if DEBUG
        Self.evidenceLock.lock(); Self.encoders.add(self); Self.evidenceLock.unlock()
        #endif
    }

    static func prepare() { _ = installed }
    private static let installed: Bool = {
        func wrapped(_ value: AnyObject?) -> AnyObject? {
            guard let factory = value as? any RTCVideoEncoderFactory,
                  !(factory is GuestColorEncoderFactory) else { return value }
            return GuestColorEncoderFactory(base: factory)
        }
        let selector = NSSelectorFromString("initWithEncoderFactory:decoderFactory:")
        guard let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, selector) else { return false }
        typealias Create = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?) -> AnyObject
        let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
        let forward: @convention(block) (AnyObject, AnyObject?, AnyObject?) -> AnyObject = { factory, encoder, decoder in
            original(factory, selector, wrapped(encoder), decoder)
        }
        method_setImplementation(method, imp_implementationWithBlock(forward))
        // The SDK may inject its own ADM. Forward it exactly, including nil.
        let audioSelector = NSSelectorFromString("initWithEncoderFactory:decoderFactory:audioDevice:")
        if let method = class_getInstanceMethod(RTCPeerConnectionFactory.self, audioSelector) {
            typealias Create = @convention(c) (AnyObject, Selector, AnyObject?, AnyObject?, AnyObject?) -> AnyObject
            let original = unsafeBitCast(method_getImplementation(method), to: Create.self)
            let forward: @convention(block) (AnyObject, AnyObject?, AnyObject?, AnyObject?) -> AnyObject = { factory, encoder, decoder, audio in
                original(factory, audioSelector, wrapped(encoder), decoder, audio)
            }
            method_setImplementation(method, imp_implementationWithBlock(forward))
        }
        return true
    }()

    static func nativeColor(for frame: RTCVideoFrame) -> H264ColorDescription? {
        H264InputColorSignalling.color((frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer)
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        lock.lock(); self.callback = callback; lock.unlock()
        base.setCallback { [weak self] image, info in
            guard let self else { return false }
            self.lock.lock()
            let callback = self.callback
            self.lock.unlock()
            #if DEBUG
            Self.evidenceLock.lock(); let drop = Self.dropCallbacks; Self.evidenceLock.unlock()
            if drop { return false } // Emulate an encoder that stops delivering output.
            #endif
            let original = image.buffer
            let output = self.signalling.output(image.timeStamp, data: original, keyframe: image.frameType == .videoFrameKey)
            image.buffer = output.data
            #if DEBUG
            self.lock.lock(); self.callbacks += 1
            if image.buffer != original { self.taggedKeyframes += 1 }
            if image.frameType == .videoFrameKey { self.keyframes += 1 }
            self.lock.unlock()
            #endif
            let accepted = callback?(image, info) ?? false
            if accepted { self.signalling.accepted(output) }
            return accepted
        }
    }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        signalling.reset()
        return base.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        let stamp = UInt32(bitPattern: frame.timeStamp)
        let changed = signalling.prepare(stamp, pixels: (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer, qualifyDefaultBGRA: qualifiedDefaultBGRA)
        #if DEBUG
        let color = Self.nativeColor(for: frame) ?? (qualifiedDefaultBGRA ? H264InputColorSignalling.defaultBGRAMatrix((frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer) : nil)
        lock.lock()
        totalInputs += 1
        lastInputSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        lastInputType = String(describing: type(of: frame.buffer))
        inputFormat = (frame.buffer as? RTCCVPixelBuffer).map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) } ?? 0
        if let pixels = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer {
            inputAttachments = [:]
            for key in [kCVImageBufferColorPrimariesKey, kCVImageBufferTransferFunctionKey, kCVImageBufferYCbCrMatrixKey, H264InputColorSignalling.presenterColorKey] {
                if let value = CVBufferCopyAttachment(pixels, key, nil) { inputAttachments[key as String] = String(describing: value) }
            }
        }
        if color != nil { knownInputs += 1 }
        lock.unlock()
        #endif
        let types = changed ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : frameTypes
        let result = base.encode(frame, codecSpecificInfo: info, frameTypes: types)
        if result != 0 {
            signalling.discard(stamp)
        }
        return result
    }
    func release() -> Int {
        let result = base.release()
        signalling.reset(); lock.lock(); callback = nil; lock.unlock()
        return result
    }
    func setBitrate(_ bitrateKbit: UInt32, framerate: UInt32) -> Int32 { base.setBitrate(bitrateKbit, framerate: framerate) }
    func implementationName() -> String { base.implementationName() }
    func scalingSettings() -> RTCVideoEncoderQpThresholds? { base.scalingSettings() }
    var resolutionAlignment: Int { base.resolutionAlignment }
    var applyAlignmentToAllSimulcastLayers: Bool { base.applyAlignmentToAllSimulcastLayers }
    var supportsNativeHandle: Bool { base.supportsNativeHandle }
}

private final class GuestColorEncoderFactory: NSObject, RTCVideoEncoderFactory {
    let base: any RTCVideoEncoderFactory
    init(base: any RTCVideoEncoderFactory) { self.base = base }
    func supportedCodecs() -> [RTCVideoCodecInfo] { base.supportedCodecs() }
    func implementations() -> [RTCVideoCodecInfo] { base.implementations?() ?? base.supportedCodecs() }
    func encoderSelector() -> (any RTCVideoEncoderSelector)? { base.encoderSelector?() }
    func createEncoder(_ info: RTCVideoCodecInfo) -> (any RTCVideoEncoder)? {
        guard let encoder = base.createEncoder(info) else { return nil }
        guard info.name == "H264", !(encoder is GuestH264ColorEncoder) else { return encoder }
        return GuestH264ColorEncoder(base: encoder)
    }
}
