import Combine
import UIKit

final class MacAudioRouteButton: UIButton {
    init() {
        super.init(frame: .zero)
        accessibilityIdentifier = "Mac audio devices"
        accessibilityLabel = L("Audio devices")
        addAction(UIAction { [weak self] _ in self?.openPicker() }, for: .touchUpInside)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func openPicker() {
        var responder: UIResponder? = self
        while let current = responder, !(current is UIViewController) { responder = current.next }
        guard var presenter = responder as? UIViewController else { return }
        while let parent = presenter.parent { presenter = parent }
        guard presenter.presentedViewController == nil else { return }
        let navigation = UINavigationController(rootViewController: MacAudioDevicePicker())
        navigation.modalPresentationStyle = .popover
        navigation.preferredContentSize = CGSize(width: 440, height: 520)
        navigation.popoverPresentationController?.sourceView = self
        navigation.popoverPresentationController?.sourceRect = bounds
        presenter.present(navigation, animated: true)
    }
}

final class MacAudioDevicePicker: UITableViewController {
    private let devices: MacAudioDevices
    private var subscriptions = Set<AnyCancellable>()

    init(devices: MacAudioDevices? = nil) {
        self.devices = devices ?? .shared
        super.init(style: .insetGrouped)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = L("Audio devices")
        tableView.accessibilityIdentifier = "Mac audio device list"
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        devices.$snapshot.removeDuplicates().combineLatest(devices.$unavailable.removeDuplicates()).receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.tableView.reloadData() }.store(in: &subscriptions)
        devices.refresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let height = min(520, max(250, tableView.contentSize.height + (navigationController?.navigationBar.frame.height ?? 44)))
        let size = CGSize(width: 440, height: height)
        if navigationController?.preferredContentSize != size { navigationController?.preferredContentSize = size }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { MacAudioDirection.allCases.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, devices.snapshot.devices(for: MacAudioDirection.allCases[section]).count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        MacAudioDirection.allCases[section] == .output ? L("Output") : L("Microphone")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard section == 0 else { return nil }
        return devices.unavailable ? L("Audio devices unavailable") : L("Selections change your Mac’s system audio devices for other apps too.")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        let direction = MacAudioDirection.allCases[indexPath.section]
        let available = devices.snapshot.devices(for: direction)
        var content = cell.defaultContentConfiguration()
        if available.isEmpty {
            content.text = direction == .output ? L("No output devices available") : L("No microphones available")
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        } else {
            let device = available[indexPath.row]
            content.text = device.name
            cell.accessoryType = device.id == devices.snapshot.selectedID(for: direction) ? .checkmark : .none
            if cell.accessoryType == .checkmark { cell.accessibilityTraits.insert(.selected) }
            cell.accessibilityIdentifier = "Mac audio \(direction) \(device.id)"
        }
        content.textProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let direction = MacAudioDirection.allCases[indexPath.section]
        let available = devices.snapshot.devices(for: direction)
        guard available.indices.contains(indexPath.row) else { return }
        do {
            try devices.select(available[indexPath.row].id, for: direction)
        } catch {
            let alert = UIAlertController(title: L("Audio devices"),
                message: L("Could not change audio device. Please try again."), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: L("OK"), style: .default))
            present(alert, animated: true)
        }
    }
}

#if DEBUG
@MainActor
final class MacAudioFixtureHardware: MacAudioHardware {
    private var value = MacAudioSnapshot(devices: [
        MacAudioDevice(id: 10, name: "Built-in speakers", directions: [.output]),
        MacAudioDevice(id: 20, name: "USB interface — headphones and microphone", directions: [.output, .input]),
        MacAudioDevice(id: 30, name: "Built-in microphone", directions: [.input])
    ], outputID: 10, inputID: 30)
    private var changed: (@MainActor () -> Void)?
    func snapshot() throws -> MacAudioSnapshot { value }
    func select(_ id: UInt32, for direction: MacAudioDirection) throws {
        if direction == .output { value.outputID = id } else { value.inputID = id }
        changed?()
    }
    func observe(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }
}
#endif
