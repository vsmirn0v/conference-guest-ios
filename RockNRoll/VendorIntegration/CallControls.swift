import Combine
import JazzSDK
import UIKit

final class CallControls: UIView {
    private var subscriptions = Set<AnyCancellable>()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let route = UIView()
    private let catchUpButton = UIButton(type: .system)
    private let displayButton = UIButton(type: .system)
    private let participantsButton = UIButton(type: .system)
    private let speakerLabel = UILabel()
    private let audioOnlyBackdrop = UIView()
    private let notices = TopNoticeView()
    private var barBottomConstraint: NSLayoutConstraint?
    private var barLeadingConstraint: NSLayoutConstraint?
    private var barTrailingConstraint: NSLayoutConstraint?
    private var noticeTopConstraint: NSLayoutConstraint?
    private var orientationObserver: NSObjectProtocol?
    private var displayMode: ConferenceDisplayMode = .all

    init(state: JazzActiveConferenceState, coordinator: JazzActiveConferenceCoordinator,
         router: JazzActiveConferenceRouter,
         catchUp: CatchUpStore, chat: ChatStore,
         onDisplayMode: @escaping (ConferenceDisplayMode) -> Void,
         onLeave: @escaping () -> Void, onMicrophoneState: @escaping (Bool) -> Void,
         onCameraState: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        backgroundColor = .clear
        audioOnlyBackdrop.backgroundColor = .black
        audioOnlyBackdrop.isHidden = true
        audioOnlyBackdrop.isUserInteractionEnabled = false
        audioOnlyBackdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(audioOnlyBackdrop)
        let audioOnlyLabel = UILabel()
        audioOnlyLabel.text = "Audio only\nJam audio continues"
        audioOnlyLabel.textColor = .lightGray
        audioOnlyLabel.font = .preferredFont(forTextStyle: .title2)
        audioOnlyLabel.numberOfLines = 2
        audioOnlyLabel.textAlignment = .center
        audioOnlyLabel.translatesAutoresizingMaskIntoConstraints = false
        audioOnlyBackdrop.addSubview(audioOnlyLabel)
        NSLayoutConstraint.activate([
            audioOnlyBackdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            audioOnlyBackdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            audioOnlyBackdrop.topAnchor.constraint(equalTo: topAnchor),
            audioOnlyBackdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            audioOnlyLabel.centerXAnchor.constraint(equalTo: audioOnlyBackdrop.centerXAnchor),
            audioOnlyLabel.centerYAnchor.constraint(equalTo: audioOnlyBackdrop.centerYAnchor),
            audioOnlyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: audioOnlyBackdrop.leadingAnchor, constant: 20),
            audioOnlyLabel.trailingAnchor.constraint(lessThanOrEqualTo: audioOnlyBackdrop.trailingAnchor, constant: -20),
        ])

        let flip = Self.button("Flip camera", symbol: "arrow.triangle.2.circlepath.camera")
        let leave = Self.button("Leave", symbol: "phone.down.fill")
        catchUpButton.configuration = Self.iconConfiguration("text.bubble")
        catchUpButton.accessibilityLabel = "Catch up"
        displayButton.configuration = Self.iconConfiguration(displayMode.symbol)
        displayButton.accessibilityLabel = "Display: All video"
        displayButton.showsMenuAsPrimaryAction = true
        participantsButton.configuration = Self.iconConfiguration("person.2.fill")
        participantsButton.accessibilityLabel = "Musicians"
        configureDisplayMenu(onChange: onDisplayMode)
        microphone.configuration = Self.iconConfiguration("mic.slash.fill")
        camera.configuration = Self.iconConfiguration("video.slash.fill")
        leave.tintColor = .systemRed

