import XCTest
@testable import MeetingEngine
@testable import RockNativeDesktop

final class NativeSettingsSearchTests: XCTestCase {
    func testSearchRanksSettingsAndRespectsAvailablePages() {
        let all = Set(0...8)
        let results = NativeSettingsSearchCatalog.search(query: "  MICROPHONE  ", availableTabs: all)
        XCTAssertEqual(results.first?.id, "settings.microphone")
        XCTAssertTrue(results.contains { $0.id == "settings.mic-readiness" })
        XCTAssertTrue(NativeSettingsSearchCatalog.search(query: "   ", availableTabs: all).isEmpty)
        XCTAssertTrue(NativeSettingsSearchCatalog.search(query: "updates", availableTabs: [0, 1, 2, 3]).isEmpty)
    }

    func testStableIdentifiersAreUnique() {
        let ids = NativeSettingsSearchCatalog.entries.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    func testGroupedSettingsHaveIndividualSearchResults() {
        let cases = [
            ("Before start", "settings.reminder-before"),
            ("Time before start", "settings.reminder-before-time"),
            ("At start", "settings.reminder-at-start"),
            ("After start", "settings.reminder-follow-up"),
            ("Follow-up delay", "settings.reminder-follow-up-delay"),
            ("Writer API key", "settings.writer-key"),
            ("Open calendar privacy settings", "settings.calendar-privacy"),
            ("Remove GPU model", "settings.voice-gpu-remove"),
            ("Delete Saved Voice…", "settings.voice-delete"),
            ("Add memory", "settings.memory-add"),
            ("Endpoint file", "settings.mcp-endpoint"),
            ("In the background", "settings.attention-mode-background")
        ]
        for (query, id) in cases {
            XCTAssertEqual(NativeSettingsSearchCatalog.search(query: query, availableTabs: Set(0...8)).first?.id, id, query)
        }
    }

    func testAvailabilityMessageDescribesTheActualRevealTarget() {
        typealias Selection = NativeSettingScrollTarget.Selection
        let id = "settings.reminder-before-time"
        XCTAssertNil(Selection(requestID: id, anchorID: id, isEnabled: true).availabilityMessage)
        XCTAssertNotNil(Selection(requestID: id, anchorID: id, isEnabled: false).availabilityMessage)
        XCTAssertNotNil(Selection(requestID: id, anchorID: "settings.reminder-before", isEnabled: true).availabilityMessage)
        XCTAssertNil(Selection(requestID: "settings.reminder-timing", anchorID: "settings.reminder-before", isEnabled: true).availabilityMessage)
    }
}
