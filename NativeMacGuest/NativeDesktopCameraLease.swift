import Combine
import Foundation
import LiveKitWebRTC

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

    func acquirePrivate(owner id: UUID, revoke: @escaping @MainActor () async throws -> Void) async throws -> Acquisition {
        guard !cleanupFailed else { throw NativeDesktopRTCError.cleanupFailed }
        if owner?.kind == .live { return liveTrack.map(Acquisition.borrowed) ?? .livePending }
        return .owned(try await acquire(id: id, kind: .privatePreview, revoke: revoke))
    }
    func acquireLive(owner id: UUID, revoke: @escaping @MainActor () async throws -> Void) async throws -> Token {
        try await acquire(id: id, kind: .live, revoke: revoke)
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
    func reportFailedStop(_ token: Token) {
        cleanupFailed = true
        if owner?.token == token { liveTrack = nil }
    }
}
