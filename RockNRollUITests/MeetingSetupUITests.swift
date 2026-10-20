import XCTest

final class MeetingSetupUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
    override func setUp() {
        super.setUp(); continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait
    }
    override func tearDown() {
        app.terminate(); XCUIDevice.shared.orientation = .portrait; super.tearDown()
    }
    private func launch(_ mode: String = "fresh", language: String = "en", large: Bool = false) {
        app.launchEnvironment["CONFERENCE_TEST_MEETING_SETUP"] = mode
        app.launchEnvironment["CONFERENCE_TEST_SETUP_ID"] = UUID().uuidString
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
    }
    private func next() {
        let next = app.buttons["setup.next"]
        XCTAssertTrue(next.waitForExistence(timeout: 5)); XCTAssertTrue(next.isHittable); next.tap()
    }
    private func toggle(_ identifier: String) {
        let element = app.switches[identifier]
        reveal(element); element.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
    }
    private func reveal(_ element: XCUIElement) {
        for _ in 0..<8 where !element.isHittable { app.swipeUp() }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); XCTAssertTrue(element.isHittable)
    }
    private func screenshot() { let item = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); item.lifetime = .keepAlways; add(item) }
    private func reopen() {
        app.buttons["Settings"].tap()
        let setup = app.buttons["settings.setup"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5)); setup.tap()
        XCTAssertTrue(app.buttons["setup.next"].waitForExistence(timeout: 5))
    }
    func testContinuePreservesAllFeaturesOffAndCompletionDoesNotRepeat() {
        launch()
        XCTAssertTrue(app.switches["setup.calendar"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["setup.calendar"].value as? String, "0")
        XCTAssertEqual(app.switches["setup.autoJoin"].value as? String, "0")
        next(); XCTAssertEqual(app.switches["setup.notifications"].value as? String, "0")
        next(); XCTAssertEqual(app.switches["setup.cloud"].value as? String, "0")
        screenshot(); next()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setup.next"].exists)
        reopen(); XCTAssertEqual(app.switches["setup.calendar"].value as? String, "0")
    }
    func testCalendarSelectionIsExplicitAndCloudFailureDoesNotBlockFinish() {
        launch(); toggle("setup.calendar")
        let choose = app.buttons["setup.calendars"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        let work = app.switches["calendar.select.work"], personal = app.switches["calendar.select.personal"]
        XCTAssertTrue(work.waitForExistence(timeout: 5))
        XCTAssertEqual(work.value as? String, "0"); XCTAssertEqual(personal.value as? String, "0")
        work.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        app.buttons["Done"].tap()
        XCTAssertEqual(app.switches["setup.autoJoin"].value as? String, "0")
        XCTAssertTrue(app.switches["setup.autoJoin"].isEnabled)
        screenshot(); next(); toggle("setup.notifications")
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: app.switches["setup.notifications"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        next(); toggle("setup.cloud")
        XCTAssertTrue(app.buttons["setup.next"].isEnabled)
        screenshot(); next()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    }
    func testFinishLaterResumesSavedStepFromSettings() {
        launch(); next(); app.buttons["setup.later"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5)); XCTAssertFalse(app.buttons["setup.next"].exists)
        reopen(); XCTAssertTrue(app.switches["setup.notifications"].exists)
    }
    func testPermissionDenialShowsRecoveryAndDoesNotBlockNavigation() {
        launch("denied"); toggle("setup.calendar")
        XCTAssertTrue(app.buttons["Open Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["setup.autoJoin"].isEnabled)
        screenshot(); next(); toggle("setup.notifications")
        XCTAssertTrue(app.staticTexts["Notifications are off in Settings"].waitForExistence(timeout: 5))
        screenshot(); next(); next()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
    }
    func testSavedCustomChoicesChangeOnlyThroughExplicitRecommendedAction() {
        launch("custom")
        XCTAssertTrue(app.switches["setup.autoJoin"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["setup.autoJoin"].value as? String, "1")
        next()
        let recommended = app.buttons["setup.recommended"]
        reveal(recommended); screenshot()
        app.buttons["setup.back"].tap()
        XCTAssertEqual(app.switches["setup.autoJoin"].value as? String, "1")
        XCTAssertTrue(app.switches["setup.autoJoin"].isEnabled)
        toggle("setup.autoJoin")
        XCTAssertEqual(app.switches["setup.autoJoin"].value as? String, "0")
        next(); reveal(recommended); recommended.tap()
        XCTAssertFalse(recommended.exists)
        XCTAssertEqual(app.switches["setup.notifications"].value as? String, "0")
    }
    func testLargeRussianPortraitAndLandscapeKeepNavigationReachable() {
        launch(language: "ru", large: true)
        for _ in 0..<3 {
            for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation.isLandscape
                var last: CGRect?
                let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                    let frame = app.frame, footer = app.buttons["setup.next"].frame
                    let correct = landscape ? frame.width > frame.height : frame.height > frame.width
                    defer { last = footer }
                    return correct && footer.maxX <= frame.maxX + 1 && footer.maxY <= frame.maxY + 1 && footer == last
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
                XCTAssertTrue(app.buttons["setup.later"].isHittable)
                XCTAssertTrue(app.buttons["setup.next"].isHittable)
                XCTAssertLessThanOrEqual(app.buttons["setup.next"].frame.height, 100)
                screenshot()
            }
            next()
        }
    }
    func testColdInvitationTakesPriorityOverAutomaticSetup() {
        launch("invitation")
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setup.next"].exists)
        reopen(); XCTAssertTrue(app.switches["setup.calendar"].exists)
    }
    func testWarmReminderWaitsForSetupDismissalAndProgressResumes() {
        launch("warm-reminder"); next(); toggle("setup.notifications")
        XCTAssertTrue(app.navigationBars["Meeting reminder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This meeting is no longer available."].exists)
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        reopen(); XCTAssertTrue(app.switches["setup.notifications"].exists)
    }
    func testWarmReminderSurvivesNestedCalendarChooserDismissal() {
        launch("warm-reminder-chooser"); toggle("setup.calendar")
        let choose = app.buttons["setup.calendars"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5)); choose.tap()
        let work = app.switches["calendar.select.work"]
        XCTAssertTrue(work.waitForExistence(timeout: 5)); work.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars["Meeting reminder"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["This meeting is no longer available."].exists)
        screenshot(); app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        reopen(); XCTAssertTrue(app.switches["setup.calendar"].exists)
    }
    func testWarmHostlessInvitationOpensItsWebsiteChooserAfterSetupDismissal() {
        launch("warm-website"); next(); toggle("setup.notifications")
        XCTAssertTrue(app.navigationBars["Meeting website"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["meeting.website-input"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        reopen(); XCTAssertTrue(app.switches["setup.notifications"].exists)
    }
    func testMeetingBeforeSetupMountsDoesNotWaitForADismissalCallback() {
        launch("same-turn-website")
        XCTAssertTrue(app.navigationBars["Meeting website"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 5))
        reopen(); XCTAssertTrue(app.switches["setup.calendar"].exists)
    }
}
