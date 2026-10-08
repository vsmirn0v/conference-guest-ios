import CoreVideo
import LiveKitWebRTC

/// Queue-confined converter for WebRTC's native CV buffers and planar VP8 output.
final class NativeVideoPixelBuffer {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    func convert(_ frame: LKRTCVideoFrame) -> CVPixelBuffer? {
        if let native = frame.buffer as? LKRTCCVPixelBuffer,
           native.cropX == 0, native.cropY == 0,
           native.cropWidth == native.width, native.cropHeight == native.height,
           CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
           CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) { return native.pixelBuffer }
        let source = frame.buffer.toI420()
        let width = Int(source.width), height = Int(source.height)
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let dimensions = CGSize(width: width, height: height)
        if pool == nil || size != dimensions {
            size = dimensions
            let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey: [:]]
            guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return nil }
        }
        var result: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 6] as CFDictionary, &result) == kCVReturnSuccess, let result else { return nil }
        CVPixelBufferLockBaseAddress(result, []); defer { CVPixelBufferUnlockBaseAddress(result, []) }
        guard let y = CVPixelBufferGetBaseAddressOfPlane(result, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(result, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(result, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(result, 1)
        for row in 0..<height { memcpy(y.advanced(by: row * yStride), source.dataY.advanced(by: row * Int(source.strideY)), width) }
        let destination = uv.assumingMemoryBound(to: UInt8.self)
        for row in 0..<Int(source.chromaHeight) {
            for column in 0..<Int(source.chromaWidth) {
                destination[row * uvStride + column * 2] = source.dataU[row * Int(source.strideU) + column]
                destination[row * uvStride + column * 2 + 1] = source.dataV[row * Int(source.strideV) + column]
            }
        }
        CVBufferRemoveAllAttachments(result)
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return result
    }
}
