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
        store.finishMeeting()
    }

    func testLeavingRemovesQueuedLocalHistory() {
        let store = CatchUpStore()
        store.enter(roomKey: "test-room-\(UUID().uuidString)")
        store.finishMeeting()

        let url = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("catch-up.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
