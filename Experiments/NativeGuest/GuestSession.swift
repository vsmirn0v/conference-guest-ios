import Foundation

/// Desired publication survives attempts; peer IDs, subscriptions and transport do not.
struct GuestMediaIntent: Equatable {
    var publish: Bool
    var codec: String
    var camera: Bool
    var audioMuted: Bool
    var videoMuted: Bool
}

struct GuestMediaPermissions: Equatable {
    var canShareMicrophone = false
    var canShareCamera = false
}

struct GuestSessionSnapshot {
    let state: GuestSession.State
    let desiredIntent: GuestMediaIntent?
    let appliedIntent: GuestMediaIntent?
    let permissions: GuestMediaPermissions
    let recoveryAttempts: Int
    let failure: Error?
    let microphoneActivated: Bool
    let desiredPlayoutEnabled: Bool?
    let appliedPlayoutEnabled: Bool?
}

/// A session has a finite automatic recovery budget, reset only by explicit connect.
struct GuestRecoveryPolicy {
    private(set) var retries = 0
    private let delays: [UInt64] = [500_000_000, 1_000_000_000, 2_000_000_000]

    static func isRecoverable(_ error: Error) -> Bool {
        if let error = error as? GuestTransportError {
            switch error {
            case .networkFailure, .closed, .timedOut: return true
            default: return false
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
                 .networkConnectionLost, .notConnectedToInternet: return true
            default: return false
            }
        }
        if case GuestPeerError.iceFailed = error { return true }
        return false
    }

    mutating func nextDelay(after error: Error) -> UInt64? {
        guard Self.isRecoverable(error), retries < delays.count else { return nil }
        let delay = delays[retries]
        retries += 1
        return delay
    }
}

@MainActor
protocol GuestSessionEngine: AnyObject {
    var sessionID: String? { get }
    var onFailure: ((Error) -> Void)? { get set }
    var onForcedMute: ((Bool) -> Void)? { get set }
    var mediaPermissions: GuestMediaPermissions { get }
    var onPermissionsChange: ((GuestMediaPermissions) -> Void)? { get set }
    func activateMicrophone() async throws
    func setPlayoutEnabled(_ enabled: Bool) async throws
    func join(_ invitation: GuestInvitation, sessionID: String?) async throws
    func publishPattern(codec: String, camera: Bool, audioMuted: Bool, videoMuted: Bool) async throws
    func mute(_ muted: Bool, video: Bool) async throws
    func setLocalMuteIntent(_ muted: Bool, video: Bool)
    func suppressOutgoingMedia()
    func leave(sendLeave: Bool) async -> Bool
    func interruptTransportForTesting() async
}

extension GuestSessionEngine {
    var mediaPermissions: GuestMediaPermissions { .init() }
    var onPermissionsChange: ((GuestMediaPermissions) -> Void)? { get { nil } set {} }
    func activateMicrophone() async throws {}
    func setPlayoutEnabled(_ enabled: Bool) async throws {}
}

enum GuestSessionError: Error { case cleanupFailed }

/// One serial control job owns startup, mute reconciliation and recovery. Leave
/// invalidates its generation before cancellation, then joins its cleanup.
@MainActor
final class GuestSession {
    enum State: Equatable { case idle, connecting, connected, recovering, failed, left }
    private(set) var state: State = .idle { didSet { notifyStateChange() } }
    private(set) var failure: Error? { didSet { notifyStateChange() } }
    private(set) var sessionID: String?
    private(set) var recoveryAttempts = 0 { didSet { notifyStateChange() } }
    private(set) var connectionCount: UInt64 = 0
    private(set) var desiredIntent: GuestMediaIntent? { didSet { notifyStateChange() } }
    private var current: (any GuestSessionEngine)? {
        didSet {
#if canImport(LiveKitWebRTC)
            onEngineChange?(engine)
#endif
            notifyStateChange()
        }
    }
    private var invitation: GuestInvitation?
    private(set) var appliedIntent: GuestMediaIntent? { didSet { notifyStateChange() } }
    private var microphoneActivationRequested = false
    private var appliedMicrophoneActivation = false
    private var desiredPlayoutEnabled: Bool? { didSet { notifyStateChange() } }
    private var appliedPlayoutEnabled: Bool? { didSet { notifyStateChange() } }
    var onStateChange: ((GuestSessionSnapshot) -> Void)? { didSet { notifyStateChange() } }
    var snapshot: GuestSessionSnapshot {
        .init(state: state, desiredIntent: desiredIntent, appliedIntent: appliedIntent,
              permissions: current?.mediaPermissions ?? .init(), recoveryAttempts: recoveryAttempts,
              failure: failure, microphoneActivated: appliedMicrophoneActivation,
              desiredPlayoutEnabled: desiredPlayoutEnabled, appliedPlayoutEnabled: appliedPlayoutEnabled)
    }
    private func notifyStateChange() { onStateChange?(snapshot) }
    private var generation: UInt64 = 0
    private var attemptID: UUID?
    private var connectedAttemptID: UUID?
    private var control: Task<Void, Never>?
    private var shutdown: Task<Bool, Never>?
    private var pendingFailure: Error?
    private var cleanupSucceeded = true
    private var policy = GuestRecoveryPolicy()
    private let makeAttempt: @MainActor () async throws -> any GuestSessionEngine
    private let sleep: @MainActor (UInt64) async throws -> Void

