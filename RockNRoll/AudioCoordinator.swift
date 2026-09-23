import AVFoundation
import Foundation
import UIKit

/// Observes iOS media changes without competing with the provider for transport ownership.
final class AudioCoordinator {
    var onStatus: ((String?) -> Void)?
    var onInterruptionChanged: ((Bool) -> Void)?
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

    /// The provider may reconfigure the shared session later; real-device validation is required.
    func prepareForJoin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .videoChat,
            options: [.mixWithOthers, .allowBluetoothHFP]
        )
        // CallKit activates the session before the SDK starts media.
        audioWarning = nil
        cameraWarning = nil
        publishStatus()
    }

    /// The SDK changes the shared session after join; restore coexistence without
    /// replacing its selected voice-chat mode or route options.
    func ensureMixing() {
        let session = AVAudioSession.sharedInstance()
        guard session.category == .playAndRecord,
              !session.categoryOptions.contains(.mixWithOthers) else { return }
        do {
            try session.setCategory(session.category, mode: session.mode,
                                    options: session.categoryOptions.union(.mixWithOthers))
            #if DEBUG
            print("Restored audio mixing: options=\(session.categoryOptions.rawValue)")
            #endif
        } catch {
            audioWarning = "Cannot mix conference audio with other apps"
            publishStatus()
        }
    }

    /// A new CallKit activation supersedes an earlier interruption warning.
    func callAudioDidActivate() {
        audioWarning = nil
        ensureMixing()
        logRoute()
        publishStatus()
    }

    private func handle(_ notification: Notification) {
        #if DEBUG
        let session = AVAudioSession.sharedInstance()
        print("Audio event: \(notification.name.rawValue), category=\(session.category.rawValue), mode=\(session.mode.rawValue), options=\(session.categoryOptions.rawValue), appState=\(UIApplication.shared.applicationState.rawValue)")
        #endif
        switch notification.name {
        case AVAudioSession.interruptionNotification:
            let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let type = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            if type == .began {
                audioWarning = "Audio interrupted by iOS"
                onInterruptionChanged?(true)
            } else if type == .ended {
                let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
                audioWarning = options.contains(.shouldResume)
                    ? nil : "Audio is paused by iOS; check the call audio"
                onInterruptionChanged?(false)
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
            // The provider's route picker and the current system route remain authoritative.
            logRoute()
            ensureMixing()
        default:
            break
        }
        publishStatus()
    }

    private func publishStatus() {
        onStatus?(audioWarning ?? cameraWarning)
    }

    private func logRoute() {
        #if DEBUG
        let route = AVAudioSession.sharedInstance().currentRoute
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("Audio route types: input=[\(inputs)] output=[\(outputs)]")
        #endif
    }
}
