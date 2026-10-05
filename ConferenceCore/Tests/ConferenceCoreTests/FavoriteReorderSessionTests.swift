import XCTest
@testable import ConferenceCore

final class FavoriteReorderSessionTests: XCTestCase {
    func testDraftOnlyCommitsChangedValidDropAndKeepsNewFavorites() throws {
        var drag = try XCTUnwrap(FavoriteReorderSession(ids: ["a", "b", "c"], sourceID: "c"))
        XCTAssertNil(drag.orderForDrop(currentIDs: ["a", "b", "c"]))
        XCTAssertTrue(drag.move(relativeTo: "a", before: true))
        XCTAssertEqual(drag.originalIDs, ["a", "b", "c"])
        XCTAssertEqual(drag.orderedIDs, ["c", "a", "b"])
        XCTAssertFalse(drag.move(relativeTo: "a", before: true))
        XCTAssertEqual(drag.orderForDrop(currentIDs: ["new", "a", "c"]), ["c", "a", "new"])
        XCTAssertNil(drag.orderForDrop(currentIDs: ["a", "b"]))
    }
    func testInvalidTargetsAndMovingBackProduceNoCommit() throws {
        XCTAssertNil(FavoriteReorderSession(ids: ["a"], sourceID: "a"))
        XCTAssertNil(FavoriteReorderSession(ids: ["a", "a"], sourceID: "a"))
        XCTAssertNil(FavoriteReorderSession(ids: ["a", "b"], sourceID: "missing"))
        var drag = try XCTUnwrap(FavoriteReorderSession(ids: ["a", "b", "c"], sourceID: "b"))
        XCTAssertFalse(drag.move(relativeTo: "missing", before: true))
        XCTAssertFalse(drag.move(relativeTo: "b", before: true))
        XCTAssertTrue(drag.move(relativeTo: "c", before: false))
        XCTAssertTrue(drag.move(relativeTo: "a", before: false))
        XCTAssertNil(drag.orderForDrop(currentIDs: drag.originalIDs))
    }
}
