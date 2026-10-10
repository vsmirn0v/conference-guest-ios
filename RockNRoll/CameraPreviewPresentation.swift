import AVFoundation
import CoreGraphics

/// Presentation only: never reflect pixels passed to a publisher or compositor.
enum CameraPreviewPresentation {
    static func isMirrored(position: AVCaptureDevice.Position) -> Bool {
        position != .back
    }

    static func isMirrored(device: AVCaptureDevice?) -> Bool {
        isMirrored(position: device?.position ?? .unspecified)
    }

    static func transform(rotation: Int, mirrored: Bool) -> CGAffineTransform {
        let angle = CGFloat(rotation) * .pi / 180
        let horizontal: CGFloat = mirrored ? -1 : 1
        // Reflect the upright image horizontally, after applying frame rotation.
        return CGAffineTransform(a: horizontal * cos(angle), b: sin(angle),
            c: -horizontal * sin(angle), d: cos(angle), tx: 0, ty: 0)
    }
}
