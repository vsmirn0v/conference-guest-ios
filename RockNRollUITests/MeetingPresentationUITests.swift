import XCTest

final class MeetingPresentationUITests: XCTestCase {
    private func launch(_ language: String = "en", autoHide: Bool = false, largeText: Bool = false,
                        scenario: String? = nil) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        if autoHide { app.launchArguments += ["-automaticallyHideMeetingControls", "YES"] }
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = scenario
        app.launch()
        return app
    }

    func testInlinePrivacyNoticeNeverCoversNavigationAndOpensTranscript() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language, scenario: "notices")
            let viewport = app.scrollViews["Shared screen viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    (app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height) == landscape
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                XCTAssertFalse(app.otherElements["Top meeting notices"].exists)
                let header = landscape ? app.otherElements["Compact meeting header"] : app.buttons["Meeting status"]
                let next = app.buttons[language == "ru" ? "Следующий поток" : "Next stream"]
                XCTAssertTrue(next.isHittable)
                XCTAssertFalse(header.frame.intersects(viewport.frame))
                if !landscape { XCTAssertFalse(header.frame.intersects(next.frame)) }
                assertControls(app, language: language)
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "Inline privacy \(language) \(orientation.rawValue)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
            app.buttons["Meeting status"].tap()
            let transcript = app.buttons[language == "ru" ? "Посмотреть расшифровку" : "View transcript"]
            XCTAssertTrue(transcript.waitForExistence(timeout: 5))
            transcript.tap()
            XCTAssertTrue(app.segmentedControls["Conversation mode"].waitForExistence(timeout: 5))
            app.buttons[language == "ru" ? "Закрыть беседу" : "Close conversation"].tap()
            app.buttons[language == "ru" ? "Другие действия" : "More call options"].tap()
            app.buttons["Provider action"].tap()
            app.buttons["Meeting status"].tap()
            app.buttons["Continue"].tap()
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.buttons["Meeting status"].label.contains("Action completed")
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 5), .completed)
            app.terminate()
        }
    }
    func testFocusRoutineNoticeStaysHiddenAndPrivacyUsesOnlyCompactHeader() throws {
        let app = launch(scenario: "notices")
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        Thread.sleep(forTimeInterval: 4)
        app.buttons["More call options"].tap(); app.buttons["Routine notice in focus"].tap()
        app.buttons["Hide controls"].tap()
        Thread.sleep(forTimeInterval: 4)
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCTAssertFalse(app.otherElements["Compact meeting header"].exists)
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        viewport.pinch(withScale: 2, velocity: 1)
        let zoom = try XCTUnwrap(viewport.value as? String)
        app.buttons["More call options"].tap(); app.buttons["Recording in focus"].tap()
        app.buttons["Hide controls"].tap()
        let header = app.otherElements["Compact meeting header"]
        XCTAssertTrue(header.waitForExistence(timeout: 5))
        XCTAssertEqual(header.frame.height, 44)
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCTAssertFalse(header.frame.intersects(viewport.frame))
        XCTAssertEqual(viewport.value as? String, zoom)
        let expired = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !header.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expired], timeout: 6), .completed)
        XCTAssertEqual(viewport.value as? String, zoom)
    }

    func testCompactSDKLayoutAllowsButtonsAndSwipeNavigation() {
        let app = launch(scenario: "compact")
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.buttons["Next stream"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Next stream"].isHittable)
        app.buttons["Next stream"].tap()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        app.buttons["Previous stream"].tap()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        viewport.swipeLeft()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Next stream"].waitForExistence(timeout: 5))
        app.buttons["Automatic view"].tap()
        XCTAssertTrue(viewport.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Next stream"].isHittable)
    }

    func testSoloMeetingKeepsInviteShortcutAboveSelfTile() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language, scenario: "solo")
            let invite = app.buttons[language == "ru" ? "Пригласить музыкантов" : "Invite musicians"]
            XCTAssertTrue(invite.waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let frame = app.windows.firstMatch.frame
                    return (frame.width > frame.height) == landscape && frame.contains(invite.frame) && invite.isHittable
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 0)
                XCTAssertFalse(app.buttons["Next stream"].exists)
            }
            app.buttons[language == "ru" ? "Копировать ссылку" : "Copy link"].tap()
            app.buttons[language == "ru" ? "Чат" : "Chat"].tap()
            XCTAssertTrue(app.segmentedControls["Conversation mode"].buttons[language == "ru" ? "Чат" : "Chat"].isSelected)
            app.buttons[language == "ru" ? "Закрыть беседу" : "Close conversation"].tap()
            XCTAssertTrue(invite.exists)
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Solo meeting invitation \(language)"; attachment.lifetime = .keepAlways; add(attachment)
            app.terminate()
        }
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
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
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
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["Leave"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
        app.scrollViews["Shared screen viewport"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
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
        XCTAssertFalse(app.buttons["Leave"].exists)
        XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
        viewport.swipeLeft()
        XCTAssertFalse(app.buttons["Leave"].exists, "Panning must keep the shared screen unobstructed")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertEqual(viewport.value as? String, zoom)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 0)
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
        XCTAssertEqual(viewport.value as? String, zoom)
        XCTAssertTrue(app.buttons["Unpin Ani’s arrangement screen share"].exists)
        XCTAssertEqual(app.staticTexts.matching(identifier: "Participant name").count, 1)
    }

    func testTapTogglesChromeWhileDoubleTapOnlyZooms() {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.doubleTap()
        XCTAssertEqual(viewport.value as? String, "200%")
        XCTAssertTrue(app.buttons["Leave"].exists, "A double tap must not toggle controls")
        viewport.tap()
        // A single tap waits for the double-tap recognizer to fail before toggling.
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["Leave"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 3), .completed)
        viewport.doubleTap()
        XCTAssertEqual(viewport.value as? String, "100%")
        XCTAssertFalse(app.buttons["Leave"].exists)
        viewport.pinch(withScale: 2, velocity: 1)
        XCTAssertNotEqual(viewport.value as? String, "100%")
        XCTAssertFalse(app.buttons["Leave"].exists, "Pinching must not restore controls")
        viewport.tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
    }

    func testFocusHintFadesAndDoesNotReturnDuringMeeting() {
        for language in ["en", "ru"] {
            let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US",
                                   "-hasSeenMeetingControlsHint", "NO", "-automaticallyHideMeetingControls", "NO"]
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launch()
            let viewport = app.scrollViews["Shared screen viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10))
            viewport.tap()
            let hint = app.staticTexts["Meeting controls hint"]
            XCTAssertTrue(hint.waitForExistence(timeout: 1))
            let faded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !hint.exists }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [faded], timeout: 4), .completed)
            XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Unobstructed shared screen \(language)"; screenshot.lifetime = .keepAlways; add(screenshot)
            viewport.tap(); viewport.tap()
            XCTAssertFalse(hint.exists, "The teaching hint must not become another persistent overlay")
            app.terminate()
        }
    }

    func testCommunityCanvasRestoresControlsWithoutFloatingButton() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-automaticallyHideMeetingControls", "NO"]
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
        app.launch()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 10))
        app.buttons["More call options"].tap()
        app.buttons["Hide controls"].tap()
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !app.buttons["Leave"].exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
        XCTAssertFalse(app.buttons["Show controls, Mic off"].exists)
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
    }
    func testSwipeBrowsesAtFitAndPansWhenZoomed() throws {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.pinch(withScale: 2, velocity: 1)
        viewport.swipeLeft()
        XCTAssertTrue(viewport.exists, "Zoomed drag pans instead of selecting another stream")
        app.buttons["More call options"].tap()
        app.buttons["Fit shared screen"].tap()
        expectation(for: NSPredicate(format: "value == '100%'"), evaluatedWith: viewport)
        waitForExpectations(timeout: 5)
        viewport.swipeLeft()
        XCTAssertTrue(app.buttons["Pin Aram video"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Automatic view"].exists)
        app.buttons["Automatic view"].tap()
        XCTAssertTrue(app.buttons["Pin Ani’s arrangement screen share"].waitForExistence(timeout: 5))
    }

    func testLandscapeHeaderKeepsNavigationAndPinOutsideMedia() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = launch(language)
            let viewport = app.scrollViews["Shared screen viewport"]
            XCTAssertTrue(viewport.waitForExistence(timeout: 10))
            XCUIDevice.shared.orientation = .landscapeLeft
            let header = app.otherElements["Compact meeting header"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                header.exists && header.frame.height == 44 && app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
            XCTAssertEqual(app.otherElements["Meeting toolbar"].frame.width, 56, accuracy: 1)
            let next = app.buttons[language == "ru" ? "Следующий поток" : "Next stream"]
            XCTAssertTrue(next.isHittable)
            XCTAssertLessThanOrEqual(next.frame.maxY, viewport.frame.minY)
            let pin = app.buttons[language == "ru" ? "Закрепить Ani’s arrangement трансляция экрана" : "Pin Ani’s arrangement screen share"]
            XCTAssertTrue(pin.isHittable)
            XCTAssertLessThanOrEqual(pin.frame.maxY, viewport.frame.minY)
            pin.tap()
            XCTAssertFalse(next.isEnabled)
            app.buttons[language == "ru" ? "Автоматический выбор" : "Automatic view"].tap()
            XCTAssertTrue(next.isEnabled)
            app.buttons["Meeting details"].tap()
            XCTAssertTrue(app.buttons[language == "ru" ? "Копировать ссылку" : "Copy link"].waitForExistence(timeout: 5))
            app.buttons[language == "ru" ? "Копировать ссылку" : "Copy link"].tap()
            let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            attachment.name = "Compact landscape \(language)"; attachment.lifetime = .keepAlways; add(attachment)
            app.buttons["Meeting details"].tap()
            app.buttons[language == "ru" ? "Пригласить музыкантов" : "Invite musicians"].tap()
            let sharing = app.otherElements["Invitation sharing"]
            if !sharing.waitForExistence(timeout: 5) {
                let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                failure.name = "Invitation sharing failure \(language)"; failure.lifetime = .keepAlways; add(failure)
                print(app.debugDescription)
                XCTFail("Invite must present the system share sheet")
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
    }

    func testZoomToolsFadeAndMoreKeepsFitAvailable() throws {
        let app = launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.pinch(withScale: 2, velocity: 1)
        let zoom = try XCTUnwrap(viewport.value as? String)
        XCTAssertNotEqual(zoom, "100%")
        let fit = app.buttons["Fit shared screen at 100%"]
        XCTAssertTrue(fit.isHittable)
        let faded = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in !fit.isHittable }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [faded], timeout: 6), .completed)
        XCTAssertEqual(viewport.value as? String, zoom)
        app.buttons["More call options"].tap()
        app.buttons["Fit shared screen"].tap()
        expectation(for: NSPredicate(format: "value == '100%'"), evaluatedWith: viewport)
        waitForExpectations(timeout: 5)
    }
}
