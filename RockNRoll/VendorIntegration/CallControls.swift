import Combine
import JazzSDK
import UIKit

final class CallControls: UIView {
    private var subscriptions = Set<AnyCancellable>()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let route = UIView()
    private let catchUpButton = UIButton(type: .system)

    init(state: JazzActiveConferenceState, coordinator: JazzActiveConferenceCoordinator,
         catchUp: CatchUpStore,
         onLeave: @escaping () -> Void, onMicrophoneState: @escaping (Bool) -> Void,
         onCameraState: @escaping (Bool) -> Void) {
        super.init(frame: .zero)
        backgroundColor = .clear

        let flip = Self.button("Flip camera", symbol: "arrow.triangle.2.circlepath.camera")
        let leave = Self.button("Leave", symbol: "phone.down.fill")
        let catchUpPanel = CatchUpPanel(store: catchUp)
        catchUpButton.configuration = Self.iconConfiguration("text.bubble")
        catchUpButton.accessibilityLabel = "Catch up"
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
        catchUpButton.addAction(UIAction { [weak catchUpPanel] _ in
            catchUpPanel?.isHidden.toggle()
        }, for: .touchUpInside)
        catchUpPanel.onClose = { [weak catchUpPanel] in catchUpPanel?.isHidden = true }

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
            route.widthAnchor.constraint(equalToConstant: 52),
            route.heightAnchor.constraint(equalToConstant: 48),
        ])

        let bar = UIStackView(arrangedSubviews: [microphone, camera, flip, route,
                                                catchUpButton, leave])
        bar.axis = .horizontal
        bar.distribution = .fillEqually
        bar.alignment = .center
        bar.spacing = 6
        bar.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        catchUpPanel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(catchUpPanel)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
            bar.widthAnchor.constraint(equalToConstant: 340),
            bar.heightAnchor.constraint(equalToConstant: 72),
            catchUpPanel.leadingAnchor.constraint(equalTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            catchUpPanel.trailingAnchor.constraint(equalTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            catchUpPanel.bottomAnchor.constraint(equalTo: bar.topAnchor, constant: -10),
            catchUpPanel.heightAnchor.constraint(lessThanOrEqualToConstant: 300),
            catchUpPanel.heightAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.heightAnchor,
                                                 multiplier: 0.62),
            catchUpPanel.topAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.topAnchor,
                                              constant: 8)
        ])
        let preferredPanelHeight = catchUpPanel.heightAnchor.constraint(equalToConstant: 290)
        preferredPanelHeight.priority = .defaultHigh
        preferredPanelHeight.isActive = true

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
