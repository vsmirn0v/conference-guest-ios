import AppKit
import CoreImage
import CoreVideo
import Foundation
import LiveKitWebRTC
import MetalKit

/// Main owns AppKit/Metal submission. One worker owns conversion; both input
/// and prepared output retain only the latest waiting frame.
final class CompanionVideoSink: NSObject, LKRTCVideoRenderer, MTKViewDelegate, @unchecked Sendable {
    private static let device = MTLCreateSystemDefaultDevice()
    private static let context = device.map { CIContext(mtlDevice: $0, options: [.cacheIntermediates: false]) }
    private static let queue = device?.makeCommandQueue()
    private struct PreparedFrame {
        let pixel: CVPixelBuffer
        let image: CIImage
        let timestamp: Int64
    }
    let view: MTKView
    private let lock = NSLock()
    private let preparationQueue = DispatchQueue(label: "NativeGuest.video-preparation", qos: .userInitiated)
    private let mirrored: Bool
    private let converter = NativeVideoPixelBuffer()
    private var latestInput: LKRTCVideoFrame?
    private var prepared: PreparedFrame?
    private var preparationScheduled = false
    private var preparationInFlight = false
    private var lastPreparationStart: UInt64 = 0
    private var drawScheduled = false
    private var gpuInFlight = false
    private var redrawNeeded = false
    private var active = true
    private var generation: UInt64 = 0
    private var lastRenderedTimestamp: Int64?
    private var crop: CGRect?
    private var zoom: CGFloat = 1
    private var pan = CGSize.zero
    private var count = 0
    private var presentationTimeline = GuestFrameTimeline()
#if DEBUG
    var trackIDForTesting: String?
    private var inputTimeline = GuestFrameTimeline()
    private var inputCallbacks = 0, advancingInputs = 0
    private var lastInputTimestamp: Int64?
    func inputWindowForTesting(from start: Double, to end: Double) -> GuestFrameWindow {
        lock.lock(); defer { lock.unlock() }
        return inputTimeline.measure(from: start, to: end)
    }
    var onEncodedDrawableForTesting: ((MTLCommandBuffer, MTLTexture, Int64) -> Void)?
    var onPreparationForTesting: ((Int64) -> Void)?
    private var preparationAttempts = 0, preparations = 0, nativePreparations = 0, genericPreparations = 0
    private var replacedInputs = 0, submittedCommands = 0
    var preparationEvidenceForTesting: [String: Int64] {
        lock.lock(); defer { lock.unlock() }
        return ["active": active ? 1 : 0, "pendingInputs": latestInput == nil ? 0 : 1,
            "preparationInFlight": preparationInFlight ? 1 : 0, "drawScheduled": drawScheduled ? 1 : 0,
            "gpuInFlight": gpuInFlight ? 1 : 0, "preparations": Int64(preparations),
            "preparationAttempts": Int64(preparationAttempts),
            "nativePreparations": Int64(nativePreparations), "genericPreparations": Int64(genericPreparations),
            "replacedInputs": Int64(replacedInputs), "submittedCommands": Int64(submittedCommands),
            "inputCallbacks": Int64(inputCallbacks), "advancingInputs": Int64(advancingInputs),
            "lastInputTimestamp": lastInputTimestamp ?? -1,
            "preparedTimestamp": prepared?.timestamp ?? -1]
    }
#endif
    init(mirrored: Bool) {
        precondition(Thread.isMainThread)
        self.mirrored = mirrored
        view = MTKView(frame: .zero, device: Self.device)
        super.init()
        view.framebufferOnly = false; view.isPaused = true; view.enableSetNeedsDisplay = false
        view.preferredFramesPerSecond = 30
        view.clearColor = MTLClearColorMake(0, 0, 0, 1); view.delegate = self
    }
    func setSize(_ size: CGSize) {}
    func setPresentation(crop: CGRect?, zoom: CGFloat, pan: CGSize) {
        let boundedZoom = zoom.isFinite ? min(8, max(1, zoom)) : 1
        let boundedPan = CGSize(width: pan.width.isFinite ? min(1, max(-1, pan.width)) : 0,
                                height: pan.height.isFinite ? min(1, max(-1, pan.height)) : 0)
        lock.lock()
        // SwiftUI rebinds unchanged tracks for roster/level/control updates. A
        // cached frame needs another GPU submission only if presentation changed.
        guard active, self.crop != crop || self.zoom != boundedZoom || self.pan != boundedPan else { lock.unlock(); return }
        self.crop = crop; self.zoom = boundedZoom; self.pan = boundedPan
        redrawNeeded = true
        let epoch = scheduleDrawLocked()
        lock.unlock()
        dispatchDraw(epoch)
    }
    func renderFrame(_ frame: LKRTCVideoFrame?) {
        guard let frame else { return }
        lock.lock()
        guard active else { lock.unlock(); return }
#if DEBUG
        inputCallbacks += 1
        if lastInputTimestamp.map({ frame.timeStampNs > $0 }) ?? true {
            lastInputTimestamp = frame.timeStampNs; advancingInputs += 1
            inputTimeline.record(ProcessInfo.processInfo.systemUptime)
        }
        if latestInput != nil { replacedInputs += 1 }
#endif
        latestInput = frame
        let epoch: UInt64? = preparationScheduled ? nil : generation
        preparationScheduled = true
        lock.unlock()
        if let epoch { schedulePreparation(epoch) }
    }
    private func schedulePreparation(_ epoch: UInt64) {
        lock.lock()
        let due = max(DispatchTime.now().uptimeNanoseconds, lastPreparationStart + 33_333_333)
        lock.unlock()
        preparationQueue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: due)) { [weak self] in self?.prepareLatest(epoch) }
    }
    private func prepareLatest(_ epoch: UInt64) {
        dispatchPrecondition(condition: .notOnQueue(.main))
        lock.lock()
        guard active, generation == epoch, let frame = latestInput else {
            preparationScheduled = false; lock.unlock(); return
        }
        latestInput = nil; preparationInFlight = true
#if DEBUG
        preparationAttempts += 1
#endif
        lastPreparationStart = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
#if DEBUG
        onPreparationForTesting?(frame.timeStampNs)
#endif
        let output = autoreleasepool { prepare(frame) }
        lock.lock()
        preparationInFlight = false
        guard active, generation == epoch else { lock.unlock(); return }
        if let output {
            prepared = output; redrawNeeded = true
#if DEBUG
            preparations += 1
            if frame.buffer is LKRTCCVPixelBuffer { nativePreparations += 1 } else { genericPreparations += 1 }
#endif
        }
        let drawEpoch = scheduleDrawLocked()
        let again = latestInput != nil
        if !again { preparationScheduled = false }
        lock.unlock()
        dispatchDraw(drawEpoch)
        if again { schedulePreparation(epoch) }
    }
    /// CV crop coordinates use a top-left origin. CI uses a bottom-left origin;
    /// normalize and adapt before applying frame rotation and final mirroring.
    private func prepare(_ frame: LKRTCVideoFrame) -> PreparedFrame? {
        dispatchPrecondition(condition: .notOnQueue(.main))
        let pixel: CVPixelBuffer
        var image: CIImage
        if let native = frame.buffer as? LKRTCCVPixelBuffer {
            pixel = native.pixelBuffer
            let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
            let x = Int(native.cropX), y = Int(native.cropY), w = Int(native.cropWidth), h = Int(native.cropHeight)
            guard width > 0, height > 0, x >= 0, y >= 0, w > 0, h > 0,
                  x <= width, y <= height, w <= width - x, h <= height - y,
                  frame.width > 0, frame.height > 0 else { return nil }
            image = CIImage(cvPixelBuffer: pixel)
            guard image.extent == CGRect(x: 0, y: 0, width: width, height: height) else { return nil }
            image = image.cropped(to: CGRect(x: x, y: height - y - h, width: w, height: h))
                .transformed(by: CGAffineTransform(translationX: -CGFloat(x), y: -CGFloat(height - y - h)))
                .transformed(by: CGAffineTransform(scaleX: CGFloat(frame.width) / CGFloat(w), y: CGFloat(frame.height) / CGFloat(h)))
        } else {
            guard let converted = converter.convert(frame) else { return nil }
            pixel = converted; image = CIImage(cvPixelBuffer: pixel)
        }
        switch frame.rotation.rawValue {
        case 0: break
        case 90: image = image.oriented(.right)
        case 180: image = image.oriented(.down)
        case 270: image = image.oriented(.left)
        default: return nil
        }
        if mirrored { image = image.oriented(.upMirrored) }
        _ = Self.context // CI initialization/preparation also stays off the main thread.
        return PreparedFrame(pixel: pixel, image: image, timestamp: frame.timeStampNs)
    }
    /// Caller holds only the state lock; AppKit/Metal never run under this lock.
    private func scheduleDrawLocked() -> UInt64? {
        guard active, prepared != nil, redrawNeeded, !drawScheduled, !gpuInFlight else { return nil }
        drawScheduled = true; return generation
    }
    private func dispatchDraw(_ epoch: UInt64?) {
        guard let epoch else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let valid = self.active && self.generation == epoch
            self.drawScheduled = false
            self.lock.unlock()
            if valid { self.view.draw() }
        }
    }
    var frames: Int { lock.lock(); defer { lock.unlock() }; return count }
    func presentationWindow(from start: Double, to end: Double) -> GuestFrameWindow {
        lock.lock(); defer { lock.unlock() }
        return presentationTimeline.measure(from: start, to: end)
    }
    func stop() {
        lock.lock(); active = false; generation &+= 1
        latestInput = nil; prepared = nil; redrawNeeded = false
        preparationScheduled = false; drawScheduled = false
        lock.unlock()
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        precondition(Thread.isMainThread)
        lock.lock(); redrawNeeded = true; let epoch = scheduleDrawLocked(); lock.unlock()
        dispatchDraw(epoch)
    }
    func draw(in view: MTKView) {
        precondition(Thread.isMainThread)
        lock.lock()
        guard active, !gpuInFlight, redrawNeeded, let prepared else { lock.unlock(); return }
        let epoch = generation, crop = crop, zoom = zoom, pan = pan
        gpuInFlight = true; redrawNeeded = false
        lock.unlock()
        guard let context = Self.context, let drawable = view.currentDrawable,
              let command = Self.queue?.makeCommandBuffer() else { failedDraw(epoch); return }
        var image = prepared.image
        if let crop, crop.origin.x.isFinite, crop.origin.y.isFinite,
           crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 {
            let region = CGRect(x: image.extent.minX + crop.minX * image.extent.width,
                y: image.extent.minY + (1 - crop.maxY) * image.extent.height,
                width: crop.width * image.extent.width, height: crop.height * image.extent.height).intersection(image.extent)
            if !region.isEmpty { image = image.cropped(to: region) }
        }
        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        guard image.extent.width > 0, image.extent.height > 0, bounds.width > 0, bounds.height > 0 else { failedDraw(epoch); return }
        image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let scale = min(bounds.width / image.extent.width, bounds.height / image.extent.height) * zoom
        image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        image = image.transformed(by: CGAffineTransform(translationX: (bounds.width-image.extent.width)/2 + pan.width * max(0, image.extent.width-bounds.width)/2,
            y: (bounds.height-image.extent.height)/2 - pan.height * max(0, image.extent.height-bounds.height)/2))
        let background = CIImage(color: .black).cropped(to: bounds)
        context.render(image.composited(over: background), to: drawable.texture, commandBuffer: command,
                       bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
#if DEBUG
        onEncodedDrawableForTesting?(command, drawable.texture, prepared.timestamp)
#endif
        // A command admitted before an off-main stop is the single bounded
        // in-flight exception. Keep its source storage alive through completion.
        command.addCompletedHandler { [weak self, prepared] completed in
            withExtendedLifetime(prepared) {}
            guard let self else { return }
            self.lock.lock(); self.gpuInFlight = false
            guard self.active, self.generation == epoch else { self.lock.unlock(); return }
            if completed.status == .completed, self.lastRenderedTimestamp.map({ prepared.timestamp > $0 }) ?? true {
                self.lastRenderedTimestamp = prepared.timestamp; self.count += 1
                self.presentationTimeline.record(ProcessInfo.processInfo.systemUptime)
            }
            let next = self.scheduleDrawLocked(); self.lock.unlock()
            self.dispatchDraw(next)
        }
        lock.lock(); let valid = active && generation == epoch
        if !valid { gpuInFlight = false }
#if DEBUG
        if valid { submittedCommands += 1 }
#endif
        lock.unlock()
        guard valid else { return }
        command.present(drawable); command.commit()
    }
    private func failedDraw(_ epoch: UInt64) {
        lock.lock(); gpuInFlight = false
        if active, generation == epoch { redrawNeeded = true }
        lock.unlock()
        // A future input/layout/presentation change retries. Do not spin while
        // an occluded or zero-size view cannot provide a drawable.
    }
}

@MainActor final class CompanionVideoTile: NSView {
    let track: LKRTCVideoTrack
    let sink: CompanionVideoSink
    init(track: LKRTCVideoTrack, title: String, mirrored: Bool = false) {
        self.track = track; sink = CompanionVideoSink(mirrored: mirrored)
        super.init(frame: .zero)
        wantsLayer = true; layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = 12; layer?.masksToBounds = true
        let label = NSTextField(labelWithString: title)
        label.textColor = .white; label.lineBreakMode = .byTruncatingTail
        label.font = .systemFont(ofSize: 13, weight: .medium)
        sink.view.translatesAutoresizingMaskIntoConstraints = false; label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sink.view); addSubview(label)
        NSLayoutConstraint.activate([
            sink.view.leadingAnchor.constraint(equalTo: leadingAnchor), sink.view.trailingAnchor.constraint(equalTo: trailingAnchor),
            sink.view.topAnchor.constraint(equalTo: topAnchor), sink.view.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12), label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10), heightAnchor.constraint(greaterThanOrEqualToConstant: 160)
        ])
        track.add(sink)
    }
    required init?(coder: NSCoder) { nil }
    func detach() { sink.stop(); track.remove(sink) }
}