    #if canImport(LiveKitWebRTC)
    var engine: NativeGuestEngine? { current as? NativeGuestEngine }
    var onEngineChange: ((NativeGuestEngine?) -> Void)? { didSet { onEngineChange?(engine) } }
    convenience init(makeEngine: @escaping @MainActor () async throws -> NativeGuestEngine) {
        self.init(makeAttempt: { try await makeEngine() })
    }
    #endif

    init(makeAttempt: @escaping @MainActor () async throws -> any GuestSessionEngine,
         sleep: @escaping @MainActor (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.makeAttempt = makeAttempt; self.sleep = sleep
    }

    func connect(_ invitation: GuestInvitation, publish: Bool, codec: String, camera: Bool,
                 initialAudioMuted: Bool = false, initialVideoMuted: Bool = false) async throws {
        guard state == .idle || state == .left || state == .failed else { throw GuestTransportError.alreadyConnecting }
        let priorShutdown = shutdown
        generation &+= 1
        let expected = generation
        state = .connecting
        let drained = await priorShutdown?.value ?? cleanupSucceeded
        guard generation == expected else { throw CancellationError() }
        if Task.isCancelled { _ = await leave(); throw CancellationError() }
        guard drained else { state = .failed; failure = GuestSessionError.cleanupFailed; throw GuestSessionError.cleanupFailed }
        shutdown = nil; failure = nil; pendingFailure = nil; sessionID = nil
        cleanupSucceeded = true; policy = GuestRecoveryPolicy(); recoveryAttempts = 0
        microphoneActivationRequested = false; appliedMicrophoneActivation = false
        desiredPlayoutEnabled = nil; appliedPlayoutEnabled = nil
        self.invitation = invitation
        desiredIntent = GuestMediaIntent(publish: publish, codec: codec, camera: camera,
            audioMuted: initialAudioMuted, videoMuted: initialVideoMuted)
        startControl()
        let job = control
        try await withTaskCancellationHandler(operation: {
            await job?.value
            try Task.checkCancellation()
            guard generation == expected else { throw CancellationError() }
            if let failure { throw failure }
            guard state == .connected else { throw GuestTransportError.notConnected }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                _ = await self.leave()
            }
        })
    }

    /// Immediate owner intent, including while a TCC/device operation is awaiting.
    /// Muting suppresses the current sender/capture before any asynchronous work.
    func setLocalMuteIntent(_ muted: Bool, video: Bool = false) {
        guard var intent = desiredIntent, intent.publish, state != .left, state != .failed else { return }
        if video { intent.videoMuted = muted } else { intent.audioMuted = muted }
        desiredIntent = intent
        current?.setLocalMuteIntent(muted, video: video)
        startControl()
    }

    /// During recovery this changes intent immediately and waits for reconciliation.
    func mute(_ muted: Bool, video: Bool = false) async throws {
        guard let intent = desiredIntent, intent.publish, state != .left, state != .failed else {
            throw failure ?? GuestTransportError.notConnected
        }
        setLocalMuteIntent(muted, video: video)
        try await reconcileControl()
    }

    /// Explicit user activation after the UI has obtained microphone authorization.
    /// It does not unmute and survives automatic engine replacement.
    func activateMicrophone() async throws {
        guard desiredIntent != nil, state != .left, state != .failed else {
            throw failure ?? GuestTransportError.notConnected
        }
        microphoneActivationRequested = true
        try await reconcileControl()
    }

