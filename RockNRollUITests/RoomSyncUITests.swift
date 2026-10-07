import XCTest

final class RoomSyncUITests: XCTestCase {
    func testFavoriteDragOrderAndContextActions() {
        checkFavoriteOrder(language: "en", moveDown: "Move down")
    }
    func testRussianFavoriteOrderOnSmallScreen() {
        checkFavoriteOrder(language: "ru", moveDown: "Переместить ниже")
    }
    private func checkFavoriteOrder(language: String, moveDown: String) {
        let app = launch("favorite-order", language: language)
        XCTAssertFalse(app.buttons["favorites.reorder"].exists)
        let warmup = app.buttons["favorite.order.https://fixture.example.test/room0?psw=fixture"]
        let songwriting = app.buttons["favorite.order.https://fixture.example.test/room2?psw=fixture"]
        XCTAssertTrue(warmup.waitForExistence(timeout: 5))
        app.swipeUp()
        reveal(songwriting, in: app)
        songwriting.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.5))
            .press(forDuration: 0.65, thenDragTo: warmup.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.15)))
        let moved = NSPredicate { _, _ in songwriting.frame.minY < warmup.frame.minY }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: moved, object: nil)], timeout: 5), .completed)
        songwriting.press(forDuration: 0.8)
        app.buttons[moveDown].tap()
        let movedDown = NSPredicate { _, _ in warmup.frame.minY < songwriting.frame.minY }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: movedDown, object: nil)], timeout: 5), .completed)
        XCTAssertLessThan(warmup.frame.minY, songwriting.frame.minY)
        let invitation = app.textFields["invitation.input"]
        reveal(invitation, in: app, down: true)
        XCTAssertFalse((invitation.value as? String ?? "").contains("fixture.example.test"))
        attach(app, "Favorite order changed directly")
    }

    func testCancelledDirectDragKeepsOrderAndRenameStillWorks() {
        let app = launch("favorite-order")
        let first = app.buttons["favorite.order.https://fixture.example.test/room0?psw=fixture"]
        let last = app.buttons["favorite.order.https://fixture.example.test/room2?psw=fixture"]
        XCTAssertTrue(first.waitForExistence(timeout: 5)); app.swipeUp(); reveal(last, in: app)
        last.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5))
            .press(forDuration: 0.65, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.02, dy: 0.1)))
        XCTAssertLessThan(first.frame.minY, last.frame.minY)
        first.press(forDuration: 0.8)
        app.buttons["Rename"].tap()
        XCTAssertTrue(app.navigationBars["Name this jam"].waitForExistence(timeout: 5))
        let name = app.textFields["New jam name"]
        name.tap(); name.typeText("My warm-up")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Rejoin My warm-up")).firstMatch.waitForExistence(timeout: 5))
        let invitation = app.textFields["invitation.input"]
        reveal(invitation, in: app, down: true)
        XCTAssertFalse((invitation.value as? String ?? "").contains("fixture.example.test"))
    }
    private func launch(_ mode: String, language: String = "en") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(\(language))", "-AppleLocale", language == "ru" ? "ru_RU" : "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_SYNC_FIXTURE"] = mode
        app.launch()
        return app
    }
    func testOptionalSyncSettingsAndInitialNameChoice() {
        let app = launch("available")
        app.buttons["Settings"].tap()
        let enabled = app.switches["Sync with iCloud"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8))
        XCTAssertEqual(enabled.value as? String, "0")
        toggle(enabled)
        let cloudName = app.buttons["Use iCloud name: Ani"]
        reveal(cloudName, in: app)
        XCTAssertTrue(cloudName.waitForExistence(timeout: 10))
        cloudName.tap()
        let recent = app.switches["Include recent jams"]
        reveal(recent, in: app)
        XCTAssertEqual(recent.value as? String, "1")
        toggle(recent); XCTAssertEqual(recent.value as? String, "0")
        app.buttons["Sync now"].tap()
        XCTAssertTrue(app.staticTexts["Up to date"].waitForExistence(timeout: 5))
        reveal(enabled, in: app); toggle(enabled); XCTAssertEqual(enabled.value as? String, "0")
        XCTAssertTrue(app.staticTexts["Stored on this device"].exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.textFields["name.input"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["name.input"].value as? String, "Ani")
        attach(app, "Optional iCloud sync")
    }
    func testUnavailableCloudDoesNotBlockJoiningAndSettingsFitRotation() {
        let app = launch("unavailable")
        app.buttons["Settings"].tap()
        let enabled = app.switches["Sync with iCloud"]
        XCTAssertTrue(enabled.waitForExistence(timeout: 8)); toggle(enabled)
        XCTAssertTrue(app.staticTexts["iCloud unavailable. Your changes stay on this device."].waitForExistence(timeout: 8))
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Done"].isHittable)
        XCUIDevice.shared.orientation = .portrait
        let settled = NSPredicate { _, _ in app.frame.width < app.frame.height && app.buttons["Done"].frame.maxX <= app.frame.width }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 5), .completed)
        app.buttons["Done"].tap()
        let closed = NSPredicate { _, _ in !app.navigationBars["Settings"].exists }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: closed, object: nil)], timeout: 5), .completed)
        let invite = app.textFields["invitation.input"]
        reveal(invite, in: app, down: true)
        invite.tap(); invite.typeText("https://rock.glowsoft.ru/jams/test")
        XCTAssertTrue(app.buttons["Join jam"].isEnabled)
        XCTAssertEqual(app.textFields["name.input"].value as? String, "Aram")
        attach(app, "Joining remains available offline")
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    private func toggle(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, down: Bool = false) {
        for _ in 0..<4 {
            if element.exists && element.isHittable { return }
            if down { app.swipeDown() } else { app.swipeUp() }
        }
    }
}
