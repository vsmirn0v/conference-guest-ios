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
        if let phase = ProcessInfo.processInfo.environment["ROCK_CLOUD_TEST_PHASE"] {
            try await crossDevice(phase: phase, marker: marker, url: url, transport: writer, session: session)
            return
        }
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

    private func crossDevice(phase: String, marker: String, url: URL,
                             transport: CloudRoomTransport, session: RoomCloudSession) async throws {
        let secondURL = url.appendingPathComponent("second")
        switch phase {
        case "write":
            var document = RoomSyncDocument()
            document.setName("Cross-device fixture musician")
            for (index, invitation) in [url, secondURL].enumerated() {
                var room = RecentRoom(invitationURL: invitation, title: "Cloud fixture \(index)",
                    identifier: "\(marker)-\(index)", isStarred: true, lastJoined: Date())
                room.alias = "Device fixture \(index)"
                document.upsert(room, visited: true)
            }
            document.setFavoriteOrder([secondURL.absoluteString, url.absoluteString])
            _ = try await transport.save(document.records, session: session)
        case "reorder", "verify":
            let changes = try await transport.fetch(session: session, after: nil)
            var document = RoomSyncDocument(); document.merge(changes.records)
            let original = phase == "reorder"
            XCTAssertEqual(document.visibleRooms.map(\.id), original
                ? [secondURL.absoluteString, url.absoluteString] : [url.absoluteString, secondURL.absoluteString])
            XCTAssertEqual(document.name?.value, original ? "Cross-device fixture musician" : "Updated device fixture musician")
            XCTAssertEqual(document.visibleRooms.first { $0.id == url.absoluteString }?.alias, "Device fixture 0")
            XCTAssertTrue(document.visibleRooms.allSatisfy(\.isStarred))
            if original {
                document.setFavoriteOrder([url.absoluteString, secondURL.absoluteString])
                document.setName("Updated device fixture musician")
                _ = try await transport.save(document.records, session: session)
            } else { try await transport.deleteVerificationZone() }
        default: XCTFail("Unknown cross-device test phase")
        }
        print("CROSS_DEVICE_CLOUD,phase=\(phase),marker=\(marker),passed=true")
    }
}
#endif
