import CoreVideo
import Foundation

/// Bounded input/output association shared by the two public WebRTC encoder adapters.
/// Supplements missing color descriptions, preserving native pixels and encoder range.
final class H264InputColorSignalling {
    static let presenterColorKey = "dev.vsmirn0v.presenter.h264-color" as CFString
    static func tagPresenter(_ pixels: CVPixelBuffer) {
        // Qualified against the pinned hardware encoders with independent RGB bars:
        // their app-owned sRGB BGRA conversion uses BT.709 YCbCr. VP8 pixels are unchanged.
        CVBufferSetAttachment(pixels, presenterColorKey, kCFBooleanTrue, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    }
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
    static func color(_ pixels: CVPixelBuffer?) -> H264ColorDescription? {
        guard let pixels else { return nil }
        let format = CVPixelBufferGetPixelFormatType(pixels)
        let yuv = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let presenter = format == kCVPixelFormatType_32BGRA &&
            (CVBufferCopyAttachment(pixels, presenterColorKey, nil) as? NSNumber)?.boolValue == true
        guard yuv || presenter else { return nil }
        func code(_ key: CFString, _ values: [(CFString, UInt8)]) -> UInt8? {
            guard let value = CVBufferCopyAttachment(pixels, key, nil) else { return nil }
            return values.first { CFEqual(value, $0.0) }?.1
        }
        guard let primaries = code(kCVImageBufferColorPrimariesKey, primaries),
              let transfer = code(kCVImageBufferTransferFunctionKey, transfers),
              let matrix = code(kCVImageBufferYCbCrMatrixKey, matrices),
              !presenter || (primaries == 1 && transfer == 13 && matrix == 1) else { return nil }
        return H264ColorDescription(primaries: primaries, transfer: transfer, matrix: matrix)
    }
    /// Device-qualified VideoToolbox BGRA default. This asserts the conversion
    /// matrix only; attachment-free RGB has unknown primaries and transfer.
    static func defaultBGRAMatrix(_ pixels: CVPixelBuffer?) -> H264ColorDescription? {
        guard let pixels, CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
              (CVBufferCopyAttachments(pixels, .shouldPropagate) as? NSDictionary)?.count ?? 0 == 0,
              (CVBufferCopyAttachments(pixels, .shouldNotPropagate) as? NSDictionary)?.count ?? 0 == 0 else { return nil }
        return .init(primaries: 2, transfer: 2, matrix: 1)
    }
    struct Output {
        let data: Data
        fileprivate let input: Input?
    }
    fileprivate struct Input { let color: H264ColorDescription?; let sequence: UInt64 }
    private let lock = NSLock()
    private var inputs: [UInt32: Input] = [:], pending: [UInt32] = []
    private var announced: H264ColorDescription?
    private var sequence: UInt64 = 0, announcedSequence: UInt64 = 0

    func prepare(_ stamp: UInt32, pixels: CVPixelBuffer?, qualifyDefaultBGRA: Bool = false) -> Bool {
        let color = Self.color(pixels) ?? (qualifyDefaultBGRA ? Self.defaultBGRAMatrix(pixels) : nil)
        lock.lock(); defer { lock.unlock() }
        sequence &+= 1
        pending.removeAll { $0 == stamp }; pending.append(stamp)
        inputs[stamp] = Input(color: color, sequence: sequence)
        while pending.count > 64 { inputs.removeValue(forKey: pending.removeFirst()) }
        return announced != color
    }
    func output(_ stamp: UInt32, data: Data, keyframe: Bool) -> Output {
        lock.lock()
        let input = inputs.removeValue(forKey: stamp); pending.removeAll { $0 == stamp }
        lock.unlock()
        let result: Data
        if keyframe, let color = input?.color { result = H264ColorSignalling.applying(color, to: data) }
        else { result = data }
        return Output(data: result, input: keyframe ? input : nil)
    }
    func accepted(_ output: Output) {
        guard let input = output.input else { return }
        lock.lock(); defer { lock.unlock() }
        if input.sequence >= announcedSequence { announced = input.color; announcedSequence = input.sequence }
    }
    func discard(_ stamp: UInt32) { lock.lock(); inputs.removeValue(forKey: stamp); pending.removeAll { $0 == stamp }; lock.unlock() }
    func reset() { lock.lock(); inputs.removeAll(); pending.removeAll(); announced = nil; announcedSequence = 0; sequence = 0; lock.unlock() }
}
