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

    private let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let statusLabel = UILabel()
    private let tiles = UIStackView()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let flipCamera = UIButton(type: .system)
    private let speaker = UIButton(type: .system)
    private let catchUpButton = UIButton(type: .system)
    private let catchUpPanel: CatchUpPanel
    private var catchUpHeight: NSLayoutConstraint?
    private let store: CatchUpStore
    private var isMicrophoneOn = false
    private var isCameraOn = false
    private var isSpeakerOn = true

    init(title: String, catchUp: CatchUpStore) {
        self.store = catchUp
        self.catchUpPanel = CatchUpPanel(store: catchUp)
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
        header.spacing = 4
        titleLabel.font = .systemFont(ofSize: 29, weight: .bold)
        titleLabel.textColor = .white
        countLabel.font = .preferredFont(forTextStyle: .subheadline)
        countLabel.textColor = .lightGray
        countLabel.text = "Connecting…"

        tiles.axis = .vertical
        tiles.spacing = 12
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
        configure(catchUpButton, symbol: "text.bubble", label: "Catch up")
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
        catchUpButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.showCatchUp(self.catchUpPanel.isHidden)
        }, for: .touchUpInside)
        leave.addAction(UIAction { [weak self] _ in self?.onLeave?() }, for: .touchUpInside)
        catchUpPanel.onClose = { [weak self] in self?.showCatchUp(false) }

        let bar = UIStackView(arrangedSubviews: [microphone, camera, flipCamera, speaker, routePicker, catchUpButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.spacing = 6
        bar.backgroundColor = .secondarySystemBackground
        bar.layer.cornerRadius = 18
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 9)

        statusLabel.font = .preferredFont(forTextStyle: .footnote)
        statusLabel.textColor = .lightGray
        statusLabel.text = "Microphone and camera are off"
        statusLabel.textAlignment = .center

        for item in [header, scroll, bar, statusLabel, catchUpPanel] {
            item.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(item)
        }
        catchUpPanel.isHidden = true
        catchUpHeight = catchUpPanel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            scroll.bottomAnchor.constraint(equalTo: catchUpPanel.topAnchor, constant: -12),
            catchUpPanel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            catchUpPanel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            catchUpPanel.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -12),
            catchUpHeight!,
            statusLabel.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            statusLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            bar.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            bar.heightAnchor.constraint(equalToConstant: 68)
        ])
    }

    func render(room: Room) {
        let participants = [room.localParticipant] + Array(room.remoteParticipants.values)
        countLabel.text = "\(participants.count) musician\(participants.count == 1 ? "" : "s") in this jam"
        tiles.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for participant in participants {
            let tile = UIView()
            tile.backgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 1)
            tile.layer.cornerRadius = 16
            tile.clipsToBounds = true
            let video = VideoView()
            video.layoutMode = .fill
            video.track = participant.videoTracks
                .compactMap { $0.track as? VideoTrack }.first
            video.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(video)
            let name = UILabel()
            name.text = participant.name ?? "Musician"
            name.textColor = .white
            name.font = .systemFont(ofSize: 15, weight: .semibold)
            name.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            name.layer.cornerRadius = 7
            name.clipsToBounds = true
            name.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(name)
            let media = UILabel()
            let audioOn = participant.audioTracks.contains { !$0.isMuted }
            let videoOn = participant.videoTracks.contains { !$0.isMuted }
            media.text = "\(audioOn ? "Mic on" : "Mic off") · \(videoOn ? "Camera on" : "Camera off")"
            media.textColor = .lightGray
            media.font = .systemFont(ofSize: 12, weight: .medium)
            media.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            media.translatesAutoresizingMaskIntoConstraints = false
            tile.addSubview(media)
            NSLayoutConstraint.activate([
                tile.heightAnchor.constraint(equalToConstant: 185),
                video.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
                video.trailingAnchor.constraint(equalTo: tile.trailingAnchor),
                video.topAnchor.constraint(equalTo: tile.topAnchor),
                video.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
                name.leadingAnchor.constraint(equalTo: tile.leadingAnchor, constant: 12),
                name.bottomAnchor.constraint(equalTo: media.topAnchor, constant: -5),
                media.leadingAnchor.constraint(equalTo: name.leadingAnchor),
                media.bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: -12)
            ])
            tiles.addArrangedSubview(tile)
        }
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

    private func showCatchUp(_ visible: Bool) {
        catchUpPanel.isHidden = !visible
        catchUpHeight?.constant = visible ? 220 : 0
    }

    private func configure(_ button: UIButton, symbol: String, label: String) {
        var style = UIButton.Configuration.tinted()
        style.image = UIImage(systemName: symbol)
        style.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 21)
        button.configuration = style
        button.accessibilityLabel = label
    }
}