    func setPlayoutEnabled(_ enabled: Bool) async throws {
        guard desiredIntent != nil, state != .left, state != .failed else {
            throw failure ?? GuestTransportError.notConnected
        }
        desiredPlayoutEnabled = enabled
        try await reconcileControl()
    }

    private func reconcileControl() async throws {
        let expected = generation
        startControl()
        await control?.value
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
        if let failure { throw failure }
        guard state == .connected else { throw GuestTransportError.notConnected }
    }

    func waitUntilConnected(timeout: TimeInterval = 30) async throws {
        try await waitUntilConnected(timeout: timeout, after: nil)
    }

    /// Faults only this session's socket; recovery follows the normal failure callback.
    func reconnectForTesting() async throws {
        guard state == .connected, let current else { throw failure ?? GuestTransportError.notConnected }
        let expected = generation, before = connectionCount
        await current.interruptTransportForTesting()
        guard generation == expected else { throw CancellationError() }
        try await waitUntilConnected(timeout: 60, after: before)
    }

    @discardableResult
    func leave() async -> Bool {
        if state == .left, let shutdown { return await shutdown.value }
        generation &+= 1
        state = .left
#if canImport(LiveKitWebRTC)
        onEngineChange?(nil)
#endif
        current?.suppressOutgoingMedia()
        invitation = nil; desiredIntent = nil; pendingFailure = nil
        current?.onFailure = nil; current?.onForcedMute = nil; current?.onPermissionsChange = nil
        let job = control, previous = shutdown
        control = nil
        job?.cancel()
        let task = Task { @MainActor [self] in
            let priorResult = await previous?.value ?? true
            await job?.value
            let result = await retireCurrent(sendLeave: true)
            return priorResult && cleanupSucceeded && result
        }
        shutdown = task
        return await task.value
    }

    private func startControl() {
        guard control == nil, invitation != nil, desiredIntent != nil,
              state != .left, state != .failed else { return }
        let expected = generation
        control = Task { @MainActor [weak self] in await self?.run(expected) }
    }

    private func check(_ expected: UInt64, attempt: UUID) throws {
        guard generation == expected, attemptID == attempt, !Task.isCancelled else { throw CancellationError() }
        if let pendingFailure { throw pendingFailure }
    }

    private func run(_ expected: UInt64) async {
        while generation == expected, !Task.isCancelled {
            do {
                if let pendingFailure { throw pendingFailure }
                if current == nil {
                    guard let invitation else { throw CancellationError() }
                    let next = try await makeAttempt()
                    guard generation == expected, !Task.isCancelled else {
                        next.suppressOutgoingMedia()
                        cleanupSucceeded = await next.leave(sendLeave: false) && cleanupSucceeded
                        return
                    }
                    let attempt = UUID()
                    current = next; attemptID = attempt; appliedIntent = nil
                    appliedMicrophoneActivation = false; appliedPlayoutEnabled = nil
                    if let intent = desiredIntent {
                        next.setLocalMuteIntent(intent.audioMuted, video: false)
                        next.setLocalMuteIntent(intent.videoMuted, video: true)
                    }
                    next.onFailure = { [weak self] error in self?.failed(error, generation: expected, attempt: attempt) }
                    next.onForcedMute = { [weak self] video in self?.forcedMute(video, generation: expected, attempt: attempt) }
                    next.onPermissionsChange = { [weak self] _ in
                        guard let self, self.generation == expected, self.attemptID == attempt else { return }
                        self.notifyStateChange()
                    }
                    try await reconcileDeviceIntent(next, generation: expected, attempt: attempt)
                    try await next.join(invitation, sessionID: sessionID)
                    try check(expected, attempt: attempt)
                    sessionID = next.sessionID ?? sessionID
                    guard let intent = desiredIntent else { throw CancellationError() }
                    if intent.publish {
                        try await next.publishPattern(codec: intent.codec, camera: intent.camera,
                            audioMuted: intent.audioMuted, videoMuted: intent.videoMuted)
                        try check(expected, attempt: attempt)
                    }
                    appliedIntent = intent
                }
                guard let current, let attempt = attemptID else { throw CancellationError() }
                while let intent = desiredIntent, intent.publish, appliedIntent != intent {
                    if appliedIntent?.audioMuted != intent.audioMuted {
                        try await current.mute(intent.audioMuted, video: false)
                        try check(expected, attempt: attempt)
                        appliedIntent?.audioMuted = intent.audioMuted
                    }
                    // Re-read desired intent after the audio operation's suspension.
                    guard let latest = desiredIntent else { throw CancellationError() }
                    if appliedIntent?.videoMuted != latest.videoMuted {
                        try await current.mute(latest.videoMuted, video: true)
                        try check(expected, attempt: attempt)
                        appliedIntent?.videoMuted = latest.videoMuted
                    }
                }
                try await reconcileDeviceIntent(current, generation: expected, attempt: attempt)
                try check(expected, attempt: attempt)
                // A device operation may suspend after the media loop. Revisit
                // any newer intent before completing the shared control job.
                if desiredIntent?.publish == true, desiredIntent != appliedIntent { continue }
                if connectedAttemptID != attempt { connectionCount &+= 1; connectedAttemptID = attempt }
                state = .connected
                control = nil
                return
            } catch {
                guard generation == expected, !Task.isCancelled else {
                    _ = await retireCurrent(sendLeave: true)
                    return
                }
                let cause = pendingFailure ?? error
                pendingFailure = nil
                let delay = policy.nextDelay(after: cause)
                let stopped = await retireCurrent(sendLeave: delay == nil)
                guard generation == expected, !Task.isCancelled else { return }
                guard stopped else { finish(GuestSessionError.cleanupFailed); return }
                guard let delay else { finish(cause); return }
                recoveryAttempts = policy.retries; state = .recovering
                probeLog("session-recovery", ["attempt": recoveryAttempts, "causeType": String(describing: type(of: cause))])
                do { try await sleep(delay) }
                catch {
                    guard generation == expected, !Task.isCancelled else { return }
                    finish(error); return
                }
                guard generation == expected, !Task.isCancelled else { return }
            }
        }
    }

