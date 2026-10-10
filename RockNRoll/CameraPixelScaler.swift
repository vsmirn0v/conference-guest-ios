import CoreMedia
import VideoToolbox

/// Camera pixels only. A bounded native pool keeps the cap independent of an
/// SDK-owned source's format requests, without converting NV12 through I420.
/// Each owner calls this on its serial frame-processing queue.
final class CameraPixelScaler {
    private var transfer: VTPixelTransferSession?
    private var pool: CVPixelBufferPool?
    private var poolKey: String?

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
        guard let pool, let transfer,
              CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &output) == kCVReturnSuccess,
              let output else { return nil }
        CVBufferRemoveAllAttachments(output); CVBufferPropagateAttachments(source, output)
        CVBufferRemoveAttachment(output, kCVImageBufferCleanApertureKey)
        guard VTPixelTransferSessionTransferImage(transfer, from: source, to: output) == noErr else { return nil }
        return output
    }
    deinit { if let transfer { VTPixelTransferSessionInvalidate(transfer) } }
}
