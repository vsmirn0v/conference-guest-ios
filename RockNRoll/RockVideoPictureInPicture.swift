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
    private var selectedTrack: VideoTrack?

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
        guard !floating.isEnded else { return }
        guard let track else { clear(); return }
        if selectedTrack !== track {
            retireSink()
            selectedTrack = track
            let sink = RoomFloatingVideoSink { [weak self, weak track] sample, rotation in
                guard let self, self.selectedTrack === track, !self.floating.isEnded else { return }
                self.video.enqueue(sample, rotation: rotation)
            }
            self.sink = sink
            sink.setWanted(presenting, fps: MediaEnergyBudget.shared.previewFPS)
            track.add(videoRenderer: sink)
        }
        video.contentMode = isScreenShare ? .scaleAspectFit : .scaleAspectFill
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
        selectedTrack = nil
        caption.text = nil
    }

    private func retireSink() {
        if let sink { sink.retire(); selectedTrack?.remove(videoRenderer: sink) }
        sink = nil
    }

    func end() {
        floating.end()
        clear()
    }
}
