import CoreImage
import CoreMedia
import ImageIO
import Metal
import Vision

struct PresenterScene {
    enum Layout: String, CaseIterable { case card, cutout, instrument, beside }
    enum Backdrop: String, CaseIterable { case dark, warm, stage }
    var layout: Layout = .card
    var backdrop: Backdrop = .dark
    var image: CGImage?
    var strokes: [[CGPoint]] = []
    var zoom: CGFloat = 1
    var focus = CGPoint(x: 0.5, y: 0.5)
    var speaking = false
    var cameraRotation = 0
    var placement = PresenterPlacement()
    var draftStroke: [CGPoint] = []
}

/// Top-left normalized geometry shared by the editor, persistence and renderer.
/// Capture consent and media are deliberately excluded from this value.
struct PresenterPlacement: Codable, Equatable {
    var x: CGFloat = 0.72
    var y: CGFloat = 0.56
    var width: CGFloat = 0.25
    var height: CGFloat = 0.40
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
    mutating func clamp() {
        width = min(0.8, max(0.12, width.isFinite ? width : 0.25))
        height = min(0.9, max(0.12, height.isFinite ? height : 0.4))
        x = min(1 - width, max(0, x.isFinite ? x : 0.72))
        y = min(1 - height, max(0, y.isFinite ? y : 0.56))
    }
    func pixels(in size: CGSize) -> CGRect {
        var safe = self; safe.clamp()
        return CGRect(x: safe.x * size.width, y: (1 - safe.y - safe.height) * size.height,
                      width: safe.width * size.width, height: safe.height * size.height)
    }
    mutating func resize(_ factor: CGFloat) {
        let center = CGPoint(x: x + width / 2, y: y + height / 2)
        width *= factor; height *= factor; clamp()
        x = center.x - width / 2; y = center.y - height / 2; clamp()
    }
}

/// Used by local preview and outgoing sharing. The worker owns this instance;
/// no CI/Vision objects are accessed concurrently, and buffers come from a pool.
// Sendability relies on the owner's serial worker, including deferred teardown.
final class PresenterCompositor: @unchecked Sendable {
    let size: CGSize
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let context: CIContext
    private var pool: CVPixelBufferPool?
    private let segmentation = VNGeneratePersonSegmentationRequest()
    private var cachedStrokes: [[CGPoint]] = []
    private var annotation: CIImage?
    private let personMask: ((CVPixelBuffer, CGImagePropertyOrientation) throws -> CVPixelBuffer?)?

    init(size: CGSize = CGSize(width: 1280, height: 720), software: Bool = false,
         personMask: ((CVPixelBuffer, CGImagePropertyOrientation) throws -> CVPixelBuffer?)? = nil) {
        self.size = size
        self.personMask = personMask
        let options: [CIContextOption: Any] = [.cacheIntermediates: false,
            .workingColorSpace: colorSpace, .outputColorSpace: colorSpace]
        if !software, let device = MTLCreateSystemDefaultDevice() { context = CIContext(mtlDevice: device, options: options) }
        else { context = CIContext(options: options.merging([.useSoftwareRenderer: true]) { _, new in new }) }
        segmentation.qualityLevel = .balanced
        segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
        CVPixelBufferPoolCreate(nil, nil, [
            kCVPixelBufferWidthKey: Int(size.width), kCVPixelBufferHeightKey: Int(size.height),
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true
        ] as CFDictionary, &pool)
    }

