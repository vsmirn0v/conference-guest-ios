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
        let ready = large && handoff ? app.buttons["handoff.join-alongside.fixture-mac"] : app.buttons["join.start"]
        XCTAssertTrue(ready.waitForExistence(timeout: 10))
        if mode != "home-later" {
            XCTAssertTrue(app.buttons["calendar.star.daily"].waitForExistence(timeout: 10))
        }
    }
    private var favorites: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "favorite.order."))
    }
    private func reveal(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<7 where !element.isHittable { if down { app.swipeDown() } else { app.swipeUp() } }
        XCTAssertTrue(element.waitForExistence(timeout: 5)); XCTAssertTrue(element.isHittable)
    }
    private func attach(_ title: String) {
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); capture.name = title; capture.lifetime = .keepAlways; add(capture)
    }
    func testEmptyStartupCalendarCheckIsSilentAndDoesNotMoveQuickActions() {
        for language in ["en", "ru"] {
            app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = "home-empty"
            app.launchEnvironment["CONFERENCE_TEST_CALENDAR_DELAY"] = "8"
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
            app.launch()
            let join = app.buttons["join.start"]
            XCTAssertTrue(join.waitForExistence(timeout: 10))
            let first = favorites.element(boundBy: 0), second = favorites.element(boundBy: 1)
            let frames = [join.frame, first.frame, second.frame]
            let checking = language == "ru" ? "Проверяем календарь…" : "Checking calendar…"
            XCTAssertFalse(app.descendants(matching: .any)["home.calendar-loading"].exists)
            XCTAssertFalse(app.staticTexts[checking].exists, "Background calendar work must not occupy Home")
            XCTAssertTrue(first.isHittable); XCTAssertTrue(second.isHittable)
            attach("Silent startup calendar check · " + language)
            // The fixture holds the read for eight seconds. Verify the completed
            // empty state below as well, so a failed scan cannot satisfy geometry.
            Thread.sleep(forTimeInterval: 9)
            XCTAssertEqual(join.frame, frames[0])
            XCTAssertEqual(first.frame, frames[1]); XCTAssertEqual(second.frame, frames[2])
            let agenda = app.buttons["calendar.agenda"]
            reveal(agenda); agenda.tap()
            let empty = language == "ru" ? "В выбранных календарях нет предстоящих встреч со ссылкой для подключения." :
                "No upcoming meetings with a join link in your selected calendars."
            XCTAssertTrue(app.staticTexts[empty].waitForExistence(timeout: 5), "The calendar scan must actually finish")
            app.terminate()
        }
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_CALENDAR_DELAY")
    }
    func testLateCalendarEnrichmentDoesNotMoveJoinOrFavoriteTapTargets() {
        for language in ["en", "ru"] {
            app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = "home-delayed-later"
            app.launchEnvironment["CONFERENCE_TEST_CALENDAR_DELAY"] = "8"
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
            app.launch()
            XCTAssertTrue(app.buttons["join.start"].waitForExistence(timeout: 10))
            let first = favorites.element(boundBy: 0), second = favorites.element(boundBy: 1)
            let frames = [app.buttons["join.start"].frame, first.frame, second.frame]
            let identity = first.identifier
            let enriched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Daily rehearsal"), object: first)
            XCTAssertEqual(XCTWaiter.wait(for: [enriched], timeout: 12), .completed)
            XCTAssertEqual(app.buttons["join.start"].frame, frames[0])
            XCTAssertEqual(first.frame, frames[1]); XCTAssertEqual(second.frame, frames[2])
            XCTAssertEqual(first.identifier, identity)
            XCTAssertTrue((first.value as? String ?? "").contains("Daily rehearsal"))
            XCTAssertFalse(app.descendants(matching: .any)["home.title.daily"].exists, "Later meetings must not occupy an urgent slot")
            XCTAssertFalse(app.descendants(matching: .any)["home.calendar-loading"].exists)
            XCTAssertFalse(app.buttons["home.show-updates"].exists, "Discoveries must appear without an acceptance gate")
            attach("Stable rows after delayed enrichment · " + language)
            app.terminate()
        }
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_CALENDAR_DELAY")
    }
    func testDelayedCalendarWaitsForTextEditingThenAppearsAutomatically() {
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = "home-delayed"
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR_DELAY"] = "3"
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        let name = app.textFields["name.input"]
        XCTAssertTrue(name.waitForExistence(timeout: 10)); name.tap(); name.typeText(" edited")
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.descendants(matching: .any)["home.title.daily"].exists,
                       "Typing protects existing controls from structural replacement")
        name.typeText("\n")
        XCTAssertTrue(app.buttons["calendar.join.daily"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.show-updates"].exists)
        XCTAssertTrue((name.value as? String ?? "").contains("edited"))
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_CALENDAR_DELAY")
    }
    func testAutomaticJoinCountdownStaysBelowQuickActions() {
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR"] = "home-countdown"
        app.launchEnvironment["CONFERENCE_TEST_CALENDAR_DELAY"] = "8"
        app.launchArguments = ["-AppleLanguages", "(en)"]
        app.launch()
        XCTAssertTrue(app.buttons["join.start"].waitForExistence(timeout: 10))
        let banner = app.descendants(matching: .any)["calendar.countdown-banner"].firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["calendar.join.daily"].exists)
        let before = app.buttons["join.start"].frame
        let firstFrame = favorites.element(boundBy: 0).frame
        XCTAssertGreaterThanOrEqual(banner.frame.minY, before.maxY)
        app.buttons["Cancel"].tap()
        XCTAssertEqual(app.buttons["join.start"].frame, before)
        XCTAssertEqual(favorites.element(boundBy: 0).frame, firstFrame)
        XCTAssertTrue(app.buttons["join.start"].isHittable)
        app.launchEnvironment.removeValue(forKey: "CONFERENCE_TEST_CALENDAR_DELAY")
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
            XCTAssertTrue(savedDetail.contains("meeting.example.test · favorite1"))
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
                XCTAssertTrue(title.label.contains("Work"))
                XCTAssertTrue(title.label.contains("Our rehearsal room"))
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
    func testConcurrentAndSoonMeetingsStayInlineWhenPromotedSlotsAreFull() {
        launch("home-overlap")
        XCTAssertTrue(app.descendants(matching: .any)["home.title.daily"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["home.title.overlap1"].exists)
        let ongoing = app.buttons["calendar.join.overlap2"], soon = app.buttons["calendar.join.soon"]
        reveal(ongoing)
        XCTAssertTrue((ongoing.value as? String ?? "").contains("meeting.example.test · overlap2"))
        reveal(soon)
        XCTAssertTrue(soon.isEnabled)
        reveal(app.buttons["calendar.join.later2"])
        XCTAssertFalse(app.buttons["calendar.join.later3"].exists)
        reveal(app.buttons["calendar.today.expand"])
        app.buttons["calendar.today.expand"].tap()
        reveal(app.buttons["calendar.join.later3"])
        XCTAssertTrue(ongoing.exists); XCTAssertTrue(soon.exists)
    }
    func testSettingsKeepsGroupedDestinationsAndSyncPrivacyAccessible() {
        launch()
        app.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["calendar.settings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["settings.devices"].exists)
        XCTAssertTrue(app.buttons["settings.websites"].exists)
        XCTAssertTrue(app.buttons["settings.about"].exists)
        app.buttons["settings.devices"].tap()
        XCTAssertTrue(app.staticTexts["Names and saved invitations, including invitation passwords, stay in your private iCloud storage."].waitForExistence(timeout: 5))
        XCTAssertTrue(app.switches["Sync with iCloud"].exists)
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
    func testHandoffActionsFitAndJoinHereKeepsSourceAvailable() {
        for language in ["en", "ru"] {
            launch("home-handoff", language: language, handoff: true)
            let move = app.buttons["calendar.join.daily"]
            let join = app.buttons["handoff.join-alongside.fixture-mac"]
            XCTAssertTrue(move.waitForExistence(timeout: 10))
            XCTAssertTrue(join.isHittable)
            let title = language == "ru" ? "Перенести сюда" : "Move here"
            let textWidth = (title as NSString).size(withAttributes: [.font: UIFont.systemFont(ofSize: 17)]).width
            XCTAssertGreaterThanOrEqual(move.frame.width, ceil(textWidth) + 20,
                                        "The action must have room for its full title and padding")
            XCTAssertLessThanOrEqual(move.frame.height, 64, "Normal text must not hyphenate onto two lines")
            XCTAssertFalse(move.frame.intersects(join.frame))
            join.tap()
            XCTAssertTrue(move.isHittable, "An independent join must not withdraw the original device's card")
            for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                var previous: CGRect?
                let settled = expectation(for: NSPredicate { _, _ in
                    let frame = join.frame
                    let matchesOrientation = (self.app.frame.width > self.app.frame.height) == orientation.isLandscape
                    defer { previous = frame }
                    return matchesOrientation && !frame.isEmpty && previous == frame
                }, evaluatedWith: app)
                wait(for: [settled], timeout: 8)
                reveal(join)
                XCTAssertTrue(move.isHittable)
                XCTAssertFalse(move.frame.intersects(join.frame))
            }
            attach("Handoff and independent join · " + language)
            app.terminate()
        }
    }
    func testHandoffActionsFitLargerText() {
        launch("home-handoff", language: "ru", large: true, handoff: true)
        let move = app.buttons["calendar.join.daily"]
        let join = app.buttons["handoff.join-alongside.fixture-mac"]
        reveal(move); reveal(join)
        XCTAssertGreaterThanOrEqual(move.frame.minX, 0)
        XCTAssertLessThanOrEqual(move.frame.maxX, app.frame.maxX)
        XCTAssertLessThanOrEqual(join.frame.maxX, app.frame.maxX)
        XCTAssertFalse(move.frame.intersects(join.frame))
        attach("Handoff actions · Russian accessibility text")
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
        if app.frame.width >= 820 {
            XCTAssertTrue(library.waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["favorites.expand"].exists)
        } else {
            XCTAssertTrue(app.buttons["favorites.expand"].waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.textFields["invitation.input"].isHittable)
    }
}
