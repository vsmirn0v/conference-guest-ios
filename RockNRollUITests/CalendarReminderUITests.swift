import XCTest

final class CalendarReminderUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
    private var appWindowFrame: CGRect {
        app.windows.allElementsBoundByIndex.map(\.frame).max {
            $0.width * $0.height < $1.width * $1.height
        } ?? .zero
    }
    override func setUp() { super.setUp(); continueAfterFailure = false }
    private var resetExperimentsAfterTest = false
    private var launchLanguage = "en"
    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
        if resetExperimentsAfterTest {
            app.launchEnvironment["CONFERENCE_TEST_RESET_BACKGROUND_EXPERIMENTS"] = "1"
            app.launch()
            _ = app.buttons[launchLanguage == "ru" ? "Настройки" : "Settings"].waitForExistence(timeout: 10)
            app.terminate()
            app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_RESET_BACKGROUND_EXPERIMENTS")
        }
        super.tearDown()
    }
    private func launch(_ language: String, largeText: Bool = false) {
        launchLanguage = language
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = "agenda"
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        let banner = XCUIApplication(bundleIdentifier: "com.apple.springboard").otherElements["NotificationShortLookView"].firstMatch
        if banner.exists { banner.swipeUp() }
        // At accessibility sizes the first calendar row may be virtualized
        // below the viewport. The fixed Settings action is the launch anchor.
        XCTAssertTrue(app.buttons[language == "ru" ? "Настройки" : "Settings"].waitForExistence(timeout: 10))
        if !largeText { XCTAssertTrue(app.buttons["calendar.star.daily"].waitForExistence(timeout: 10)) }
    }
    func testSettingsDefaultOffAndCustomDurationWithoutChangingHomeLayout() {
        launch("en")
        let before = app.buttons["calendar.join.daily"].frame
        app.buttons["Settings"].tap(); app.buttons["calendar.settings"].tap()
        app.buttons["calendar.reminders"].tap()
        let enabled = app.switches["reminders.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5)); XCTAssertEqual(enabled.value as? String, "0")
        app.buttons["reminders.before"].tap(); app.buttons["reminders.custom"].tap()
        let quantity = app.textFields["reminders.quantity"]
        XCTAssertTrue(quantity.waitForExistence(timeout: 3)); quantity.tap()
        quantity.typeText(XCUIKeyboardKey.delete.rawValue + "1")
        let save = app.buttons["reminders.saveDuration"]
        if !save.isHittable { app.swipeUp() }
        save.tap()
        XCTAssertTrue(app.buttons["reminders.before"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["reminders.before"].label.contains("minute"))
        XCTAssertEqual(enabled.value as? String, "0", "Editing timing must not enable device notifications")
        app.navigationBars["Meeting reminders"].buttons.element(boundBy: 0).tap()
        app.navigationBars["Calendars"].buttons.element(boundBy: 0).tap()
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["calendar.join.daily"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["calendar.join.daily"].frame.minY, before.minY, accuracy: 2)
    }
    private func launchExperiments(_ language: String, largeText: Bool = false) {
        resetExperimentsAfterTest = true
        app.launchEnvironment["CONFERENCE_TEST_RESET_BACKGROUND_EXPERIMENTS"] = "1"
        launch(language, largeText: largeText)
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_RESET_BACKGROUND_EXPERIMENTS")
        openExperiments(language)
    }
    private func openExperiments(_ language: String) {
        app.buttons[language == "ru" ? "Настройки" : "Settings"].tap()
        let experiments = app.buttons["settings.experiments"]
        for _ in 0..<6 where !experiments.isHittable { app.swipeUp() }
        XCTAssertTrue(experiments.isHittable); experiments.tap()
        XCTAssertTrue(app.collectionViews["experiments.form"].waitForExistence(timeout: 5))
    }
    private func reveal(_ element: XCUIElement, in form: XCUIElement) {
        var unlocatedAttempts = 0
        for _ in 0..<16 where !element.isHittable {
            let viewport = form.frame.intersection(appWindowFrame)
            let target = element.exists ? element.frame : .zero
            if target.width > 1, target.height > 1, target.midY < viewport.minY {
                form.swipeDown()
            } else if target.width > 1, target.height > 1, target.midY > viewport.maxY {
                form.swipeUp()
            } else {
                // Virtualized rows may have no frame. Search below first:
                // pulling down at the top can dismiss the native Settings sheet.
                unlocatedAttempts += 1
                if unlocatedAttempts <= 8 { form.swipeUp() } else { form.swipeDown() }
            }
        }
        XCTAssertTrue(element.isHittable)
    }
    private func flip(_ element: XCUIElement, in form: XCUIElement) {
        reveal(element, in: form)
        let expected = element.value as? String == "1" ? "0" : "1"
        // SwiftUI exports an outer row and a nested physical switch on iPad.
        // Activate the actual control, whose center excludes the row label.
        let nested = element.descendants(matching: .switch).firstMatch
        let control = nested.exists ? nested : element
        let frame = control.frame
        print("EXPERIMENT_SWITCH_ACTIVATE row=\(element.frame) control=\(frame) center=(\(frame.midX),\(frame.midY)) expected=\(expected)")
        control.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: element)
        let result = XCTWaiter.wait(for: [changed], timeout: 3)
        if result != .completed {
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Experimental switch activation hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "Experimental switch activation failure"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        XCTAssertEqual(result, .completed, "Switch did not reach value \(expected) after activation")
    }
    func testReleaseExperimentalSwitchesAreAvailable() {
        app.launchEnvironment = [:]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let settings = app.buttons["Settings"], finishLater = app.buttons["setup.later"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            settings.isHittable || finishLater.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        if finishLater.isHittable { finishLater.tap() }
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        openExperiments("en")
        let form = app.collectionViews["experiments.form"]
        let audio = app.switches["reminders.backgroundAudioJoin"]
        let pip = app.switches["experiments.firstBackgroundPiP"]
        reveal(audio, in: form); XCTAssertEqual(audio.value as? String, "0")
        reveal(pip, in: form); XCTAssertEqual(pip.value as? String, "0")
        flip(audio, in: form); XCTAssertEqual(audio.value as? String, "1")
        flip(audio, in: form); XCTAssertEqual(audio.value as? String, "0")
        flip(pip, in: form); XCTAssertEqual(pip.value as? String, "1")
        flip(pip, in: form); XCTAssertEqual(pip.value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "Release experimental switches"; screenshot.lifetime = .keepAlways; add(screenshot)
    }
    func testExperimentsDefaultOffPersistIndependentlyAndDoNotEnableReminders() {
        launchExperiments("en")
        let audio = app.switches["reminders.backgroundAudioJoin"]
        let pip = app.switches["experiments.firstBackgroundPiP"]
        let form = app.collectionViews["experiments.form"]
        XCTAssertEqual(audio.value as? String, "0")
        reveal(pip, in: form); XCTAssertEqual(pip.value as? String, "0")
        reveal(audio, in: form); flip(audio, in: form)
        XCTAssertEqual(audio.value as? String, "1")
        reveal(pip, in: form); XCTAssertEqual(pip.value as? String, "0")
        XCTAssertFalse(app.alerts.firstMatch.exists, "Opting in must not request permissions")
        let configure = app.buttons["experiments.reminders"]
        reveal(configure, in: form); configure.tap()
        app.buttons["calendar.reminders"].tap()
        XCTAssertEqual(app.switches["reminders.enabled"].value as? String, "0")
        app.buttons["reminders.delivery"].tap()
        XCTAssertFalse(app.switches["reminders.backgroundAudioJoin"].exists)
        app.terminate(); launch("en"); openExperiments("en")
        XCTAssertEqual(audio.value as? String, "1")
        reveal(pip, in: form); XCTAssertEqual(pip.value as? String, "0")
        flip(pip, in: form)
        reveal(audio, in: form); flip(audio, in: form)
        XCTAssertEqual(audio.value as? String, "0")
        app.terminate(); launch("en"); openExperiments("en")
        XCTAssertEqual(audio.value as? String, "0")
        reveal(pip, in: form); XCTAssertEqual(pip.value as? String, "1")
        flip(pip, in: form)
        reveal(configure, in: form); configure.tap()
        app.buttons["calendar.reminders"].tap()
        let remindersEnabled = app.switches["reminders.enabled"]
        XCTAssertTrue(remindersEnabled.waitForExistence(timeout: 5))
        XCTAssertEqual(remindersEnabled.value as? String, "0")
    }
    func testRussianAccessibilitySizeExperimentsRemainReadableAndReachable() {
        launchExperiments("ru", largeText: true)
        let form = app.collectionViews["experiments.form"]
        let audio = app.switches["reminders.backgroundAudioJoin"]
        let pip = app.switches["experiments.firstBackgroundPiP"]
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let layout = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                let frame = appWindowFrame
                return frame.width > 1 && frame.height > 1 &&
                    (orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 5), .completed)
            reveal(audio, in: form)
            XCTAssertEqual(audio.value as? String, "0")
            let instructions = app.staticTexts["experiments.audioInstructions"]
            reveal(instructions, in: form)
            XCTAssertGreaterThan(instructions.frame.height, 40)
            XCTAssertGreaterThanOrEqual(instructions.frame.minX, form.frame.minX)
            XCTAssertLessThanOrEqual(instructions.frame.maxX, form.frame.maxX)
            reveal(pip, in: form)
            XCTAssertEqual(pip.value as? String, "0")
            XCTAssertGreaterThanOrEqual(pip.frame.minX, form.frame.minX)
            XCTAssertLessThanOrEqual(pip.frame.maxX, form.frame.maxX)
            let pipInstructions = app.staticTexts["experiments.pipInstructions"]
            reveal(pipInstructions, in: form)
            XCTAssertGreaterThan(pipInstructions.frame.height, 40)
            XCTAssertGreaterThanOrEqual(pipInstructions.frame.minX, form.frame.minX)
            XCTAssertLessThanOrEqual(pipInstructions.frame.maxX, form.frame.maxX)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.lifetime = .keepAlways; add(screenshot)
        }
    }
    func testEnableRequestsNativeNotificationPermission() {
        launch("en")
        app.buttons["Settings"].tap(); app.buttons["calendar.settings"].tap(); app.buttons["calendar.reminders"].tap()
        let enabled = app.switches["reminders.enabled"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        enabled.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let allow = springboard.buttons["Allow"]
        if allow.waitForExistence(timeout: 5) { allow.tap() }
        XCTAssertTrue(enabled.waitForExistence(timeout: 5))
        let on = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == '1'"), object: enabled)
        XCTAssertEqual(XCTWaiter.wait(for: [on], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["Notifications are off in Settings"].exists)
    }
    func testShortFollowUpChoicesAndOneSecondCustomDelay() {
        launch("en")
        app.buttons["Settings"].tap(); app.buttons["calendar.settings"].tap(); app.buttons["calendar.reminders"].tap()
        XCTAssertTrue(app.buttons["reminders.before"].label.contains("Off"))
        app.buttons["reminders.after"].tap()
        let delay = app.buttons["reminders.followUp.delay"]
        XCTAssertTrue(delay.waitForExistence(timeout: 3)); XCTAssertTrue(delay.label.contains("30 seconds"))
        delay.tap()
        XCTAssertTrue(app.buttons["reminders.duration.15"].exists)
        app.buttons["reminders.duration.10"].tap()
        XCTAssertTrue(delay.waitForExistence(timeout: 3)); XCTAssertTrue(delay.label.contains("10 seconds"))
        delay.tap(); app.buttons["reminders.custom"].tap()
        let quantity = app.textFields["reminders.quantity"]
        XCTAssertTrue(quantity.waitForExistence(timeout: 3)); quantity.tap()
        quantity.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 2) + "0")
        let save = app.buttons["reminders.saveDuration"]
        XCTAssertFalse(save.isEnabled)
        quantity.typeText(XCUIKeyboardKey.delete.rawValue + "1")
        XCTAssertTrue(save.isEnabled); save.tap()
        XCTAssertTrue(delay.waitForExistence(timeout: 3)); XCTAssertTrue(delay.label.contains("1 second"))
    }
    func testRussianOccurrenceOverridesAndRotation() {
        launch("ru")
        app.descendants(matching: .any)["home.title.daily"].firstMatch.press(forDuration: 1.2)
        app.buttons["Напоминания"].tap()
        XCTAssertTrue(app.navigationBars["Напоминания"].waitForExistence(timeout: 5))
        let custom = app.buttons["Настроить"]
        XCTAssertTrue(custom.exists); custom.tap()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let layout = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
                let frame = appWindowFrame
                return frame.width > 1 && frame.height > 1 &&
                    (orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [layout], timeout: 5), .completed)
            let done = app.buttons["Готово"]
            XCTAssertTrue(done.waitForExistence(timeout: 3)); XCTAssertTrue(done.isHittable)
            let before = app.buttons["reminders.before"]
            let form = app.collectionViews["reminders.occurrenceForm"]
            for _ in 0..<5 where !before.isHittable { form.swipeUp() }
            XCTAssertTrue(before.isHittable)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        }
        app.buttons["Готово"].tap()
        XCTAssertTrue(app.buttons["calendar.join.daily"].waitForExistence(timeout: 5))
    }
    func testAccessibilitySizeCustomEditorKeepsSaveReachable() {
        launch("en", largeText: true)
        app.buttons["Settings"].tap(); app.buttons["calendar.settings"].tap(); app.buttons["calendar.reminders"].tap()
        let before = app.buttons["reminders.before"]
        for _ in 0..<4 where !before.isHittable { app.swipeUp() }
        XCTAssertTrue(before.isHittable); before.tap()
        let custom = app.buttons["reminders.custom"]
        for _ in 0..<5 where !custom.isHittable { app.swipeUp() }
        XCTAssertTrue(custom.isHittable); custom.tap()
        let quantity = app.textFields["reminders.quantity"]
        XCTAssertTrue(quantity.isHittable); quantity.tap()
        quantity.typeText(XCUIKeyboardKey.delete.rawValue + "3")
        let save = app.buttons["reminders.saveDuration"]
        XCTAssertTrue(save.isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.lifetime = .keepAlways; add(attachment)
        save.tap()
        XCTAssertTrue(app.buttons["reminders.before"].waitForExistence(timeout: 3))
    }
    func testAgendaMenuEditsOnlyThisOccurrenceAndReturnsToAgenda() {
        launch("en")
        app.buttons["calendar.agenda"].tap()
        let more = app.buttons["calendar.more.daily"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        let reminder = app.buttons["Reminders"]
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        reminder.tap()
        XCTAssertTrue(app.navigationBars["Reminders"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["For this meeting only."].exists)
        app.buttons["Off"].tap(); app.navigationBars["Reminders"].buttons["Done"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertTrue(more.isHittable)
        more.tap()
        XCTAssertTrue(reminder.waitForExistence(timeout: 3))
        if app.buttons["Cancel"].exists {
            app.buttons["Cancel"].tap()
        } else {
            // Compact popovers omit Cancel; tapping outside dismisses them.
            app.navigationBars["Upcoming meetings"].staticTexts["Upcoming meetings"].tap()
        }
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: reminder)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 3), .completed)
        XCTAssertFalse(app.navigationBars["Reminders"].exists)
        more.tap()
        let chooseRoom = app.buttons["Choose another room"]
        XCTAssertTrue(chooseRoom.waitForExistence(timeout: 3)); chooseRoom.tap()
        XCTAssertTrue(app.navigationBars["Choose room"].waitForExistence(timeout: 5))
        app.navigationBars["Choose room"].buttons["Cancel"].tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertTrue(more.isHittable)
        XCTAssertTrue(app.buttons.matching(identifier: "calendar.join.daily").allElementsBoundByIndex.contains { $0.isEnabled })
    }
    func testGlobalFollowUpModesAndRememberedDelay() {
        launch("en")
        app.buttons["Settings"].tap(); app.buttons["calendar.settings"].tap(); app.buttons["calendar.reminders"].tap()
        app.buttons["reminders.after"].tap()
        XCTAssertTrue(app.buttons["reminders.followUp.anotherMeeting"].waitForExistence(timeout: 3))
        app.buttons["reminders.followUp.always"].tap()
        app.buttons["reminders.followUp.delay"].tap(); app.buttons["reminders.custom"].tap()
        let quantity = app.textFields["reminders.quantity"]; quantity.tap()
        quantity.typeText(XCUIKeyboardKey.delete.rawValue + "3"); app.buttons["reminders.saveDuration"].tap()
        app.buttons["reminders.followUp.off"].tap()
        XCTAssertFalse(app.buttons["reminders.followUp.delay"].exists)
        app.buttons["reminders.followUp.anotherMeeting"].tap()
        XCTAssertTrue(app.buttons["reminders.followUp.delay"].label.contains("3 minutes"))
    }
    func testNativeFollowUpCardActionsAndBackgroundRestore() { exerciseCallReminder(guest: false) }
    func testGuestFollowUpCardActionsAndBackgroundRestore() { exerciseCallReminder(guest: true) }

    func testDueGuestReminderWaitsForParticipantsAndResumesAfterDismissal() {
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "reminder-call"
        app.launchEnvironment["CONFERENCE_TEST_REMINDER_HOST"] = "guest"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "participants"
        app.launchEnvironment["CONFERENCE_TEST_REMINDER_DELAY"] = "1"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let participants = app.buttons["Musicians"].firstMatch
        XCTAssertTrue(participants.waitForExistence(timeout: 10)); participants.tap()
        XCTAssertTrue(app.navigationBars["Musicians"].waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 6)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["reminders.collapse"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reminders.collapse"].isHittable)
    }
    func testLargeRussianLandscapeUsesCompactFallbackAndKeepsMoreReachable() {
        XCUIDevice.shared.orientation = .landscapeLeft
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "reminder-call"
        app.launchEnvironment["CONFERENCE_TEST_REMINDER_HOST"] = "guest"
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let more = app.buttons["call.more"]
        XCTAssertTrue(more.waitForExistence(timeout: 10)); XCTAssertTrue(more.isHittable)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        more.tap()
        XCTAssertTrue(app.buttons["Посмотреть встречи"].waitForExistence(timeout: 5))
    }
    private func exerciseCallReminder(guest: Bool) {
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "reminder-call"
        app.launchEnvironment["CONFERENCE_TEST_REMINDER_HOST"] = guest ? "guest" : "native"
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let collapse = app.buttons["reminders.collapse"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 10)); XCTAssertTrue(collapse.isHittable)
        let more = app.buttons["call.more"], view = app.buttons["call.view"]
        let anchors = [more.frame, view.frame]
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.lifetime = .keepAlways; add(screenshot)
        collapse.tap()
        XCTAssertEqual([more.frame, view.frame], anchors)
        XCTAssertTrue(more.isHittable); more.tap()
        let meetings = app.buttons["View meetings"]
        XCTAssertTrue(meetings.waitForExistence(timeout: 5)); meetings.tap()
        let choice = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Design review' ")).firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        XCTAssertTrue(app.buttons["reminders.join"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["reminders.join"].label.contains("Leave and join"))
        app.buttons["Close"].tap()
        XCUIDevice.shared.press(.home); app.activate()
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertFalse(collapse.isHittable)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(more.waitForExistence(timeout: 5)); XCTAssertTrue(more.isHittable)
    }

}
