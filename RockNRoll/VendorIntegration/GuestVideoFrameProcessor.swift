import AVFoundation
import Foundation
import QuartzCore
import WebRTC

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

    private func pixelBuffer(for frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let native = frame.buffer as? RTCCVPixelBuffer,
           native.cropX == 0, native.cropY == 0,
           Int(native.cropWidth) == CVPixelBufferGetWidth(native.pixelBuffer),
           Int(native.cropHeight) == CVPixelBufferGetHeight(native.pixelBuffer),
           CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
           CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) {
            return native.pixelBuffer
        }
        let source = frame.buffer.toI420()
        let width = Int(source.width), height = Int(source.height)
        guard width > 0, height > 0 else { return nil }
        let size = CGSize(width: width, height: height)
        let sourcePixelFormat = (frame.buffer as? RTCCVPixelBuffer)
            .map { CVPixelBufferGetPixelFormatType($0.pixelBuffer) }
        let pixelFormat = sourcePixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        if pool == nil || size != poolSize || poolPixelFormat != pixelFormat {
            pool = nil
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: pixelFormat,
                kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:]
            ]
            guard CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
                == kCVReturnSuccess else { return nil }
            poolSize = size
            poolPixelFormat = pixelFormat
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        let limit = [kCVPixelBufferPoolAllocationThresholdKey: 4] as CFDictionary
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, limit, &output)
            == kCVReturnSuccess, let output else { return nil }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(output, 0),
              let uv = CVPixelBufferGetBaseAddressOfPlane(output, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
        let uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
        for row in 0..<height {
            memcpy(y.advanced(by: row * yStride), source.dataY.advanced(by: row * Int(source.strideY)), width)
        }
        for row in 0..<((height + 1) / 2) {
            let destination = uv.advanced(by: row * uvStride).assumingMemoryBound(to: UInt8.self)
            let u = source.dataU.advanced(by: row * Int(source.strideU))
            let v = source.dataV.advanced(by: row * Int(source.strideV))
            for column in 0..<((width + 1) / 2) {
                destination[column * 2] = u[column]
                destination[column * 2 + 1] = v[column]
            }
        }
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
}
