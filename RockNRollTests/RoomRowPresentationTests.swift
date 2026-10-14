import ConferenceCore
import XCTest
@testable import RockNRoll

@MainActor
final class RoomRowPresentationTests: XCTestCase {
    private func fixture() -> (RecentRoom, RoomHistoryStore, CalendarMeetingStore) {
        let room = RecentRoom(invitationURL: URL(string: "https://meeting.example.test/calls/team?psw=secret")!,
            title: "Daily", identifier: "team", isStarred: true, lastJoined: Date())
        let history = RoomHistoryStore(storage: RoomSyncCoordinatorTests.Storage())
        history.applySyncedRooms([room])
        let calendar = CalendarMeetingStore(detector: MeetingEngineDetector(serviceName: "fixture"),
                                            storage: RoomSyncCoordinatorTests.Storage())
        return (room, history, calendar)
    }
    func testRoomRowsKeepTheirHeightWhenDetailsChangeAndPreserveFullAccessibilityText() {
        let (room, history, calendar) = fixture()
        let row = FavoriteRoomControl()
        func content(_ value: RoomRowPresentation) -> FavoriteRoomRow {
            FavoriteRoomRow(room: room, presentation: value, tint: .orange, history: history, drag: FavoriteDragState(),
                onJoin: {}, onRename: {}, onStar: {}, onOriginalName: {})
        }
        let original = RoomRowPresentation(room: room, calendar: calendar)
        row.configure(content(original))
        func size() -> CGSize { row.systemLayoutSizeFitting(CGSize(width: 280, height: 0),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel) }
        let before = size()
        let enriched = RoomRowPresentation(title: String(repeating: "Long room title ", count: 10),
            timing: "Tomorrow · 10:00–11:00", location: original.location,
            details: "Full calendar description, calendar name and event title")
        row.configure(content(enriched))
        XCTAssertEqual(size(), before)
        let join = row.subviews.compactMap { $0 as? UIStackView }.first?.arrangedSubviews.first
        XCTAssertEqual(join?.accessibilityValue, enriched.details)
        XCTAssertFalse(original.details.contains("secret"))
    }
    func testTouchKeepsItsOriginalActionAcrossEnrichmentAndCancelsRetargeting() throws {
        let (room, history, calendar) = fixture()
        let row = FavoriteRoomControl(); let drag = FavoriteDragState()
        var actions: [String] = []
        func configure(_ room: RecentRoom, action: String) {
            row.configure(FavoriteRoomRow(room: room, presentation: RoomRowPresentation(room: room, calendar: calendar),
                tint: .orange, history: history, drag: drag, onJoin: { actions.append(action) },
                onRename: {}, onStar: {}, onOriginalName: {}))
        }
        configure(room, action: "pressed")
        let join = try XCTUnwrap(row.subviews.compactMap { $0 as? UIStackView }.first?.arrangedSubviews.first as? UIControl)
        join.sendActions(for: .touchDown)
        configure(room, action: "enriched")
        join.sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, ["pressed"])
        join.sendActions(for: .touchDown)
        let other = RecentRoom(invitationURL: URL(string: "https://other.example.test/other")!, title: "Other", identifier: "other", lastJoined: Date())
        configure(other, action: "other")
        join.sendActions(for: .touchUpInside)
        XCTAssertEqual(actions, ["pressed"], "Never retarget a press to a different room")
        configure(room, action: "accessible")
        join.sendActions(for: .touchDown); join.sendActions(for: .touchCancel)
        XCTAssertTrue(join.accessibilityActivate())
        XCTAssertEqual(actions, ["pressed", "accessible"], "Cancelled drag must not block VoiceOver activation")
    }
}
