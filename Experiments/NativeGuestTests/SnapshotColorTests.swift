import CoreImage
import CoreVideo
import Foundation
import ImageIO
import LiveKitWebRTC

private enum SnapshotTestError: Error { case assertion(String) }

/// Synthetic color bars only: no capture, device, conference or network.
@main struct SnapshotColorTests {
    static let colors: [[Double]] = [[20,204,71], [224,60,120], [40,60,220],
                                     [16,16,16], [235,235,235], [128,128,128]]
    static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    static let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw SnapshotTestError.assertion(message) }
    }
    static func byte(_ value: Double) -> UInt8 { UInt8(max(0, min(255, value.rounded()))) }

    // Independent forward matrix generates encoded samples from known RGB bars.
    // Production snapshot code must recover the known RGB, not compare with a
    // second invocation of its own converter or hardcoded inverse coefficients.
    static func samples(_ rgb: [Double], full: Bool, rec709: Bool) -> [UInt8] {
        let kr = rec709 ? 0.2126 : 0.299, kb = rec709 ? 0.0722 : 0.114
        let y = kr * rgb[0] + (1 - kr - kb) * rgb[1] + kb * rgb[2]
        let cb = (rgb[2] - y) / (2 * (1 - kb)), cr = (rgb[0] - y) / (2 * (1 - kr))
        return full ? [byte(y), byte(128 + cb), byte(128 + cr)] :
            [byte(16 + y * 219 / 255), byte(128 + cb * 224 / 255), byte(128 + cr * 224 / 255)]
    }
    static func pixels(full: Bool, rec709: Bool, transfer: CFString) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        let format = full ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        try require(CVPixelBufferCreate(nil, 96, 32, format,
                    [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &value) == kCVReturnSuccess,
                    "NV12 fixture allocation")
        let pixels = value!
        CVBufferSetAttachment(pixels, kCVImageBufferYCbCrMatrixKey,
                              rec709 ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(pixels, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
        CVPixelBufferLockBaseAddress(pixels, []); defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let y = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)!.assumingMemoryBound(to: UInt8.self)
        let uv = CVPixelBufferGetBaseAddressOfPlane(pixels, 1)!.assumingMemoryBound(to: UInt8.self)
        let ys = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0), uvs = CVPixelBufferGetBytesPerRowOfPlane(pixels, 1)
        for row in 0..<32 { for column in 0..<96 { y[row * ys + column] = samples(colors[column / 16], full: full, rec709: rec709)[0] } }
        for row in 0..<16 { for column in 0..<48 {
            let sample = samples(colors[column / 8], full: full, rec709: rec709)
            uv[row * uvs + column * 2] = sample[1]; uv[row * uvs + column * 2 + 1] = sample[2]
        } }
        return pixels
    }
    static func check(_ frame: LKRTCVideoFrame, expected: [[Double]], name: String, output: URL) throws -> [String: Any] {
        let counter = GuestFrameCounter(verifyPixels: false)
        counter.renderFrame(frame)
        let file = output.appendingPathComponent(name + ".png")
        try counter.savePNG(file.path)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw SnapshotTestError.assertion("PNG decode") }
        try require(cg.width == Int(frame.width) && cg.height == Int(frame.height), "Snapshot dimensions changed")
        try require(cg.colorSpace?.model == .rgb, "Snapshot lacks RGB color profile")
        let permission = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        try require(permission.map { $0 & 0o777 == 0o600 } == true, "Snapshot lost private permissions")
        let image = CIImage(cgImage: cg)
        var decoded: [[Int]] = [], maxError = 0.0
        for (index, rgb) in expected.enumerated() {
            var pixel = [UInt8](repeating: 0, count: 4)
            let x = (Double(index) + 0.5) * Double(cg.width) / Double(expected.count)
            context.render(image, toBitmap: &pixel, rowBytes: 4,
                bounds: CGRect(x: x, y: Double(cg.height) / 2, width: 1, height: 1), format: .RGBA8, colorSpace: space)
            decoded.append(pixel.prefix(3).map(Int.init))
            for channel in 0..<3 { maxError = max(maxError, abs(Double(pixel[channel]) - rgb[channel])) }
        }
        print("\(name): max RGB error \(maxError), green bar \(decoded.first!)")
        try require(maxError <= 4, "\(name) exceeds independent RGB tolerance (\(maxError) > 4)")
        return ["case": name, "maximumRGBError": maxError, "decodedRGB": decoded,
                "width": cg.width, "height": cg.height, "pass": true]
    }
    static func main() throws {
        setbuf(stdout, nil)
        guard CommandLine.arguments.count == 2 else { throw SnapshotTestError.assertion("Pass output directory") }
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var rows: [[String: Any]] = []
        for full in [false, true] { for rec709 in [false, true] {
            let input = try pixels(full: full, rec709: rec709, transfer: kCVImageBufferTransferFunction_sRGB)
            let label = "\(full ? "full" : "video")-\(rec709 ? "709" : "601")"
            let wrapped = LKRTCCVPixelBuffer(pixelBuffer: input)
            rows.append(try check(LKRTCVideoFrame(buffer: wrapped, rotation: ._0, timeStampNs: 1),
                                  expected: colors, name: label, output: output))
            let cropped = LKRTCCVPixelBuffer(pixelBuffer: input, adaptedWidth: 32, adaptedHeight: 16,
                                            cropWidth: 64, cropHeight: 32, cropX: 16, cropY: 0)
            rows.append(try check(LKRTCVideoFrame(buffer: cropped, rotation: ._0, timeStampNs: 2),
                                  expected: Array(colors[1..<5]), name: label + "-cropped-scaled", output: output))
        } }
        // Generic I420 has no color metadata. Check the companion's documented
        // video-range601/709-transfer fallback against the original explicitly
        // tagged source, using Core Image's actual platform color management.
        // The eight native cases above independently recover known sRGB bars.
        let original = try pixels(full: false, rec709: false, transfer: kCVImageBufferTransferFunction_ITU_R_709_2)
        let reference = CIImage(cvPixelBuffer: original)
        let managedRGB: [[Double]] = (0..<colors.count).map { index in
            var rgba = [UInt8](repeating: 0, count: 4)
            context.render(reference, toBitmap: &rgba, rowBytes: 4,
                           bounds: CGRect(x: index * 16 + 8, y: 16, width: 1, height: 1), format: .RGBA8, colorSpace: space)
            return rgba.prefix(3).map(Double.init)
        }
        let generic = LKRTCCVPixelBuffer(pixelBuffer: original).toI420()
        rows.append(try check(LKRTCVideoFrame(buffer: generic, rotation: ._0, timeStampNs: 3),
                              expected: managedRGB, name: "planar-video-601-709transfer", output: output))
        try JSONSerialization.data(withJSONObject: ["passed": true, "cases": rows], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("result.json"))
        print("PASS: 9 snapshot controls; full/video range, 601/709 matrices, native crop/scale, planar fallback, sRGB and private PNG")
    }
}
