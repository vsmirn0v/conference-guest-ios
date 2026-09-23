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
    private let audioOnlyBackdrop = UIView()
    private var barBottomConstraint: NSLayoutConstraint?
    private var orientationObserver: NSObjectProtocol?
    private var displayMode: ConferenceDisplayMode = .all

    init(state: JazzActiveConferenceState, coordinator: JazzActiveConferenceCoordinator,
         catchUp: CatchUpStore, chat: ChatStore,
         onDisplayMode: @escaping (ConferenceDisplayMode) -> Void,
         onLeave: @escaping () -> Void, onMicrophoneState: @escaping (Bool) -> Void,
         onCameraState: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        backgroundColor = .clear
        audioOnlyBackdrop.backgroundColor = .black
        audioOnlyBackdrop.isHidden = true
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
                                                displayButton, catchUpButton, leave])
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
        let bottom = bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -4)
        barBottomConstraint = bottom
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 6),
            bar.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -6),
            bottom,
            bar.heightAnchor.constraint(equalToConstant: 54),
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
    }

    required init?(coder: NSCoder) { nil }

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
        guard let window, let barBottomConstraint else { return }
        let visibleBottom = convert(
            CGPoint(x: 0, y: window.bounds.maxY - window.safeAreaInsets.bottom), from: window
        ).y
        let ownSafeBottom = bounds.maxY - safeAreaInsets.bottom
        let constant = min(-4, visibleBottom - ownSafeBottom - 4)
        if abs(barBottomConstraint.constant - constant) > 0.5 {
            barBottomConstraint.constant = constant
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
