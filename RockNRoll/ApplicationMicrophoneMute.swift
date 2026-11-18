import AVFoundation
import Foundation
import LiveKitWebRTC
import MeetingEngine

/// iOS 17 AirPods gestures without a registered CallKit call. All state changes
/// belong to the main queue, like SystemCallCoordinator's delegates, while blocking
/// `AVAudioApplication` IPC is offloaded to `AudioSessionWorker` via `LivePlatformInputMuteBox`.
final class ApplicationMicrophoneMute {
    static let shared: ApplicationMicrophoneMute? = {
        guard #available(iOS 17.0, *) else { return nil }
        let application = AVAudioApplication.shared
        let box = LivePlatformInputMuteBox(
            readPlatform: { application.isInputMuted },
            writePlatform: { try application.setInputMuted($0) }
        )
        return ApplicationMicrophoneMute(
            read: { box.read() },
            write: { box.write($0) },
            observe: { handler in
                NotificationCenter.default.addObserver(
                    forName: AVAudioApplication.inputMuteStateChangeNotification,
                    object: nil,
                    queue: .main
                ) { note in
                    guard let value = note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber else { return }
                    let nativeReconfiguring = NativeApplicationInputMute.isReconfiguring()
                        || MainActor.assumeIsolated { SharedAudioEngine.shared.rebuilding }
                    box.handleNotification(
                        value.boolValue,
                        nativeReconfiguring: nativeReconfiguring,
                        forward: handler
                    )
                }
            },
            publishIntent: { muted in
                NativeApplicationInputMute.publish(muted)
                box.ensurePlatformMatches(muted)
            },
            releaseIntent: NativeApplicationInputMute.release,
            isReconfiguring: {
                let nativeReconfiguring = NativeApplicationInputMute.isReconfiguring()
                    || MainActor.assumeIsolated { SharedAudioEngine.shared.rebuilding }
                return box.isReconfiguring(nativeReconfiguring: nativeReconfiguring)
            }
        )
    }()

    static var privateCaptureBridge: ApplicationMicrophoneMute? {
        shared
    }

    private let read: () -> Bool
    private let write: (Bool) throws -> Void
    private let observe: (@escaping (Bool) -> Void) -> NSObjectProtocol?
    private let publishIntent: (Bool) -> Void
    private let releaseIntent: () -> Void
    private let isReconfiguring: () -> Bool
    private let reconcileCapture: (Bool) -> Void
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
         isReconfiguring: @escaping () -> Bool = { false },
         reconcileCapture: @escaping (Bool) -> Void = { _ in }) {
        self.read = read; self.write = write; self.observe = observe
        self.publishIntent = publishIntent; self.isReconfiguring = isReconfiguring
        self.releaseIntent = releaseIntent
        self.reconcileCapture = reconcileCapture
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
        guard !changing, !isReconfiguring(), read() == muted else {
            reconcileCapture(privateCaptures.isEmpty ? meetingMuted : privateInputMuted)
            return
        }
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
        defer { reconcileCapture(privateCaptures.isEmpty ? meetingMuted : privateInputMuted) }
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
    static func publish(_ muted: Bool) { LKRTCSetApplicationInputMuteIntent(muted ? 1 : 0) }
    static func release() { LKRTCSetApplicationInputMuteIntent(-1) }
    static func isReconfiguring() -> Bool { LKRTCApplicationInputMuteReconfiguring() != 0 }
}

/// Shields `@MainActor` from synchronous `AVAudioApplication` IPC by keeping an in-memory
/// mute shadow and coalescing platform reads/writes onto `AudioSessionWorker`.
final class LivePlatformInputMuteBox: @unchecked Sendable {
    private let worker: AudioSessionWorker
    private let readPlatform: @Sendable () -> Bool
    private let writePlatform: @Sendable (Bool) throws -> Void
    private let uptime: @Sendable () -> TimeInterval
    private let notifications: NotificationCenter
    private let lock = NSLock()
    private let observerQueue: OperationQueue
    private var observers: [NSObjectProtocol] = []

    private var shadowMuted = false
    private var desiredWrite: Bool?
    private var verifyDesired = false
    private var workerRunning = false
    private var lastWriteCompletedUptime: TimeInterval = -.infinity
    private var lastRouteResetUptime: TimeInterval = -.infinity

    init(
        worker: AudioSessionWorker = .shared,
        readPlatform: @escaping @Sendable () -> Bool,
        writePlatform: @escaping @Sendable (Bool) throws -> Void,
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        notifications: NotificationCenter = .default
    ) {
        self.worker = worker
        self.readPlatform = readPlatform
        self.writePlatform = writePlatform
        self.uptime = uptime
        self.notifications = notifications

        let queue = OperationQueue()
        queue.name = "rocknroll.platform-input-mute.events"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.observerQueue = queue

        for name in [AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereResetNotification,
                     AVAudioSession.interruptionNotification] {
            observers.append(notifications.addObserver(forName: name, object: nil, queue: queue) { [weak self] _ in
                self?.handleAudioSessionReset()
            })
        }
    }

    deinit {
        observers.forEach(notifications.removeObserver)
    }

    func read() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return shadowMuted
    }

    func write(_ value: Bool) {
        lock.lock()
        shadowMuted = value
        desiredWrite = value
        verifyDesired = false
        enqueueDrainIfNeededLocked()
        lock.unlock()
    }

    func ensurePlatformMatches(_ value: Bool) {
        lock.lock()
        shadowMuted = value
        if desiredWrite == nil {
            verifyDesired = true
            enqueueDrainIfNeededLocked()
        }
        lock.unlock()
    }

    func isReconfiguring(nativeReconfiguring: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return isReconfiguringLocked(nativeReconfiguring: nativeReconfiguring)
    }

    func handleNotification(_ muted: Bool, nativeReconfiguring: Bool, forward: (Bool) -> Void) {
        lock.lock()
        let reconfiguring = isReconfiguringLocked(nativeReconfiguring: nativeReconfiguring)
        let target = desiredWrite ?? shadowMuted
        if reconfiguring {
            if muted != target {
                desiredWrite = target
                enqueueDrainIfNeededLocked()
            }
        } else {
            shadowMuted = muted
        }
        lock.unlock()
        forward(muted)
    }

    private func handleAudioSessionReset() {
        lock.lock()
        lastRouteResetUptime = uptime()
        verifyDesired = true
        enqueueDrainIfNeededLocked()
        lock.unlock()
    }

    private func isReconfiguringLocked(nativeReconfiguring: Bool) -> Bool {
        let now = uptime()
        return workerRunning
            || (now - lastWriteCompletedUptime) < 0.25
            || (now - lastRouteResetUptime) < 0.6
            || nativeReconfiguring
    }

    private func enqueueDrainIfNeededLocked() {
        guard !workerRunning else { return }
        workerRunning = true
        worker.enqueue { [weak self] in
            self?.drainLoop()
        }
    }

    private func drainLoop() {
        while true {
            lock.lock()
            let target: Bool?
            if let pending = desiredWrite {
                desiredWrite = nil
                verifyDesired = false
                target = pending
            } else if verifyDesired {
                verifyDesired = false
                target = shadowMuted
            } else {
                workerRunning = false
                target = nil
            }
            lock.unlock()

            guard let target else { return }
            if readPlatform() != target {
                try? writePlatform(target)
                lock.lock()
                lastWriteCompletedUptime = uptime()
                lock.unlock()
            }
        }
    }
}
