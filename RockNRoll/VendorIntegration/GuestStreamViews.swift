import Combine
import JazzSDK
import UIKit

/// View state belongs to the active share, not the SDK's short-lived participant tile.
final class GuestStreamViews {
    struct PinTarget: Hashable {
        let participant: String
        let isShare: Bool
    }
    struct Participant {
        let id: String
        let name: String
        let isLocal: Bool
        let microphoneOn: Bool
        let cameraOn: Bool
        let sharing: Bool
    }
    struct GalleryItem {
        let id: PinTarget
        let name: String
        let microphoneOn: Bool
        let active: Bool
        let speaking: Bool
        let watermark: String?
        let renderer: UIView?
        var mirrored = false
    }
    var onGalleryPresentation: (([GalleryItem]) -> Void)?
    var localCameraMirrored: () -> Bool = { true }
    private var cameraDeviceObservation: NSObjectProtocol?
    init() {
        cameraDeviceObservation = NotificationCenter.default.addObserver(
            forName: GuestCaptureDeviceObserver.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSelection() }
            }
    }
    deinit {
        if let cameraDeviceObservation { NotificationCenter.default.removeObserver(cameraDeviceObservation) }
    }
    struct Presentation: Equatable {
        let target: PinTarget?
        let name: String?
        let microphoneOn: Bool
        let watermark: String?
        let active: Bool
        let automatic: Bool
        let count: Int
        let browsing: Bool
        static let empty = Presentation(target: nil, name: nil, microphoneOn: false,
            watermark: nil, active: false, automatic: true, count: 0, browsing: false)
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
    private var participants: [String: Participant]?
    private var selectionUpdateScheduled = false
    private var preserveBackgroundSelection = false
    private var activeShares: Set<String>?
    private var activeCameras: Set<String>?
    private var activeParticipants = Set<String>()
    private var pinLossTask: Task<Void, Never>?
    private var pinLossGeneration = UUID()
    private(set) var pinnedTarget: PinTarget?
    private(set) var browsedTarget: PinTarget?
    private var orderedTargets: [PinTarget] = []
    private(set) var selectedTarget: PinTarget?
    let localCameraChanges = CurrentValueSubject<UIView?, Never>(nil)
    var onStagePresentation: ((Presentation) -> Void)?
    var onPreferredVideo: ((StreamViewport?, String, Bool) -> Void)?
    var onFloatingVideo: ((StreamViewport?, String, Bool, Bool) -> Void)?
    var onShareOffer: ((String?, PinTarget?) -> Void)?
    var displayMode: ConferenceDisplayMode = .all {
        didSet { updatePreferredVideo() }
    }

    /// A rebuilt SDK session must not reuse renderers from the old transport.
    /// Keep view selection when reconnecting to the same room.
    func reset(preservingSelection: Bool = false) {
        participantSubscription = nil
        participants = nil
        activeShares = nil
        activeCameras = nil
        activeParticipants.removeAll()
        pinLossTask?.cancel()
        pinLossTask = nil
        pinLossGeneration = UUID()
        if !preservingSelection {
            preserveBackgroundSelection = false
            pinnedTarget = nil
            browsedTarget = nil
            viewports.removeAll()
        }
        selectedTarget = nil
        orderedTargets = []
        onStagePresentation?(.empty)
        onGalleryPresentation?([])
        renderedTiles.removeAll()
        localCameraChanges.send(nil)
        onPreferredVideo?(nil, "", false)
        onFloatingVideo?(nil, "", false, false)
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
                self?.updateParticipants(([local] + Array(remote.values)).map {
                    Participant(id: $0.id, name: $0.userName ?? L("Musician"), isLocal: $0.isLocal,
                        microphoneOn: $0.microphone.isOn, cameraOn: $0.camera.isOn,
                        sharing: $0.screenSharing.isOn)
                })
            }
    }

    func updateParticipants(_ roster: [Participant]) {
        participants = Dictionary(uniqueKeysWithValues: roster.map { ($0.id, $0) })
        let sharing = Set(roster.filter { $0.sharing }.map(\.id))
        let cameras = Set(roster.filter { $0.cameraOn }.map(\.id))
        let active = Set(roster.map(\.id))
        updateActiveMedia(sharing: sharing, cameras: cameras, participants: active)
    }

    func updateActiveMedia(sharing: Set<String>, cameras: Set<String>, participants active: Set<String>) {
        activeShares = sharing
        activeCameras = cameras
        publishLocalCamera()
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

    private func publishLocalCamera() {
        let renderer = localCameraView()
        if renderer !== localCameraChanges.value { localCameraChanges.send(renderer) }
    }
    func localCameraView() -> UIView? {
        renderedTiles.values.filter { $0.model.isLocal && !$0.model.isSharingScreen && $0.model.isVideoOn && (activeCameras?.contains($0.model.id) ?? true) }
            .sorted(by: preferredSource).first?.video
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
            view.accessibilityElementsHidden = onStagePresentation != nil
            publishLocalCamera()
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
        view.accessibilityElementsHidden = onStagePresentation != nil
        renderedTiles[key] = RenderedTile(model: model, video: video, view: view)
        publishLocalCamera()
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

    func browse(_ offset: Int) {
        guard pinnedTarget == nil, orderedTargets.count > 1 else { return }
        let index = orderedTargets.firstIndex(of: browsedTarget ?? selectedTarget ?? orderedTargets[0]) ?? 0
        browsedTarget = orderedTargets[(index + offset % orderedTargets.count + orderedTargets.count) % orderedTargets.count]
        updatePreferredVideo()
    }

    func useAutomaticView() { browsedTarget = nil; setPin(nil); updatePreferredVideo() }
    func toggleSelectedPin() {
        guard let selectedTarget else { return }
        setPin(pinnedTarget == selectedTarget ? nil : selectedTarget)
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
        for tile in renderedTiles.values {
            tile.view?.isCameraMirrored = tile.model.isLocal && !tile.model.isSharingScreen && localCameraMirrored()
        }
        publishGallery()
        // The call window can become hidden while system PiP remains active.
        // Keep a signaled stream eligible until the participant ends it.
        let available = renderedTiles.values.filter {
            displayMode != .audioOnly && $0.view != nil && $0.video != nil &&
            (displayMode == .all || $0.model.isSharingScreen) &&
            ($0.model.displayMode != .pip || onStagePresentation != nil) && !$0.model.isLocal &&
            isActiveStream($0.model) &&
            (onStagePresentation != nil || preserveBackgroundSelection || isVisible($0.view) ||
                pinnedTarget == PinTarget(participant: $0.model.id,
                                          isShare: $0.model.isSharingScreen))
        }.sorted(by: preferredSource)
        let eligiblePin = pinnedTarget.flatMap { pin -> PinTarget? in
            if displayMode == .audioOnly || displayMode == .screenShares && !pin.isShare { return nil }
            return pin
        }
        var candidates: [PinTarget: RenderedTile] = [:]
        let hasRemote = participants?.values.contains { !$0.isLocal } ??
            renderedTiles.values.contains { !$0.model.isLocal }
        // Navigation describes the meeting, not the SDK's visible page. On a
        // phone the other renderers can have zero bounds or live offscreen.
        // Keep a source available for an explicitly selected participant too.
        for tile in renderedTiles.values.sorted(by: preferredSource) {
            guard tile.view != nil, participants == nil || participants?[tile.model.id] != nil,
                  !(tile.model.isLocal && (tile.model.isSharingScreen || !hasRemote && !isActiveStream(tile.model))),
                  displayMode != .audioOnly, displayMode == .all || tile.model.isSharingScreen else { continue }
            let target = PinTarget(participant: tile.model.id, isShare: tile.model.isSharingScreen)
            if candidates[target] == nil { candidates[target] = tile }
        }
        let targets: [PinTarget]
        if let participants {
            targets = participants.values.flatMap { participant -> [PinTarget] in
                guard displayMode != .audioOnly else { return [] }
                var result: [PinTarget] = []
                if displayMode == .all && (!participant.isLocal || participant.cameraOn || hasRemote) {
                    result.append(PinTarget(participant: participant.id, isShare: false))
                }
                if participant.sharing && !participant.isLocal {
                    result.append(PinTarget(participant: participant.id, isShare: true))
                }
                return result
            }
        } else {
            targets = Array(candidates.keys)
        }
        orderedTargets = targets.sorted {
            if $0.participant != $1.participant { return $0.participant < $1.participant }
            return !$0.isShare && $1.isShare
        }
        if let browsedTarget, !orderedTargets.contains(browsedTarget) { self.browsedTarget = nil }
        let requested = eligiblePin ?? browsedTarget
        // An idle self tile must not displace the waiting/invitation screen.
        let fallback = candidates.values.filter {
            onStagePresentation != nil || preserveBackgroundSelection || isVisible($0.view)
        }
        let automatic = available.first ?? fallback.filter { !$0.model.isLocal }.sorted { $0.model.id < $1.model.id }.first ??
            fallback.first { $0.model.isLocal && isActiveStream($0.model) }
        let chosen = requested.flatMap { candidates[$0] } ?? (requested == nil ? automatic : nil)
        let chosenTarget = chosen.map { PinTarget(participant: $0.model.id, isShare: $0.model.isSharingScreen) }
        let defaultTarget = orderedTargets.first { $0.isShare } ??
            orderedTargets.first { participants?[$0.participant]?.isLocal != true } ?? orderedTargets.first
        selectedTarget = requested ?? chosenTarget ?? defaultTarget
        let preferred = chosen.flatMap { isActiveStream($0.model) ? $0 : nil }
        let pinName = pinnedTarget.flatMap { target in
            renderedTiles.first { $0.key.participant == target.participant &&
                $0.key.isShare == target.isShare }?.value.model.name
        }
        if let pin = eligiblePin, !pin.isShare,
           let share = available.first(where: { $0.model.isSharingScreen }) {
            onShareOffer?(share.model.name,
                          PinTarget(participant: share.model.id, isShare: true))
        } else {
            onShareOffer?(nil, nil)
        }
        let participant = selectedTarget.flatMap { participants?[$0.participant] }
        let stageName = participant?.name ?? chosen?.model.name ?? (eligiblePin != nil ? pinName ?? L("Musician") : nil)
        let active = participant.map { selectedTarget?.isShare == true ? $0.sharing : $0.cameraOn } ?? (preferred != nil)
        let watermark: String?
        if case .visible(let text) = chosen?.model.watermarkState { watermark = text } else { watermark = nil }
        onStagePresentation?(Presentation(target: selectedTarget, name: stageName,
            microphoneOn: participant?.microphoneOn ?? (chosen?.model.isAudioOn == true), watermark: watermark,
            active: active, automatic: eligiblePin == nil,
            count: orderedTargets.count, browsing: browsedTarget != nil))
        renderedTiles.values.forEach { $0.view?.accessibilityElementsHidden = onStagePresentation != nil }
        onPreferredVideo?(preferred?.view, preferred == nil ? "" : stageName ?? "",
                          preferred?.model.isSharingScreen == true)
        // An automatic gallery can select an idle remote tile while the local
        // camera remains visible. Its live self view may keep this call in PiP,
        // without changing the foreground stage or its participant caption.
        let floating = preferred ?? (displayMode == .all && requested == nil
            ? candidates.values.first { $0.model.isLocal && !$0.model.isSharingScreen && isActiveStream($0.model) && $0.video != nil }
            : nil)
        onFloatingVideo?(floating?.view, floating?.model.name ?? "",
                         floating?.model.isSharingScreen == true,
                         floating?.view === preferred?.view && floating != nil)
    }

    private func publishGallery() {
        guard let onGalleryPresentation else { return }
        var source: [PinTarget: RenderedTile] = [:]
        for tile in renderedTiles.values.sorted(by: preferredSource) {
            let key = PinTarget(participant: tile.model.id, isShare: tile.model.isSharingScreen)
            if source[key] == nil { source[key] = tile }
        }
        let roster = participants?.values.sorted { $0.id < $1.id } ?? []
        let items = roster.flatMap { participant -> [GalleryItem] in
            var result: [GalleryItem] = []
            for isShare in [false, true] {
                guard displayMode != .audioOnly, displayMode == .all || isShare,
                      !isShare || participant.sharing && !participant.isLocal else { continue }
                let id = PinTarget(participant: participant.id, isShare: isShare)
                let tile = source[id]
                let watermark: String?
                if case .visible(let text) = tile?.model.watermarkState { watermark = text } else { watermark = nil }
                result.append(GalleryItem(id: id, name: participant.name, microphoneOn: participant.microphoneOn,
                    active: isShare ? participant.sharing : participant.cameraOn,
                    speaking: tile?.model.isDominantSpeaker == true, watermark: watermark,
                    renderer: tile?.video, mirrored: participant.isLocal && !isShare && localCameraMirrored()))
            }
            return result
        }
        onGalleryPresentation(items)
    }

    private func preferredSource(_ lhs: RenderedTile, _ rhs: RenderedTile) -> Bool {
        func priority(_ tile: RenderedTile) -> Int {
            let content = tile.model.isPinned ? 0 : tile.model.isSharingScreen ? 10 : tile.model.isDominantSpeaker ? 20 : 30
            switch tile.model.displayMode {
            case .speaker: return content
            case .tile: return content + 1
            case .thumbnail: return content + 2
            case .pip: return content + 3
            @unknown default: return content + 4
            }
        }
        if priority(lhs) != priority(rhs) { return priority(lhs) < priority(rhs) }
        if lhs.model.id != rhs.model.id { return lhs.model.id < rhs.model.id }
        return lhs.model.isSharingScreen && !rhs.model.isSharingScreen
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
        refresh.setTitle(L("Refresh participant"), for: .normal)
        refresh.addAction(UIAction { [weak self] _ in self?.replaceTile() }, for: .touchUpInside)
        let restart = UIButton(type: .system)
        restart.setTitle(L("Start new share"), for: .normal)
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
