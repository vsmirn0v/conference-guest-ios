import AVFoundation
import Darwin
import Foundation
import LiveKitWebRTC

/// Only the platform input-mute callback is non-main. It can close the native
/// process PCM gate, but can never authorize or open microphone capture.
@MainActor final class NativeDesktopHeadsetMute {
    struct Platform {
        var available: Bool
        var readMuted: () -> Bool
        var writeMuted: (Bool) throws -> Void
        var install: (@escaping @Sendable (Bool) -> Bool) throws -> Void
        var uninstall: () throws -> Void
        var observe: (@escaping @MainActor (Bool) -> Void) -> NSObjectProtocol
        var removeObserver: (NSObjectProtocol) -> Void
        var setCaptureMuted: @Sendable (Bool) -> Void
        var captureState: @Sendable () -> UInt64
        var unmuteIfState: @Sendable (UInt64) -> Bool
        var setIntent: (Int32) -> Void
        var isReconfiguring: () -> Bool

        static func live() -> Self {
            if #available(macOS 14.0, *) {
                let application = AVAudioApplication.shared
                return .init(available: true, readMuted: { application.isInputMuted },
                    writeMuted: { try application.setInputMuted($0) },
                    install: { try application.setInputMuteStateChangeHandler($0) },
                    uninstall: { try application.setInputMuteStateChangeHandler(nil) },
                    observe: { receive in
                        NotificationCenter.default.addObserver(forName: AVAudioApplication.inputMuteStateChangeNotification,
                            object: nil, queue: .main) { note in
                                // Read this notification's metadata. Reading only the
                                // latest platform bit turns queued old events into gestures.
                                guard let value = note.userInfo?[AVAudioApplication.muteStateKey] as? NSNumber else { return }
                                let muted = value.boolValue
                                Task { @MainActor in receive(muted) }
                            }
                    }, removeObserver: { NotificationCenter.default.removeObserver($0) },
                    setCaptureMuted: { LKRTCSetApplicationCaptureMuted($0 ? 1 : 0) },
                    captureState: { LKRTCApplicationCaptureState() },
                    unmuteIfState: { LKRTCUnmuteApplicationCaptureIfState($0) },
                    setIntent: { LKRTCSetApplicationInputMuteIntent($0) },
                    isReconfiguring: { LKRTCApplicationInputMuteReconfiguring() != 0 })
            }
            return .init(available: false, readMuted: { true }, writeMuted: { _ in }, install: { _ in },
                uninstall: {}, observe: { _ in NSObject() }, removeObserver: { _ in },
                setCaptureMuted: { _ in }, captureState: { 1 }, unmuteIfState: { _ in false },
                setIntent: { _ in }, isReconfiguring: { false })
        }
    }

    private static weak var current: NativeDesktopHeadsetMute?
    private static var currentOwner: UUID?
    struct Request: Equatable {
        fileprivate let owner: UUID
        fileprivate let revision: UInt64
        fileprivate let muteEpoch: Int64
    }
    private let platform: Platform
    private var lifetime: HandlerLifetime?
    private var observer: NSObjectProtocol?
    private var owner: UUID?
    private var policy = NativeDesktopHeadsetMutePolicy()
    private var requestRevision: UInt64 = 0
    private var platformSynchronized = true
    private var latestRequest: Request?
    private var requested: (@MainActor (Bool) -> Void)?
    private(set) var lastError: String?
    var onError: ((Error) -> Void)?
    var isActive: Bool { owner != nil && Self.current === self }

    init(platform: Platform? = nil) { self.platform = platform ?? .live() }
    deinit {
        let wasActive = lifetime?.invalidate() == true
        // Close synchronously; queued main cleanup must never tear down a replacement.
        if wasActive { platform.setCaptureMuted(true) }
        if let observer { platform.removeObserver(observer) }
        guard wasActive, let token = owner else { return }
        let platform = platform
        Task { @MainActor in
            guard Self.currentOwner == token else { return }
            Self.currentOwner = nil; Self.current = nil
            platform.setIntent(-1)
            try? platform.uninstall()
        }
    }

    /// Registration itself never requests TCC or starts the microphone. Initial
    /// accessory unmute requires optional, explicitly enabled muted-capture priming.
    @discardableResult
    func begin(onRequestedMute: @escaping @MainActor (Bool) -> Void) -> Bool {
        end()
        guard platform.available else { return false }
        if let previous = Self.current { previous.invalidate(unregister: false) }
        let token = UUID(), lifetime = HandlerLifetime()
        owner = token; self.lifetime = lifetime; requested = onRequestedMute
        Self.current = self; Self.currentOwner = token; policy.begin(); lastError = nil
        platformSynchronized = true
        platform.setCaptureMuted(true); platform.setIntent(1)
        let gate = platform.setCaptureMuted
        do {
            try platform.install { muted in
                guard lifetime.active else { return false }
                // Atomic PCM suppression completes before success is returned.
                // An unmute stays closed until the current engine confirms it.
                if muted { lifetime.recordMute(); gate(true) }
                return true
            }
        } catch {
            invalidate(unregister: true)
            record(error)
            return false
        }
        observer = platform.observe { [weak self] muted in self?.receive(muted, owner: token) }
        synchronizePlatform(muted: true)
        return isActive && owner == token
    }

    /// Both directions close immediately: a pending unmute is not capture authority.
    @discardableResult func requestIntent(muted: Bool) -> Request? {
        guard isActive, let owner else { return nil }
        requestRevision &+= 1
        let request = Request(owner: owner, revision: requestRevision, muteEpoch: lifetime?.muteEpoch ?? 0)
        policy.request(muted)
        platform.setCaptureMuted(true); platform.setIntent(muted ? 1 : 0)
        synchronizePlatform(muted: muted)
        guard accepts(request) else { return nil }
        latestRequest = request
        return request
    }

    /// Old confirmations cannot reopen after a newer mute. The caller confirms
    /// effective engine state after authorization/publication, never UI optimism.
    func confirm(muted: Bool) {
        guard isActive else { return }
        // Untagged status can close capture, but never grants new authority.
        guard muted else { return }
        policy.confirm(muted)
        platform.setCaptureMuted(true)
    }
    func confirm(muted: Bool, request: Request?) {
        guard let request, accepts(request) else { return }
        if !muted && !policy.requestedMuted {
            guard lifetime?.muteEpoch == request.muteEpoch, !platform.readMuted() else {
                platform.setCaptureMuted(true); return
            }
        }
        policy.confirm(muted)
        let keepMuted = !policy.mayCapture
        if keepMuted { platform.setCaptureMuted(true) }
        platform.setIntent(policy.requestedMuted ? 1 : 0)
        guard synchronizePlatform(muted: policy.requestedMuted), accepts(request) else { return }
        if keepMuted { platform.setCaptureMuted(true); return }
        let state = platform.captureState()
        guard accepts(request), lifetime?.muteEpoch == request.muteEpoch, !platform.readMuted() else { return }
        // A newer synchronous mute changes this native epoch even if PCM was
        // already closed. Its compare/exchange cannot be overwritten by this open.
        _ = platform.unmuteIfState(state)
    }

    /// Explicit fallback after a failed registration. The caller must have
    /// independently confirmed all current network microphone senders are muted.
    @discardableResult func useEngineOnlyFallback(confirmedMuted: Bool) -> Bool {
        guard confirmedMuted, owner == nil, Self.currentOwner == nil else { return false }
        platform.setIntent(-1); platform.setCaptureMuted(false); return true
    }

    func end() { invalidate(unregister: true) }

    private func invalidate(unregister: Bool) {
        lifetime?.invalidate(); lifetime = nil
        if let observer { platform.removeObserver(observer) }; observer = nil
        let owned = owner != nil && owner == Self.currentOwner
        owner = nil; requested = nil; latestRequest = nil; policy.end(); requestRevision &+= 1
        guard owned else { return }
        Self.current = nil; Self.currentOwner = nil
        platform.setCaptureMuted(true); platform.setIntent(-1)
        if unregister { do { try platform.uninstall() } catch { record(error) } }
    }

    private func receive(_ muted: Bool, owner token: UUID) {
        guard isActive, owner == token else { return }
        guard platform.readMuted() == muted else { return }
        guard platformSynchronized else { synchronizePlatform(muted: policy.requestedMuted); return }
        // Unexpected mute always wins, including during native reconfiguration.
        if muted, !policy.requestedMuted {
            guard let request = requestIntent(muted: true), accepts(request) else { return }
            requested?(true); return
        }
        guard !platform.isReconfiguring() else {
            platform.setIntent(policy.requestedMuted ? 1 : 0)
            synchronizePlatform(muted: policy.requestedMuted)
            return
        }
        let newerUnmute = !muted && latestRequest?.muteEpoch != lifetime?.muteEpoch
        guard muted != policy.requestedMuted || newerUnmute,
              let request = requestIntent(muted: muted), accepts(request) else { return }
        requested?(muted)
    }

    @discardableResult private func synchronizePlatform(muted: Bool) -> Bool {
        guard platform.readMuted() != muted else { platformSynchronized = true; return true }
        do { try platform.writeMuted(muted); platformSynchronized = true; return true }
        catch {
            // Fail closed; a later confirmed state can retry the platform write.
            platform.setCaptureMuted(true)
            platformSynchronized = false
            record(error); return false
        }
    }
    private func accepts(_ request: Request) -> Bool {
        isActive && owner == request.owner && requestRevision == request.revision
    }
    private func record(_ error: Error) { lastError = error.localizedDescription; onError?(error) }
}

