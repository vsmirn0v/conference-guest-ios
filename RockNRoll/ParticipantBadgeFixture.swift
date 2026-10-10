#if DEBUG
import UIKit

/// Uses the real viewport and captions without requiring a connected meeting.
final class ParticipantBadgeFixture: UIViewController {
    private var tiles: [StreamViewport] = []
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        for (index, name, on, speaking) in [
            (0, "Alexander Smirnov — acoustic guitar", false, false),
            (1, "Николай Александрович — акустическая гитара", true, false),
            (2, "Alexander Petrosyan — arrangement and rehearsal", true, true),
            (3, "Александра Владимировна — фортепиано", false, true)
        ] {
            let video = UIView()
            video.backgroundColor = index.isMultiple(of: 2) ? .darkGray : .systemIndigo
            let tile = StreamViewport(video: video, state: StreamViewportState(), zoomable: true,
                name: name, showInfo: true, microphoneOn: on, pinned: true,
                watermark: nil, isSpeaking: speaking)
            tile.accessibilityIdentifier = "badge-tile.\(index)"
            tile.controlsHidden = false
            view.addSubview(tile); tiles.append(tile)
        }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.bounds.inset(by: view.safeAreaInsets).insetBy(dx: 10, dy: 10)
        let width = (bounds.width - 8) / 2, height = (bounds.height - 8) / 2
        for (index, tile) in tiles.enumerated() {
            tile.frame = CGRect(x: bounds.minX + CGFloat(index % 2) * (width + 8),
                y: bounds.minY + CGFloat(index / 2) * (height + 8), width: width, height: height)
        }
    }
}
#endif
