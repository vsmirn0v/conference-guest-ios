import XCTest

final class NativeMacRecommendationUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
    override func tearDown() { app.terminate(); super.tearDown() }
    private func launch(host: String, id: UUID, reset: Bool = true, russian: Bool = false, large: Bool = false) {
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = "home"
        app.launchEnvironment["CONFERENCE_TEST_MAC_RECOMMENDATION"] = host
        app.launchEnvironment["CONFERENCE_TEST_MAC_RECOMMENDATION_ID"] = id.uuidString
        app.launchEnvironment["CONFERENCE_TEST_MAC_RECOMMENDATION_RESET"] = reset ? "1" : "0"
        app.launchArguments = ["-AppleLanguages", russian ? "(ru)" : "(en)", "-AppleLocale", russian ? "ru_RU" : "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["join.start"].waitForExistence(timeout: 10))
    }
    private func settings() {
        app.buttons["Settings"].tap()
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.isHittable)
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testMobileHasNoMacRecommendationOrSettingsEntry() {
        launch(host: "ios", id: UUID())
        XCTAssertFalse(app.buttons["nativeMacRecommendation.dismiss"].exists)
        settings()
        XCTAssertFalse(app.buttons["settings.nativeMacApp"].exists)
        XCTAssertFalse(app.links["settings.nativeMacApp"].exists)
    }
    func testMacNoticeDismissalPersistsAndSettingsRemainsAvailable() {
        let id = UUID(); launch(host: "mac", id: id)
        let close = app.buttons["nativeMacRecommendation.dismiss"]
        reveal(close)
        XCTAssertLessThan(app.buttons["join.start"].frame.midY, close.frame.midY)
        let download = app.buttons["nativeMacRecommendation.download"]
        XCTAssertTrue(download.isHittable)
        screenshot("Mac recommendation below Join")
        close.tap(); XCTAssertFalse(close.exists)
        app.terminate(); launch(host: "mac", id: id, reset: false)
        XCTAssertFalse(close.exists)
        settings()
        let entry = app.buttons["settings.nativeMacApp"]
        reveal(entry); entry.tap()
        let permanent = app.buttons["nativeMacRecommendation.settings.download"]
        XCTAssertTrue(permanent.waitForExistence(timeout: 5)); reveal(permanent)
        XCTAssertTrue(app.staticTexts["You can keep using this app."].exists)
        screenshot("Mac app rediscovery after dismissal")
    }
    func testRussianLargeTextKeepsNoticeActionsReachable() {
        launch(host: "mac", id: UUID(), russian: true, large: true)
        let close = app.buttons["nativeMacRecommendation.dismiss"]
        reveal(close)
        XCTAssertTrue(app.buttons["nativeMacRecommendation.download"].exists)
        screenshot("Russian accessible Mac recommendation")
        close.tap()
        XCTAssertFalse(close.exists)
        XCTAssertTrue(app.buttons["join.start"].exists)
    }
}
