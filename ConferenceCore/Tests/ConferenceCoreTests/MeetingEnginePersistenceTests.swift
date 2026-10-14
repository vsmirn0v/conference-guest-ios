import XCTest
@testable import ConferenceCore

final class MeetingEnginePersistenceTests: XCTestCase {
    private enum LegacyEngine: String, Codable, Equatable, Sendable { case guest, community }
    private struct LegacyRoom: Decodable { let invitationURL: URL; let engine: LegacyEngine? }
    private struct LegacySyncedRoom: Decodable { let invitationURL: URL; let engine: SyncValue<LegacyEngine>? }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let targets: [(MeetingEngineKind, String)] = [
        (.trueconf, "https://custom.example.test/c/one"),
        (.telemost, "https://telemost.yandex.ru/j/12345678901234"),
        (.community, "https://custom.example.test/jams/one"),
        (.guest, "https://custom.example.test/calls/one")
    ]

    func testResolvedEnginesSurviveHistoryAndCloudWithoutBreakingOlderDecoders() throws {
        for (engine, text) in targets {
            let url = URL(string: text)!
            var history = RecentRooms()
            history.saveFavorite(url: url, title: "Room", identifier: "one", engine: engine, at: now)
            history.setAlias("My room", for: url)
            let room = try XCTUnwrap(history.items.first)
            let encoded = try JSONEncoder().encode(room)
            XCTAssertEqual(try JSONDecoder().decode(RecentRoom.self, from: encoded), room)
            let legacy = try JSONDecoder().decode(LegacyRoom.self, from: encoded)
            XCTAssertEqual(legacy.engine?.rawValue, engine.persistenceHint?.rawValue)
            XCTAssertEqual(legacy.invitationURL, url)
            var phone = RoomSyncDocument(device: "phone")
            phone.upsert(room, saved: true)
            let record = try XCTUnwrap(phone.rooms[room.id])
            let cloudData = try JSONEncoder().encode(record)
            let oldCloud = try JSONDecoder().decode(LegacySyncedRoom.self, from: cloudData)
            XCTAssertEqual(oldCloud.engine?.value.rawValue, engine.persistenceHint?.rawValue)
            var mac = RoomSyncDocument(device: "mac")
            mac.merge([.room(try JSONDecoder().decode(SyncedRoom.self, from: cloudData))])
            XCTAssertEqual(mac.visibleRooms.first?.engine, engine)
            XCTAssertEqual(mac.visibleRooms.first?.alias, "My room")
            XCTAssertNil(mac.visibleRooms.first?.lastVisit)
            XCTAssertEqual(MeetingRoomIdentity(url, engine: mac.visibleRooms.first?.engine)?.engine, engine)
        }
    }

