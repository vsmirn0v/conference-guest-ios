import Combine
import JazzSDK
import UIKit

/// View state belongs to the active share, not the SDK's short-lived participant tile.
final class GuestStreamViews {
    struct PinTarget: Hashable {
        let participant: String
        let isShare: Bool
    }
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
    private var preserveBackgroundSelection = false
    private var activeShares: Set<String>?
    private var activeCameras: Set<String>?
    private var activeParticipants = Set<String>()
    private var pinLossTask: Task<Void, Never>?
    private var pinLossGeneration = UUID()
    private(set) var pinnedTarget: PinTarget?
    var onPreferredVideo: ((StreamViewport?, String, Bool) -> Void)?
    var onPinPresentation: ((PinTarget?, String?, Bool) -> Void)?
    var onShareOffer: ((String?, PinTarget?) -> Void)?
    var displayMode: ConferenceDisplayMode = .all {
        didSet { updatePreferredVideo() }
    }

    private var pinStageVisible: Bool {
        guard let pinnedTarget else { return false }
        return displayMode == .all || displayMode == .screenShares && pinnedTarget.isShare
    }

    func reset() {
        participantSubscription = nil
        preserveBackgroundSelection = false
        activeShares = nil
        activeCameras = nil
        activeParticipants.removeAll()
        pinLossTask?.cancel()
        pinLossTask = nil
        pinLossGeneration = UUID()
        pinnedTarget = nil
        viewports.removeAll()
        renderedTiles.removeAll()
        onPreferredVideo?(nil, "", false)
        onPinPresentation?(nil, nil, false)
        onShareOffer?(nil, nil)
    }

    func setBackgrounded(_ backgrounded: Bool) {
        guard preserveBackgroundSelection != backgrounded else { return }
        preserveBackgroundSelection = backgrounded
        updatePreferredVideo()
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
        let cameras = Set(participants.filter { $0.camera.isOn }.map(\.id))
        let active = Set(participants.map(\.id))
        updateActiveMedia(sharing: sharing, cameras: cameras, participants: active)
    }

