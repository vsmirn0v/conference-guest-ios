import AVKit
import UIKit

/// Frames feed a separate sample-buffer surface. The SDK's inline OpenGL view
/// can suspend normally while the system keeps this surface live in the background.
@MainActor
final class GuestVideoPictureInPicture {
    private let content = UIView()
    private let caption = UILabel()
    private let video = GuestSampleBufferView()
    private let processor = GuestVideoFrameProcessor()
    private let floating: FloatingVideoController
    private var frameTap: GuestVideoFrameTap?
    private var hasFrame = false
    private var presenting = false
    private var suspended = false
    private weak var selectedViewport: StreamViewport?
    private weak var selectedRenderer: UIView?
    var onAvailabilityChanged: ((Bool) -> Void)?
    var canShow: Bool { hasFrame && frameTap != nil && !suspended && floating.canShow }

    init() {
        floating = FloatingVideoController(contentView: content)
        content.backgroundColor = .black
        content.accessibilityIdentifier = "Floating video surface"
        video.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(video)
        caption.accessibilityIdentifier = "Floating video source"
        caption.font = .preferredFont(forTextStyle: .caption1)
        caption.textColor = .white
        caption.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        caption.layer.cornerRadius = 5
        caption.clipsToBounds = true
        caption.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(caption)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            video.topAnchor.constraint(equalTo: content.topAnchor),
            video.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            caption.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 8),
            caption.topAnchor.constraint(equalTo: content.topAnchor, constant: 8),
            caption.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -8)
        ])
        floating.onWillStart = { [weak self] in
            self?.presenting = true
            self?.processor.setEnabled(true)
        }
        floating.onStopped = { [weak self] in
            self?.presenting = false
            self?.processor.setEnabled(false)
        }
        processor.onSample = { [weak self] sample, size, rotation in
            guard let self else { return }
            self.video.enqueue(sample, rotation: rotation)
            self.floating.preferredSize = rotation == 90 || rotation == 270
                ? CGSize(width: size.height, height: size.width) : size
            if !self.hasFrame {
                self.hasFrame = true
                self.floating.setSourceView(self.selectedViewport)
                self.onAvailabilityChanged?(self.canShow)
            }
            if !self.presenting { self.processor.setEnabled(false) }
        }
    }

    func select(viewport: StreamViewport?, name: String, isScreenShare: Bool) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        guard let viewport else { clear(); return }
        selectedViewport = viewport
        if selectedRenderer !== viewport.rendererView || frameTap?.matches(viewport.rendererView) != true {
            frameTap?.invalidate()
            frameTap = nil
            let sourceID = processor.replaceSource()
            processor.setEnabled(false)
            video.clear()
            hasFrame = false
            onAvailabilityChanged?(false)
            selectedRenderer = viewport.rendererView
            let processor = processor
            frameTap = GuestVideoFrameTap(view: viewport.rendererView) { [weak processor] frame in
                processor?.submit(frame, source: sourceID)
            }
            processor.setEnabled(frameTap != nil && !suspended)
        }
        caption.text = name.isEmpty ? nil : "  \(name)\(isScreenShare ? " · Screen" : "")  "
        caption.isHidden = name.isEmpty
        floating.setSourceView(hasFrame && frameTap != nil ? viewport : nil)
    }

    func start(manual: Bool = false) { if canShow { floating.start() } }
    func refreshPreference() { floating.refreshPreference() }
    func foregrounded() { floating.foregrounded() }

    func setSuspended(_ suspended: Bool) {
        self.suspended = suspended
        floating.setSuspended(suspended)
        if suspended { processor.setEnabled(false) }
        else if !hasFrame && frameTap != nil { processor.setEnabled(true) }
        onAvailabilityChanged?(canShow)
    }

    func clear() {
        floating.setSourceView(nil)
        processor.setEnabled(false)
        _ = processor.replaceSource()
        frameTap?.invalidate()
        frameTap = nil
        hasFrame = false
        presenting = false
        selectedViewport = nil
        selectedRenderer = nil
        video.clear()
        onAvailabilityChanged?(false)
    }

}
