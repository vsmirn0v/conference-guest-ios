import LiveKit
import Combine
import UIKit

/// A separate background-capable renderer leaves the in-call tile and zoom intact.
@MainActor
final class RockVideoPictureInPicture {
    private let content = UIView()
    private let video = GuestSampleBufferView()
    private var sink: RoomFloatingVideoSink?
    private var energySubscription: AnyCancellable?
    private var presenting = false
    var onPresentationChanged: ((Bool) -> Void)?
    private let caption = UILabel()
    private let floating: FloatingVideoController
    private weak var sourceView: UIView?
    private var selectedSource: CallVideoSource?

    init(sourceView: UIView, speaker: ActiveSpeakerStore? = nil) {
        self.sourceView = sourceView
        floating = FloatingVideoController(contentView: content, speaker: speaker)
        content.backgroundColor = .black
        content.accessibilityIdentifier = "Floating video surface"
        floating.onPresentationChanged = { [weak self] visible in
            guard let self else { return }
            self.presenting = visible
            self.sink?.setWanted(visible, fps: MediaEnergyBudget.shared.previewFPS)
            self.onPresentationChanged?(visible)
        }
        energySubscription = MediaEnergyBudget.shared.$pressure.sink { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.sink?.setWanted(self.presenting, fps: MediaEnergyBudget.shared.previewFPS)
            }
        }
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
        show(source: track.map { .room($0) }, name: name, isScreenShare: isScreenShare)
    }

    func show(source: CallVideoSource?, name: String = "", isScreenShare: Bool = false) {
        guard !floating.isEnded else { return }
        guard let source else { clear(); return }
        if selectedSource?.identity != source.identity {
            retireSink()
            selectedSource = source
            let identity = source.identity
            let sink = RoomFloatingVideoSink { [weak self] sample, rotation in
                guard let self, self.selectedSource?.identity == identity, !self.floating.isEnded else { return }
                self.video.enqueue(sample, rotation: rotation)
                if let pixels = CMSampleBufferGetImageBuffer(sample) {
                    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
                    self.floating.preferredSize = rotation == 90 || rotation == 270
                        ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
                }
            }
            self.sink = sink
            sink.setWanted(presenting, fps: MediaEnergyBudget.shared.previewFPS)
            source.add(sink)
        }
        video.contentMode = .scaleAspectFit
        caption.text = name.isEmpty ? nil : "  \(name)\(isScreenShare ? L(" · Screen") : "")  "
        caption.isHidden = name.isEmpty
        floating.setSourceView(sourceView)
    }

    func start() { floating.start() }
    func bindMicrophoneActivity(_ activity: MicrophoneActivity) { floating.bindMicrophoneActivity(activity) }
    func setMicrophoneStatus(_ status: PiPMicrophoneStatus) { floating.setMicrophoneStatus(status) }
    func refreshPreference() { floating.refreshPreference() }
    func setSuspended(_ suspended: Bool) { floating.setSuspended(suspended) }
    func foregrounded() { floating.foregrounded() }

    func clear() {
        floating.setSourceView(nil)
        retireSink()
        video.clear()
        selectedSource = nil
        caption.text = nil
    }

    private func retireSink() {
        if let sink { sink.retire(); selectedSource?.remove(sink) }
        sink = nil
    }

    func end() {
        floating.end()
        clear()
    }
}