        microphone.addAction(UIAction { _ in
            coordinator.toggleMicrohone(isOn: state.microphoneState != .on)
        }, for: .touchUpInside)
        camera.addAction(UIAction { _ in
            coordinator.toggleCamera(isOn: state.cameraState != .on)
        }, for: .touchUpInside)
        flip.addAction(UIAction { _ in coordinator.switchCamera() }, for: .touchUpInside)
        leave.addAction(UIAction { _ in onLeave() }, for: .touchUpInside)
        catchUpButton.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            var responder: UIResponder? = self
            while let current = responder, !(current is UIViewController) { responder = current.next }
            guard let presenter = responder as? UIViewController else { return }
            presenter.present(ConversationPanelViewController(catchUp: catchUp, chat: chat), animated: true)
        }, for: .touchUpInside)
        participantsButton.addAction(UIAction { _ in router.openParticipants() }, for: .touchUpInside)

        route.translatesAutoresizingMaskIntoConstraints = false
        route.accessibilityLabel = "Audio route"
        let picker = coordinator.audioRoutePickerButton
        picker.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(picker)
        let routeIcon = UIImageView(image: UIImage(systemName: "speaker.wave.2.fill"))
        routeIcon.tintColor = .systemBlue
        routeIcon.isUserInteractionEnabled = false
        routeIcon.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(routeIcon)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: route.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: route.trailingAnchor),
            picker.topAnchor.constraint(equalTo: route.topAnchor),
            picker.bottomAnchor.constraint(equalTo: route.bottomAnchor),
            routeIcon.centerXAnchor.constraint(equalTo: route.centerXAnchor),
            routeIcon.centerYAnchor.constraint(equalTo: route.centerYAnchor),
            routeIcon.widthAnchor.constraint(equalToConstant: 25),
            routeIcon.heightAnchor.constraint(equalToConstant: 25),
        ])

        let bar = UIStackView(arrangedSubviews: [microphone, camera, flip, route,
                                                participantsButton, displayButton, catchUpButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.alignment = .center
        bar.spacing = 2
        bar.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 5, leading: 5, bottom: 5, trailing: 5)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        notices.translatesAutoresizingMaskIntoConstraints = false
        addSubview(notices)
        speakerLabel.font = .preferredFont(forTextStyle: .subheadline)
        speakerLabel.textColor = .systemGreen
        speakerLabel.backgroundColor = UIColor.black.withAlphaComponent(0.7)
        speakerLabel.layer.cornerRadius = 8
        speakerLabel.clipsToBounds = true
        speakerLabel.isHidden = true
        speakerLabel.isUserInteractionEnabled = false
        speakerLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(speakerLabel)
        let bottom = bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4)
        let leading = bar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6)
        let trailing = bar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6)
        barBottomConstraint = bottom
        barLeadingConstraint = leading
        barTrailingConstraint = trailing
        let noticeTop = notices.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor, constant: 8)
        noticeTopConstraint = noticeTop
        NSLayoutConstraint.activate([
            leading, trailing,
            bottom,
            bar.heightAnchor.constraint(equalToConstant: 54),
            noticeTop,
            notices.centerXAnchor.constraint(equalTo: safeAreaLayoutGuide.centerXAnchor),
            notices.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            notices.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            notices.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            speakerLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 8),
            speakerLabel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -7),
            speakerLabel.trailingAnchor.constraint(lessThanOrEqualTo: bar.trailingAnchor, constant: -8),
        ])
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { self?.alignBarWithVisibleWindow() }
        }

        catchUp.$timeline.receive(on: DispatchQueue.main).sink { [weak self] timeline in
            guard let self else { return }
            let count = timeline.unreadCount
            self.catchUpButton.tintColor = count > 0 ? .systemOrange : .systemBlue
            self.catchUpButton.accessibilityLabel = count > 0
                ? "Catch up, \(count) missed section\(count == 1 ? "" : "s")"
                : "Catch up"
        }.store(in: &subscriptions)

        state.$microphoneState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            #if DEBUG
            print("Microphone state changed: \(media)")
            #endif
            self.microphone.configuration?.image = UIImage(systemName: media == .on ? "mic.fill" : "mic.slash.fill")
            self.microphone.isEnabled = media != .disabled
            self.microphone.accessibilityLabel = media == .on ? "Mute microphone" : "Unmute microphone"
            if media != .disabled { onMicrophoneState(media == .on) }
        }.store(in: &subscriptions)
        state.$cameraState.receive(on: DispatchQueue.main).sink { [weak self] media in
            guard let self else { return }
            #if DEBUG
            print("Camera state changed: \(media)")
            #endif
            self.camera.configuration?.image = UIImage(systemName: media == .on ? "video.fill" : "video.slash.fill")
            self.camera.isEnabled = media != .disabled
            self.camera.accessibilityLabel = media == .on ? "Stop video" : "Start video"
            if media != .disabled { onCameraState(media == .on) }
        }.store(in: &subscriptions)
        Publishers.CombineLatest3(state.$localParticipant, state.$remoteParticipants,
                                  state.$dominantSpeaker)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, remote, speaker in
                guard let self else { return }
                self.participantsButton.accessibilityLabel = "Musicians, \(remote.count + 1)"
                self.participantsButton.accessibilityValue = remote.values.contains { $0.screenSharing.isOn }
                    ? "A screen is being shared" : nil
                if let speaker, speaker.microphone.isOn {
                    self.speakerLabel.text = "  Speaking: \(speaker.isLocal ? "You" : (speaker.userName ?? "Musician"))  "
                    self.speakerLabel.isHidden = false
                } else {
                    self.speakerLabel.isHidden = true
                }
            }.store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        // The SDK's video renderer sits behind this full-screen controls view.
        // Passing empty space through lets its own screen-share scroll view
        // receive pinch and pan gestures without changing the video renderer.
        if hit === self { return nil }
        return hit
    }

    func showNotices(_ items: [InCallNotice]) {
        notices.show(items)
    }

    deinit {
        if let orientationObserver { NotificationCenter.default.removeObserver(orientationObserver) }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        alignBarWithVisibleWindow()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        alignBarWithVisibleWindow()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        alignBarWithVisibleWindow()
    }

    private func alignBarWithVisibleWindow() {
        guard let window, let barBottomConstraint,
              let barLeadingConstraint, let barTrailingConstraint else { return }
        let visibleLeft = convert(CGPoint(x: window.safeAreaInsets.left, y: 0), from: window).x
        let visibleRight = convert(CGPoint(x: window.bounds.maxX - window.safeAreaInsets.right, y: 0), from: window).x
        let ownSafeLeft = safeAreaInsets.left
        let ownSafeRight = bounds.maxX - safeAreaInsets.right
        let leading = max(6, visibleLeft - ownSafeLeft + 6)
        let trailing = min(-6, visibleRight - ownSafeRight - 6)
        if abs(barLeadingConstraint.constant - leading) > 0.5 { barLeadingConstraint.constant = leading }
        if abs(barTrailingConstraint.constant - trailing) > 0.5 { barTrailingConstraint.constant = trailing }
        let visibleBottom = convert(
            CGPoint(x: 0, y: window.bounds.maxY - window.safeAreaInsets.bottom), from: window
        ).y
        let ownSafeBottom = bounds.maxY - safeAreaInsets.bottom
        let constant = min(-4, visibleBottom - ownSafeBottom - 4)
        if abs(barBottomConstraint.constant - constant) > 0.5 {
            barBottomConstraint.constant = constant
        }
        if let noticeTopConstraint {
            let visibleTop = convert(CGPoint(x: 0, y: window.safeAreaInsets.top), from: window).y
            let constant = max(8, visibleTop - safeAreaInsets.top + 8)
            if abs(noticeTopConstraint.constant - constant) > 0.5 {
                noticeTopConstraint.constant = constant
            }
        }
    }

    private func configureDisplayMenu(onChange: @escaping (ConferenceDisplayMode) -> Void) {
        displayButton.menu = UIMenu(children: ConferenceDisplayMode.allCases.map { option in
            UIAction(title: option == .screenShares ? "Screen shares unavailable" : option.title,
                     image: UIImage(systemName: option.symbol),
                     attributes: option == .screenShares ? .disabled : [],
                     state: option == displayMode ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.displayMode = option
                self.audioOnlyBackdrop.isHidden = option != .audioOnly
                self.displayButton.configuration?.image = UIImage(systemName: option.symbol)
                self.displayButton.accessibilityLabel = "Display: \(option.title)"
                self.configureDisplayMenu(onChange: onChange)
                onChange(option)
            }
        })
    }

    private static func button(_ title: String, symbol: String) -> UIButton {
        let button = UIButton(type: .system)
        button.configuration = iconConfiguration(symbol)
        button.accessibilityLabel = title
        return button
    }

    private static func iconConfiguration(_ symbol: String) -> UIButton.Configuration {
        var configuration = UIButton.Configuration.tinted()
        configuration.image = UIImage(systemName: symbol)
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 22)
        return configuration
    }
}

