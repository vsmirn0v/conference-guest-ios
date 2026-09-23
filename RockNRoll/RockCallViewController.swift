import AVKit
import LiveKit
import UIKit

@MainActor
final class RockCallViewController: UIViewController {
    var onLeave: (() -> Void)?
    var onMicrophone: ((Bool) -> Void)?
    var onCamera: ((Bool) -> Void)?
    var onFlipCamera: (() -> Void)?
    var onSpeaker: ((Bool) -> Void)?
    var onDisplayMode: ((ConferenceDisplayMode) -> Void)?

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let statusLabel = UILabel()
    private let tiles = UIStackView()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let flipCamera = UIButton(type: .system)
    private let speaker = UIButton(type: .system)
    private let displayModeButton = UIButton(type: .system)
    private let conversationButton = UIButton(type: .system)
    private let store: CatchUpStore
    private let chat: ChatStore
    private weak var displayedRoom: Room?
    private var displayMode: ConferenceDisplayMode = .all
    private var isMicrophoneOn = false
    private var isCameraOn = false
    private var isSpeakerOn = true

    init(title: String, catchUp: CatchUpStore, chat: ChatStore) {
        store = catchUp
        self.chat = chat
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
        titleLabel.text = title
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.06, green: 0.06, blue: 0.085, alpha: 1)
        let header = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        header.axis = .vertical
        header.spacing = 2
        titleLabel.font = .systemFont(ofSize: 25, weight: .bold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = .lightGray
        countLabel.text = "Connecting…"

        tiles.axis = .vertical
        tiles.spacing = 10
        let scroll = UIScrollView()
        scroll.addSubview(tiles)
        tiles.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tiles.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            tiles.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            tiles.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            tiles.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            tiles.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])

        configure(microphone, symbol: "mic.slash.fill", label: "Unmute microphone")
        configure(camera, symbol: "video.slash.fill", label: "Start video")
        configure(flipCamera, symbol: "arrow.triangle.2.circlepath.camera", label: "Flip camera")
        flipCamera.isEnabled = false
        configure(speaker, symbol: "speaker.wave.2.fill", label: "Use iPhone speaker")
        configure(displayModeButton, symbol: displayMode.symbol, label: "Display: All video")
        displayModeButton.showsMenuAsPrimaryAction = true
        configureModeMenu()
        configure(conversationButton, symbol: "text.bubble", label: "Catch up")
        let routePicker = AVRoutePickerView()
        routePicker.tintColor = .systemPurple
        routePicker.activeTintColor = .systemPurple
        routePicker.accessibilityLabel = "Choose audio output"
        let leave = UIButton(type: .system)
        configure(leave, symbol: "phone.down.fill", label: "Leave")
        leave.tintColor = .systemRed

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
            self.onSpeaker?(self.isSpeakerOn)
            self.speaker.accessibilityLabel = self.isSpeakerOn ? "Use iPhone receiver" : "Use iPhone speaker"
        }, for: .touchUpInside)
        conversationButton.addAction(UIAction { [weak self] _ in
            guard let self, self.presentedViewController == nil else { return }
            self.present(ConversationPanelViewController(catchUp: self.store, chat: self.chat),
                         animated: true)
        }, for: .touchUpInside)
        leave.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .touchUpInside)

        let bar = UIStackView(arrangedSubviews: [microphone, camera, flipCamera, speaker,
                                                 routePicker, displayModeButton,
                                                 conversationButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 2
        bar.backgroundColor = .secondarySystemBackground
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.text = "Microphone and camera are off"
        statusLabel.textAlignment = .center
        for item in [header, scroll, bar, statusLabel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 4),
            scroll.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -5),
            statusLabel.leadingAnchor.constraint(equalTo: header.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: header.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -5),
            bar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            bar.heightAnchor.constraint(equalToConstant: 54)
        ])
    }

    func render(room: Room) {
        displayedRoom = room
        let participants: [Participant] = [room.localParticipant] + room.remoteParticipants.values.sorted {
            ($0.identity?.stringValue ?? "") < ($1.identity?.stringValue ?? "")
        }
        countLabel.text = "\(participants.count) musician\(participants.count == 1 ? "" : "s") in this jam"
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        var visibleVideoCount = 0
        for participant in participants {
            let publications = participant.videoTracks.filter { !$0.isMuted && $0.track is VideoTrack }
                .filter { displayMode == .all ||
                    (displayMode == .screenShares && $0.source == .screenShareVideo) }
            if displayMode == .audioOnly || (displayMode == .all && publications.isEmpty) {
                tiles.addArrangedSubview(audioTile(for: participant))
            }
            for publication in publications where displayMode != .audioOnly {
                guard let track = publication.track as? VideoTrack else { continue }
                visibleVideoCount += 1
                tiles.addArrangedSubview(videoTile(for: participant, track: track,
                    isShare: publication.source == .screenShareVideo))
            }
        }
        if displayMode == .screenShares && visibleVideoCount == 0 {
            let empty = UILabel()
            empty.text = "No screen share is live. Audio continues."
            empty.textColor = .lightGray
            empty.textAlignment = .center
            empty.numberOfLines = 0
            tiles.addArrangedSubview(empty)
            empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 100).isActive = true
        }
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

    private func videoTile(for participant: Participant, track: VideoTrack, isShare: Bool) -> UIView {
        let tile = baseTile()
        let video = VideoView()
        video.layoutMode = isShare ? .fit : .fill
        video.track = track
        video.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(video)
        let name = UILabel()
        name.text = "  \(participant.name ?? "Musician")\(isShare ? " · Screen share" : "")  "
        name.textColor = .white
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        name.layer.cornerRadius = 7
        name.clipsToBounds = true
        name.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(name)
        NSLayoutConstraint.activate([
            tile.heightAnchor.constraint(equalToConstant: isShare ? 240 : 185),
            video.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
            video.topAnchor.constraint(equalTo: tile.topAnchor),
            video.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
            name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 10),
            name.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -10)
        ])
        return tile
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

    func setMicrophone(_ enabled: Bool) {
        isMicrophoneOn = enabled
        microphone.configuration?.image = UIImage(systemName: enabled ? "mic.fill" : "mic.slash.fill")
        microphone.accessibilityLabel = enabled ? "Mute microphone" : "Unmute microphone"
    }

    func setCamera(_ enabled: Bool) {
        isCameraOn = enabled
        flipCamera.isEnabled = enabled
        camera.configuration?.image = UIImage(systemName: enabled ? "video.fill" : "video.slash.fill")
        camera.accessibilityLabel = enabled ? "Stop video" : "Start video"
    }

    func setHeld(_ held: Bool) {
        statusLabel.text = held ? "Jam on hold for another call" : "Jam active"
    }

    private func configure(_ button: UIButton, symbol: String, label: String) {
        var style = UIButton.Configuration.tinted()
        style.image = UIImage(systemName: symbol)
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 19)
        button.configuration = style
        button.accessibilityLabel = label
    }
}
