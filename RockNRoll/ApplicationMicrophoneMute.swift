import AVFoundation
import Foundation
import Darwin

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
            }, publishIntent: NativeApplicationInputMute.publish,
            releaseIntent: NativeApplicationInputMute.release,
            isReconfiguring: NativeApplicationInputMute.isReconfiguring)
    }()

    private let read: () -> Bool
    private let write: (Bool) throws -> Void
    private let observe: (@escaping (Bool) -> Void) -> NSObjectProtocol?
    private let publishIntent: (Bool) -> Void
    private let releaseIntent: () -> Void
    private let isReconfiguring: () -> Bool
    private var observer: NSObjectProtocol?
    private var owner: UUID?
    private var meetingMuted = true
    private var changing = false
    private var privateCaptures = Set<UUID>()
    private var privateInputMuted = false
    private var changed: ((Bool) -> Bool)?

    init(read: @escaping () -> Bool, write: @escaping (Bool) throws -> Void,
         observe: @escaping (@escaping (Bool) -> Void) -> NSObjectProtocol? = { _ in nil },
         publishIntent: @escaping (Bool) -> Void = { _ in },
         releaseIntent: @escaping () -> Void = {},
         isReconfiguring: @escaping () -> Bool = { false }) {
        self.read = read; self.write = write; self.observe = observe
        self.publishIntent = publishIntent; self.isReconfiguring = isReconfiguring
        self.releaseIntent = releaseIntent
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    func begin(owner: UUID, muted: Bool, changed: @escaping (Bool) -> Bool) {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        self.owner = owner; meetingMuted = muted; self.changed = changed
        observer = nil; updateObservation()
        synchronize()
        trace("begin")
    }
    func setMuted(_ value: Bool, owner: UUID) {
        guard self.owner == owner else { return }
        meetingMuted = value; synchronize()
    }
    func end(owner: UUID) {
        guard self.owner == owner else { return }
        self.owner = nil; changed = nil; meetingMuted = true
        updateObservation()
        synchronize()
    }

    /// verifyMuted has already confirmed that the network track is off. Private
    /// sound checks may read input, but their gestures must never publish audio.
    func beginPrivateCapture() -> UUID {
        if privateCaptures.isEmpty { privateInputMuted = false }
        let token = UUID(); privateCaptures.insert(token)
        updateObservation(); synchronize(); return token
    }
    func endPrivateCapture(_ token: UUID) {
        guard privateCaptures.remove(token) != nil else { return }
        updateObservation(); synchronize()
    }

    func received(_ muted: Bool) {
        trace("notification-\(muted)")
        // Ignore our own writes and stale notifications queued before a newer
        // app action. While checking sound, gestures affect private input only.
        // Native resets can clear the platform bit. Those notifications are
        // lifecycle changes, not accessory gestures. App actions still update
        // intent during recovery, and the native worker restores the latest one.
        guard !changing, !isReconfiguring(), read() == muted else { return }
        if !privateCaptures.isEmpty {
            privateInputMuted = muted; publishIntent(muted)
            return  // Accessory gestures affect private input, never the meeting.
        }
        guard owner != nil, muted != meetingMuted else { return }
        let previous = meetingMuted
        let notifiedOwner = owner
        meetingMuted = muted
        publishIntent(muted)
        let accepted = changed?(muted) == true
        // A callback can end or replace the meeting. Its new owner's intent
        // must survive even if this old gesture was accepted or rejected.
        guard owner == notifiedOwner else { return }
        if !accepted { meetingMuted = previous; synchronize() }
    }
    private func synchronize() {
        let value = privateCaptures.isEmpty ? meetingMuted : privateInputMuted
        // Publish even if the platform already matches: the native layer may
        // still hold the previous owner's or private sound check's intent.
        if owner != nil || !privateCaptures.isEmpty { publishIntent(value) }
        else { releaseIntent() }
        guard read() != value else { return }
        changing = true; defer { changing = false }
        do { try write(value) }
        catch {
            #if DEBUG
            print("Application microphone mute synchronization failed: \(error.localizedDescription)")
            #endif
        }
    }
    private func updateObservation() {
        if owner != nil || !privateCaptures.isEmpty {
            if observer == nil { observer = observe { [weak self] in self?.received($0) } }
        } else {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
    private func trace(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["CONFERENCE_TEST_MEDIA_TRACE"] == "1" {
            print("Accessory mute event=\(event) owner=\(owner != nil) read=\(read()) meeting=\(meetingMuted) private=\(privateCaptures.count) changing=\(changing)")
        }
        #endif
    }
}

private enum NativeApplicationInputMute {
    private static let setter: (@convention(c) (Int32) -> Void)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCSetApplicationInputMuteIntent") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)
    }()
    private static let reconfiguring: (@convention(c) () -> Int32)? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "RTCApplicationInputMuteReconfiguring") else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) () -> Int32).self)
    }()
    static func publish(_ muted: Bool) { setter?(muted ? 1 : 0) }
    static func release() { setter?(-1) }
    static func isReconfiguring() -> Bool { (reconfiguring?() ?? 0) != 0 }
}
