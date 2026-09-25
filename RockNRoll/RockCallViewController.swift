import AVKit
import Combine
import LiveKit
import UIKit

@MainActor
final class RockCallViewController: UIViewController, UIScrollViewDelegate {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .allButUpsideDown }
    override var shouldAutorotate: Bool { true }
    var onLeave: (() -> Void)?
    var onMicrophone: ((Bool) -> Void)?
    var onCamera: ((Bool) -> Void)?
    var onFlipCamera: (() -> Void)?
    var onSpeaker: ((Bool) -> Void)?
    var onDisplayMode: ((ConferenceDisplayMode) -> Void)?

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let routeLabel = UILabel()
    private let statusLabel = UILabel()
    private let tiles = UIStackView()
    private let streamScroll = UIScrollView()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let flipCamera = UIButton(type: .system)
    private let speaker = UIButton(type: .system)
    private let displayModeButton = UIButton(type: .system)
    private let conversationButton = UIButton(type: .system)
    private let missedButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let moreButton = UIButton(type: .system)
    private let fitButton = UIButton(type: .system)
    private var currentPrimaryKey: String?
    private var floatingVideo: RockVideoPictureInPicture?
    private var zoomStates: [String: (CGFloat, CGPoint)] = [:]
    private weak var primaryZoom: UIScrollView?
    private weak var participantsPanel: ParticipantPanelViewController?
    private var pinnedStreamKey: String?
    private var speakingLabels: [String: UILabel] = [:]
    private var speakingTiles: [String: [UIView]] = [:]
    private let store: CatchUpStore
    private let chat: ChatStore
    private let workspace = CallWorkspaceControls()
    private weak var displayedRoom: Room?
    private var displayMode: ConferenceDisplayMode = .all
    private var isMicrophoneOn = false
    private var isCameraOn = false
    private var isSpeakerOn = true
    private var isHeld = false
    private var mediaStatus: String?
    private var subscriptions = Set<AnyCancellable>()
    private let accent = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)

    init(title: String, catchUp: CatchUpStore, chat: ChatStore,
         invitationURL: URL? = nil, roomIdentifier: String? = nil) {
        store = catchUp
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        titleLabel.text = title
        workspace.invitationURL = invitationURL
        workspace.roomIdentifier = roomIdentifier
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        floatingVideo?.refreshPreference()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.085, alpha: 1)
        floatingVideo = RockVideoPictureInPicture(sourceView: view)
        let identity = UIStackView(arrangedSubviews: [titleLabel, countLabel, routeLabel])
        identity.axis = .vertical
        identity.spacing = 2
        let header = UIStackView(arrangedSubviews: [identity, participantsButton,
                                                    missedButton, conversationButton])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = 4
        header.setContentHuggingPriority(.required, for: .vertical)
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = .lightGray
        countLabel.text = "Connecting…"
        routeLabel.font = .preferredFont(forTextStyle: .caption1)
        routeLabel.textColor = .lightGray
        routeLabel.text = "Audio output"

        tiles.axis = .vertical
        tiles.spacing = 10
        streamScroll.addSubview(tiles)
        tiles.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tiles.leadingAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.trailingAnchor),
            tiles.topAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: streamScroll.contentLayoutGuide.bottomAnchor),
            tiles.widthAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.widthAnchor)
        ])

        configure(microphone, symbol: "mic.slash.fill", label: "Unmute microphone", title: "Mic off")
        configure(camera, symbol: "video.slash.fill", label: "Start video", title: "Cam off")
        microphone.configuration?.baseForegroundColor = .white
        camera.configuration?.baseForegroundColor = .white
        configure(flipCamera, symbol: "arrow.triangle.2.circlepath.camera", label: "Flip camera")
        flipCamera.isEnabled = false
        configure(speaker, symbol: "speaker.wave.2.fill", label: "Use iPhone speaker")
        configure(displayModeButton, symbol: displayMode.symbol, label: "Display: All video")
        displayModeButton.showsMenuAsPrimaryAction = true
        configureModeMenu()
        configure(conversationButton, symbol: "text.bubble", label: "Chat")
        configure(missedButton, symbol: "clock.arrow.circlepath", label: "Catch up")
        missedButton.isHidden = true
        missedButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.catchUp)
        }, for: .touchUpInside)
        configure(participantsButton, symbol: "person.2.fill", label: "Musicians")
        configure(moreButton, symbol: "ellipsis.circle.fill", label: "More call options", title: "More")
        moreButton.showsMenuAsPrimaryAction = true
        configureMoreMenu()
        configure(fitButton, symbol: "arrow.down.right.and.arrow.up.left", label: "Fit screen to view")
        fitButton.isHidden = true
        fitButton.addAction(UIAction { [weak self] _ in
            self?.primaryZoom?.setZoomScale(1, animated: true)
        }, for: .touchUpInside)
        participantsButton.isEnabled = false
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = accent
        routePicker.activeTintColor = accent
        routePicker.accessibilityLabel = "Choose audio output"
        let leave = UIButton(type: .system)
        configure(leave, symbol: "phone.down.fill", label: "Leave", title: "Leave")
        leave.configuration?.baseForegroundColor = .systemRed

        microphone.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onMicrophone?(!self.isMicrophoneOn)
        }, for: .touchUpInside)
        camera.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onCamera?(!self.isCameraOn)
        }, for: .touchUpInside)
        flipCamera.addAction(UIAction { [weak self] _ in self?.onFlipCamera?() }, for: .touchUpInside)
        speaker.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.isSpeakerOn.toggle()
            self.workspace.speakerOn = self.isSpeakerOn
            self.onSpeaker?(self.isSpeakerOn)
            self.speaker.accessibilityLabel = self.isSpeakerOn ? "Use iPhone receiver" : "Use iPhone speaker"
        }, for: .touchUpInside)
        conversationButton.addAction(UIAction { [weak self] _ in
            self?.openConversation(.chat)
        }, for: .touchUpInside)
        participantsButton.addAction(UIAction { [weak self] _ in
            guard let self, let room = self.displayedRoom, self.presentedViewController == nil else { return }
            let panel = ParticipantPanelViewController()
            panel.onPin = { [weak self] key in
                guard let self else { return }
                self.pinnedStreamKey = key
                if let room = self.displayedRoom { self.render(room: room) }
            }
            self.participantsPanel = panel
            panel.update(self.statuses(in: room), pinnedKey: self.pinnedStreamKey)
            let navigation = UINavigationController(rootViewController: panel)
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            self.present(navigation, animated: true)
        }, for: .touchUpInside)
        leave.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .touchUpInside)
        workspace.toggleMicrophone = { [weak self] in self?.microphone.sendActions(for: .touchUpInside) }
        workspace.toggleCamera = { [weak self] in self?.camera.sendActions(for: .touchUpInside) }
        workspace.toggleSpeaker = { [weak self] in self?.speaker.sendActions(for: .touchUpInside) }
        workspace.leave = { [weak self] in leave.sendActions(for: .touchUpInside); self?.workspace.onHold = false }

        let audioControl = UIView()
        routePicker.translatesAutoresizingMaskIntoConstraints = false
        audioControl.addSubview(routePicker)
        let audioTitle = UILabel()
        audioTitle.text = "Audio"
        audioTitle.font = .preferredFont(forTextStyle: .caption2)
        audioTitle.textColor = .white
        audioTitle.translatesAutoresizingMaskIntoConstraints = false
        audioControl.addSubview(audioTitle)
        NSLayoutConstraint.activate([
            routePicker.centerXAnchor.constraint(equalTo: audioControl.centerXAnchor),
            routePicker.centerYAnchor.constraint(equalTo: audioControl.centerYAnchor, constant: -7),
            routePicker.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            routePicker.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            audioTitle.centerXAnchor.constraint(equalTo: audioControl.centerXAnchor),
            audioTitle.bottomAnchor.constraint(equalTo: audioControl.bottomAnchor, constant: -4)
        ])
        audioControl.accessibilityLabel = "Audio output"
        let bar = UIStackView(arrangedSubviews: [microphone, camera, audioControl, moreButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 4
        bar.backgroundColor = UIColor(red: 0.12, green: 0.14, blue: 0.21, alpha: 0.96)
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.text = "Microphone and camera are off"
        statusLabel.textAlignment = .center
        for item in [header, streamScroll, bar, statusLabel, fitButton] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            participantsButton.widthAnchor.constraint(equalToConstant: 48),
            participantsButton.heightAnchor.constraint(equalToConstant: 48),
            missedButton.widthAnchor.constraint(equalToConstant: 48).withPriority(.defaultHigh),
            missedButton.heightAnchor.constraint(equalToConstant: 48),
            conversationButton.widthAnchor.constraint(equalToConstant: 48),
            conversationButton.heightAnchor.constraint(equalToConstant: 48),
            streamScroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            streamScroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            streamScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            streamScroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -5),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -5),
            bar.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            bar.widthAnchor.constraint(equalTo: view.safeAreaLayoutGuide.widthAnchor, constant: -16).withPriority(.defaultHigh),
            bar.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 62),
            fitButton.topAnchor.constraint(equalTo: streamScroll.topAnchor, constant: 12),
            fitButton.trailingAnchor.constraint(equalTo: streamScroll.trailingAnchor, constant: -12),
            fitButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            fitButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        Publishers.CombineLatest(chat.$unreadCount, store.$timeline)
            .receive(on: DispatchQueue.main).sink { [weak self] count, timeline in
            guard let self else { return }
            self.conversationButton.configuration?.title = count > 0 ? "\(count)" : nil
            self.missedButton.isHidden = timeline.unreadCount == 0
            self.missedButton.configuration?.title = timeline.unreadCount > 0 ?
                "\(timeline.unreadCount)" : nil
            self.missedButton.accessibilityLabel = "Catch up, \(timeline.unreadCount) missed " +
                (timeline.unreadCount == 1 ? "section" : "sections")
            self.conversationButton.accessibilityLabel = count > 0 ?
                "Chat, \(count) unread" : "Chat"
        }.store(in: &subscriptions)
    }

    private func openConversation(_ selected: ConversationMode) {
        guard presentedViewController == nil else { return }
        present(ConversationPanelViewController(catchUp: store, chat: chat,
                                                initialMode: selected, call: workspace),
                animated: true)
    }

    func render(room: Room) {
        displayedRoom = room
        let participants: [Participant] = [room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "")
        }
        let identifier = workspace.roomIdentifier.map { " · \($0)" } ?? ""
        countLabel.text = room.remoteParticipants.isEmpty ? "Only you here\(identifier)" :
            "\(participants.count) musicians\(identifier)"
        participantsButton.isEnabled = true
        participantsButton.accessibilityLabel = "Musicians, \(participants.count)"
        participantsPanel?.update(statuses(in: room), pinnedKey: pinnedStreamKey)
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        speakingLabels.removeAll()
        speakingTiles.removeAll()
        var streams: [(Participant, TrackPublication, VideoTrack)] = []
        for participant in participants {
            let publications = participant.videoTracks.filter { !$0.isMuted && $0.track is VideoTrack }
                .filter { displayMode == .all ||
                    (displayMode == .screenShares && $0.source == .screenShareVideo) }
            if displayMode == .audioOnly ||
                (displayMode == .all && publications.isEmpty && !room.remoteParticipants.isEmpty) {
                tiles.addArrangedSubview(audioTile(for: participant))
            }
            for publication in publications where displayMode != .audioOnly {
                guard let track = publication.track as? VideoTrack else { continue }
                streams.append((participant, publication, track))
            }
        }
        if let pin = pinnedStreamKey, !streams.contains(where: { $0.1.sid.stringValue == pin }) {
            pinnedStreamKey = nil
        }
        let primary = streams.first { $0.1.sid.stringValue == pinnedStreamKey } ??
            streams.first { $0.1.source == .screenShareVideo } ??
            streams.first { $0.0 is RemoteParticipant } ?? streams.first
        if let primary {
            let primaryKey = primary.1.sid.stringValue
            floatingVideo?.show(track: primary.0 is RemoteParticipant ? primary.2 : nil,
                                name: primary.0.name ?? "Musician",
                                isScreenShare: primary.1.source == .screenShareVideo)
            // The selected stream fills the available viewing area. Other streams remain below it.
            let primaryTile = videoTile(for: primary.0, publication: primary.1,
                                        track: primary.2, primary: true)
            tiles.insertArrangedSubview(primaryTile, at: 0)
            primaryTile.heightAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.heightAnchor).isActive = true
            for stream in streams where stream.1.sid != primary.1.sid {
                tiles.addArrangedSubview(videoTile(for: stream.0, publication: stream.1,
                                                    track: stream.2, primary: false))
            }
            if currentPrimaryKey != primaryKey { streamScroll.setContentOffset(.zero, animated: false) }
            currentPrimaryKey = primaryKey
        } else {
            floatingVideo?.clear()
            currentPrimaryKey = nil
            primaryZoom = nil
            fitButton.isHidden = true
        }
        if displayMode == .screenShares && streams.isEmpty {
            let empty = UILabel()
            empty.text = "No screen share is live. Audio continues."
            empty.textColor = .lightGray
            empty.textAlignment = .center
            empty.numberOfLines = 0
            tiles.addArrangedSubview(empty)
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
        if room.remoteParticipants.isEmpty && streams.isEmpty && displayMode == .all {
            let waiting = waitingRoomView()
            tiles.addArrangedSubview(waiting)
            waiting.heightAnchor.constraint(equalTo: streamScroll.frameLayoutGuide.heightAnchor).isActive = true
        }
        refreshSpeaking(room: room)
        configureMoreMenu()
    }

    private func waitingRoomView() -> UIView {
        let view = UIView()
        let title = UILabel()
        title.text = "You're connected. Waiting for others."
        title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title3)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.textAlignment = .center
        let column = UIStackView(arrangedSubviews: [title])
        column.axis = .vertical
        column.alignment = .center
        column.spacing = 12
        if workspace.invitationURL != nil {
            let invite = UIButton(type: .system)
            invite.configuration = .tinted()
            invite.configuration?.title = "Invite musicians"
            invite.configuration?.image = UIImage(systemName: "square.and.arrow.up")
            invite.tintColor = accent
            invite.addAction(UIAction { [weak self] _ in
                guard let self else { return }
                self.workspace.shareInvitation(from: invite)
            }, for: .touchUpInside)
            let copy = UIButton(type: .system)
            copy.configuration = .plain()
            copy.configuration?.title = "Copy link"
            copy.tintColor = accent
            copy.addAction(UIAction { [weak self] _ in self?.workspace.copyInvitation() },
                           for: .touchUpInside)
            column.addArrangedSubview(invite)
            column.addArrangedSubview(copy)
        }
        column.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            column.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 16),
            column.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -16)
        ])
        return view
    }

    private func audioTile(for participant: Participant) -> UIView {
        let tile = baseTile()
        let name = UILabel()
        name.text = participant.name ?? "Musician"
        name.textColor = .white
        name.font = .systemFont(ofSize: 16, weight: .semibold)
        let state = UILabel()
        state.text = participant.audioTracks.contains { !$0.isMuted } ? "Microphone on" : "Microphone off"
        state.textColor = .lightGray
        state.font = .preferredFont(forTextStyle: .caption1)
        let id = participantID(participant)
        speakingLabels[id] = state
        speakingTiles[id, default: []].append(tile)
        let column = UIStackView(arrangedSubviews: [name, state])
        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(column)
        NSLayoutConstraint.activate([
            tile.heightAnchor.constraint(equalToConstant: 72),
            column.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 14),
            column.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -14),
            column.centerYAnchor.constraint(equalTo: tile.centerYAnchor)
        ])
        return tile
    }

    private func videoTile(for participant: Participant, publication: TrackPublication,
                           track: VideoTrack, primary: Bool) -> UIView {
        let isShare = publication.source == .screenShareVideo
        let tile = baseTile()
        let zoom = UIScrollView()
        zoom.minimumZoomScale = 1
        zoom.maximumZoomScale = isShare ? 5 : 2
        zoom.bouncesZoom = true
        zoom.delegate = self
        let key = publication.sid.stringValue
        zoom.accessibilityIdentifier = key
        zoom.accessibilityLabel = isShare ? "Pinch to zoom screen share" : "Video stream"
        zoom.accessibilityValue = "100%"
        zoom.translatesAutoresizingMaskIntoConstraints = false
        let video = VideoView()
        video.layoutMode = isShare ? .fit : .fill
        video.track = track
        video.translatesAutoresizingMaskIntoConstraints = false
        zoom.addSubview(video)
        tile.addSubview(zoom)
        let name = UILabel()
        name.text = "  \(participant.name ?? "Musician") · \(isShare ? "Screen" : "Video") · \(pinnedStreamKey == key ? "Pinned" : "Auto")  "
        name.textColor = .white
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        name.layer.cornerRadius = 7
        name.clipsToBounds = true
        name.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(name)
        let pin = UIButton(type: .system)
        pin.configuration = .tinted()
        pin.configuration?.image = UIImage(systemName: pinnedStreamKey == key ? "pin.slash.fill" : "pin.fill")
        pin.accessibilityLabel = pinnedStreamKey == key ? "Unpin \(participant.name ?? "Musician") \(isShare ? "screen" : "video")" :
            "Pin \(participant.name ?? "Musician") \(isShare ? "screen" : "video")"
        pin.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.pinnedStreamKey = self.pinnedStreamKey == key ? nil : key
            if let room = self.displayedRoom { self.render(room: room) }
        }, for: .touchUpInside)
        pin.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(pin)
        if participant === displayedRoom?.localParticipant && !isShare {
            flipCamera.isHidden = !isCameraOn
            flipCamera.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(flipCamera)
            NSLayoutConstraint.activate([
                flipCamera.topAnchor.constraint(equalTo: tile.topAnchor, constant: 8),
                flipCamera.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -8),
                flipCamera.widthAnchor.constraint(equalToConstant: 44),
                flipCamera.heightAnchor.constraint(equalToConstant: 44)
            ])
        }
        speakingTiles[participantID(participant), default: []].append(tile)
        if !primary {
            tile.heightAnchor.constraint(equalToConstant: isShare ? 240 : 185).isActive = true
        }
        NSLayoutConstraint.activate([
            zoom.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            zoom.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            zoom.topAnchor.constraint(equalTo: tile.topAnchor),
            zoom.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            video.leadingAnchor.constraint(equalTo: zoom.contentLayoutGuide.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: zoom.contentLayoutGuide.trailingAnchor),
            video.topAnchor.constraint(equalTo: zoom.contentLayoutGuide.topAnchor),
            video.bottomAnchor.constraint(equalTo: zoom.contentLayoutGuide.bottomAnchor),
            video.widthAnchor.constraint(equalTo: zoom.frameLayoutGuide.widthAnchor),
            video.heightAnchor.constraint(equalTo: zoom.frameLayoutGuide.heightAnchor),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            name.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -10),
            pin.trailingAnchor.constraint(equalTo: tile.trailingAnchor, constant: -10),
            pin.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -8),
            pin.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            pin.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        ])
        if primary { primaryZoom = zoom }
        if let state = zoomStates[key] {
            DispatchQueue.main.async { [weak zoom] in
                guard let zoom, zoom.window != nil else { return }
                zoom.setZoomScale(state.0, animated: false)
                zoom.setContentOffset(state.1, animated: false)
            }
        }
        return tile
    }

    private func participantID(_ participant: Participant) -> String {
        participant.sid?.stringValue ?? "local"
    }

    private func statuses(in room: Room) -> [ParticipantStatus] {
        let participants: [Participant] = [room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.name ?? "") < ($1.name ?? "")
        }
        return participants.map { participant in
            let videos = participant.videoTracks.filter { !$0.isMuted }
            return ParticipantStatus(id: participantID(participant),
                name: participant.name ?? "Musician", isLocal: participant === room.localParticipant,
                microphoneOn: participant.audioTracks.contains { !$0.isMuted },
                cameraOn: videos.contains { $0.source != .screenShareVideo },
                screenShareOn: videos.contains { $0.source == .screenShareVideo },
                isSpeaking: participant.isSpeaking,
                videoKey: videos.first { $0.source != .screenShareVideo && $0.track is VideoTrack }?.sid.stringValue,
                shareKey: videos.first { $0.source == .screenShareVideo && $0.track is VideoTrack }?.sid.stringValue)
        }
    }

    func refreshSpeaking(room: Room) {
        participantsPanel?.update(statuses(in: room), pinnedKey: pinnedStreamKey)
        for participant in [room.localParticipant] + Array(room.remoteParticipants.values) {
            let id = participantID(participant)
            if let label = speakingLabels[id] {
                label.text = participant.isSpeaking ? "Speaking" :
                    (participant.audioTracks.contains { !$0.isMuted } ? "Microphone on" : "Microphone off")
                label.textColor = participant.isSpeaking ? .systemGreen : .lightGray
            }
            for tile in speakingTiles[id] ?? [] {
                tile.layer.borderWidth = participant.isSpeaking ? 3 : 0
                tile.layer.borderColor = UIColor.systemGreen.cgColor
            }
        }
    }

    private func baseTile() -> UIView {
        let tile = UIView()
        tile.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
        tile.layer.cornerRadius = 14
        tile.clipsToBounds = true
        return tile
    }

    private func configureModeMenu() {
        displayModeButton.menu = UIMenu(children: ConferenceDisplayMode.allCases.map { option in
            UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                     state: option == displayMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.displayMode = option
                self.displayModeButton.configuration?.image = UIImage(systemName: option.symbol)
                self.displayModeButton.accessibilityLabel = "Display: \(option.title)"
                self.configureModeMenu()
                if let room = self.displayedRoom { self.render(room: room) }
                self.onDisplayMode?(option)
            }
        })
    }

    private func configureMoreMenu() {
        moreButton.accessibilityValue = floatingVideo?.canShow == true ? "Floating video available" : nil
        var items: [UIMenuElement] = []
        if workspace.invitationURL != nil {
            items.append(UIAction(title: "Invite musicians", image: UIImage(systemName: "square.and.arrow.up")) {
                [weak self] _ in guard let self else { return }
                self.workspace.shareInvitation(from: self.moreButton)
            })
            items.append(UIAction(title: "Copy link", image: UIImage(systemName: "doc.on.doc")) {
                [weak self] _ in self?.workspace.copyInvitation()
            })
        }
        items += [
            UIAction(title: "Show floating video", image: UIImage(systemName: "pip.enter"),
                     attributes: floatingVideo?.canShow == true && !isHeld ? [] : [.disabled]) {
                [weak self] _ in self?.floatingVideo?.start(manual: true)
            },
            UIAction(title: "Floating video when multitasking",
                     image: UIImage(systemName: "pip"),
                     state: FloatingVideoPreference.enabled ? .on : .off) { [weak self] _ in
                FloatingVideoPreference.enabled.toggle()
                self?.floatingVideo?.refreshPreference()
                self?.configureMoreMenu()
            },
            UIMenu(title: "View", children: ConferenceDisplayMode.allCases.map { option in
                UIAction(title: option.title, image: UIImage(systemName: option.symbol),
                         state: option == displayMode ? .on : .off) { [weak self] _ in
                    guard let self else { return }
                    self.displayMode = option
                    self.configureMoreMenu()
                    if let room = self.displayedRoom { self.render(room: room) }
                    self.onDisplayMode?(option)
                }
            }),
            UIAction(title: isSpeakerOn ? "Use iPhone receiver" : "Use iPhone speaker",
                     image: UIImage(systemName: "speaker.wave.2")) { [weak self] _ in
                guard let self else { return }
                self.isSpeakerOn.toggle()
                self.workspace.speakerOn = self.isSpeakerOn
                self.onSpeaker?(self.isSpeakerOn)
                self.configureMoreMenu()
            },
            UIAction(title: "Flip camera", image: UIImage(systemName: "camera.rotate"),
                     attributes: isCameraOn ? [] : [.disabled]) { [weak self] _ in
                self?.onFlipCamera?()
            }
        ]
        moreButton.menu = UIMenu(children: items)
    }

    func setMicrophone(_ enabled: Bool) {
        isMicrophoneOn = enabled
        workspace.microphoneOn = enabled
        microphone.configuration?.image = UIImage(systemName: enabled ? "mic.fill" : "mic.slash.fill")
        microphone.configuration?.title = enabled ? "Mic on" : "Mic off"
        microphone.configuration?.baseForegroundColor = enabled ? accent : .white
        microphone.accessibilityLabel = enabled ? "Mute microphone" : "Unmute microphone"
        microphone.largeContentTitle = microphone.accessibilityLabel
        updateStatus()
    }

    func setCamera(_ enabled: Bool) {
        isCameraOn = enabled
        workspace.cameraOn = enabled
        flipCamera.isEnabled = enabled
        configureMoreMenu()
        camera.configuration?.image = UIImage(systemName: enabled ? "video.fill" : "video.slash.fill")
        camera.configuration?.title = enabled ? "Cam on" : "Cam off"
        camera.configuration?.baseForegroundColor = enabled ? accent : .white
        camera.accessibilityLabel = enabled ? "Stop video" : "Start video"
        camera.largeContentTitle = camera.accessibilityLabel
        updateStatus()
    }

    func setHeld(_ held: Bool) {
        isHeld = held
        workspace.onHold = held
        floatingVideo?.setSuspended(held)
        configureMoreMenu()
        updateStatus()
    }

    func prepareToFloat() {
        floatingVideo?.setSuspended(isHeld || displayMode == .audioOnly)
    }

    func restoreFromFloatingVideo() { floatingVideo?.foregrounded() }

    func endFloatingVideo() { floatingVideo?.clear() }

    func showMediaStatus(_ message: String?) {
        mediaStatus = message
        updateStatus()
    }

    func setAudioRouteName(_ name: String) {
        routeLabel.text = "Audio · \(name)"
        workspace.routeName = name
    }

    private func updateStatus() {
        statusLabel.text = isHeld ? "Jam on hold for another call" :
            (mediaStatus ?? "Microphone \(isMicrophoneOn ? "on" : "off") · Camera \(isCameraOn ? "on" : "off")")
        statusLabel.textColor = mediaStatus == nil ? .lightGray : .systemOrange
    }

    private func configure(_ button: UIButton, symbol: String, label: String, title: String? = nil) {
        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: symbol)
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        style.title = title
        style.imagePlacement = .top
        style.imagePadding = 2
        style.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 12, weight: .medium)
            return attributes
        }
        style.baseForegroundColor = accent
        button.configuration = style
        button.accessibilityLabel = label
        button.showsLargeContentViewer = true
        button.largeContentTitle = label
        button.largeContentImage = UIImage(systemName: symbol)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        scrollView === streamScroll ? nil : scrollView.subviews.first { $0 is VideoView }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView !== streamScroll {
            scrollView.accessibilityValue = "\(Int((scrollView.zoomScale * 100).rounded()))%"
            if let key = scrollView.accessibilityIdentifier {
                zoomStates[key] = (scrollView.zoomScale, scrollView.contentOffset)
            }
            if scrollView === primaryZoom { fitButton.isHidden = scrollView.zoomScale <= 1.01 }
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView !== streamScroll, let key = scrollView.accessibilityIdentifier else { return }
        zoomStates[key] = (scrollView.zoomScale, scrollView.contentOffset)
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
