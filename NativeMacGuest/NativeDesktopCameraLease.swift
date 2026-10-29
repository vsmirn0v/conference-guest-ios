import Combine
import AVFoundation
import Foundation
import LiveKitWebRTC

/// Cold AVFoundation discovery may enqueue a main-thread preferred-camera refresh.
/// Keep that metadata-only work before audio starts, including across canceled joins.
@MainActor final class NativeDesktopCameraMetadataPreparation {
    enum Outcome: String { case skipped, prepared, drained }
    static let shared = NativeDesktopCameraMetadataPreparation()
    private static let queue = DispatchQueue(label: "native-guest.camera.metadata")
    private let authorized: @MainActor () -> Bool
    private let read: @MainActor (String?) async -> Void
    private let timeout: TimeInterval
    private var pending: (id: UUID, task: Task<Bool, Never>)?

    init(timeout: TimeInterval = 3,
         authorized: @escaping @MainActor () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         read: (@MainActor (String?) async -> Void)? = nil) {
        self.timeout = timeout; self.authorized = authorized
        self.read = read ?? { id in await Self.readMetadata(deviceID: id) }
    }

    func prepare(eligible: @escaping @MainActor () -> Bool, deviceID: String?) async throws -> Outcome {
        try Task.checkCancellation()
        let draining = pending != nil
        if pending == nil, eligible(), authorized() {
            let id = UUID()
            let task = Task { @MainActor [self] in
                // A policy change can withdraw work before the native read enters.
                guard eligible(), authorized() else {
                    if pending?.id == id { pending = nil }; return false
                }
                await self.read(deviceID)
                if pending?.id == id { pending = nil }
                return true
            }
            pending = (id, task)
        }
        guard let task = pending?.task else { return .skipped }
        // Timeout/cancellation ends this caller, never the underlying native read.
        // A later join, even camera-Off, must wait for the retained barrier.
        let performed: Bool = try await guestAwait(timeout: timeout) { done in
            Task { @MainActor in
                let result = await task.value
                done(.success(result))
            }
        }
        try Task.checkCancellation()
        return performed ? (draining ? .drained : .prepared) : .skipped
    }

    private static func readMetadata(deviceID: String?) async {
        await withCheckedContinuation { continuation in
            queue.async {
                if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                    if let deviceID, !deviceID.isEmpty {
                        _ = AVCaptureDevice.devices(for: .video).first { $0.uniqueID == deviceID }
                    } else {
                        _ = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                            ?? AVCaptureDevice.default(for: .video)
                    }
                }
                continuation.resume()
            }
        }
    }
}

/// Process-wide hardware ownership. A live reservation exists before capture
/// starts and survives temporary track loss during network recovery. Private
/// views may borrow it, but cannot revoke or create competing hardware capture.
@MainActor final class NativeDesktopCameraLease: ObservableObject {
    static let shared = NativeDesktopCameraLease()
    struct Token: Equatable { fileprivate let id: UUID }
    enum Acquisition { case owned(Token), borrowed(LKRTCVideoTrack), livePending }
    private enum Kind { case live, privatePreview }
    private struct Owner {
        let token: Token
        let id: UUID
        let kind: Kind
        let revoke: @MainActor () async throws -> Void
    }
    @Published private(set) var liveTrack: LKRTCVideoTrack?
    private var owner: Owner?
    private var retiring: Task<Void, Error>?
    private var cleanupFailed = false
    // A failed stop has no affirmative release witness. Keep its owner alive
    // for the process lifetime, including failures reported by a retired token.
    private var quarantinedOwners: [UUID: AnyObject] = [:]

    func acquirePrivate(owner id: UUID, revoke: @escaping @MainActor () async throws -> Void) async throws -> Acquisition {
        guard !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
        if owner?.kind == .live { return liveTrack.map(Acquisition.borrowed) ?? .livePending }
        return .owned(try await acquire(id: id, kind: .privatePreview, revoke: revoke))
    }
    func acquireLive(owner id: UUID, revoke: @escaping @MainActor () async throws -> Void) async throws -> Token {
        try await acquire(id: id, kind: .live, revoke: revoke)
    }
    /// Speculative work may reserve only a vacant camera and never revoke a
    /// preview/live owner. No suspension can leave an untracked late reservation.
    func acquirePreparationIfVacant(owner id: UUID, revoke: @escaping @MainActor () async throws -> Void) throws -> Token? {
        guard !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
        guard owner == nil, retiring == nil else { return nil }
        let token = Token(id: UUID())
        owner = Owner(token: token, id: id, kind: .privatePreview, revoke: revoke)
        return token
    }
    private func acquire(id: UUID, kind: Kind, revoke: @escaping @MainActor () async throws -> Void) async throws -> Token {
        guard !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
        if let owner, owner.id == id, owner.kind == kind {
            try await retiring?.value; try Task.checkCancellation()
            guard isCurrent(owner.token) else { throw CancellationError() }
            return owner.token
        }
        let old = owner, previous = retiring, token = Token(id: UUID())
        // Reserve before the first suspension: a new private check cannot slip
        // between the old capturer's stop and the live engine's startup.
        owner = Owner(token: token, id: id, kind: kind, revoke: revoke); liveTrack = nil
        let task = Task { try await previous?.value; try await old?.revoke() }
        retiring = task
        do {
            try await task.value; try Task.checkCancellation()
            guard isCurrent(token) else { throw CancellationError() }
            retiring = nil
            return token
        } catch {
            if !(error is CancellationError) { cleanupFailed = true }
            if isCurrent(token) { owner = nil; liveTrack = nil }
            throw error
        }
    }
    func isCurrent(_ token: Token) -> Bool { !cleanupFailed && owner?.token == token }
    func setLiveTrack(_ track: LKRTCVideoTrack?, owner id: UUID) {
        guard !cleanupFailed, owner?.kind == .live, owner?.id == id else { return }
        liveTrack = track
    }
    /// Call only after the owner's capturer confirms stop. A retired owner
    /// cannot release a newer reservation while its asynchronous stop completes.
    func release(_ token: Token) {
        guard owner?.token == token else { return }
        owner = nil; liveTrack = nil
    }
    func reportFailedStop(_ token: Token, retainingOwner: AnyObject? = nil) {
        cleanupFailed = true
        if let retainingOwner { quarantinedOwners[token.id] = retainingOwner }
        if owner?.token == token { liveTrack = nil }
    }
}