    func testOldDocumentsAndUnknownRawIdentifiersRemainReadable() throws {
        var room = RecentRoom(invitationURL: URL(string: "https://example.test/c/one")!, title: "One", identifier: "one", lastJoined: now)
        room.engine = .guest
        var payload = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(room)) as? [String: Any])
        payload.removeValue(forKey: "engineIdentifier")
        let legacy = try JSONSerialization.data(withJSONObject: payload)
        XCTAssertEqual(try JSONDecoder().decode(RecentRoom.self, from: legacy).engine, .guest)
        payload["engineIdentifier"] = "future-engine"
        XCTAssertEqual(try JSONDecoder().decode(RecentRoom.self, from: JSONSerialization.data(withJSONObject: payload)).engine, .guest)
        payload.removeValue(forKey: "engine")
        XCTAssertNil(try JSONDecoder().decode(RecentRoom.self, from: JSONSerialization.data(withJSONObject: payload)).engine)
        var record = SyncedRoom(room, version: .init(counter: 1, device: "old"))
        record.engineIdentifier = .init("future-engine", version: .init(counter: 9, device: "future"))
        XCTAssertEqual(try JSONDecoder().decode(SyncedRoom.self, from: JSONEncoder().encode(record)).room.engine, .guest)
    }

    func testVerifiedEngineEnrichesLegacyRoomAcrossRotatedInvitations() throws {
        let original = URL(string: "https://example.test/c/one?psw=old")!
        let latest = URL(string: "https://example.test/c/one?psw=new")!
        var history = RecentRooms()
        history.saveFavorite(url: original, title: "My room", identifier: "one", at: now)
        history.record(url: latest, title: "Provider title", identifier: "one", at: now, engine: .trueconf)
        XCTAssertEqual(history.items.count, 1)
        XCTAssertEqual(history.items.first?.id, original.absoluteString)
        XCTAssertEqual(history.items.first?.engine, .trueconf)
        XCTAssertEqual(history.items.first?.joinURL, latest)
        XCTAssertEqual(history.items.first?.displayTitle, "My room")
        let next = URL(string: "https://example.test/c/one?psw=next")!
        XCTAssertEqual(history.matching(next)?.id, original.absoluteString)
        XCTAssertEqual(history.matching(next)?.engine, .trueconf)
        var saved = RecentRooms()
        saved.saveFavorite(url: original, title: "Legacy", identifier: "one", at: now)
        saved.saveFavorite(url: original, title: "Calendar", identifier: "one", engine: .trueconf, at: now)
        XCTAssertEqual(saved.items.first?.engine, .trueconf)
        XCTAssertEqual(saved.items.first?.displayTitle, "Legacy")
    }

    func testVersionedEngineChangesConvergeAcrossOldAndNewWriters() throws {
        var room = RecentRoom(invitationURL: URL(string: "https://example.test/c/one")!, title: "One", identifier: "one", lastJoined: now)
        var phone = RoomSyncDocument(device: "phone"), mac = RoomSyncDocument(device: "mac")
        phone.upsert(room, visited: true)
        room.engine = .trueconf; phone.upsert(room, visited: true)
        mac.merge(phone.records)
        XCTAssertEqual(mac.visibleRooms.first?.engine, .trueconf)
        var oldEdit = try XCTUnwrap(mac.rooms[room.id])
        oldEdit.engineIdentifier = nil
        oldEdit.alias = .init("Old reader rename", version: .init(counter: 5, device: "old"))
        phone.merge([.room(oldEdit)])
        XCTAssertEqual(phone.visibleRooms.first?.engine, .trueconf)
        oldEdit.engine = .init(.community, version: .init(counter: 6, device: "old"))
        phone.merge([.room(oldEdit)])
        XCTAssertEqual(phone.visibleRooms.first?.engine, .community)
        room.engine = .telemost; phone.upsert(room, visited: true)
        mac.merge(phone.records); phone.merge(mac.records)
        XCTAssertEqual(mac.visibleRooms.first?.engine, .telemost)
        XCTAssertEqual(mac.visibleRooms, phone.visibleRooms)
    }

    func testVerifiedHandoffAndCalendarUseTheSameRoomIdentityAfterPersistence() throws {
        for (engine, text) in targets {
            let url = URL(string: text)!
            var meeting = CalendarMeeting(id: "event", seriesID: "series", calendarID: "work", calendarTitle: "Work",
                title: "Planning", start: now, end: now.addingTimeInterval(3600))
            meeting.invitation = url; meeting.engine = engine
            let active = ActiveJam(deviceID: "mac", invitation: url, title: "Room", name: "Guest", deviceLabel: "Mac", updatedAt: now, engine: engine)
            let restored = try JSONDecoder().decode(ActiveJam.self, from: JSONEncoder().encode(active))
            let items = HomeMeetingPolicy.candidates(meetings: [meeting], handoffs: [restored], at: now)
            XCTAssertEqual(items.count, 1)
            XCTAssertEqual(items.first?.calendar?.id, meeting.id)
            XCTAssertEqual(items.first?.id.engine, engine)
            XCTAssertEqual(items.first?.currentHandoff(in: [restored], at: now)?.sessionID, active.sessionID)
        }
    }

    func testPresenceWithoutEngineAndWithUnknownEngineStillDecodes() throws {
        var jam = ActiveJam(deviceID: "old", invitation: URL(string: "https://example.test/c/one")!, title: "One", name: "Guest", deviceLabel: "Mac")
        XCTAssertNil(try JSONDecoder().decode(ActiveJam.self, from: JSONEncoder().encode(jam)).engine)
        jam.engineIdentifier = "future-engine"
        XCTAssertNil(try JSONDecoder().decode(ActiveJam.self, from: JSONEncoder().encode(jam)).engine)
    }
}
