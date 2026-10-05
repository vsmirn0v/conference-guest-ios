import AVFoundation
import Foundation
import QuartzCore
import WebRTC
#if DEBUG
import Accelerate
import VideoToolbox

/// Experimental conversion paths are opt-in and excluded from distribution builds.
enum GuestVideoConversionExperiment: String, CaseIterable, Hashable {
    case reference, cachedPlanes, accelerate, nativeCopy, nativeTransfer
}
#endif

/// Converts at most one frame at a time and keeps only the newest waiting frame.
/// Limits output to 30 fps inline or 15 fps in floating video.
/// All pixels remain in memory. Generation checks discard frames from a prior room.
final class GuestVideoFrameProcessor: @unchecked Sendable {
    var onSample: (@MainActor (CMSampleBuffer, CGSize, Int) -> Void)?
    private let queue = DispatchQueue(label: "dev.vsmirn0v.conferenceguest.floating-frames")
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var sourceID = UUID()
    private var enabled = false
    private var busy = false
    private var nextFrameTime: CFTimeInterval = 0
    private var frameInterval: CFTimeInterval = 1.0 / 30
    private var pendingFrame: RTCVideoFrame?
    private var drainScheduled = false
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var poolPixelFormat: OSType = 0
#if DEBUG
    private let experiment: GuestVideoConversionExperiment
    private var transferSession: VTPixelTransferSession?
    var onDeliveryForTesting: (@MainActor (Int64) -> Void)?
    private var nativeConversionCount = 0
    var experimentalNativeConversions: Int {
        lock.lock(); defer { lock.unlock() }; return nativeConversionCount
    }

    init(experiment: GuestVideoConversionExperiment = .reference) {
        self.experiment = experiment
    }
    deinit { if let transferSession { VTPixelTransferSessionInvalidate(transferSession) } }
#endif

    func setEnabled(_ enabled: Bool) {
        lock.lock()
        generation &+= 1
        self.enabled = enabled
        busy = false
        nextFrameTime = 0
        pendingFrame = nil
        drainScheduled = false
        lock.unlock()
    }

    func replaceSource() -> UUID {
        lock.lock(); defer { lock.unlock() }
        sourceID = UUID()
        generation &+= 1
        enabled = false
        busy = false
        nextFrameTime = 0
        pendingFrame = nil
        drainScheduled = false
        return sourceID
    }

    func setFrameRate(_ framesPerSecond: Int) {
        lock.lock()
        frameInterval = 1.0 / Double(max(framesPerSecond, 1))
        lock.unlock()
    }

    func submit(_ frame: RTCVideoFrame, source: UUID? = nil) {
        lock.lock()
        guard (source == nil || source == sourceID), enabled else { lock.unlock(); return }
        pendingFrame = frame
        lock.unlock()
        drainPendingFrame()
    }

    private func drainPendingFrame() {
        lock.lock()
        guard enabled, !busy, let frame = pendingFrame else { lock.unlock(); return }
        let now = CACurrentMediaTime()
        if now < nextFrameTime {
            if !drainScheduled {
                drainScheduled = true
                let expected = generation
                DispatchQueue.main.asyncAfter(deadline: .now() + (nextFrameTime - now)) { [weak self] in
                    self?.drainScheduledFrame(generation: expected)
                }
            }
            lock.unlock()
            return
        }
        pendingFrame = nil
        busy = true
        nextFrameTime = now + frameInterval
        let expected = generation
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let current = self.enabled && self.generation == expected
            self.lock.unlock()
            guard current else { return }
            let sample = self.makeSample(frame)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let current = self.enabled && self.generation == expected
                if current { self.busy = false }
                self.lock.unlock()
                guard current else { return }
                if let sample {
#if DEBUG
                    self.onDeliveryForTesting?(frame.timeStampNs)
#endif
                    self.onSample?(sample, CGSize(width: Int(frame.width), height: Int(frame.height)),
                                   frame.rotation.rawValue)
                }
                self.drainPendingFrame()
            }
        }
    }

    private func drainScheduledFrame(generation expected: UInt64) {
        lock.lock()
        guard enabled && generation == expected else { lock.unlock(); return }
        drainScheduled = false
        lock.unlock()
        drainPendingFrame()
    }

    private func makeSample(_ frame: RTCVideoFrame) -> CMSampleBuffer? {
        guard let pixelBuffer = pixelBuffer(for: frame) else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
            presentationTimeStamp: CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer, formatDescription: format, sampleTiming: &timing,
            sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let native = frame.buffer as? RTCCVPixelBuffer,
           native.cropX == 0, native.cropY == 0,
           Int(native.cropWidth) == CVPixelBufferGetWidth(native.pixelBuffer),
           Int(native.cropHeight) == CVPixelBufferGetHeight(native.pixelBuffer),
           CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
           CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) {
            return native.pixelBuffer
        }
