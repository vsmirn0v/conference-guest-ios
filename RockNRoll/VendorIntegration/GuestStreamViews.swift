import Combine
import JazzSDK
import UIKit

/// View state belongs to the active share, not the SDK's short-lived participant tile.
final class GuestStreamViews {
    private struct Key: Hashable {
        let participant: String
        let mode: JazzParticipantViewModel.DisplayMode
        let isShare: Bool
    }
    private struct RenderedTile {
        let model: JazzParticipantViewModel
        weak var video: UIView?
        weak var view: StreamViewport?
    }
    private var viewports: [Key: StreamViewportState] = [:]
    private var renderedTiles: [Key: RenderedTile] = [:]
    private var participantSubscription: AnyCancellable?
    private var selectionUpdateScheduled = false
    var onPreferredVideo: ((StreamViewport?, String, Bool) -> Void)?
    var displayMode: ConferenceDisplayMode = .all {
        didSet { updatePreferredVideo() }
    }

    func reset() {
        participantSubscription = nil
        viewports.removeAll()
        renderedTiles.removeAll()
        onPreferredVideo?(nil, "", false)
    }

    func observe(_ state: JazzActiveConferenceState) {
        participantSubscription = Publishers.CombineLatest(state.$localParticipant, state.$remoteParticipants)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] local, remote in
                self?.retainShares(for: [local] + Array(remote.values))
            }
    }

    private func retainShares(for participants: [JazzConferenceParticipant]) {
        let sharing = Set(participants.filter { $0.screenSharing.isOn }.map(\.id))
        let active = Set(participants.map(\.id))
        viewports = viewports.filter { sharing.contains($0.key.participant) }
        renderedTiles = renderedTiles.filter {
            active.contains($0.key.participant) && (!$0.key.isShare || sharing.contains($0.key.participant))
        }
        updatePreferredVideo()
    }

    func makeView(model: JazzParticipantViewModel, video: UIView) -> UIView {
        let key = Key(participant: model.id, mode: model.displayMode, isShare: model.isSharingScreen)
        // The SDK also invokes this builder from layoutSubviews. Reparenting its
        // video view for an unchanged model would invalidate that same layout again.
        if let tile = renderedTiles[key], tile.model == model, let view = tile.view,
           tile.video === video, view.containsRenderer(video) {
            updatePreferredVideo()
            return view
        }
        let state: StreamViewportState
        if model.isSharingScreen {
            state = viewports[key] ?? StreamViewportState()
            viewports[key] = state
        } else {
            state = StreamViewportState()
        }
        let watermark: String?
        switch model.watermarkState {
        case .visible(let text): watermark = text
        case .hidden: watermark = nil
        }
        let view = StreamViewport(video: video, state: state,
                              zoomable: model.isSharingScreen && model.isZoomable,
                              name: model.name, showInfo: model.shouldShowParticipantInfo,
                              microphoneOn: model.isAudioOn, pinned: model.isPinned,
                              watermark: watermark,
                              showsPlaceholder: !model.isVideoOn && !model.isSharingScreen)
        renderedTiles[key] = RenderedTile(model: model, video: video, view: view)
        view.onVisibilityChanged = { [weak self] in self?.updatePreferredVideo() }
        updatePreferredVideo()
        return view
    }

    private func updatePreferredVideo() {
        guard !selectionUpdateScheduled else { return }
        selectionUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionUpdateScheduled = false
            self.publishPreferredVideo()
        }
    }

    private func publishPreferredVideo() {
        let available = renderedTiles.values.filter {
            displayMode != .audioOnly && isVisible($0.view) && $0.video != nil &&
            $0.model.displayMode != .pip && !$0.model.isLocal &&
            ($0.model.isSharingScreen || (displayMode == .all && $0.model.isVideoOn))
        }.sorted {
            func priority(_ tile: RenderedTile) -> Int {
                let content = tile.model.isPinned ? 0 : tile.model.isSharingScreen ? 10 : 20
                switch tile.model.displayMode {
                case .speaker: return content
                case .tile: return content + 1
                case .thumbnail: return content + 2
                case .pip: return content + 3
                @unknown default: return content + 4
                }
            }
            if priority($0) != priority($1) { return priority($0) < priority($1) }
            return $0.model.id < $1.model.id
        }
        let preferred = available.first
        onPreferredVideo?(preferred?.view, preferred?.model.name ?? "",
                          preferred?.model.isSharingScreen == true)
    }

    private func isVisible(_ view: UIView?) -> Bool {
        guard let view, let window = view.window, !view.bounds.isEmpty else { return false }
        var ancestor: UIView? = view
        while let current = ancestor {
            if current.isHidden || current.alpha < 0.01 { return false }
            ancestor = current.superview
        }
        return view.convert(view.bounds, to: window).intersects(window.bounds)
    }
}

#if DEBUG
final class GuestStreamViewportFixtureViewController: UIViewController {
    private let streams = GuestStreamViews()
    private let canvas = UIView()
    private var revision = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let refresh = UIButton(type: .system)
        refresh.setTitle("Refresh participant", for: .normal)
        refresh.addAction(UIAction { [weak self] _ in self?.replaceTile() }, for: .touchUpInside)
        let restart = UIButton(type: .system)
        restart.setTitle("Start new share", for: .normal)
        restart.addAction(UIAction { [weak self] _ in
            self?.streams.reset()
            self?.replaceTile()
        }, for: .touchUpInside)
        let buttons = UIStackView(arrangedSubviews: [refresh, restart])
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false
        canvas.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(canvas)
        view.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            buttons.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            buttons.heightAnchor.constraint(equalToConstant: 48),
            canvas.topAnchor.constraint(equalTo: buttons.bottomAnchor),
            canvas.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor),
            canvas.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor)
        ])
        replaceTile()
    }

    private func replaceTile() {
        revision += 1
        let video = UILabel()
        video.backgroundColor = .systemIndigo
        video.text = "Shared screen\nViewport persistence"
        video.textColor = .white
        video.font = .systemFont(ofSize: 30)
        video.textAlignment = .center
        video.numberOfLines = 0
        let model = JazzParticipantViewModel(
            name: "Participant update \(revision)", isAudioOn: revision.isMultiple(of: 2),
            isVideoOn: true, isPinned: false, isSharingScreen: true, isLocal: false,
            id: "fixture-share", isDominantSpeaker: false, shouldShowParticipantInfo: true,
            isZoomable: true, watermarkState: .hidden, displayMode: .speaker)
        let tile = streams.makeView(model: model, video: video)
        canvas.subviews.forEach { $0.removeFromSuperview() }
        canvas.addSubview(tile)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: canvas.leadingAnchor),
            tile.trailingAnchor.constraint(equalTo: canvas.trailingAnchor),
            tile.topAnchor.constraint(equalTo: canvas.topAnchor),
            tile.bottomAnchor.constraint(equalTo: canvas.bottomAnchor)
        ])
    }
}
#endif
