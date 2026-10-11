import AVFoundation
import UIKit

final class GuestSampleBufferView: UIView {
    private let display = AVSampleBufferDisplayLayer()
    private lazy var renderTarget = SampleBufferRenderTarget(layer: display)
    private var frameDelivery: SampleBufferFrameDelivery?
    private var rotation = 0
    private var capturePreview: CameraCapturePreviewView?
    private weak var captureSource: CameraCapturePreview?
    private var captureRevision: UInt64 = 0
    private var captureEnabled = true
    var onCameraPreviewSizeChanged: ((CGSize) -> Void)?
    var mirrored = false {
        didSet { capturePreview?.mirrored = mirrored; if oldValue != mirrored { setNeedsLayout(); layoutIfNeeded() } }
    }
    override var contentMode: UIView.ContentMode {
        didSet { display.videoGravity = contentMode == .scaleAspectFill ? .resizeAspectFill : .resizeAspect; capturePreview?.contentMode = contentMode }
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
    }

    func existingFrameDelivery() -> SampleBufferFrameDelivery? {
        frameDelivery.flatMap { $0.isCurrent ? $0 : nil }
    }
    func makeFrameDelivery(onGeometry: @escaping @MainActor (CGSize, Int) -> Void) -> SampleBufferFrameDelivery {
        frameDelivery?.invalidate()
        let delivery = SampleBufferFrameDelivery(target: renderTarget) { [weak self] size, rotation in
            guard let self else { return }
            if self.rotation != rotation { self.rotation = rotation; self.setNeedsLayout(); self.layoutIfNeeded() }
            onGeometry(size, rotation)
        }
        frameDelivery = delivery
        return delivery
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
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sideways = rotation == 90 || rotation == 270
        display.bounds = CGRect(origin: .zero,
            size: sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        display.position = CGPoint(x: bounds.midX, y: bounds.midY)
        display.setAffineTransform(CameraPreviewPresentation.transform(rotation: rotation, mirrored: mirrored))
        CATransaction.commit()
    }
}
