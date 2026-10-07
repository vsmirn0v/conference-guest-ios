import XCTest

final class CalendarUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; app.terminate(); super.tearDown() }
    private func launch(_ mode: String = "agenda", language: String = "en") {
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = mode
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        app.launch()
        if mode == "countdown" {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Joining in")).firstMatch.waitForExistence(timeout: 5))
        }
        else if mode == "engine-choice" {
            XCTAssertTrue(app.buttons["calendar.agenda"].waitForExistence(timeout: 10))
        } else { XCTAssertTrue(app.buttons["calendar.star.daily"].waitForExistence(timeout: 10)) }
    }
    func testStarSavesRoomAndAppliesToAnotherOccurrenceWithoutCreatingRecentHistory() {
        launch()
        app.buttons["calendar.star.daily"].tap()
        XCTAssertTrue(app.buttons["calendar.star.daily"].label.contains("Unstar"))
        app.buttons["calendar.agenda"].tap()
        XCTAssertTrue(app.buttons["calendar.star.planning"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar.star.planning"].label.contains("Unstar"))
        XCTAssertFalse(app.staticTexts["Recent jams"].exists)
        app.buttons["calendar.star.planning"].tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["calendar.star.daily"].label.contains("Star"))
        XCTAssertFalse(app.staticTexts["Recent jams"].exists)
    }
    func testCalendarSelectionAndLocalBinding() {
        launch()
        app.buttons["calendar.star.daily"].tap()
        app.descendants(matching: .any)["home.title.daily"].firstMatch.press(forDuration: 1.2)
        app.buttons["Choose another room"].tap()
        XCTAssertTrue(app.navigationBars["Choose room"].waitForExistence(timeout: 5))
        app.buttons["Daily rehearsal"].tap()
        XCTAssertTrue(app.buttons["calendar.star.daily"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["calendar.star.daily"].label.contains("Unstar"))
        XCTAssertFalse(app.staticTexts["Sync"].exists)
        app.buttons["Settings"].tap()
        app.buttons["calendar.settings"].tap()
        let work = app.switches["calendar.select.work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        XCTAssertEqual(work.value as? String, "1")
        XCTAssertEqual(app.switches["calendar.select.personal"].value as? String, "0")
        work.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let excluded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '0'"), object: work)
        XCTAssertEqual(XCTWaiter.wait(for: [excluded], timeout: 3), .completed)
    }
    func testRussianAgendaSurvivesRotationWithReachableActions() {
        launch(language: "ru")
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Начало через")).firstMatch.exists)
        XCTAssertEqual(app.buttons["calendar.join.daily"].label, "Войти")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            // Accessibility remains available during rotation; allow the visual transition to settle too.
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(app.buttons["calendar.star.daily"].isHittable)
            XCTAssertTrue(app.buttons["calendar.join.daily"].isHittable)
        }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Russian calendar on compact iPhone"; image.lifetime = .keepAlways; add(image)
    }
    func testAutoJoinCountdownCanBeCancelled() {
        launch("countdown")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Joining in")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Joining in")).firstMatch.exists)
        XCTAssertTrue(app.buttons["calendar.star.daily"].exists)
    }
    func testGenuineEngineConflictAllowsAnExplicitChoiceToStartJoining() {
        launch("engine-choice")
        XCTAssertFalse(app.buttons["calendar.join.daily"].exists)
        let join = app.buttons["Join jam"]
        for _ in 0..<4 where !join.isHittable { app.swipeUp() }
        XCTAssertTrue(join.isHittable); join.tap()
        let choice = app.buttons["Community jam"]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
        let failure = app.staticTexts["The jam service is temporarily unavailable. Try again shortly."]
        for _ in 0..<3 where !failure.exists { app.swipeUp() }
        XCTAssertTrue(failure.waitForExistence(timeout: 5), "The selected engine must receive the join request; the fixture returns 503.")
    }
    func testUnlinkedCalendarMeetingsAreHidden() {
        launch()
        XCTAssertFalse(app.buttons["calendar.join.sync"].exists)
        XCTAssertFalse(app.staticTexts["Sync"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        Thread.sleep(forTimeInterval: 1)
        XCTAssertFalse(app.buttons["calendar.join.sync"].exists)
        XCTAssertFalse(app.staticTexts["Sync"].exists)
    }
    func testCurrentLocationRemainsJoinableDespiteAQuotedOlderInvitation() {
        launch("forwarded")
        XCTAssertEqual(app.buttons["calendar.join.daily"].label, "Join")
        XCTAssertTrue(app.buttons["calendar.join.daily"].isEnabled)
        XCTAssertTrue(app.buttons["calendar.star.daily"].isHittable)
    }
}
