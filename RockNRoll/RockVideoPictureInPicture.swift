import LiveKit
import UIKit

/// A separate background-capable renderer leaves the in-call tile and zoom intact.
@MainActor
final class RockVideoPictureInPicture {
    private let content = UIView()
    private let video = VideoView()
    private let caption = UILabel()
    private let floating: FloatingVideoController
    private weak var sourceView: UIView?
    private var selectedTrack: VideoTrack?

    init(sourceView: UIView) {
        self.sourceView = sourceView
        floating = FloatingVideoController(contentView: content)
        content.backgroundColor = .black
        content.accessibilityIdentifier = "Floating video surface"
        video.renderMode = .sampleBuffer
        video.layoutMode = .fit
        video.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(video)
        caption.accessibilityIdentifier = "Floating video source"
        caption.textColor = .white
        caption.font = .preferredFont(forTextStyle: .caption1)
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
    }

    var canShow: Bool { floating.canShow }

    func show(track: VideoTrack?, name: String = "", isScreenShare: Bool = false) {
        guard let track else { clear(); return }
        if selectedTrack !== track {
            selectedTrack = track
            video.track = track
        }
        video.layoutMode = isScreenShare ? .fit : .fill
        caption.text = name.isEmpty ? nil : "  \(name)  "
        caption.isHidden = name.isEmpty
        floating.setSourceView(sourceView)
    }

    func start() { floating.start() }
    func refreshPreference() { floating.refreshPreference() }
    func setSuspended(_ suspended: Bool) { floating.setSuspended(suspended) }
    func foregrounded() { floating.foregrounded() }

    func clear() {
        floating.setSourceView(nil)
        video.track = nil
        selectedTrack = nil
        caption.text = nil
    }
}
