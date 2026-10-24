import AppKit
import Foundation

private enum EntryTestError: Error { case assertion(String) }
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw EntryTestError.assertion(message) }
}

@MainActor private final class EntryEngine: GuestSessionEngine {
    var sessionID: String?
    var onFailure: ((Error) -> Void)?
    var onForcedMute: ((Bool) -> Void)?
    var onPermissionsChange: ((GuestMediaPermissions) -> Void)?
    var mediaPermissions = GuestMediaPermissions(canShareMicrophone: true, canShareCamera: true)
    var publications: [(Bool, Bool)] = []
    var leaves = 0
    var clean = true
    func join(_ invitation: GuestInvitation, sessionID: String?) async throws { self.sessionID = "standalone-test" }
    func publishPattern(codec: String, camera: Bool, audioMuted: Bool, videoMuted: Bool) async throws {
        publications.append((audioMuted, videoMuted))
    }
    func mute(_ muted: Bool, video: Bool) async throws {}
    func setLocalMuteIntent(_ muted: Bool, video: Bool) {}
    func suppressOutgoingMedia() {}
    func leave(sendLeave: Bool) async -> Bool { leaves += 1; return clean }
    func interruptTransportForTesting() async {}
}

@main private struct StandaloneEntryTests {
    @MainActor static func spin(_ predicate: () -> Bool) async throws {
        for _ in 0..<20_000 { if predicate() { return }; await Task.yield() }
        throw EntryTestError.assertion("The deterministic session did not complete its operation")
    }
    static func inputValidation() throws {
        try expect(try NativeGuestLaunchMode.parse(["app"]) == .automatic, "Direct launch discovers only an existing ticket")
        try expect(try NativeGuestLaunchMode.parse(["app", "--standalone"]) == .standalone, "Explicit standalone bypasses host admission")
        let id = UUID()
        try expect(try NativeGuestLaunchMode.parse(["app", "--session", id.uuidString]) == .companion(id), "Valid host identity survives parsing")
        for args in [["app", "--session"], ["app", "--session", "invalid"],
                     ["app", "--standalone", "--session", id.uuidString],
                     ["app", "--session", id.uuidString, "--session", id.uuidString]] {
            do { _ = try NativeGuestLaunchMode.parse(args); throw EntryTestError.assertion("Malformed host request accepted") }
            catch NativeGuestEntryError.invalidLaunch { }
        }
        let request = try NativeGuestJoinRequest.parse(invitation: " https://example.test/calls/room \n", displayName: "  Guest 😀  ")
        try expect(request.displayName == "Guest 😀" && request.invitation.roomID == "room", "Manual input uses the canonical invitation parser")
        for name in [" \n ", "Guest\u{0000}", "First\nLast", String(repeating: "😀", count: 129)] {
            do { _ = try NativeGuestJoinRequest.parse(invitation: "https://example.test/calls/room", displayName: name)
                throw EntryTestError.assertion("Invalid display name accepted") }
            catch NativeGuestEntryError.invalidName { }
        }
        for url in ["http://example.test/calls/room", "https://user:password@example.test/calls/room", "https://example.test/calls/room#secret"] {
            do { _ = try NativeGuestJoinRequest.parse(invitation: url, displayName: "Guest")
                throw EntryTestError.assertion("Unsafe invitation accepted") }
            catch NativeGuestEntryError.invalidInvitation { }
        }
    }
    @MainActor static func standaloneLifecycle() async throws {
        _ = NSApplication.shared
        let request = try NativeGuestJoinRequest.parse(invitation: "https://example.test/calls/room", displayName: "Guest")
        var controllers: [CompanionMeetingController] = []
        var completions: [NativeGuestMeetingCompletion] = []
        for iteration in 0..<2 {
            let engine = EntryEngine()
            let session = GuestSession(makeAttempt: { engine })
            let controller = CompanionMeetingController(request: request, makeSession: { session }) { completions.append($0) }
            controllers.append(controller)
            await controller.start()
            try await spin { session.state == .connected }
            try expect(engine.publications.count == 1 && engine.publications[0].0 && engine.publications[0].1,
                       "Every fresh join starts with microphone and camera off")
            if iteration == 0 {
                // Exercise the real controller beyond the host-death deadline with no app group or heartbeat.
                try await Task.sleep(nanoseconds: UInt64((NativeGuestProtocol.ownerDeathTimeout + 1) * 1_000_000_000))
                try expect(session.state == .connected && !controller.finished, "A standalone session must outlive a missing host heartbeat")
            }
            await controller.finish(); await controller.finish()
            try expect(controller.finished && engine.leaves == 1 && completions.count == iteration + 1,
                       "Leave joins media cleanup once and reports completion once")
            try expect(completions.last == .left, "Clean standalone Leave returns to manual admission")
        }
        try expect(controllers.count == 2, "Rejoin creates a fresh session after teardown")
        let engine = EntryEngine(); engine.clean = false
        let session = GuestSession(makeAttempt: { engine })
        let controller = CompanionMeetingController(request: request, makeSession: { session }) { completions.append($0) }
        await controller.start(); try await spin { session.state == .connected }; await controller.finish()
        try expect(completions.last == .cleanupFailed && completions.last?.permitsRejoin == false,
                   "Unproven media teardown blocks a second session")
    }
    static func rejectedCompanionAdmission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("native-entry-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NativeGuestSessionStore(rootURL: root)
        let files = CompanionFiles(store: store)
        let ticket = NativeGuestTicket(invitationURL: URL(string: "https://example.test/calls/room")!, displayName: "Host guest")
        try store.create(ticket)
        try store.writeHeartbeat(NativeGuestHeartbeat(metadata: ticket.metadata))
        var command = NativeGuestCommand(metadata: ticket.metadata)
        command.expectedHelperPID = getpid() + 1
        try store.writeCommand(command)
        do { _ = try await files.admit(ticket.metadata.sessionID, processID: getpid())
            throw EntryTestError.assertion("An unauthorized helper PID admitted the host ticket") }
        catch NativeGuestStoreError.incompatibleRecord { }
        try expect(try store.readTicket(ticket.metadata.sessionID) != nil, "Rejected admission must not consume the authorized host ticket")
        command.expectedHelperPID = getpid(); try command.advance(changing: [], acknowledged: nil); try store.writeCommand(command)
        let admitted = try await files.admit(ticket.metadata.sessionID, processID: getpid())
        try expect(admitted == ticket, "The exact authorized helper still admits its one-use ticket")
        do { _ = try await files.admit(ticket.metadata.sessionID, processID: getpid())
            throw EntryTestError.assertion("An already consumed host ticket was reused") }
        catch NativeGuestStoreError.io(let code) where code == EEXIST { }
    }
    @MainActor static func main() async {
        do {
            try inputValidation()
            try await rejectedCompanionAdmission()
            try await standaloneLifecycle()
            print("PASS: standalone input, media-off join/Leave/rejoin, host-independent lifetime, cleanup gate and exact-PID one-use companion admission")
        } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
    }
}
