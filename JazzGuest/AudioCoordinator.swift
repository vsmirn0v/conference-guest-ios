import AVFoundation
import Foundation

/// Observes iOS media changes without competing with Jazz for transport ownership.
final class AudioCoordinator {
    var onStatus: ((String?) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private var audioWarning: String?
    private var cameraWarning: String?

    init() {
        let center = NotificationCenter.default
        for name in [AVAudioSession.interruptionNotification,
                     AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification,
                     AVAudioSession.mediaServicesWereResetNotification,
                     AVCaptureSession.wasInterruptedNotification,
                     AVCaptureSession.interruptionEndedNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                self?.handle(note)
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Jazz may reconfigure the shared session later; real-device validation is required.
    func prepareForJoin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        try session.setActive(true)
        audioWarning = nil
        cameraWarning = nil
        publishStatus()
    }

    private func handle(_ notification: Notification) {
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                audioWarning = "Audio interrupted by iOS"
            } else if type == .ended {
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                audioWarning = options.contains(.shouldResume)
                    ? nil : "Audio is paused by iOS; check the call audio"
            }
        case AVAudioSession.mediaServicesWereLostNotification:
            audioWarning = "Audio service unavailable"
        case AVAudioSession.mediaServicesWereResetNotification:
            audioWarning = "Audio service restarted; rejoin if audio does not recover"
        case AVCaptureSession.wasInterruptedNotification:
            cameraWarning = "Camera paused by iOS"
        case AVCaptureSession.interruptionEndedNotification:
            cameraWarning = nil
        case AVAudioSession.routeChangeNotification:
            // Jazz's route picker and the current system route remain authoritative.
            break
        default:
            break
        }
        publishStatus()
    }

    private func publishStatus() {
        onStatus?(audioWarning ?? cameraWarning)
    }
}
