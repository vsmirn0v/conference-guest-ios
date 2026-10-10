import CoreMedia
import VideoToolbox

/// Camera pixels only. A bounded native pool keeps the cap independent of an
/// SDK-owned source's format requests, without converting NV12 through I420.
/// Each owner calls this on its serial frame-processing queue.
final class CameraPixelScaler {
    /// Encoder reference frames, local preview and PiP can retain more than a
    /// triple buffer. Eight 720p NV12 surfaces remain bounded (~11 MiB), without
    /// starving a hardware encoder that needs the next frame to make progress.
    static let maximumRetainedBuffers = 8
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: String?
    #if DEBUG
    private let diagnosticLock = NSLock()
    private var allocationFailures = 0
    private var transferFailures = 0
    private var lastStatus: Int32 = 0
    var diagnostics: [String: Any] {
        diagnosticLock.lock(); defer { diagnosticLock.unlock() }
        return ["allocationFailures": allocationFailures, "transferFailures": transferFailures, "lastStatus": lastStatus]
    }
    #endif

    func scale(_ source: CVPixelBuffer, maximum: CMVideoDimensions) -> CVPixelBuffer? {
        let input = CMVideoDimensions(width: Int32(CVPixelBufferGetWidth(source)), height: Int32(CVPixelBufferGetHeight(source)))
        let size = CameraQualityPolicy.bounded(input, maximum: maximum)
        guard size.width > 0, size.height > 0 else { return nil }
        if input.width == size.width && input.height == size.height { return source }
        if transfer == nil {
            var value: VTPixelTransferSession?
            guard VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &value) == noErr else { return nil }
            transfer = value
            if let value { VTSessionSetProperty(value, key: kVTPixelTransferPropertyKey_ScalingMode, value: kVTScalingMode_Normal) }
        }
        let format = CVPixelBufferGetPixelFormatType(source)
        let key = "\(size.width)x\(size.height)/\(format)"
        if poolKey != key {
            pool = nil; poolKey = nil
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferPixelFormatTypeKey: format, kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
            poolKey = key
        }
        var output: CVPixelBuffer?
        guard let pool, let transfer else { return nil }
        let allocation = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: Self.maximumRetainedBuffers] as CFDictionary, &output)
        guard allocation == kCVReturnSuccess, let output else {
            #if DEBUG
            diagnosticLock.lock(); allocationFailures += 1; lastStatus = allocation; diagnosticLock.unlock()
            #endif
            return nil
        }
        CVBufferRemoveAllAttachments(output); CVBufferPropagateAttachments(source, output)
        CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
        let status = VTPixelTransferSessionTransferImage(transfer, from: source, to: output)
        guard status == noErr else {
            #if DEBUG
            diagnosticLock.lock(); transferFailures += 1; lastStatus = status; diagnosticLock.unlock()
            #endif
            return nil
        }
        return output
    }
    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }
}
