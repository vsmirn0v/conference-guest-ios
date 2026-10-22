import UIKit

/// Keep Mac's Close shortcut scoped to this meeting's UIKit responder chain.
final class MeetingContainerViewController: UIViewController {
    var canHideMeeting: (() -> Bool)?
    var hideMeeting: (() -> Void)?
    private(set) var homeController: UIViewController?

    func mountHome(_ controller: UIViewController) {
        if let previous = homeController {
            previous.willMove(toParent: nil); previous.view.removeFromSuperview(); previous.removeFromParent()
        }
        homeController = controller
        addChild(controller); view.insertSubview(controller.view, at: 0)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = super.keyCommands ?? []
        if ProcessInfo.processInfo.isiOSAppOnMac, canHideMeeting?() == true {
            let close = UIKeyCommand(title: L("Hide meeting"), action: #selector(closeMeetingWindow),
                input: "w", modifierFlags: .command)
            close.wantsPriorityOverSystemBehavior = true
            commands.append(close)
        }
        return commands
    }
    @objc private func closeMeetingWindow() { hideMeeting?() }
}
