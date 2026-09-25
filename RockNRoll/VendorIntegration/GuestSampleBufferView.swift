import AVFoundation
import UIKit

final class GuestSampleBufferView: UIView {
    private let display = AVSampleBufferDisplayLayer()
    private var rotation = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        display.videoGravity = .resizeAspect
        layer.addSublayer(display)
    }

    required init?(coder: NSCoder) { nil }

    func enqueue(_ sample: CMSampleBuffer, rotation: Int) {
        if self.rotation != rotation {
            self.rotation = rotation
            setNeedsLayout()
            layoutIfNeeded()
        }
        if display.status == .failed { display.flush() }
        if display.isReadyForMoreMediaData { display.enqueue(sample) }
    }

    func clear() { display.flushAndRemoveImage() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let sideways = rotation == 90 || rotation == 270
        display.bounds = CGRect(origin: .zero,
            size: sideways ? CGSize(width: bounds.height, height: bounds.width) : bounds.size)
        display.position = CGPoint(x: bounds.midX, y: bounds.midY)
        display.setAffineTransform(CGAffineTransform(rotationAngle: CGFloat(rotation) * .pi / 180))
        CATransaction.commit()
    }
}
