import AVFoundation
import Foundation

/// iOS 17 AirPods gestures without a registered CallKit call. All state changes
/// belong to the main queue, like SystemCallCoordinator's delegates.
final class ApplicationMicrophoneMute {
    static let shared: ApplicationMicrophoneMute? = {
        guard #available(iOS 17.0, *), !ProcessInfo.processInfo.isiOSAppOnMac else { return nil }
        let application = AVAudioApplication.shared
        return ApplicationMicrophoneMute(read: { application.isInputMuted }, write: { try application.setInputMuted($0) },
            observe: { handler in
                NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification,
                    object: nil, queue: .main) { note in
                        guard let value = note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber else { return }
                        handler(value.boolValue)
                    }
            })
    }()

    private let read: () -> Bool
    private let write: (Bool) throws -> Void
    private let observe: (@escaping (Bool) -> Void) -> NSObjectProtocol?
    private var observer: NSObjectProtocol?
    private var owner: UUID?
    private var meetingMuted = true
    private var changing = false
    private var privateCaptures = Set<UUID>()
    private var changed: ((Bool) -> Bool)?

    init(read: @escaping () -> Bool, write: @escaping (Bool) throws -> Void,
         observe: @escaping (@escaping (Bool) -> Void) -> NSObjectProtocol? = { _ in nil }) {
        self.read = read; self.write = write; self.observe = observe
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func begin(owner: UUID, muted: Bool, changed: @escaping (Bool) -> Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.owner = owner; meetingMuted = muted; self.changed = changed
        observer = observe { [weak self] in self?.received($0) }
        synchronize()
    }
    func setMuted(_ value: Bool, owner: UUID) {
        guard self.owner == owner else { return }
        meetingMuted = value; synchronize()
    }
    func end(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; changed = nil; meetingMuted = true
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        synchronize()
    }

    /// verifyMuted has already confirmed that the network track is off. Private
    /// sound checks may read input, but their gestures must never publish audio.
    func beginPrivateCapture() -> UUID {
        let token = UUID(); privateCaptures.insert(token); synchronize(); return token
    }
    func endPrivateCapture(_ token: UUID) {
        guard privateCaptures.remove(token) != nil else { return }
        synchronize()
    }

    func received(_ muted: Bool) {
        // Ignore our own writes and stale notifications queued before a newer
        // app action. While checking sound, gestures affect private input only.
        guard !changing, owner != nil, read() == muted, privateCaptures.isEmpty,
              muted != meetingMuted else { return }
        let previous = meetingMuted
        meetingMuted = muted
        if changed?(muted) != true { meetingMuted = previous; synchronize() }
    }
    private func synchronize() {
        let value = privateCaptures.isEmpty ? meetingMuted : false
        guard read() != value else { return }
        changing = true; defer { changing = false }
        do { try write(value) }
        catch {
            #if DEBUG
            print("Application microphone mute synchronization failed: \(error.localizedDescription)")
            #endif
        }
    }
}