#if DEBUG
        if let native = frame.buffer as? RTCCVPixelBuffer,
           experiment == .nativeCopy || experiment == .nativeTransfer,
           let converted = convertNativeCrop(native) {
            lock.lock(); nativeConversionCount += 1; lock.unlock()
            return converted
        }
#endif
        let source = frame.buffer.toI420()
        let width = Int(source.width), height = Int(source.height)
        guard width > 0, height > 0 else { return nil }
        let sourcePixelFormat = (frame.buffer as? RTCCVPixelBuffer)
            .map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
        let pixelFormat = sourcePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard let output = pooledBuffer(width: width, height: height, format: pixelFormat) else { return nil }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(output, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(output, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
#if DEBUG
        if experiment == .cachedPlanes {
            copyCachedPlanes(source, y: y, uv: uv, yStride: yStride, uvStride: uvStride)
        } else {
            for row in 0..<height {
                memcpy(y.advanced(by: row * yStride), source.dataY.advanced(by: row * Int(source.strideY)), width)
            }
            if experiment == .accelerate {
                guard interleaveWithAccelerate(source, destination: uv, stride: uvStride) else { return nil }
            } else {
                interleave(source, destination: uv, stride: uvStride)
            }
        }
#else
        for row in 0..<height {
            memcpy(y.advanced(by: row * yStride), source.dataY.advanced(by: row * Int(source.strideY)), width)
        }
        interleave(source, destination: uv, stride: uvStride)
#endif
        CVBufferRemoveAllAttachments(output)
        if let native = frame.buffer as? RTCCVPixelBuffer,
           sourcePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
           sourcePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange {
            CVBufferPropagateAttachments(native.pixelBuffer, output)
        } else {
            CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey,
                                  kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey,
                                  kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                                  kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        }
        return output
    }

    private func pooledBuffer(width: Int, height: Int, format: OSType) -> CVPixelBuffer? {
        let size = CGSize(width: width, height: height)
        if pool == nil || size != poolSize || poolPixelFormat != format {
            pool = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
                == kCVReturnSuccess else { return nil }
            poolSize = size
            poolPixelFormat = format
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &output)
            == kCVReturnSuccess, let output else { return nil }
        return output
    }

    private func interleave(_ source: RTCI420BufferProtocol, destination: UnsafeMutableRawPointer, stride: Int) {
        for row in 0..<((Int(source.height) + 1) / 2) {
            let destination = destination.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            let u = source.dataU.advanced(by: row * Int(source.strideU))
            let v = source.dataV.advanced(by: row * Int(source.strideV))
            for column in 0..<((Int(source.width) + 1) / 2) {
                destination[column * 2] = u[column]
                destination[column * 2 + 1] = v[column]
            }
        }
    }

#if DEBUG
    private func copyCachedPlanes(_ source: RTCI420BufferProtocol, y: UnsafeMutableRawPointer,
                                  uv: UnsafeMutableRawPointer, yStride: Int, uvStride: Int) {
        let width = Int(source.width), height = Int(source.height)
        let chromaWidth = (width + 1) / 2, chromaHeight = (height + 1) / 2
        let dataY = source.dataY, dataU = source.dataU, dataV = source.dataV
        let sourceYStride = Int(source.strideY), sourceUStride = Int(source.strideU)
        let sourceVStride = Int(source.strideV)
        for row in 0..<height {
            memcpy(y.advanced(by: row * yStride), dataY.advanced(by: row * sourceYStride), width)
        }
        for row in 0..<chromaHeight {
            let destination = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            let u = dataU.advanced(by: row * sourceUStride), v = dataV.advanced(by: row * sourceVStride)
            for column in 0..<chromaWidth {
                destination[column * 2] = u[column]
                destination[column * 2 + 1] = v[column]
            }
        }
    }

    private func interleaveWithAccelerate(_ source: RTCI420BufferProtocol, destination: UnsafeMutableRawPointer,
                                         stride: Int) -> Bool {
        let width = (Int(source.width) + 1) / 2, height = (Int(source.height) + 1) / 2
        var u = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.dataU), height: UInt(height),
                              width: UInt(width), rowBytes: Int(source.strideU))
        var v = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: source.dataV), height: UInt(height),
                              width: UInt(width), rowBytes: Int(source.strideV))
        return withUnsafePointer(to: &u) { up in withUnsafePointer(to: &v) { vp in
            var inputs: [UnsafePointer<vImage_Buffer>?] = [up, vp]
            var outputs: [UnsafeMutableRawPointer?] = [destination, destination.advanced(by: 1)]
            return vImageConvert_PlanarToChunky8(&inputs, &outputs, 2, 2, UInt(width), UInt(height),
                                               stride, vImage_Flags(kvImageDoNotTile)) == kvImageNoError
        }}
    }

    private func convertNativeCrop(_ native: RTCCVPixelBuffer) -> CVPixelBuffer? {
        let input = native.pixelBuffer
        let format = CVPixelBufferGetPixelFormatType(input)
        let x = Int(native.cropX), y = Int(native.cropY)
        let width = Int(native.cropWidth), height = Int(native.cropHeight)
        guard format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
              format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              x >= 0, y >= 0, width > 0, height > 0, x % 2 == 0, y % 2 == 0,
              x + width <= CVPixelBufferGetWidth(input), y + height <= CVPixelBufferGetHeight(input),
              CVPixelBufferGetPlaneCount(input) == 2,
              experiment == .nativeTransfer || (width == Int(native.width) && height == Int(native.height)),
              experiment != .nativeTransfer ||
                (width % 2 == 0 && height % 2 == 0 && native.width % 2 == 0 && native.height % 2 == 0),
              let output = pooledBuffer(width: Int(native.width), height: Int(native.height), format: format),
              CVPixelBufferLockBaseAddress(input, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(input, .readOnly) }
        guard let baseY = CVPixelBufferGetBaseAddressOfPlane(input, 0),
              let baseUV = CVPixelBufferGetBaseAddressOfPlane(input, 1) else { return nil }
        let strideY = CVPixelBufferGetBytesPerRowOfPlane(input, 0)
        let strideUV = CVPixelBufferGetBytesPerRowOfPlane(input, 1)
        let croppedY = baseY.advanced(by: y * strideY + x)
        let croppedUV = baseUV.advanced(by: y / 2 * strideUV + x)
        if experiment == .nativeCopy {
            guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
            defer { CVPixelBufferUnlockBaseAddress(output, []) }
            guard let outY = CVPixelBufferGetBaseAddressOfPlane(output, 0),
                  let outUV = CVPixelBufferGetBaseAddressOfPlane(output, 1) else { return nil }
            for row in 0..<height {
                memcpy(outY.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(output, 0)),
                       croppedY.advanced(by: row * strideY), width)
            }
            for row in 0..<((height + 1) / 2) {
                memcpy(outUV.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(output, 1)),
                       croppedUV.advanced(by: row * strideUV), 2 * ((width + 1) / 2))
            }
        } else {
            // VideoToolbox's NV12 transfer leaves incomplete chroma for odd extents.
            // Those inputs take the reference path above rather than losing edge pixels.
            if transferSession == nil {
                var created: VTPixelTransferSession?
                guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &created)
                    == noErr, let created else { return nil }
                transferSession = created
            }
            guard let transferSession else { return nil }
            // The wrapper borrows the locked source planes until the synchronous transfer returns.
            var addresses: [UnsafeMutableRawPointer?] = [croppedY, croppedUV]
            var widths = [width, (width + 1) / 2], heights = [height, (height + 1) / 2]
            var strides = [strideY, strideUV]
            var view: CVPixelBuffer?
            guard CVPixelBufferCreateWithPlanarBytes(nil, width, height, format, nil, 0, 2,
                &addresses, &widths, &heights, &strides, nil, nil, nil, &view) == kCVReturnSuccess,
                let view else { return nil }
            CVBufferPropagateAttachments(input, view)
            CVBufferRemoveAttachment(view, kCVImageBufferCleanApertureKey)
            CVBufferRemoveAllAttachments(output)
            CVBufferPropagateAttachments(input, output)
            guard VTPixelTransferSessionTransferImage(transferSession, from: view, to: output) == noErr
                else { return nil }
        }
        CVBufferRemoveAllAttachments(output)
        CVBufferPropagateAttachments(input, output)
        return output
    }
#endif
}
