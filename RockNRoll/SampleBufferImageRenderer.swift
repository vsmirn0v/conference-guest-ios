import AVFoundation
import CoreImage
import UIKit

/// A bounded decoded-pixel recovery surface. Created only if AVFoundation's
/// sample-buffer connection remains orphaned after its completed flushes.
final class SampleBufferImageRenderer: @unchecked Sendable {
    private struct Input { let pixels: CVPixelBuffer; let epoch: UUID }
    private struct Output { let image: CGImage; let epoch: UUID }
    let layer = CALayer()
    private let lock = NSLock()
    private var epoch = UUID()
    private var displayed = false
#if DEBUG
    private var presentedFrames = 0
    var beforeConversionForTesting: (() -> Void)?
    var validatedPresentationForTesting: (() -> Void)?
    var evidenceForTesting: [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return ["imagePresented": presentedFrames]
    }
#endif
    @MainActor private var displayedEpoch: UUID?
    // Accessed only by the processor's serial conversion queue.
    private var context: CIContext?
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let onFrame: @MainActor () -> Void
    private lazy var processor = LatestVideoFrameProcessor<Input, Output>(
        label: "app.video.renderer-recovery", convert: { [weak self] input in
            guard let self else { return nil }
#if DEBUG
            self.beforeConversionForTesting?()
#endif
            if self.context == nil { self.context = CIContext(options: [.cacheIntermediates: false]) }
            let image = CIImage(cvPixelBuffer: input.pixels)
            return self.context?.createCGImage(image, from: image.extent,
                format: .RGBA8, colorSpace: self.colorSpace).map { Output(image: $0, epoch: input.epoch) }
        }, deliver: { [weak self] output in self?.display(output) })

    @MainActor init(onFrame: @escaping @MainActor () -> Void = {}) {
        self.onFrame = onFrame
        layer.contentsGravity = .resizeAspect
        processor.setEnabled(true)
    }

    var status: AVQueuedSampleBufferRenderingStatus {
        lock.lock(); defer { lock.unlock() }; return displayed ? .rendering : .unknown
    }

    @discardableResult func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return false }
        lock.lock(); let current = epoch; lock.unlock()
        processor.setEnabled(true)
        processor.submit(Input(pixels: pixels, epoch: current))
        return true
    }

    func flush(removingImage: Bool) {
        lock.lock(); epoch = UUID(); displayed = false; lock.unlock()
        processor.setEnabled(false)
        guard removingImage else { return }
        let clear: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.lock.lock(); let current = self.epoch; self.lock.unlock()
            guard self.displayedEpoch != current else { return }
            CATransaction.begin(); CATransaction.setDisableActions(true)
            self.layer.contents = nil; self.displayedEpoch = nil
            CATransaction.commit()
        }
        if Thread.isMainThread { MainActor.assumeIsolated { clear() } }
        else { DispatchQueue.main.async(execute: clear) }
    }

    @MainActor private func display(_ output: Output) {
        lock.lock(); let current = epoch == output.epoch
        let first = !displayed
        if current {
            displayed = true
#if DEBUG
            presentedFrames += 1
#endif
        }
        guard current else { lock.unlock(); return }
#if DEBUG
        validatedPresentationForTesting?()
#endif
        displayedEpoch = output.epoch
        CATransaction.begin(); CATransaction.setDisableActions(true)
        layer.contents = output.image
        CATransaction.commit()
        lock.unlock()
        // Retirement and contents assignment serialize; callbacks can reenter
        // the owner and must run outside the image lock.
        if first { onFrame() }
    }
}
