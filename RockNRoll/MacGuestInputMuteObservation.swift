import AVFoundation
import Foundation

/// Lifetime of the public macOS accessory callback and its UI notification.
@available(iOS 17.0, *)
final class MacGuestInputMuteObservation: NSObject {
    private var notification: NSObjectProtocol?
    init?(changed: @escaping (Bool) -> Void) {
        guard RockMacInputMuteRegister(true) else { return nil }
        super.init()
        notification = NotificationCenter.default.addObserver(
            forName: AVAudioApplication.inputMuteStateChangeNotification, object: nil, queue: .main
        ) { note in
            guard let value = note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber else { return }
            changed(value.boolValue)
        }
    }
    deinit {
        if let notification { NotificationCenter.default.removeObserver(notification) }
        RockMacInputMuteRegister(false)
    }
}
