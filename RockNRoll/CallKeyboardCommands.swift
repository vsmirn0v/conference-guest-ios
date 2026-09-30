import UIKit

/// Shared discoverable shortcuts; each engine retains its own action handlers.
enum CallKeyboardCommands {
    static func make(microphone: Selector, camera: Selector, chat: Selector,
                     participants: Selector, fit: Selector) -> [UIKeyCommand] {
        [(L("Mute or unmute microphone"), microphone, "a", UIKeyModifierFlags.command.union(.shift)),
         (L("Start or stop video"), camera, "v", .command.union(.shift)),
         (L("Open chat"), chat, "c", .command.union(.shift)),
         (L("Show musicians"), participants, "p", .command.union(.shift)),
         (L("Fit shared screen"), fit, "0", .command)].map {
            UIKeyCommand(title: $0.0, action: $0.1, input: $0.2, modifierFlags: $0.3)
        }
    }
}
