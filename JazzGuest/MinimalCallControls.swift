import Combine
import JazzSDK
import UIKit

final class MinimalCallControls: UIView {
    private var subscriptions = Set<AnyCancellable>()
    private let microphone = UIButton(type: .system)
    private let camera = UIButton(type: .system)
    private let route = UIView()

    init(state: JazzActiveConferenceState, coordinator: JazzActiveConferenceCoordinator) {
        super.init(frame: .zero)
        backgroundColor = .clear

        let flip = Self.button("Flip camera", symbol: "arrow.triangle.2.circlepath.camera")
        let leave = Self.button("Leave", symbol: "phone.down.fill")
        microphone.configuration = .tinted()
        camera.configuration = .tinted()
        leave.tintColor = .systemRed

        microphone.addAction(UIAction { _ in
            coordinator.toggleMicrohone(isOn: state.microphoneState != .on)
        }, for: .touchUpInside)
        camera.addAction(UIAction { _ in
            coordinator.toggleCamera(isOn: state.cameraState != .on)
        }, for: .touchUpInside)
        flip.addAction(UIAction { _ in coordinator.switchCamera() }, for: .touchUpInside)
        leave.addAction(UIAction { _ in coordinator.endConference() }, for: .touchUpInside)

        route.translatesAutoresizingMaskIntoConstraints = false
        route.accessibilityLabel = "Audio route"
        let picker = coordinator.audioRoutePickerButton
        picker.translatesAutoresizingMaskIntoConstraints = false
        route.addSubview(picker)
        NSLayoutConstraint.activate([
            picker.leadingAnchor.constraint(equalTo: route.leadingAnchor),
            picker.trailingAnchor.constraint(equalTo: route.trailingAnchor),
            picker.topAnchor.constraint(equalTo: route.topAnchor),
            picker.bottomAnchor.constraint(equalTo: route.bottomAnchor),
            route.widthAnchor.constraint(equalToConstant: 52),
            route.heightAnchor.constraint(equalToConstant: 48),
        ])

        let bar = UIStackView(arrangedSubviews: [microphone, camera, flip, route, leave])
        bar.axis = .horizontal
        bar.alignment = .center
        bar.spacing = 8
        bar.distribution = .fillEqually
        bar.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.94)
        bar.layer.cornerRadius = 16
        bar.isLayoutMarginsRelativeArrangement = true
        bar.directionalLayoutMargins = NSDirectionalEdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8)
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(greaterThanOrEqualTo: safeAreaLayoutGuide.leadingAnchor, constant: 12),
            bar.trailingAnchor.constraint(lessThanOrEqualTo: safeAreaLayoutGuide.trailingAnchor, constant: -12),
            bar.centerXAnchor.constraint(equalTo: centerXAnchor),
            bar.bottomAnchor.constraint(equalTo: safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])

        state.$microphoneState.receive(on: DispatchQueue.main).sink { [weak self] media in
            self?.microphone.configuration?.title = media == .on ? "Mute" : "Unmute"
            self?.microphone.configuration?.image = UIImage(systemName: media == .on ? "mic.fill" : "mic.slash.fill")
            self?.microphone.isEnabled = media != .disabled
            self?.microphone.accessibilityLabel = media == .on ? "Mute microphone" : "Unmute microphone"
        }.store(in: &subscriptions)
        state.$cameraState.receive(on: DispatchQueue.main).sink { [weak self] media in
            self?.camera.configuration?.title = media == .on ? "Stop video" : "Start video"
            self?.camera.configuration?.image = UIImage(systemName: media == .on ? "video.fill" : "video.slash.fill")
            self?.camera.isEnabled = media != .disabled
            self?.camera.accessibilityLabel = media == .on ? "Stop video" : "Start video"
        }.store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { nil }

    private static func button(_ title: String, symbol: String) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = title
        configuration.image = UIImage(systemName: symbol)
        configuration.imagePlacement = .top
        button.configuration = configuration
        button.accessibilityLabel = title
        return button
    }
}
