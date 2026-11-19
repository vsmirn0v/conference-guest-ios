import Foundation
import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

@MainActor private final class HistoryGate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor final class GuestHistoryIntegrationTests: XCTestCase {
    private func joined(chat: Bool = false, transcript: Bool = true, restricted: Bool = false) -> [String: Any] {
        ["event": "joined", "roomId": "fixture-room", "payload": [
            "roomId": "fixture-room", "participant": ["participantId": "local", "sessionId": "session",
                "isNetworkRestrictTranscription": restricted,
                "permissions": ["canViewChat": chat, "canViewTranscription": transcript]],
            "participantGroup": ["groupId": "fixture-group", "participants": [
                ["participantId": "local", "name": "Local", "role": "MEMBER"]]]]]
    }
    private func updated(_ payload: [String: Any]) -> [String: Any] {
        ["event": "permissions-updated", "roomId": "fixture-room", "groupId": "fixture-group", "payload": payload]
    }
    private func response(_ kind: String, id: String = "fresh") -> [String: Any] {
        ["event": "\(kind)-response", "roomId": "fixture-room", "groupId": "fixture-group", "payload": [
            "messages": [["id": id, "participantId": "remote", "text": "fixture"]]]]
    }
    private func spin(_ condition: () -> Bool) async throws {
        for _ in 0..<600 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Condition did not become true")
    }
    private func setup() async throws -> (NativeGuestEngine, GuestAdapter) {
        let native = NativeGuestEngine(label: "History fixture")
        _ = try await native.prepareJoinForTesting()
        let adapter = GuestAdapter(); adapter.bindHistoryForTesting(native)
        return (native, adapter)
    }
    private func finish(_ native: NativeGuestEngine, _ adapter: GuestAdapter) async {
        adapter.unbindHistoryForTesting(); _ = await native.leave(sendLeave: false)
    }

    func testTransientFirstHistoryFailureRetriesAndLoads() async throws {
        let (native, adapter) = try await setup(); var calls = 0
        native.featureRequestForTesting = { kind, _, _ in
            calls += 1
            if calls == 1 { throw GuestTransportError.timedOut }
            return self.response(kind)
        }
        try await native.processEventForTesting(joined())
        try await spin { adapter.guestSnapshot.transcriptHistoryLoaded }
        XCTAssertEqual(calls, 2); XCTAssertEqual(adapter.guestSnapshot.transcript.map(\.id), ["fresh"])
        await finish(native, adapter)
    }

    func testTranscriptCaptureObserverCanReadMeetingState() async throws {
        let (native, adapter) = try await setup()
        var capturedIDs: [String] = []
        adapter.onCapturedMessages = { [weak native] messages, transcript in
            XCTAssertTrue(transcript)
            XCTAssertEqual(native?.participationRoomScope?.room, "fixture-room")
            XCTAssertEqual(native?.participationRoomScope?.group, "fixture-group")
            capturedIDs.append(contentsOf: messages.map(\.id))
        }
        native.featureRequestForTesting = { kind, _, _ in self.response(kind, id: "history") }
        try await native.processEventForTesting(joined())
        try await spin { adapter.guestSnapshot.transcriptHistoryLoaded }
        try await native.processEventForTesting([
            "event": "transcription-message", "roomId": "fixture-room", "groupId": "fixture-group",
            "payload": ["message": ["id": "live", "participantId": "remote", "text": "fixture"]]
        ])
        XCTAssertEqual(capturedIDs, ["history", "live"])
        await finish(native, adapter)
    }

    func testRevocationAndRegrantDrainsCancelledRequestBeforeReplacement() async throws {
        let (native, adapter) = try await setup(); let gate = HistoryGate(); var calls = 0
        native.featureRequestForTesting = { kind, _, _ in
            calls += 1
            if calls == 1 { await gate.wait(); return self.response(kind, id: "stale") }
            return self.response(kind)
        }
        try await native.processEventForTesting(joined())
        try await spin { gate.continuation != nil }
        try await native.processEventForTesting(updated(["canViewTranscription": false]))
        try await native.processEventForTesting(updated(["canViewTranscription": true]))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(calls, 1, "Replacement must wait for the retired request to unwind")
        gate.release()
        try await spin { adapter.guestSnapshot.transcriptHistoryLoaded }
        XCTAssertEqual(calls, 2); XCTAssertEqual(adapter.guestSnapshot.transcript.map(\.id), ["fresh"])
        await finish(native, adapter)
    }

    func testUnrelatedPermissionEpochChangeRetriesStaleTranscript() async throws {
        let (native, adapter) = try await setup(); let gate = HistoryGate(); var calls = 0
        native.featureRequestForTesting = { kind, _, _ in
            if kind == "get-chat-messages" { return self.response(kind) }
            calls += 1
            if calls == 1 { await gate.wait(); return self.response(kind, id: "stale") }
            return self.response(kind)
        }
        try await native.processEventForTesting(joined(chat: true))
        try await spin { gate.continuation != nil }
        try await native.processEventForTesting(updated(["canViewChat": false]))
        gate.release()
        try await spin { adapter.guestSnapshot.transcriptHistoryLoaded }
        XCTAssertEqual(calls, 2); XCTAssertEqual(adapter.guestSnapshot.transcript.map(\.id), ["fresh"])
        await finish(native, adapter)
    }

    func testTerminalFailureCanBeRetriedManually() async throws {
        let (native, adapter) = try await setup(); var calls = 0; var failed = false
        adapter.onFeatureError = { _ in failed = true }
        native.featureRequestForTesting = { kind, _, _ in
            calls += 1
            if calls == 1 { throw GuestTransportError.server(code: "fixture") }
            return self.response(kind)
        }
        try await native.processEventForTesting(joined())
        try await spin { failed && adapter.transcriptHistoryIdleForTesting }
        XCTAssertEqual(calls, 1)
        adapter.retryInitialTranscriptHistory()
        try await spin { adapter.guestSnapshot.transcriptHistoryLoaded }
        XCTAssertEqual(calls, 2)
        await finish(native, adapter)
    }

    func testNetworkRestrictionMetadataDoesNotOverrideServerPermission() async throws {
        let (native, adapter) = try await setup(); var calls = 0
        native.featureRequestForTesting = { kind, _, _ in calls += 1; return self.response(kind) }
        try await native.processEventForTesting(joined(transcript: false, restricted: true))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertTrue(adapter.guestSnapshot.transcriptNetworkRestricted)
        XCTAssertFalse(adapter.guestSnapshot.permissions.canViewTranscript)
        XCTAssertEqual(calls, 0)
        try await native.processEventForTesting(joined(transcript: true, restricted: true))
        try await spin { adapter.guestSnapshot.transcriptHistoryLoaded }
        XCTAssertTrue(adapter.guestSnapshot.transcriptNetworkRestricted)
        XCTAssertTrue(adapter.guestSnapshot.permissions.canViewTranscript)
        XCTAssertEqual(calls, 1)
        await finish(native, adapter)
    }
}
