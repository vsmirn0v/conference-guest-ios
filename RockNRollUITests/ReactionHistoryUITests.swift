import XCTest

final class ReactionHistoryUITests: XCTestCase {
    func testEnglishHistoryFiltersDetailsAndRotation() { checkHistory(language: "en") }
    func testRussianHistoryFiltersDetailsAndRotation() { checkHistory(language: "ru") }
    func testHistoryWithUnavailableTextChat() {
        let app = launch(language: "en", fixture: "reactions-unavailable")
        defer { app.terminate() }
        let filter = app.buttons["chat.activity-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Chat isn't available right now."].exists)
        filter.tap(); app.buttons["Reactions"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["reaction.history-scope"].exists)
        XCTAssertTrue(app.segmentedControls["Conversation mode"].buttons["Chat"].isSelected)
    }
    func testPaletteShortcutOpensHistoryAndReactionOnlyBadgeIsQuiet() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "reactions"
        app.launch(); defer { app.terminate() }
        let chat = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Chat, New reactions")).firstMatch
        XCTAssertTrue(chat.waitForExistence(timeout: 8))
        XCTAssertFalse(chat.label.contains("unread"))
        app.buttons["call.more"].tap()
        app.buttons["reactions.send.like"].tap()
        let shortcut = app.buttons["reactions.history"]
        for _ in 0..<3 where !shortcut.isHittable { app.swipeUp() }
        XCTAssertTrue(shortcut.isHittable); shortcut.tap()
        XCTAssertTrue(app.buttons["chat.activity-filter"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["chat.activity-filter"].label, "Reactions")
        XCTAssertTrue(app.staticTexts["reaction.history-scope"].exists)
        app.buttons["Close conversation"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label == %@", "Chat")).firstMatch.waitForExistence(timeout: 5))
    }
    private func launch(language: String, fixture: String = "reactions") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = fixture
        XCUIDevice.shared.orientation = .portrait
        app.launch(); return app
    }
    private func checkHistory(language: String) {
        let app = launch(language: language)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        let filter = app.buttons["chat.activity-filter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 8)); filter.tap()
        app.buttons[language == "ru" ? "Реакции" : "Reactions"].firstMatch.tap()
        let history = app.scrollViews[language == "ru" ? "Сообщения чата джема" : "Jam chat messages"]
        // Keep reading earlier content when a delayed reaction arrives.
        history.swipeDown(); history.swipeDown()
        filter.tap(); app.buttons["Receive test reaction"].tap()
        XCTAssertTrue(app.buttons[language == "ru" ? "Новая активность ↓" : "New activity ↓"].waitForExistence(timeout: 8))
        app.buttons[language == "ru" ? "Новая активность ↓" : "New activity ↓"].tap()
        let details = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "reaction.details.")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 5)); XCTAssertTrue(details.isHittable)
        details.tap()
        XCTAssertEqual(details.label, language == "ru" ? "Скрыть подробности" : "Hide reaction details")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(filter.waitForExistence(timeout: 5)); XCTAssertTrue(filter.isHittable)
        filter.tap(); app.buttons[language == "ru" ? "Сообщения" : "Messages"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts["reaction.history-scope"].exists)
        XCUIDevice.shared.orientation = .portrait
        filter.tap(); app.buttons[language == "ru" ? "Вся активность" : "All activity"].firstMatch.tap()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Reaction history \(language)"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.staticTexts["reaction.history-scope"].exists)
    }
}