    private func reconcileDeviceIntent(_ engine: any GuestSessionEngine, generation expected: UInt64, attempt: UUID) async throws {
        if microphoneActivationRequested && !appliedMicrophoneActivation {
            try await engine.activateMicrophone()
            try check(expected, attempt: attempt)
            appliedMicrophoneActivation = true; notifyStateChange()
        }
        while let enabled = desiredPlayoutEnabled, enabled != appliedPlayoutEnabled {
            try await engine.setPlayoutEnabled(enabled)
            try check(expected, attempt: attempt)
            appliedPlayoutEnabled = enabled
        }
    }

    private func failed(_ error: Error, generation expected: UInt64, attempt: UUID) {
        guard generation == expected, attemptID == attempt, state != .left, pendingFailure == nil else { return }
        pendingFailure = error; state = .recovering
        startControl()
    }

    private func forcedMute(_ video: Bool, generation expected: UInt64, attempt: UUID) {
        guard generation == expected, attemptID == attempt, var intent = desiredIntent else { return }
        if video { intent.videoMuted = true } else { intent.audioMuted = true }
        desiredIntent = intent
        current?.setLocalMuteIntent(true, video: video)
        startControl()
    }

    private func retireCurrent(sendLeave: Bool) async -> Bool {
        guard let retired = current else { return cleanupSucceeded }
        retired.suppressOutgoingMedia()
        sessionID = retired.sessionID ?? sessionID
        current = nil; attemptID = nil; connectedAttemptID = nil; appliedIntent = nil
        appliedMicrophoneActivation = false; appliedPlayoutEnabled = nil
        retired.onFailure = nil; retired.onForcedMute = nil; retired.onPermissionsChange = nil
        let stopped = await retired.leave(sendLeave: sendLeave)
        cleanupSucceeded = stopped && cleanupSucceeded
        return stopped
    }

    private func finish(_ error: Error) {
        failure = error; state = .failed; control = nil
    }

    private func waitUntilConnected(timeout: TimeInterval, after count: UInt64?) async throws {
        guard timeout.isFinite, timeout > 0, timeout <= 300 else { throw GuestTransportError.timedOut }
        let expected = generation, deadline = ProcessInfo.processInfo.systemUptime + timeout
        while true {
            try Task.checkCancellation()
            guard generation == expected, state != .left else { throw CancellationError() }
            if let failure { throw failure }
            if state == .connected, count.map({ connectionCount > $0 }) ?? true { return }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw GuestTransportError.timedOut }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}

#if canImport(LiveKitWebRTC)
extension NativeGuestEngine: GuestSessionEngine {}
#endif
