import XCTest

final class HomeLayoutUITests: XCTestCase {
    private let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
    override func tearDown() { XCUIDevice.shared.orientation = .portrait; app.terminate(); super.tearDown() }
    private func launch(_ mode: String = "home", language: String = "en", large: Bool = false, handoff: Bool = false) {
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = mode
        if handoff { app.launchEnvironment["CONFERENCE_TEST_HANDOFF_FIXTURE"] = "ready" }
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        if large { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launch()
        XCTAssertTrue(app.buttons["join.start"].waitForExistence(timeout: 10))
        if mode != "home-later" { XCTAssertTrue(app.buttons["calendar.star.daily"].waitForExistence(timeout: 10)) }
    }
    private var favorites: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorite.order."))
    }
    private func reveal(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<7 where !element.isHittable { if down { app.swipeDown() } else { app.swipeUp() } }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); XCTAssertTrue(element.isHittable)
    }
    private func attach(_ title: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = title; capture.lifetime = .keepAlways; add(capture)
    }
    func testCompactHomeShowsJoinAndTwoFavoritesBeforeScrolling() {
        launch()
        XCTAssertTrue(app.textFields["invitation.input"].isHittable)
        XCTAssertTrue(app.textFields["name.input"].isHittable)
        XCTAssertTrue(app.buttons["studio.prejoin"].isHittable)
        XCTAssertLessThan(app.buttons["studio.prejoin"].frame.height, 70, "Media setup must not stretch the Join panel")
        XCTAssertTrue(favorites.element(boundBy: 0).isHittable)
        XCTAssertTrue(favorites.element(boundBy: 1).isHittable)
        XCTAssertFalse(app.buttons["calendar.star.community"].exists, "Tomorrow's meeting belongs in the full agenda.")
        attach("Compact home · Join and favorites")
    }
    func testFavoriteExpansionAndPrivateMediaCheckStayAccessible() {
        launch()
        XCTAssertEqual(favorites.count, 3)
        app.buttons["favorites.expand"].tap()
        reveal(app.buttons["favorite.order.https://meeting.example.test/favorite5"])
        reveal(app.buttons["favorites.expand"], down: true)
        app.buttons["favorites.expand"].tap()
        reveal(app.buttons["studio.prejoin"], down: true)
        app.buttons["studio.prejoin"].tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["studio.preview-status"].firstMatch.label.contains("Only you"))
    }
    func testFavoritesKeepCalendarAndRoomDetailsInBothLanguages() {
        for language in ["en", "ru"] {
            launch("home-details", language: language)
            let calendarRoom = favorites.element(boundBy: 0)
            let savedRoom = favorites.element(boundBy: 1)
            let calendarDetail = calendarRoom.value as? String ?? ""
            let savedDetail = savedRoom.value as? String ?? ""
            XCTAssertTrue(calendarDetail.contains("Daily rehearsal"), "Calendar title must remain visible in favorites")
            XCTAssertTrue(calendarDetail.contains(String(Calendar.current.component(.year, from: Date()))),
                          "Calendar date must remain visible in favorites")
            XCTAssertTrue(savedDetail.contains("favorite1 · meeting.example.test"))
            XCTAssertTrue(savedDetail.contains(language == "en" ? "Saved" : "Сохранено"))
            XCTAssertTrue(calendarRoom.isHittable); XCTAssertTrue(savedRoom.isHittable)
            attach("Favorites with details · " + language)
            app.terminate()
        }
    }
    func testExpandedMeetingPreviewKeepsEventTimeCalendarAndFavoriteAlias() {
        for language in ["en", "ru"] {
            for mode in ["home-preview", "home-preview-current"] {
                launch(mode, language: language)
                let title = app.descendants(matching: .any)["home.title.daily"].firstMatch
                XCTAssertTrue(title.label.contains("Rehearsal and arrangements for the upcoming community concert"))
                let schedule = app.staticTexts["home.schedule.daily"]
                XCTAssertTrue(schedule.isHittable)
                XCTAssertTrue(schedule.label.contains(" – "), "Both start and end times must be visible")
                XCTAssertTrue(app.staticTexts["home.calendar.daily"].label.contains("Work"))
                XCTAssertTrue(app.staticTexts["home.calendar.daily"].label.contains("Our rehearsal room"))
                XCTAssertTrue(title.label.contains("meeting.example.test"))
                XCTAssertFalse(title.label.contains("psw="))
                if mode == "home-preview-current" {
                    XCTAssertTrue(title.label.contains(language == "en" ? "Scheduled now" : "По расписанию сейчас"))
                }
                attach("Expanded meeting preview · " + language + " · " + mode)
                let favorite = favorites.element(boundBy: 0)
                reveal(favorite)
                XCTAssertTrue((favorite.value as? String ?? "").contains("community concert"))
                XCTAssertTrue((favorite.value as? String ?? "").contains(" – "))
                attach("Favorite event preview · " + language + " · " + mode)
                app.terminate()
            }
        }
    }
    func testLaterMeetingDoesNotTakeTopSlotAndTomorrowIsInAgenda() {
        launch("home-later")
        XCTAssertFalse(app.descendants(matching: .any)["home.title.daily"].exists)
        XCTAssertTrue(app.textFields["invitation.input"].isHittable)
        XCTAssertTrue(favorites.element(boundBy: 1).isHittable)
        reveal(app.buttons["calendar.agenda"]); app.buttons["calendar.agenda"].tap()
        XCTAssertTrue(app.buttons["calendar.star.community"].waitForExistence(timeout: 5))
        attach("Full agenda · future meetings")
    }
    func testRussianHomeSurvivesRotationAndReturnsToReachableFavorites() {
        launch(language: "ru")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            Thread.sleep(forTimeInterval: 1)
            XCTAssertTrue(app.textFields["invitation.input"].isHittable)
            XCTAssertTrue(app.buttons["calendar.star.daily"].isHittable)
        }
        XCTAssertTrue(favorites.element(boundBy: 1).isHittable)
        attach("Russian compact home after rotation")
    }
    func testLargeTextKeepsNameJoinAndFavoritesUsable() {
        launch(language: "ru", large: true)
        reveal(app.textFields["name.input"])
        reveal(favorites.element(boundBy: 0))
        attach("Home at accessibility text size")
    }
    func testHandoffMergesWithCalendarAndDoesNotDuplicateTopAction() {
        launch("home-handoff", handoff: true)
        let move = app.buttons["Continue on this device"]
        XCTAssertTrue(move.waitForExistence(timeout: 10))
        let room = app.descendants(matching: .any)["home.title.daily"].firstMatch
        XCTAssertTrue(room.exists)
        XCTAssertTrue(room.label.contains("meeting.example.test"))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "label == %@", "Continue on this device")).count, 1)
        XCTAssertTrue(app.buttons["calendar.star.daily"].isHittable)
        XCTAssertTrue(favorites.element(boundBy: 1).isHittable)
        attach("Merged calendar and handoff")
    }
    func testWideLayoutKeepsLibraryAndJoinVisibleTogether() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad)
        launch(language: "ru")
        XCUIDevice.shared.orientation = .landscapeLeft
        let library = app.descendants(matching: .any)["home.library"].firstMatch
        XCTAssertTrue(library.waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["invitation.input"].isHittable)
        XCTAssertTrue(favorites.element(boundBy: 0).isHittable)
        XCTAssertTrue(favorites.element(boundBy: 1).isHittable)
        XCTAssertFalse(app.buttons["favorites.expand"].exists)
        XCTAssertTrue(app.buttons["join.start"].isHittable)
        XCTAssertTrue(app.buttons["calendar.star.daily"].isHittable)
        Thread.sleep(forTimeInterval: 1) // Let the window rotation finish before capturing its pixels.
        attach("Wide home · saved rooms alongside Join")
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["favorites.expand"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["invitation.input"].isHittable)
    }
}
