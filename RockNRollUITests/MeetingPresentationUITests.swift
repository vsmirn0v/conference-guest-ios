import XCTest

final class MeetingPresentationUITests: XCTestCase {
    private func launch(_ language: String = "en", autoHide: Bool = false, largeText: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if autoHide { app.launchArguments += ["-automaticallyHideMeetingControls", "YES"] }
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launch()
        return app
    }
    private func assertControls(_ app: XCUIApplication, language: String) {
        let labels = language == "ru" ? ["Включить микрофон", "Включить видео", "Транслировать экран", "Другие действия", "Выйти"] :
            ["Unmute microphone", "Start video", "Share screen", "More call options", "Leave"]
        let window = app.windows.firstMatch.frame
        for label in labels {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 5), label)
            XCTAssertTrue(button.isHittable, label)
            XCTAssertTrue(window.contains(button.frame), "\(label): \(button.frame)")
            XCTAssertGreaterThanOrEqual(button.frame.width, 44)
            XCTAssertGreaterThanOrEqual(button.frame.height, 44)
        }
        let name = app.staticTexts.matching(identifier: "Participant name").firstMatch
        XCTAssertTrue(name.exists)
        let toolbar = app.otherElements["Meeting toolbar"]
        XCTAssertFalse(name.frame.intersects(toolbar.frame), "Name must not be under the toolbar")
    }
    func testGuestControlsAndFooterFitEnglishAndRussianRotation() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language)
            XCTAssertTrue(app.scrollViews["Shared screen viewport"].waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait, .landscapeRight, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft || orientation == .landscapeRight
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    let leave = app.buttons[language == "ru" ? "Выйти" : "Leave"].frame
                    return (frame.width > frame.height) == landscape && frame.contains(leave)
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                assertControls(app, language: language)
            }
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Guest controls \(language)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
    }
    func testRussianLargestTextKeepsActionsVisible() {
        let app = launch("ru", largeText: true)
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Выйти"].waitForExistence(timeout: 10))
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation == .landscapeLeft
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return (frame.width > frame.height) == landscape && frame.contains(app.buttons["Выйти"].frame)
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
            assertControls(app, language: "ru")
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Largest Russian text"; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testAutoHideWaitsForMenuAndRestoresWithoutClickThrough() {
        let app = launch(autoHide: true)
        XCTAssertTrue(app.buttons["More call options"].waitForExistence(timeout: 10))
        app.buttons["More call options"].tap()
        Thread.sleep(forTimeInterval: 6)
        XCTAssertTrue(app.buttons["Leave"].exists, "An open menu must prevent auto-hide")
        if app.buttons["View"].exists { app.buttons["View"].tap() }
        app.buttons["All video"].tap()
        XCTAssertTrue(app.buttons["Show controls, Mic off"].waitForExistence(timeout: 10))
        app.buttons["Show controls, Mic off"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Pin Ani’s arrangement screen share"].exists,
            "Restoring controls must not trigger the control underneath the tap")
    }

    func testFocusPreservesZoomAndPinAcrossRotation() throws {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        app.buttons["Pin Ani’s arrangement screen share"].tap()
        viewport.pinch(withScale: 2, velocity: 1)
        let zoom = try XCTUnwrap(viewport.value as? String)
        XCTAssertNotEqual(zoom, "100%")
        app.buttons["Hide controls"].tap()
        XCTAssertTrue(app.buttons["Show controls, Mic off"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(viewport.value as? String, zoom)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 0)
        app.buttons["Show controls, Mic off"].tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        XCTAssertEqual(viewport.value as? String, zoom)
        XCTAssertTrue(app.buttons["Unpin Ani’s arrangement screen share"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 1)
    }
    func testSwipeBrowsesAtFitAndPansWhenZoomed() throws {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.pinch(withScale: 2, velocity: 1)
        viewport.swipeLeft()
        XCTAssertTrue(viewport.exists, "Zoomed drag pans instead of selecting another stream")
        app.buttons["Fit shared screen at 100%"].tap()
        expectation(for: NSPredicate(format: "value == '100%'"), evaluatedWith: viewport)
        waitForExpectations(timeout: 5)
        viewport.swipeLeft()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Automatic view"].exists)
        app.buttons["Automatic view"].tap()
        XCTAssertTrue(app.buttons["Pin Ani’s arrangement screen share"].waitForExistence(timeout: 5))
    }
}
