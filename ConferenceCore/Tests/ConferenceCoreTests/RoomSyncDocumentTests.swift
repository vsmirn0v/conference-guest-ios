import XCTest
@testable import ConferenceCore

final class RoomSyncDocumentTests: XCTestCase {
    func testLegacyCloudFavoritesKeepTheirOrderAfterVisitsAndRepeatedMigrations() {
        var document = RoomSyncDocument(device: "new")
        let items = [room("one", starred: true, day: 1), room("two", starred: true, day: 2)]
        items.forEach { document.upsert($0, visited: true) }
        document.migrateFavoriteOrderIfNeeded()
        document.upsert(room("one", starred: true, day: 3), visited: true)
        XCTAssertEqual(document.visibleRooms.map(\.id), [items[1].id, items[0].id])
        let before = document
        document.migrateFavoriteOrderIfNeeded()
        XCTAssertEqual(document, before)
    }

    func testConcurrentFavoriteOrdersConvergeAndDoNotOverwriteAliasOrDeletion() throws {
        var seed = RoomSyncDocument(device: "seed")
        let items = [room("one", starred: true), room("two", starred: true), room("three", starred: true)]
        items.forEach { seed.upsert($0, visited: true) }
        seed.setFavoriteOrder(items.map(\.id))
        var phone = RoomSyncDocument(device: "phone"), mac = RoomSyncDocument(device: "mac")
        phone.merge(seed.records); mac.merge(seed.records)
        phone.setFavoriteOrder([items[2].id, items[0].id, items[1].id])
        mac.setFavoriteOrder([items[1].id, items[2].id, items[0].id])
        var renamed = items[0]; renamed.alias = "Friday band"
        mac.upsert(renamed); mac.remove(items[1].id)
        let phoneChanges = phone.records, macChanges = mac.records
        phone.merge(macChanges); mac.merge(phoneChanges)
        XCTAssertEqual(phone.visibleRooms, mac.visibleRooms)
        XCTAssertEqual(phone.visibleRooms.map(\.id), [items[2].id, items[0].id])
        XCTAssertEqual(phone.visibleRooms.first { $0.id == items[0].id }?.alias, "Friday band")
        let before = phone.records; phone.merge(mac.records)
        XCTAssertEqual(Set(before.map(\.id)), Set(phone.records.map(\.id)))
        let restored = try JSONDecoder().decode(RoomSyncDocument.self, from: JSONEncoder().encode(phone))
        XCTAssertEqual(restored.visibleRooms, phone.visibleRooms)
    }

    func testOlderRecordsWithoutOrderDoNotEraseSyncedOrder() throws {
        var document = RoomSyncDocument(device: "new")
        let items = [room("one", starred: true), room("two", starred: true)]
        items.forEach { document.upsert($0, visited: true) }
        document.setFavoriteOrder([items[1].id, items[0].id])
        var legacy = RoomSyncDocument(device: "old")
        items.forEach { legacy.upsert($0, visited: true) }
        var renamed = items[0]; renamed.alias = "Legacy rename"
        for _ in 0..<10 { legacy.upsert(renamed) }
        document.merge(legacy.records)
        XCTAssertEqual(document.visibleRooms.map(\.id), [items[1].id, items[0].id])
        XCTAssertEqual(document.visibleRooms.last?.alias, "Legacy rename")
    }
    private func room(_ id: String, starred: Bool = false, day: Double = 1) -> RecentRoom {
        RecentRoom(invitationURL: URL(string: "https://\(id).example.test/calls/one?psw=secret")!,
                   title: id, identifier: "one", isStarred: starred, lastJoined: Date(timeIntervalSince1970: day))
    }

    func testIndependentStarAndRenameSurviveConcurrentOfflineEdits() {
        let item = room("one")
        var seed = RoomSyncDocument(device: "seed"); seed.upsert(item, visited: true)
        var phone = RoomSyncDocument(device: "phone"); phone.merge(seed.records)
        var mac = RoomSyncDocument(device: "mac"); mac.merge(seed.records)
        var starred = item; starred.isStarred = true; phone.upsert(starred)
        var renamed = item; renamed.alias = "Friday quartet"; mac.upsert(renamed)
        let phoneChanges = phone.records, macChanges = mac.records
        phone.merge(macChanges); mac.merge(phoneChanges)
        XCTAssertEqual(phone.visibleRooms, mac.visibleRooms)
        XCTAssertTrue(phone.visibleRooms[0].isStarred)
        XCTAssertEqual(phone.visibleRooms[0].alias, "Friday quartet")
        XCTAssertEqual(phone.visibleRooms[0].invitationURL, item.invitationURL)
    }

