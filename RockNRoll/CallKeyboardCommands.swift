import UIKit

/// Shared discoverable shortcuts; each engine retains its own action handlers.
enum CallKeyboardCommands {
    static func make(microphone: Selector, camera: Selector, chat: Selector,
                     participants: Selector, fit: Selector) -> [UIKeyCommand] {
        [("Mute or unmute microphone", microphone, "a", UIKeyModifierFlags.command.union(.shift)),
         ("Start or stop video", camera, "v", .command.union(.shift)),
         ("Open chat", chat, "c", .command.union(.shift)),
         ("Show musicians", participants, "p", .command.union(.shift)),
         ("Fit shared screen", fit, "0", .command)].map {
            UIKeyCommand(title: $0.0, action: $0.1, input: $0.2, modifierFlags: $0.3)
        }
    }
}