struct InCallNotice {
    let title: String
    let actionTitle: String?
    let action: (() -> Void)?
}

final class TopNoticeView: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .vertical
        spacing = 8
        isHidden = true
        accessibilityIdentifier = "Top meeting notices"
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ items: [InCallNotice]) {
        arrangedSubviews.forEach { view in
            removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        for item in items.suffix(2) {
            let row = UIStackView()
            row.axis = .horizontal
            row.alignment = .center
            row.spacing = 10
            row.isLayoutMarginsRelativeArrangement = true
            row.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 10, leading: 14,
                                                                   bottom: 10, trailing: 14)
            row.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.97)
            row.layer.cornerRadius = 14
            row.layer.masksToBounds = true
            let label = UILabel()
            label.text = item.title
            label.font = .preferredFont(forTextStyle: .subheadline)
            label.textColor = .label
            label.numberOfLines = 3
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            row.addArrangedSubview(label)
            if let title = item.actionTitle, let action = item.action {
                let button = UIButton(type: .system)
                button.setTitle(title, for: .normal)
                button.titleLabel?.font = .preferredFont(forTextStyle: .subheadline)
                button.addAction(UIAction { _ in action() }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            addArrangedSubview(row)
        }
        isHidden = arrangedSubviews.isEmpty
    }
}

#if DEBUG
final class NoticeLayoutFixtureViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let notice = TopNoticeView()
        notice.show([InCallNotice(title: "Meeting transcript is on", actionTitle: nil, action: nil)])
        notice.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(notice)
        let controls = UIButton(type: .system)
        controls.setTitle("Fixture controls", for: .normal)
        controls.backgroundColor = .secondarySystemBackground
        controls.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(controls)
        NSLayoutConstraint.activate([
            notice.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            notice.centerXAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerXAnchor),
            notice.leadingAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            notice.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            notice.widthAnchor.constraint(lessThanOrEqualToConstant: 440),
            controls.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 6),
            controls.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -6),
            controls.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -4),
            controls.heightAnchor.constraint(equalToConstant: 54),
        ])
    }
}
#endif