    func render(scene: PresenterScene, camera: CVPixelBuffer?, screen: CVPixelBuffer? = nil, rotation: Int = 0,
                time: CMTime) -> CMSampleBuffer? {
        let bounds = CGRect(origin: .zero, size: size)
        let contentBounds = scene.layout == .beside && camera != nil ?
            CGRect(x: 0, y: 0, width: size.width * 0.72, height: size.height) : bounds
        var canvas = background(scene, bounds: bounds, contentBounds: contentBounds)
        if let screen { canvas = fit(CIImage(cvPixelBuffer: screen), into: contentBounds, fill: false).composited(over: canvas) }
        if let camera {
            let rotation = (rotation + scene.cameraRotation) % 360
            var input = CIImage(cvPixelBuffer: camera)
            switch rotation {
            case 90: input = input.oriented(.right)
            case 180: input = input.oriented(.down)
            case 270: input = input.oriented(.left)
            default: break
            }
            input = input.transformed(by: CGAffineTransform(translationX: -input.extent.minX, y: -input.extent.minY))
            let card = scene.placement.pixels(in: size)
            switch scene.layout {
            case .card, .beside:
                let card = scene.layout == .beside ? CGRect(x: size.width * 0.74, y: size.height * 0.08,
                    width: size.width * 0.24, height: size.height * 0.84) : card
                canvas = fit(input, into: card, fill: false).composited(over: canvas)
            case .instrument:
                let crop = Self.instrumentCrop(extent: input.extent, zoom: scene.zoom, focus: scene.focus)
                let target = card
                canvas = fit(input.cropped(to: crop), into: target, fill: false).composited(over: canvas)
            case .cutout:
                // No cached mask from another person/frame. If Vision cannot protect
                // the room, omit the entire camera card rather than send raw pixels.
                if let person = cutout(input, pixels: camera, rotation: rotation) {
                    let target = card
                    canvas = fit(person, into: target, fill: false).composited(over: canvas)
                }
            }
        }
        let strokes = scene.strokes + (scene.draftStroke.isEmpty ? [] : [scene.draftStroke])
        if strokes != cachedStrokes {
            cachedStrokes = strokes
            annotation = drawStrokes(strokes)
        }
        if let annotation { canvas = annotation.composited(over: canvas) }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nil, pool,
            [kCVPixelBufferPoolAllocationThresholdKey: 3] as CFDictionary, &output) == kCVReturnSuccess,
            let output else { return nil }
        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_sRGB, .shouldPropagate)
        context.render(canvas.cropped(to: bounds), to: output, bounds: bounds, colorSpace: colorSpace)
        return Self.sample(output, time: time)
    }

    static func sample(_ pixels: CVPixelBuffer, time: CMTime) -> CMSampleBuffer? {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescriptionOut: &format) == noErr, let format else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr else { return nil }
        if let sample, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    static func instrumentCrop(extent: CGRect, zoom: CGFloat, focus: CGPoint) -> CGRect {
        let scale = min(4, max(1, zoom.isFinite ? zoom : 1))
        let width = extent.width / scale, height = extent.height / scale
        let fx = focus.x.isFinite ? min(1, max(0, focus.x)) : 0.5
        let fy = focus.y.isFinite ? min(1, max(0, focus.y)) : 0.5
        return CGRect(x: min(extent.maxX - width, max(extent.minX, extent.minX + fx * extent.width - width / 2)),
                      y: min(extent.maxY - height, max(extent.minY, extent.minY + (1 - fy) * extent.height - height / 2)),
                      width: width, height: height)
    }

    private func background(_ scene: PresenterScene, bounds: CGRect, contentBounds: CGRect) -> CIImage {
        let base: CIColor
        switch scene.backdrop {
        case .dark: base = CIColor(red: 0.035, green: 0.04, blue: 0.055)
        case .warm: base = CIColor(red: 0.19, green: 0.09, blue: 0.035)
        case .stage: base = CIColor(red: 0.055, green: 0.025, blue: 0.12)
        }
        var background = CIImage(color: base).cropped(to: bounds)
        if let image = scene.image {
            background = fit(CIImage(cgImage: image), into: contentBounds, fill: false).composited(over: background)
        } else {
            if scene.backdrop == .stage {
                // Deliberately reacts to speech activity, not an invented audio-level
                // meter. This does not capture microphone PCM or alter Music mode.
                let glow = CIFilter(name: "CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: size.width * 0.5, y: size.height * 0.45),
                    "inputRadius0": 0, "inputRadius1": size.width * 0.55,
                    "inputColor0": CIColor(red: 0.55, green: 0.16, blue: 0.35, alpha: scene.speaking ? 0.65 : 0.25),
                    "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0)
                ])?.outputImage
                if let glow { background = glow.cropped(to: bounds).composited(over: background) }
            }
        }
        return background
    }

    private func fit(_ image: CIImage, into target: CGRect, fill: Bool) -> CIImage {
        let extent = image.extent
        let scale = fill ? max(target.width / extent.width, target.height / extent.height) :
            min(target.width / extent.width, target.height / extent.height)
        let transformed = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: target.midX - extent.width * scale / 2,
                                              y: target.midY - extent.height * scale / 2))
        return transformed.cropped(to: target)
    }

    private func cutout(_ image: CIImage, pixels: CVPixelBuffer, rotation: Int) -> CIImage? {
        let orientation: CGImagePropertyOrientation
        switch rotation { case 90: orientation = .right; case 180: orientation = .down; case 270: orientation = .left; default: orientation = .up }
        do {
            let mask: CVPixelBuffer?
            if let personMask { mask = try personMask(pixels, orientation) }
            else {
                try VNImageRequestHandler(cvPixelBuffer: pixels, orientation: orientation).perform([segmentation])
                mask = segmentation.results?.first?.pixelBuffer
            }
            guard let mask else { return nil }
            let inputMask = CIImage(cvPixelBuffer: mask)
            let scaled = inputMask.transformed(by: CGAffineTransform(scaleX: image.extent.width / inputMask.extent.width,
                                                                      y: image.extent.height / inputMask.extent.height))
            return image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage(color: .clear).cropped(to: image.extent), kCIInputMaskImageKey: scaled])
        } catch { return nil }
    }

    private func drawStrokes(_ strokes: [[CGPoint]]) -> CIImage? {
        guard !strokes.isEmpty, let drawing = CGContext(data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        drawing.setStrokeColor(CGColor(red: 1, green: 0.62, blue: 0.18, alpha: 1))
        drawing.setLineWidth(max(3, size.width / 250)); drawing.setLineCap(.round); drawing.setLineJoin(.round)
        for stroke in strokes {
            guard let first = stroke.first else { continue }
            drawing.move(to: CGPoint(x: first.x * size.width, y: (1 - first.y) * size.height))
            for point in stroke.dropFirst() { drawing.addLine(to: CGPoint(x: point.x * size.width, y: (1 - point.y) * size.height)) }
            drawing.strokePath()
        }
        return drawing.makeImage().map(CIImage.init(cgImage:))
    }
}