    func updateActiveMedia(sharing: Set<String>, cameras: Set<String>, participants active: Set<String>) {
        activeShares = sharing
        activeCameras = cameras
        activeParticipants = active
        if let pin = pinnedTarget,
           !active.contains(pin.participant) {
            if pinLossTask == nil {
                let generation = UUID()
                pinLossGeneration = generation
                pinLossTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(8))
                    guard let self, !Task.isCancelled,
                          self.pinLossGeneration == generation else { return }
                    if !self.activeParticipants.contains(pin.participant) && self.pinnedTarget == pin {
                        self.setPin(nil)
                    }
                    self.pinLossTask = nil
                }
            }
        } else {
            pinLossTask?.cancel()
            pinLossTask = nil
            pinLossGeneration = UUID()
            if let pin = pinnedTarget, pin.isShare && !sharing.contains(pin.participant) {
                pinnedTarget = nil
            }
        }
        // A renderer can retain its last frame after its camera track ends.
        // Hide it before dropping the tile, even if the SDK keeps that view onscreen.
        for tile in renderedTiles.values {
            tile.view?.setMediaActive(active.contains(tile.model.id) && isActiveStream(tile.model))
        }
        viewports = viewports.filter { sharing.contains($0.key.participant) }
        renderedTiles = renderedTiles.filter {
            active.contains($0.key.participant) && (!$0.key.isShare || sharing.contains($0.key.participant))
        }
        updatePreferredVideo()
    }

    func makeView(model: JazzParticipantViewModel, video: UIView) -> UIView {
        let key = Key(participant: model.id, mode: model.displayMode, isShare: model.isSharingScreen)
        let target = PinTarget(participant: model.id, isShare: model.isSharingScreen)
        let onPin: (() -> Void)? = model.isLocal && model.isSharingScreen ? nil : { [weak self] in
            self?.setPin(self?.pinnedTarget == target ? nil : target)
        }
        let watermark: String?
        switch model.watermarkState {
        case .visible(let text): watermark = text
        case .hidden: watermark = nil
        @unknown default: watermark = nil
        }
        let placeholderText = model.isLocal && model.isSharingScreen ? "" : nil
        // The SDK also invokes this builder from layoutSubviews. Reparenting its
        // video view for an unchanged model would invalidate that same layout again.
        // Speaker/microphone/name updates do not replace the decoded stream:
        // rebuilding its viewport would briefly expose the brighter SDK renderer.
        if let tile = renderedTiles[key], let view = tile.view,
           tile.video === video, view.containsRenderer(video) {
            if tile.model != model {
                renderedTiles[key] = RenderedTile(model: model, video: video, view: view)
                view.updatePresentation(name: model.name, showInfo: model.shouldShowParticipantInfo,
                                        microphoneOn: model.isAudioOn, pinned: model.isPinned,
                                        watermark: watermark, zoomable: model.isSharingScreen && model.isZoomable,
                                        placeholderText: placeholderText)
            }
            view.updatePin(name: model.name, isShare: model.isSharingScreen,
                           pinned: pinnedTarget == target, onPin: onPin)
            view.setMediaActive(isActiveStream(model))
            view.accessibilityElementsHidden = pinStageVisible && onPinPresentation != nil
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
        let view = StreamViewport(video: video, state: state,
                              zoomable: model.isSharingScreen && model.isZoomable,
                              name: model.name, showInfo: model.shouldShowParticipantInfo,
                              microphoneOn: model.isAudioOn, pinned: model.isPinned,
                              watermark: watermark,
                              showsPlaceholder: !model.isVideoOn && !model.isSharingScreen ||
                                  model.isLocal && model.isSharingScreen,
                              placeholderText: placeholderText,
                              onPin: onPin)
        view.updatePin(name: model.name, isShare: model.isSharingScreen,
                       pinned: pinnedTarget == target, onPin: onPin)
        view.setMediaActive(isActiveStream(model))
        view.accessibilityElementsHidden = pinStageVisible && onPinPresentation != nil
        renderedTiles[key] = RenderedTile(model: model, video: video, view: view)
        view.onVisibilityChanged = { [weak self] in self?.updatePreferredVideo() }
        updatePreferredVideo()
        return view
    }

    func setPin(_ target: PinTarget?) {
        guard pinnedTarget != target else { return }
        pinnedTarget = target
        for (key, tile) in renderedTiles {
            tile.view?.updatePin(name: tile.model.name, isShare: key.isShare,
                                 pinned: target == PinTarget(participant: key.participant,
                                                             isShare: key.isShare),
                                 onPin: tile.model.isLocal && key.isShare ? nil : { [weak self] in
                let selected = PinTarget(participant: key.participant, isShare: key.isShare)
                self?.setPin(self?.pinnedTarget == selected ? nil : selected)
            })
        }
        updatePreferredVideo()
    }

    func refreshSelection() { updatePreferredVideo() }

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
        // The call window can become hidden while system PiP remains active.
        // Keep a signaled stream eligible until the participant ends it.
        let available = renderedTiles.values.filter {
            displayMode != .audioOnly && $0.view != nil && $0.video != nil &&
            (displayMode == .all || $0.model.isSharingScreen) &&
            $0.model.displayMode != .pip && !$0.model.isLocal &&
            isActiveStream($0.model) &&
            (preserveBackgroundSelection || isVisible($0.view) ||
                pinnedTarget == PinTarget(participant: $0.model.id,
                                          isShare: $0.model.isSharingScreen))
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
        let eligiblePin = pinnedTarget.flatMap { pin -> PinTarget? in
            if displayMode == .audioOnly || displayMode == .screenShares && !pin.isShare { return nil }
            return pin
        }
        for tile in renderedTiles.values {
            tile.view?.accessibilityElementsHidden = eligiblePin != nil && onPinPresentation != nil
        }
        let preferred = eligiblePin == nil ? available.first : available.first {
            $0.model.id == eligiblePin?.participant && $0.model.isSharingScreen == eligiblePin?.isShare
        }
        let pinName = pinnedTarget.flatMap { target in
            renderedTiles.first { $0.key.participant == target.participant &&
                $0.key.isShare == target.isShare }?.value.model.name
        }
        onPinPresentation?(eligiblePin, eligiblePin == nil ? nil : (pinName ?? "Musician"),
                           preferred != nil)
        if let pin = eligiblePin, !pin.isShare,
           let share = available.first(where: { $0.model.isSharingScreen }) {
            onShareOffer?(share.model.name,
                          PinTarget(participant: share.model.id, isShare: true))
        } else {
            onShareOffer?(nil, nil)
        }
        onPreferredVideo?(preferred?.view, preferred?.model.name ?? "",
                          preferred?.model.isSharingScreen == true)
    }

    private func isActiveStream(_ model: JazzParticipantViewModel) -> Bool {
        if model.isSharingScreen {
            // The SDK's local broadcast renderer is a solid red preview; the
            // ReplayKit extension still sends the real screen to other peers.
            if model.isLocal { return false }
            return activeShares?.contains(model.id) ?? true
        }
        return model.isVideoOn && (activeCameras?.contains(model.id) ?? true)
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
