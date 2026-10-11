import AVFoundation
import UIKit

final class GuestSampleBufferView: UIView {
    private let display = AVSampleBufferDisplayLayer()
    private var rotation = 0
    private var capturePreview: CameraCapturePreviewView?
    private weak var captureSource: CameraCapturePreview?
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
        if display.status == .failed { display.flush() }
        guard display.isReadyForMoreMediaData else { return false }
        display.enqueue(sample)
        return true
    }

    func clear() { setCameraPreview(nil); display.flushAndRemoveImage() }

    func setCameraPreview(_ source: CameraCapturePreview?, enabled: Bool = true) {
        if captureSource !== source {
            capturePreview?.stop(); capturePreview?.removeFromSuperview(); capturePreview = nil
            captureSource = source
            if let source {
                let preview = source.makeView()
                preview.onDisplaySizeChanged = { [weak self] size in self?.onCameraPreviewSizeChanged?(size) }
                preview.autoresizingMask = [.flexibleWidth, .flexibleHeight]
                preview.frame = bounds; addSubview(preview); capturePreview = preview
                display.flushAndRemoveImage()
            }
        }
        capturePreview?.mirrored = mirrored
        capturePreview?.contentMode = contentMode
        capturePreview?.enabled = enabled
    }

    /// A static canvas has no next frame to restart display after reparenting.
    func restore(_ sample: CMSampleBuffer, rotation: Int) {
        layoutIfNeeded()
        display.flush()
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
