import AVFoundation
import UIKit

final class GuestSampleBufferView: UIView {
    private var display = AVSampleBufferDisplayLayer()
    private var recoveryLayer: CALayer?
    private lazy var renderTarget = SampleBufferRenderTarget(layer: display,
        onLayerReplaced: { [weak self] layer in self?.replaceDisplayLayer(layer) },
        onRecoveredFrame: { [weak self] in
            self?.isHidden = false
            self?.frameDelivery?.recoveredFramePresented()
        })
    private var frameDelivery: SampleBufferFrameDelivery?
    private var rotation = 0
    private var capturePreview: CameraCapturePreviewView?
    private weak var captureSource: CameraCapturePreview?
    private var captureRevision: UInt64 = 0
    private var captureEnabled = true
    var onCameraPreviewSizeChanged: ((CGSize) -> Void)?
    private(set) var displaySize = CGSize.zero
    var onDisplaySizeChanged: (() -> Void)?
    private func updateDisplaySize(_ size: CGSize, rotation: Int) {
        let oriented = rotation == 90 || rotation == 270 ? CGSize(width: size.height, height: size.width) : size
        guard oriented != displaySize else { return }
        displaySize = oriented
        onDisplaySizeChanged?()
    }
#if DEBUG
    var evidenceForTesting: [String: Any] { renderTarget.evidenceForTesting }
    func forceResetErrorForTesting(_ value: Bool) { renderTarget.forceResetErrorForTesting(value) }
#endif
    var mirrored = false {
        didSet { capturePreview?.mirrored = mirrored; if oldValue != mirrored { setNeedsLayout(); layoutIfNeeded() } }
    }
    override var contentMode: UIView.ContentMode {
        didSet {
            display.videoGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
            recoveryLayer?.contentsGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
            capturePreview?.contentMode = contentMode
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        display.videoGravity = .resizeAspect
        layer.addSublayer(display)
    }

    required init?(coder: NSCoder) { nil }

    @discardableResult
    func enqueue(_ sample: CMSampleBuffer, rotation: Int) -> Bool {
        if let format = CMSampleBufferGetFormatDescription(sample) {
            updateDisplaySize(CMVideoFormatDescriptionGetPresentationDimensions(format, usePixelAspectRatio: true, useCleanAperture: true), rotation: rotation)
        }
        if self.rotation != rotation {
            self.rotation = rotation
            setNeedsLayout()
            layoutIfNeeded()
        }
        return renderTarget.enqueue(sample)
    }

    func clear() {
        frameDelivery?.invalidate(); frameDelivery = nil
        setCameraPreview(nil); renderTarget.clear(removingImage: true)
        updateDisplaySize(.zero, rotation: 0)
    }

    func existingFrameDelivery() -> SampleBufferFrameDelivery? {
        frameDelivery.flatMap { $0.isCurrent ? $0 : nil }
    }
    func makeFrameDelivery(onGeometry: @escaping @MainActor (CGSize, Int) -> Void) -> SampleBufferFrameDelivery {
        frameDelivery?.invalidate()
        let delivery = SampleBufferFrameDelivery(target: renderTarget) { [weak self] size, rotation in
            guard let self else { return }
            self.updateDisplaySize(size, rotation: rotation)
            self.renderTarget.checkRecovery()
            if self.rotation != rotation { self.rotation = rotation; self.setNeedsLayout(); self.layoutIfNeeded() }
            onGeometry(size, rotation)
        }
        frameDelivery = delivery
        return delivery
    }

    private func replaceDisplayLayer(_ next: AVSampleBufferDisplayLayer) {
        let previous = display
        display = next
        next.videoGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
        recoveryLayer?.removeFromSuperlayer()
        recoveryLayer = renderTarget.recoveryImageLayer
        if let recoveryLayer {
            previous.removeFromSuperlayer()
            layer.insertSublayer(recoveryLayer, at: 0)
        } else if previous !== next {
            layer.insertSublayer(next, at: 0)
            previous.removeFromSuperlayer()
        }
        setNeedsLayout(); layoutIfNeeded()
    }
    func setFrameDeliverySuspended(_ suspended: Bool) {
        frameDelivery?.setEnabled(!suspended)
        if suspended { renderTarget.clearImage() }
    }

    func setCameraPreview(_ source: CameraCapturePreview?, enabled: Bool = true) {
        captureEnabled = enabled
        if captureSource !== source {
            captureRevision &+= 1
            let revision = captureRevision, previous = capturePreview
            // AVFoundation may reenter this setter while detaching. Publish
            // the new binding first and let any newer request win.
            capturePreview = nil
            captureSource = source
            previous?.stop(); previous?.removeFromSuperview()
            guard revision == captureRevision else { return }
            if let source {
                let preview = source.makeView()
                guard revision == captureRevision else { preview.stop(); return }
                preview.onDisplaySizeChanged = { [weak self] size in self?.onCameraPreviewSizeChanged?(size) }
                preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                capturePreview = preview
                preview.frame = bounds; addSubview(preview)
                renderTarget.clear(removingImage: true)
            }
        }
        capturePreview?.mirrored = mirrored
        capturePreview?.contentMode = contentMode
        capturePreview?.enabled = captureEnabled
    }

    /// A static canvas has no next frame to restart display after reparenting.
    func restore(_ sample: CMSampleBuffer, rotation: Int) {
        layoutIfNeeded()
        renderTarget.clear(removingImage: false)
        enqueue(sample, rotation: rotation)
        renderTarget.checkRecovery()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sideways = rotation == 90 || rotation == 270
        let surface = recoveryLayer ?? display
        surface.bounds = CGRect(origin: .zero,
            size: sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        surface.position = CGPoint(x: bounds.midX, y: bounds.midY)
        surface.setAffineTransform(CameraPreviewPresentation.transform(rotation: rotation, mirrored: mirrored))
        recoveryLayer?.contentsGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect
        CATransaction.commit()
    }
}
