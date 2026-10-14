import UIKit

/// Keep Mac's Close shortcut scoped to this meeting's UIKit responder chain.
final class MeetingContainerViewController: UIViewController {
    var canHideMeeting: (() -> Bool)?
    var hideMeeting: (() -> Void)?

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
