import AVFoundation
import UIKit

/// Serializes enqueue/flush and rejects frames from retired video sources. On
/// iOS 17+ only the renderer is touched off-main, never its layer or UIView.
final class SampleBufferRenderTarget: @unchecked Sendable {
    let supportsBackground: Bool
    private let displayLayer: AVSampleBufferDisplayLayer
    private let lock = NSLock()
    private var generation = UUID()
    private let enqueueSample: (CMSampleBuffer) -> Bool
    private let flush: (Bool) -> Void

    @MainActor init(layer: AVSampleBufferDisplayLayer) {
        // The iOS 17 renderer does not keep its display layer alive. Releasing
        // the layer during enqueue can deadlock AVFoundation's video queue.
        displayLayer = layer
        if #available(iOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            supportsBackground = true
            enqueueSample = { sample in
                if renderer.status == .failed { renderer.flush() }
                guard renderer.isReadyForMoreMediaData else { return false }
                renderer.enqueue(sample); return true
            }
            flush = { renderer.flush(removingDisplayedImage: $0, completionHandler: nil) }
        } else {
            supportsBackground = false
            enqueueSample = { sample in
                precondition(Thread.isMainThread)
                if layer.status == .failed { layer.flush() }
                guard layer.isReadyForMoreMediaData else { return false }
                layer.enqueue(sample); return true
            }
            flush = { remove in
                precondition(Thread.isMainThread)
                if remove { layer.flushAndRemoveImage() } else { layer.flush() }
            }
        }
    }

    deinit {
        // A retired converter may release its last reference off-main. Keep
        // layer teardown on the UI queue, after the current enqueue returns.
        let layer = displayLayer
        DispatchQueue.main.async { withExtendedLifetime(layer) {} }
    }

    func beginSource() -> UUID {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); return generation
    }
    func isCurrent(_ source: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }; return generation == source
    }
    @discardableResult func enqueue(_ sample: CMSampleBuffer, source: UUID? = nil) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard source == nil || source == generation else { return false }
        return enqueueSample(sample)
    }
    func invalidate(_ source: UUID) {
        lock.lock(); defer { lock.unlock() }
        if generation == source { generation = UUID() }
    }
    func clear(removingImage: Bool) {
        lock.lock(); defer { lock.unlock() }
        generation = UUID(); flush(removingImage)
    }
    func clearImage() {
        lock.lock(); defer { lock.unlock() }; flush(true)
    }
}

/// Camera/decoded pixels arrive on the converter queue. Stable-size frames go
/// straight to AVFoundation; only changed geometry schedules a coalesced UI job.
/// The iOS 16 fallback keeps at most one newest sample awaiting the main thread.
final class SampleBufferFrameDelivery: @unchecked Sendable {
    private struct Geometry: Equatable { let size: CGSize; let rotation: Int }
    private let target: SampleBufferRenderTarget
    private let source: UUID
    private let background: Bool
    private let onGeometry: @MainActor (CGSize, Int) -> Void
    private let lock = NSLock()
    private var enabled = true
    private var retired = false
    private var active = false
    private var primed = false
    private var scheduled = false
    private var geometry: Geometry?
    private var pending: (CMSampleBuffer?, Geometry)?
    #if DEBUG
    private var enqueueObserver: ((CMSampleBuffer, Bool) -> Void)?
    var onEnqueuedForTesting: ((CMSampleBuffer, Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return enqueueObserver }
        set { lock.lock(); enqueueObserver = newValue; lock.unlock() }
    }
    #endif

    @MainActor init(target: SampleBufferRenderTarget, allowBackground: Bool = true,
                    onGeometry: @escaping @MainActor (CGSize, Int) -> Void) {
        self.target = target; source = target.beginSource()
        background = allowBackground && target.supportsBackground
        self.onGeometry = onGeometry
    }
    var isCurrent: Bool { lock.lock(); defer { lock.unlock() }; return !retired && target.isCurrent(source) }
    func setActive(_ value: Bool) { lock.lock(); active = value; lock.unlock() }
    func setEnabled(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        if enabled != value {
            enabled = value; pending = nil
            if value { primed = false; geometry = nil }
        }
    }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        retired = true; pending = nil; target.invalidate(source)
    }
    func deliver(_ sample: CMSampleBuffer, rotation: Int) {
        guard let pixels = CMSampleBufferGetImageBuffer(sample) else { return }
        let next = Geometry(size: CGSize(width: CVPixelBufferGetWidth(pixels), height: CVPixelBufferGetHeight(pixels)), rotation: rotation)
        lock.lock(); defer { lock.unlock() }
        guard enabled, !retired, active || !primed, target.isCurrent(source) else { return }
        if background {
            guard enqueue(sample) else { return }
            primed = true
            guard geometry != next else { return }
            pending = (nil, next)
        } else { pending = (sample, next) }
        if !scheduled {
            scheduled = true
            DispatchQueue.main.async { [weak self] in self?.deliverGeometry() }
        }
    }
    private func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let accepted = target.enqueue(sample, source: source)
        #if DEBUG
        enqueueObserver?(sample, accepted)
        #endif
        return accepted
    }
    @MainActor private func deliverGeometry() {
        lock.lock()
        scheduled = false
        let latest = pending; pending = nil
        guard enabled, !retired, target.isCurrent(source), let latest else { lock.unlock(); return }
        if let sample = latest.0 {
            guard active || !primed, enqueue(sample) else { lock.unlock(); return }
            primed = true
        }
        let changed = geometry != latest.1
        geometry = latest.1
        lock.unlock()
        if changed { onGeometry(latest.1.size, latest.1.rotation) }
    }
}
