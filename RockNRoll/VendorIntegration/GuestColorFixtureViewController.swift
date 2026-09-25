#if DEBUG
import UIKit
import WebRTC

/// A deterministic studio-range ramp rendered through the SDK's WebRTC view
/// and our corrected foreground surface. Used only by the UI regression test.
final class GuestColorFixtureViewController: UIViewController {
    private let originalRenderer = RTCMTLVideoView()
    private let correctedRenderer = RTCMTLVideoView()
    private let processor = GuestVideoFrameProcessor()
    private var correctedViewport: StreamViewport?
    private var refresh: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = 12
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            column.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
        ])
        for (renderer, title) in [(originalRenderer, "Original video"),
                                  (correctedRenderer, "Corrected video")] {
            let label = UILabel()
            label.text = title
            label.textColor = .white
            column.addArrangedSubview(label)
            let viewport = StreamViewport(video: renderer, state: StreamViewportState(),
                                          zoomable: false, name: title, showInfo: false,
                                          microphoneOn: false, pinned: false, watermark: nil)
            viewport.accessibilityIdentifier = title
            viewport.isAccessibilityElement = true
            column.addArrangedSubview(viewport)
            viewport.heightAnchor.constraint(equalTo: viewport.widthAnchor, multiplier: 0.3).isActive = true
            if title == "Corrected video" { correctedViewport = viewport }
        }
        processor.onSample = { [weak self] sample, _, rotation in
            self?.correctedViewport?.showCorrectedVideo(sample, rotation: rotation)
            self?.correctedViewport?.accessibilityValue = "Rendered"
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        processor.setEnabled(true)
        refresh = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let frame = self.makeRamp()
            self.originalRenderer.renderFrame(frame)
            self.correctedRenderer.renderFrame(frame)
            self.processor.submit(frame)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        refresh?.invalidate()
        refresh = nil
        processor.setEnabled(false)
    }

    private func makeRamp() -> RTCVideoFrame {
        let width = 600, height = 180
        let buffer = RTCMutableI420Buffer(width: Int32(width), height: Int32(height))
        for row in 0..<height {
            for column in 0..<width {
                buffer.mutableDataY[row * Int(buffer.strideY) + column] =
                    column < width / 3 ? 16 : column < 2 * width / 3 ? 128 : 235
            }
        }
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                buffer.mutableDataU[row * Int(buffer.strideU) + column] = 128
                buffer.mutableDataV[row * Int(buffer.strideV) + column] = 128
            }
        }
        return RTCVideoFrame(buffer: buffer, rotation: RTCVideoRotation(rawValue: 0)!,
                             timeStampNs: Int64(Date().timeIntervalSince1970 * 1_000_000_000))
    }
}
#endif
