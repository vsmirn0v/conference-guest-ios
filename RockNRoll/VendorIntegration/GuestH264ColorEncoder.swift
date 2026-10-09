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
    private struct Input { let color: H264ColorDescription?; let sequence: UInt64 }
    private var inputs: [UInt32: Input] = [:]
    private var pending: [UInt32] = []
    private var announced: H264ColorDescription?
    private var sequence: UInt64 = 0
    private var announcedSequence: UInt64 = 0
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
    private var lastInputSize = CGSize.zero
    static func evidenceForTesting() -> [[String: Any]] {
        evidenceLock.lock(); let all = encoders.allObjects; evidenceLock.unlock()
        return all.map { encoder in
            encoder.lock.lock(); defer { encoder.lock.unlock() }
            return ["id": encoder.evidenceID, "inputs": encoder.totalInputs, "callbacks": encoder.callbacks, "taggedKeyframes": encoder.taggedKeyframes,
                    "inputWidth": encoder.lastInputSize.width, "inputHeight": encoder.lastInputSize.height,
                    "knownInputs": encoder.knownInputs, "keyframes": encoder.keyframes,
                    "inputType": encoder.lastInputType, "inputFormat": encoder.inputFormat]
        }
    }
    #endif
    init(base: any RTCVideoEncoder) {
        self.base = base; super.init()
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

    private static let primaries: [(CFString, UInt8)] = [
        (kCVImageBufferColorPrimaries_ITU_R_709_2, 1), (kCVImageBufferColorPrimaries_EBU_3213, 5),
        (kCVImageBufferColorPrimaries_SMPTE_C, 6), (kCVImageBufferColorPrimaries_ITU_R_2020, 9),
        (kCVImageBufferColorPrimaries_P3_D65, 12)]
    private static let transfers: [(CFString, UInt8)] = [
        (kCVImageBufferTransferFunction_ITU_R_709_2, 1), (kCVImageBufferTransferFunction_sRGB, 13),
        (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, 16), (kCVImageBufferTransferFunction_ITU_R_2100_HLG, 18)]
    private static let matrices: [(CFString, UInt8)] = [
        (kCVImageBufferYCbCrMatrix_ITU_R_709_2, 1), (kCVImageBufferYCbCrMatrix_ITU_R_601_4, 6),
        (kCVImageBufferYCbCrMatrix_SMPTE_240M_1995, 7), (kCVImageBufferYCbCrMatrix_ITU_R_2020, 9)]
    static func nativeColor(for frame: RTCVideoFrame) -> H264ColorDescription? {
        guard let native = frame.buffer as? RTCCVPixelBuffer else { return nil }
        let pixels = native.pixelBuffer, format = CVPixelBufferGetPixelFormatType(pixels)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange else { return nil }
        func code(_ key: CFString, _ values: [(CFString, UInt8)]) -> UInt8? {
            guard let value = CVBufferCopyAttachment(pixels, key, nil) else { return nil }
            return values.first { CFEqual(value, $0.0) }?.1
        }
        guard let primaries = code(kCVImageBufferColorPrimariesKey, primaries),
              let transfer = code(kCVImageBufferTransferFunctionKey, transfers),
              let matrix = code(kCVImageBufferYCbCrMatrixKey, matrices) else { return nil }
        return H264ColorDescription(primaries: primaries, transfer: transfer, matrix: matrix)
    }
    func setCallback(_ callback: RTCVideoEncoderCallback?) {
        lock.lock(); self.callback = callback; lock.unlock()
        base.setCallback { [weak self] image, info in
            guard let self else { return false }
            self.lock.lock()
            let input = self.inputs.removeValue(forKey: image.timeStamp)
            self.pending.removeAll { $0 == image.timeStamp }
            let callback = self.callback
            self.lock.unlock()
            #if DEBUG
            Self.evidenceLock.lock(); let drop = Self.dropCallbacks; Self.evidenceLock.unlock()
            if drop { return false } // Emulate an encoder that stops delivering output.
            #endif
            if image.frameType == .videoFrameKey, let color = input?.color {
                #if DEBUG
                let original = image.buffer
                #endif
                image.buffer = H264ColorSignalling.applying(color, to: image.buffer)
                #if DEBUG
                self.lock.lock(); if image.buffer != original { self.taggedKeyframes += 1 }; self.lock.unlock()
                #endif
            }
            #if DEBUG
            self.lock.lock(); self.callbacks += 1
            if image.frameType == .videoFrameKey { self.keyframes += 1 }
            self.lock.unlock()
            #endif
            let accepted = callback?(image, info) ?? false
            if accepted, image.frameType == .videoFrameKey, let input {
                self.lock.lock()
                if input.sequence >= self.announcedSequence {
                    self.announced = input.color; self.announcedSequence = input.sequence
                }
                self.lock.unlock()
            }
            return accepted
        }
    }
    func startEncode(with settings: RTCVideoEncoderSettings, numberOfCores: Int32) -> Int {
        lock.lock(); inputs.removeAll(); pending.removeAll(); announced = nil; announcedSequence = 0; sequence = 0; lock.unlock()
        return base.startEncode(with: settings, numberOfCores: numberOfCores)
    }
    func encode(_ frame: RTCVideoFrame, codecSpecificInfo info: (any RTCCodecSpecificInfo)?, frameTypes: [NSNumber]) -> Int {
        let color = Self.nativeColor(for: frame), stamp = UInt32(bitPattern: frame.timeStamp)
        lock.lock()
        let changed = announced != color
        sequence &+= 1
        #if DEBUG
        totalInputs += 1
        lastInputSize = CGSize(width: Int(frame.width), height: Int(frame.height))
        lastInputType = String(describing: type(of: frame.buffer))
        inputFormat = (frame.buffer as? RTCCVPixelBuffer).map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) } ?? 0
        if color != nil { knownInputs += 1 }
        #endif
        pending.removeAll { $0 == stamp }; pending.append(stamp)
        inputs[stamp] = Input(color: color, sequence: sequence)
        while pending.count > 64 { inputs.removeValue(forKey: pending.removeFirst()) }
        lock.unlock()
        let types = changed ? [NSNumber(value: RTCFrameType.videoFrameKey.rawValue)] : frameTypes
        let result = base.encode(frame, codecSpecificInfo: info, frameTypes: types)
        if result != 0 {
            lock.lock(); inputs.removeValue(forKey: stamp); pending.removeAll { $0 == stamp }; lock.unlock()
        }
        return result
    }
    func release() -> Int {
        let result = base.release()
        lock.lock(); inputs.removeAll(); pending.removeAll(); callback = nil; lock.unlock()
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