/// A one-shot private capture using the existing process-wide camera lease.
/// No track is created or attached to a peer. Stop failure quarantines the lease.
/// Successful stop tears down the entire session; this measures one-shot hardware
/// warmup and does not retain a capture graph for later camera activation.
@MainActor final class NativeDesktopJoinCameraPrime {
    private let id = UUID()
    private let lease: NativeDesktopCameraLease
    private let authorized: () -> Bool
    private let makeCapture: (LKRTCVideoSource) -> any GuestCameraCapture
    private let budget: Duration
    private var token: NativeDesktopCameraLease.Token?
    private var capture: (any GuestCameraCapture)?
    private var stopping: Task<Void, Error>?
    private var cancelled = false
    private(set) var cleanupSucceeded = true
    private(set) var report: [String: Any] = ["state": "idle"]

    init(lease: NativeDesktopCameraLease = .shared, budget: Duration = .seconds(3),
         authorized: @escaping () -> Bool = { AVCaptureDevice.authorizationStatus(for: .video) == .authorized },
         makeCapture: @escaping (LKRTCVideoSource) -> any GuestCameraCapture = {
             let id = UserDefaults.standard.string(forKey: "nativeDesktop.cameraID")
             return GuestCamera(source: $0, deviceID: id?.isEmpty == false ? id : nil, existingAuthorizationOnly: true)
         }) {
        self.lease = lease; self.budget = budget; self.authorized = authorized; self.makeCapture = makeCapture
    }

    func cancel() { cancelled = true; capture?.cancel() }

    func run(source: () -> LKRTCVideoSource?) async throws {
        guard !cancelled, !Task.isCancelled else { throw CancellationError() }
        guard authorized() else { report = ["state": "skipped", "reason": "authorization"]; return }
        guard let reservation = try lease.acquirePreparationIfVacant(owner: id, revoke: { [weak self] in try await self?.stop() }) else {
            report = ["state": "skipped", "reason": "cameraOwned"]; return
        }
        token = reservation
        let began = ProcessInfo.processInfo.systemUptime
        do {
            try Task.checkCancellation()
            guard !cancelled, lease.isCurrent(reservation), authorized() else { throw CancellationError() }
            guard let source = source() else {
                report = ["state": "skipped", "reason": "factoryUnavailable"]
                try await stop(); return
            }
            let capture = makeCapture(source); self.capture = capture
            report = ["state": "starting", "startedUptime": began]
            // Whole-start budget: no frame means cancel, then wait for real cleanup.
            let deadline = Task { [budget, weak self] in
                do {
                    try await Task.sleep(for: budget)
                    self?.report["budgetExpired"] = true
                    capture.cancel()
                } catch {}
            }
            defer { deadline.cancel() }
            _ = try await withTaskCancellationHandler(operation: { try await capture.start() }, onCancel: { capture.cancel() })
            deadline.cancel()
            let value = capture.snapshot()
            guard value.frames > 0 else { throw GuestCameraError.configurationFailed }
            report["firstFrameUptime"] = ProcessInfo.processInfo.systemUptime
            report["startupMilliseconds"] = value.startupMilliseconds
            report["frames"] = value.frames
            try await stop()
            report["state"] = "completed"
        } catch {
            let failure = error
            do { try await stop() } catch { report["state"] = "stopFailed"; throw error }
            report["state"] = failure is CancellationError ? "cancelled" : "failed"
            report["error"] = failure.localizedDescription
            report["totalMilliseconds"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
            throw failure
        }
        report["totalMilliseconds"] = (ProcessInfo.processInfo.systemUptime - began) * 1000
    }

    func stop() async throws {
        cancel()
        if let stopping { try await stopping.value; return }
        let capture = capture, token = token
        let task = Task { @MainActor in if let capture { try await capture.stop() } }
        stopping = task
        do {
            try await task.value
            if let token { lease.release(token) }
            self.capture = nil; self.token = nil
            report["stopped"] = true; report["stoppedUptime"] = ProcessInfo.processInfo.systemUptime
        } catch {
            cleanupSucceeded = false
            if let token { lease.reportFailedStop(token, retainingOwner: capture) }
            report["stopped"] = false
            throw error
        }
    }
}
