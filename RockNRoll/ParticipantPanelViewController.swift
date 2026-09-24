import UIKit

struct ParticipantStatus: Equatable {
    let id: String
    let name: String
    let isLocal: Bool
    let microphoneOn: Bool
    let cameraOn: Bool
    let screenShareOn: Bool
    let isSpeaking: Bool
    let videoKey: String?
    let shareKey: String?
}

final class ParticipantPanelViewController: UIViewController {
    var onPin: ((String?) -> Void)?
    var onMoreControls: (() -> Void)?
    private let list = UIStackView()
    private var statuses: [ParticipantStatus] = []
    private var pinnedKey: String?
    private var labels: [String: (name: UILabel, media: UILabel, speaking: UILabel)] = [:]

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        title = "Musicians"
        view.backgroundColor = .systemBackground
        view.tintColor = UIColor(red: 1, green: 0.60, blue: 0.33, alpha: 1)
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done, target: self, action: #selector(close))
        list.axis = .vertical
        list.spacing = 8
        list.layoutMargins = UIEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        list.isLayoutMarginsRelativeArrangement = true
        let scroll = UIScrollView()
        scroll.addSubview(list)
        list.translatesAutoresizingMaskIntoConstraints = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            list.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            list.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            list.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            list.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        redraw()
    }

    func update(_ statuses: [ParticipantStatus], pinnedKey: String?) {
        guard self.statuses != statuses || self.pinnedKey != pinnedKey else { return }
        let canUpdateInPlace = self.pinnedKey == pinnedKey &&
            self.statuses.map(\.id) == statuses.map(\.id) &&
            zip(self.statuses, statuses).allSatisfy {
                $0.0.videoKey == $0.1.videoKey && $0.0.shareKey == $0.1.shareKey
            }
        self.statuses = statuses
        self.pinnedKey = pinnedKey
        guard isViewLoaded else { return }
        if canUpdateInPlace {
            statuses.forEach(updateLabels)
        } else {
            redraw()
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory {
            redraw()
        }
    }

    private func redraw() {
        list.arrangedSubviews.forEach { $0.removeFromSuperview() }
        labels.removeAll()
        if statuses.isEmpty {
            let empty = UILabel()
            empty.text = "No musicians are connected yet."
            empty.textColor = .secondaryLabel
            list.addArrangedSubview(empty)
        }
        for status in statuses {
            let card = UIStackView()
            card.axis = .vertical
            card.spacing = 6
            card.backgroundColor = .secondarySystemBackground
            card.layer.cornerRadius = 14
            card.layoutMargins = UIEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
            card.isLayoutMarginsRelativeArrangement = true
            let name = UILabel()
            name.font = .preferredFont(forTextStyle: .headline)
            name.adjustsFontForContentSizeCategory = true
            name.numberOfLines = 0
            card.addArrangedSubview(name)
            let speaking = UILabel()
            speaking.font = .preferredFont(forTextStyle: .subheadline)
            speaking.adjustsFontForContentSizeCategory = true
            speaking.textColor = .systemGreen
            speaking.text = "● Speaking"
            card.addArrangedSubview(speaking)
            let media = UILabel()
            media.font = .preferredFont(forTextStyle: .subheadline)
            media.adjustsFontForContentSizeCategory = true
            media.numberOfLines = 0
            media.textColor = .secondaryLabel
            card.addArrangedSubview(media)
            labels[status.id] = (name, media, speaking)
            updateLabels(status)
            if let onPin {
                let actions = UIStackView()
                actions.axis = traitCollection.preferredContentSizeCategory.isAccessibilityCategory ?
                    .vertical : .horizontal
                actions.spacing = 12
                if let key = status.videoKey {
                    actions.addArrangedSubview(pinButton("Video", key: key, action: onPin))
                }
                if let key = status.shareKey {
                    actions.addArrangedSubview(pinButton("Screen", key: key, action: onPin))
                }
                if !actions.arrangedSubviews.isEmpty { card.addArrangedSubview(actions) }
            }
            list.addArrangedSubview(card)
        }
        if pinnedKey != nil, let onPin {
            let reset = UIButton(type: .system)
            reset.setTitle("Return to automatic view", for: .normal)
            reset.accessibilityLabel = "Return to automatic view"
            reset.addAction(UIAction { _ in onPin(nil) }, for: .touchUpInside)
            list.addArrangedSubview(reset)
        }
        if let onMoreControls {
            let button = UIButton(type: .system)
            button.setTitle("More participant controls", for: .normal)
            button.accessibilityLabel = "More participant controls"
            button.addAction(UIAction { [weak self] _ in
                self?.dismiss(animated: true, completion: onMoreControls)
            }, for: .touchUpInside)
            list.addArrangedSubview(button)
        }
    }

    private func updateLabels(_ status: ParticipantStatus) {
        guard let cell = labels[status.id] else { return }
        cell.name.text = status.name + (status.isLocal ? " (you)" : "")
        cell.name.accessibilityLabel = cell.name.text
        cell.speaking.isHidden = !status.isSpeaking
        cell.media.text = "Mic \(status.microphoneOn ? "on" : "off") · Video \(status.cameraOn ? "on" : "off")" +
            (status.screenShareOn ? " · Sharing screen" : "")
    }

    private func pinButton(_ title: String, key: String, action: @escaping (String?) -> Void) -> UIButton {
        let button = UIButton(type: .system)
        var configuration = UIButton.Configuration.tinted()
        configuration.title = key == pinnedKey ? "Unpin \(title.lowercased())" : "Pin \(title.lowercased())"
        configuration.image = UIImage(systemName: key == pinnedKey ? "pin.slash" : "pin")
        button.configuration = configuration
        button.titleLabel?.numberOfLines = 0
        button.accessibilityLabel = configuration.title
        button.addAction(UIAction { [weak self] _ in action(self?.pinnedKey == key ? nil : key) },
                         for: .touchUpInside)
        return button
    }

    @objc private func close() { dismiss(animated: true) }
}