    func testDeletionWinsOverStaleEditButExplicitRejoinRestores() {
        let item = room("one")
        var phone = RoomSyncDocument(device: "phone"); phone.upsert(item, visited: true)
        var mac = RoomSyncDocument(device: "mac"); mac.merge(phone.records)
        phone.remove(item.id)
        var renamed = item; renamed.alias = "Offline edit"; mac.upsert(renamed)
        mac.merge(phone.records); phone.merge(mac.records)
        XCTAssertTrue(mac.visibleRooms.isEmpty); XCTAssertTrue(phone.visibleRooms.isEmpty)
        mac.upsert(room("one", day: 2), visited: true)
        phone.merge(mac.records)
        XCTAssertEqual(phone.visibleRooms.count, 1)
        XCTAssertEqual(phone.visibleRooms[0].lastJoined, Date(timeIntervalSince1970: 2))
    }

    func testLatestTenAcrossReplicasExcludeAllFavoritesAndRetainRemovalMarkers() {
        var first = RoomSyncDocument(device: "first"), second = RoomSyncDocument(device: "second")
        for number in 1...12 { first.upsert(room("room\(number)", day: Double(number)), visited: true) }
        for number in 13...16 { second.upsert(room("room\(number)", starred: true, day: Double(number)), visited: true) }
        first.merge(second.records); first.trimHistory()
        XCTAssertEqual(first.visibleRooms.count, 14)
        XCTAssertEqual(first.visibleRooms.filter { !$0.isStarred }.count, 10)
        XCTAssertFalse(first.rooms[room("room1").id]!.exists.value)
        first.remove(room("room12").id)
        XCTAssertFalse(first.visibleRooms.contains { $0.id == room("room1").id })
        let restored = try! JSONDecoder().decode(RoomSyncDocument.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(first, restored)
    }

    func testDifferentSitesRemainDistinctEvenWhenRoomCodesMatch() {
        var document = RoomSyncDocument()
        document.upsert(room("first"), visited: true); document.upsert(room("second"), visited: true)
        XCTAssertEqual(document.visibleRooms.count, 2)
        XCTAssertEqual(Set(document.visibleRooms.compactMap { $0.invitationURL.host }), ["first.example.test", "second.example.test"])
    }

    func testMergesAreCommutativeAssociativeAndIdempotentForConflictingNames() {
        var a = RoomSyncDocument(device: "a"), b = RoomSyncDocument(device: "b"), c = RoomSyncDocument(device: "c")
        a.setName("Ani"); b.setName("Aram"); c.setName("Lilit")
        var left = RoomSyncDocument(device: "left"); left.merge(a.records); left.merge(b.records); left.merge(c.records)
        var right = RoomSyncDocument(device: "right"); right.merge(c.records); right.merge(a.records); right.merge(b.records)
        XCTAssertEqual(left.name, right.name)
        let before = left.records; left.merge(left.records); XCTAssertEqual(before, left.records)
        left.setName("Chosen after merge"); right.merge(left.records)
        XCTAssertEqual(right.name?.value, "Chosen after merge")
    }

    func testLatestVisitDoesNotDependOnRenameClock() {
        var old = RoomSyncDocument(device: "old"), fresh = RoomSyncDocument(device: "fresh")
        old.upsert(room("one", day: 10), visited: true)
        fresh.merge(old.records); fresh.upsert(room("one", day: 20), visited: true)
        for number in 0..<20 { var item = room("one", day: 10); item.alias = "Name \(number)"; old.upsert(item) }
        old.merge(fresh.records); fresh.merge(old.records)
        XCTAssertEqual(old.visibleRooms[0].lastJoined, Date(timeIntervalSince1970: 20))
        XCTAssertEqual(old.visibleRooms, fresh.visibleRooms)
    }
}
