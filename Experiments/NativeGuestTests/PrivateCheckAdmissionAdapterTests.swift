import Foundation
enum ErrorCase: Error { case notConnected, permissionDenied, staleOperation, cleanupFailed, closed, invalidResponse }
typealias NativeDesktopGuestError = ErrorCase
typealias NativeDesktopRTCError = ErrorCase
enum Kind { case audio }
@MainActor enum GuestCaptureAuthorization {
    static var holdNext = false, pending: CheckedContinuation<Bool, Never>?
    static func request(_ kind: Kind) async throws -> Bool {
        if holdNext { holdNext = false; return await withCheckedContinuation { pending = $0 } }
        return true
    }
}
enum Phase { case connected }
struct Snapshot { var phase = Phase.connected }
final class Session {}
@MainActor final class Owner {
    var active: UUID?
    func beginPrivateInputCheck(requestID: UUID = UUID()) async -> Bool { active = requestID; return true }
    func endPrivateInputCheck(requestID: UUID? = nil) async -> Bool {
        #if ROCK_VPIO_BUILTIN_RELEASE
        if requestID == nil || requestID == active { active = nil }
        #else
        active = nil
        #endif
        return true
    }
}
@MainActor final class GuestAdapter {
    var mediaRevokedForLeave = false, snapshot = Snapshot(), revision = UUID(), privateAudioCheck = UUID()
    var session: Session? = Session(), systemAudio: Owner? = Owner()
    func check(_ token: UUID, session: Session) throws { if token != revision || self.session !== session { throw ErrorCase.staleOperation } }
    // INSERT GUEST METHODS
}
@MainActor final class ExternalAdapter {
    var snapshot = Snapshot(), epoch = UUID(), privateAudioCheck = UUID(), audio: Owner? = Owner()
    func check(_ token: UUID) throws { if token != epoch { throw ErrorCase.staleOperation } }
    // INSERT EXTERNAL METHODS
}
@main struct Tests {
    @MainActor static func main() async {
        let guest = GuestAdapter()
        GuestCaptureAuthorization.holdNext = true
        let a = Task { try? await guest.startPrivateAudioCheck() }
        while GuestCaptureAuthorization.pending == nil { await Task.yield() }
        try! await guest.startPrivateAudioCheck(); let b = guest.systemAudio!.active
        GuestCaptureAuthorization.pending!.resume(returning: true); GuestCaptureAuthorization.pending = nil
        await a.value
        precondition(b != nil && guest.systemAudio!.active == b, "stale Guest A must not stop B")
        try! await guest.stopPrivateAudioCheck(); precondition(guest.systemAudio!.active == nil)

        let external = ExternalAdapter()
        GuestCaptureAuthorization.holdNext = true
        let e = Task { try? await external.startPrivateAudioCheck() }
        while GuestCaptureAuthorization.pending == nil { await Task.yield() }
        try! await external.startPrivateAudioCheck(); let f = external.audio!.active
        GuestCaptureAuthorization.pending!.resume(returning: true); GuestCaptureAuthorization.pending = nil
        await e.value
        precondition(f != nil && external.audio!.active == f, "stale External A must not stop B")
        try! await external.stopPrivateAudioCheck(); precondition(external.audio!.active == nil)

        let replacing = GuestAdapter(); let old = replacing.systemAudio!
        GuestCaptureAuthorization.holdNext = true
        let r = Task { try? await replacing.startPrivateAudioCheck() }
        while GuestCaptureAuthorization.pending == nil { await Task.yield() }
        replacing.systemAudio = Owner(); replacing.revision = UUID()
        try! await replacing.startPrivateAudioCheck(); let replacementID = replacing.systemAudio!.active
        GuestCaptureAuthorization.pending!.resume(returning: true); GuestCaptureAuthorization.pending = nil
        await r.value
        precondition(old.active == nil && replacing.systemAudio!.active == replacementID, "permission reply cannot start old owner")
        print("PASS 5 adapter assertions: delayed permission, overlapping request and replacement owner")
    }
}