/// Latest requested and confirmed states are separate. Platform reset notifications
/// never become authority to transmit; only a matching engine confirmation can.
struct NativeDesktopHeadsetMutePolicy {
    private(set) var active = false
    private(set) var requestedMuted = true
    private(set) var confirmedMuted = true
    private(set) var pending = false
    var mayCapture: Bool { active && !pending && !requestedMuted && !confirmedMuted }
    mutating func begin() { active = true; requestedMuted = true; confirmedMuted = true; pending = false }
    mutating func end() { active = false; requestedMuted = true; confirmedMuted = true; pending = false }
    mutating func request(_ muted: Bool) { requestedMuted = muted; pending = true }
    mutating func confirm(_ muted: Bool) {
        confirmedMuted = muted
        if muted == requestedMuted { pending = false }
    }
}

/// The callback retains its own lock-free validity cell. Main invalidates it
/// before replacing/removing the handler; a queued obsolete callback fails closed.
private final class HandlerLifetime: @unchecked Sendable {
    private let value = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
    private let epoch = UnsafeMutablePointer<Int64>.allocate(capacity: 1)
    init() { value.initialize(to: 1); epoch.initialize(to: 0) }
    deinit { value.deinitialize(count: 1); value.deallocate(); epoch.deinitialize(count: 1); epoch.deallocate() }
    var active: Bool { OSAtomicAdd32Barrier(0, value) == 1 }
    var muteEpoch: Int64 { OSAtomicAdd64Barrier(0, epoch) }
    func recordMute() { _ = OSAtomicIncrement64Barrier(epoch) }
    @discardableResult func invalidate() -> Bool { OSAtomicCompareAndSwap32Barrier(1, 0, value) }
}
