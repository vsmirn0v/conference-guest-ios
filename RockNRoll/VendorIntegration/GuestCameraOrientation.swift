import AVFoundation
import VideoToolbox
import WebRTC

/// Bake RTC rotation into native NV12 before WebRTC's software rotation strips
/// its range/color attachments. The existing hardware encoder receives NV12.
final class GuestCameraOrientation {
    enum Output { case frame(RTCVideoFrame), backpressure, unsupported }
    private let lock = NSLock()
    private var session: VTPixelRotationSession?
    private var pool: CVPixelBufferPool?
    private var size = CGSize.zero
    private var format: OSType = 0
    private var rotation: RTCVideoRotation?
    #if DEBUG
    private static let observerLock = NSLock()
    private static var observer: ((RTCVideoFrame, RTCVideoFrame) -> Void)?
    static func observeForTesting(_ value: ((RTCVideoFrame, RTCVideoFrame) -> Void)?) {
        observerLock.lock(); observer = value; observerLock.unlock()
    }
    #endif
    func orient(_ frame: RTCVideoFrame) -> Output {
        guard frame.rotation != ._0 else { return .frame(frame) }
        guard let native = frame.buffer as? RTCCVPixelBuffer,
              !native.requiresCropping(),
              Int(native.width) == CVPixelBufferGetWidth(native.pixelBuffer),
              Int(native.height) == CVPixelBufferGetHeight(native.pixelBuffer),
              GuestH264ColorEncoder.nativeColor(for: frame) != nil else { return .unsupported }
        let source = native.pixelBuffer
        let turns = frame.rotation == ._90 || frame.rotation == ._270
        let width = turns ? CVPixelBufferGetHeight(source) : CVPixelBufferGetWidth(source)
        let height = turns ? CVPixelBufferGetWidth(source) : CVPixelBufferGetHeight(source)
        let dimensions = CGSize(width: width, height: height), pixelFormat = CVPixelBufferGetPixelFormatType(source)
        let result: Output = {
            lock.lock(); defer { lock.unlock() }
            if session == nil, VTPixelRotationSessionCreate(nil, &session) != noErr { return .unsupported }
            guard let session else { return .unsupported }
            if rotation != frame.rotation {
                let value: CFString
                switch frame.rotation {
                case ._90: value = kVTRotation_CW90
                case ._180: value = kVTRotation_180
                case ._270: value = kVTRotation_CCW90
                default: return .unsupported
                }
                guard VTSessionSetProperty(session, key: kVTPixelRotationPropertyKey_Rotation, value: value) == noErr else { return .unsupported }
                rotation = frame.rotation
            }
            if pool == nil || size != dimensions || format != pixelFormat {
                pool = nil; size = dimensions; format = pixelFormat
                let attributes: [CFString: Any] = [kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
                    kCVPixelBufferPixelFormatTypeKey: pixelFormat, kCVPixelBufferIOSurfacePropertiesKey: [:]]
                guard CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool) == kCVReturnSuccess else { return .unsupported }
            }
            guard let pool else { return .unsupported }
            var pixels: CVPixelBuffer?
            let status = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
                [kCVPixelBufferPoolAllocationThresholdKey: 8] as CFDictionary, &pixels)
            if status == kCVReturnWouldExceedAllocationThreshold { return .backpressure }
            guard status == kCVReturnSuccess, let pixels,
                  VTPixelRotationSessionRotateImage(session, source, pixels) == noErr else { return .unsupported }
            let result = RTCVideoFrame(buffer: RTCCVPixelBuffer(pixelBuffer: pixels), rotation: ._0, timeStampNs: frame.timeStampNs)
            result.timeStamp = frame.timeStamp
            return .frame(result)
        }()
        #if DEBUG
        Self.observerLock.lock(); let callback = Self.observer; Self.observerLock.unlock()
        if case .frame(let output) = result { callback?(frame, output) }
        #endif
        return result
    }
    deinit { if let session { VTPixelRotationSessionInvalidate(session) } }
}
