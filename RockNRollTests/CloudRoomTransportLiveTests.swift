#if DEBUG
import ConferenceCore
import XCTest
@testable import RockNRoll

/// Opt-in integration check: only generated test invitations are written.
@MainActor
final class CloudRoomTransportLiveTests: XCTestCase {
    func testEncryptedCloudRoundtrip() async throws {
        guard ProcessInfo.processInfo.environment["ROCK_CLOUD_LIVE_TEST"] == "1" else {
            throw XCTSkip("Requires an explicitly selected signed device with iCloud available")
        }
        let marker = ProcessInfo.processInfo.environment["ROCK_CLOUD_TEST_MARKER"] ?? UUID().uuidString
        let url = URL(string: "https://sync-fixture.example.test/\(marker)?psw=generated-fixture")!
        let writer = CloudRoomTransport(zoneName: "SyncVerification-" + marker, notifications: false)
        let session = try await writer.connect()
        var document = RoomSyncDocument()
        document.setName("Sync fixture musician")
        var room = RecentRoom(invitationURL: url, title: "Cloud sync fixture", identifier: marker,
                              isStarred: true, lastJoined: Date())
        room.alias = "Friday sync check"
        document.upsert(room, visited: true)
        let second = RecentRoom(invitationURL: url.appendingPathComponent("second"), title: "Second favorite",
            identifier: "second", isStarred: true, lastJoined: Date())
        document.upsert(second, visited: true)
        document.setFavoriteOrder([second.id, room.id])
        _ = try await writer.save(document.records, session: session)
        let reader = CloudRoomTransport(zoneName: "SyncVerification-" + marker, notifications: false)
        let readerSession = try await reader.connect()
        XCTAssertEqual(session, readerSession)
        let fetched = try await reader.fetch(session: readerSession, after: nil)
        var restored = RoomSyncDocument(); restored.merge(fetched.records)
        XCTAssertEqual(restored.visibleRooms.map(\.id), [second.id, room.id])
        let result = try XCTUnwrap(restored.visibleRooms.first { $0.invitationURL == url })
        XCTAssertEqual(result.alias, room.alias); XCTAssertTrue(result.isStarred)
        XCTAssertEqual(result.invitationURL.absoluteString, url.absoluteString)
        XCTAssertEqual(restored.name?.value, "Sync fixture musician")
        document.setFavoriteOrder([room.id, second.id])
        _ = try await writer.save(document.records, session: session)
        let ordered = try await reader.fetch(session: readerSession, after: fetched.token)
        restored.merge(ordered.records)
        XCTAssertEqual(restored.visibleRooms.map(\.id), [room.id, second.id])
        // Remove only this fixture with the same tombstone mechanism users use.
        document.remove(url.absoluteString)
        _ = try await writer.save(document.records, session: session)
        let delta = try await reader.fetch(session: readerSession, after: ordered.token)
        restored.merge(delta.records)
        XCTAssertFalse(restored.visibleRooms.contains { $0.invitationURL == url })
        try await writer.deleteVerificationZone()
    }
}
#endif
