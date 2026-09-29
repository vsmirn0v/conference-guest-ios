import Foundation
import XCTest
@testable import RockNRoll

final class CatchUpStoreTests: XCTestCase {
    func testQueuedHistoryRestoresAfterRestart() async {
        let store = CatchUpStore()
        let key = "test-room-\(UUID().uuidString)"
        store.enter(roomKey: key)
        store.begin(.anotherCall)
        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("catch-up.json")
        var savedKey: String?
        for _ in 0..<100 {
            if let data = try? Data(contentsOf: url),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                savedKey = object["roomKey"] as? String
                if savedKey == key { break }
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(savedKey, key)
        XCTAssertEqual(CatchUpStore().timeline.unreadCount, 1)
        await store.finishMeeting().value
    }

    func testLeavingRemovesQueuedLocalHistory() async {
        let store = CatchUpStore()
        store.enter(roomKey: "test-room-\(UUID().uuidString)")
        await store.finishMeeting().value

        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("catch-up.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
    func testBlockedWriterDoesNotBlockLeaveAndTombstonePreventsRestore() async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        let queue = DispatchQueue(label: "test-blocked-writer")
        let gate = DispatchSemaphore(value: 0)
        queue.async { gate.wait() }
        let store = CatchUpStore(storageURL: url, writer: queue)
        store.enter(roomKey: "old")
        store.begin(.anotherCall)
        let start = Date()
        let leave = store.finishMeeting()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1)
        XCTAssertEqual(CatchUpStore(storageURL: url).timeline.unreadCount, 0)
        store.enter(roomKey: "new")
        store.begin(.connection)
        gate.signal()
        await leave.value
        // Delete is enqueued before the new room write, even with an immediate rejoin.
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
        XCTAssertEqual(CatchUpStore(storageURL: url).timeline.unreadCount, 1)
        await store.finishMeeting().value
    }
}
