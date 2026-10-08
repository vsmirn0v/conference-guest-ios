import CoreVideo
import LiveKitWebRTC

/// Queue-confined converter for WebRTC's native CV buffers and planar VP8 output.
final class NativeVideoPixelBuffer {
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    func convert(_ frame: LKRTCVideoFrame, region: CGRect? = nil) -> CVPixelBuffer? {
        if region == nil, let native = frame.buffer as? LKRTCCVPixelBuffer,
           native.cropX == 0, native.cropY == 0,
           native.cropWidth == native.width, native.cropHeight == native.height,
           CVPixelBufferGetWidth(native.pixelBuffer) == Int(frame.width),
           CVPixelBufferGetHeight(native.pixelBuffer) == Int(frame.height) { return native.pixelBuffer }
        let source = frame.buffer.toI420()
        let fullWidth = Int(source.width), fullHeight = Int(source.height)
        var x = 0, y = 0, width = fullWidth, height = fullHeight
        if let region {
            guard !region.isNull, !region.isEmpty, [region.minX, region.minY, region.width, region.height].allSatisfy(\.isFinite),
                  region.minX >= 0, region.minY >= 0, region.maxX <= 1.001, region.maxY <= 1.001 else { return nil }
            x = Int(region.minX * CGFloat(fullWidth)) / 2 * 2
            y = Int(region.minY * CGFloat(fullHeight)) / 2 * 2
            width = min(fullWidth - x, Int(region.width * CGFloat(fullWidth))) / 2 * 2
            height = min(fullHeight - y, Int(region.height * CGFloat(fullHeight))) / 2 * 2
        }
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
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(result, 0), let uv = CVPixelBufferGetBaseAddressOfPlane(result, 1) else { return nil }
        let yStride = CVPixelBufferGetBytesPerRowOfPlane(result, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(result, 1)
        for row in 0..<height { memcpy(luma.advanced(by: row * yStride), source.dataY.advanced(by: (row + y) * Int(source.strideY) + x), width) }
        let destination = uv.assumingMemoryBound(to: UInt8.self)
        for row in 0..<(height + 1) / 2 {
            for column in 0..<(width + 1) / 2 {
                destination[row * uvStride + column * 2] = source.dataU[(row + y / 2) * Int(source.strideU) + column + x / 2]
                destination[row * uvStride + column * 2 + 1] = source.dataV[(row + y / 2) * Int(source.strideV) + column + x / 2]
            }
        }
        CVBufferRemoveAllAttachments(result)
        CVBufferSetAttachment(result, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(result, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        return result
    }
}
