import XCTest

final class MeetingAccessUITests: XCTestCase {
    func testGuestDirectMoreAndViewKeepGalleryAndReceiveChoicesIndependent() {
        let app = launch(guest: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        exerciseDirectAccess(app)
        choose(app, "meeting.view.layout.gallery")
        XCTAssertTrue(app.buttons["call.view"].label.contains("Gallery"))
        choose(app, "meeting.view.receive.audio")
        XCTAssertTrue(app.buttons["call.view"].label.contains("Audio only"))
        XCTAssertEqual(app.buttons["call.view"].value as? String, "Layout: Gallery")
        app.openMeetingMore(.view)
        XCTAssertFalse(app.buttons["meeting.view.layout.gallery"].isEnabled)
        XCTAssertTrue(app.buttons["meeting.view.layout.gallery"].isSelected)
        app.meetingActionButton("meeting.view.receive.all").tap()
        XCTAssertTrue(app.waitForMeetingToolsToClose())
        XCTAssertTrue(app.buttons["call.view"].label.contains("Gallery"))
        choose(app, "meeting.view.receive.shares")
        choose(app, "meeting.view.layout.focus")
        XCTAssertTrue(app.buttons["call.view"].label.contains("Shares only"))
        app.openMeetingMore(.view)
        XCTAssertTrue(app.buttons["meeting.view.receive.shares"].isSelected)
        app.buttons["meeting.view.done"].tap()
        attach("Guest direct More and View")
    }

    func testNativeDirectToolsAndRotationRemainReachable() {
        let app = launch(guest: false)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            exerciseDirectAccess(app)
        }
        attach("Native direct tools after rotation")
    }

    func testRussianLargeTextKeepsDirectControlsReachable() {
        let app = launch(guest: true, russian: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let view = app.buttons["call.view"], more = app.buttons["call.more"]
            XCTAssertTrue(view.waitForExistence(timeout: 10)); XCTAssertTrue(view.isHittable); XCTAssertTrue(more.isHittable)
            XCTAssertGreaterThanOrEqual(view.frame.height, 44); XCTAssertGreaterThanOrEqual(more.frame.width, 44)
            app.openMeetingMore(.view)
            XCTAssertTrue(app.meetingActionButton("meeting.view.receive.audio").isHittable)
            app.buttons["meeting.view.done"].tap()
            XCTAssertTrue(app.waitForMeetingToolsToClose())
            app.buttons["call.more"].tap()
            XCTAssertTrue(app.descendants(matching: .any)["meeting.menu.call.group.cameraSound"].firstMatch.waitForExistence(timeout: 5))
            attach("Russian large text tools")
            app.buttons["reactions.done"].tap()
            XCTAssertTrue(app.waitForMeetingToolsToClose())
        }
    }

    private func exerciseDirectAccess(_ app: XCUIApplication) {
        let view = app.buttons["call.view"], more = app.buttons["call.more"]
        XCTAssertTrue(view.waitForExistence(timeout: 10)); XCTAssertTrue(view.isHittable); XCTAssertTrue(more.isHittable)
        let initial = more.frame
        more.tap()
        let root = app.descendants(matching: .any)["meeting.menu.call.group.cameraSound"].firstMatch
        XCTAssertTrue(root.waitForExistence(timeout: 5), "One tap should reach actual More tools")
        XCTAssertFalse(app.buttons["meeting.more.reactions"].exists)
        app.buttons["reactions.done"].tap()
        XCTAssertTrue(app.waitForMeetingToolsToClose())
        XCTAssertEqual(app.buttons["call.more"].frame, initial)
        app.openMeetingMore(.view)
        XCTAssertTrue(app.buttons["meeting.view.layout.focus"].waitForExistence(timeout: 5))
        app.buttons["meeting.view.done"].tap()
        XCTAssertTrue(app.waitForMeetingToolsToClose())
        XCTAssertTrue(app.buttons["call.reactions"].isHittable)
    }

    private func choose(_ app: XCUIApplication, _ identifier: String) {
        app.openMeetingMore(.view)
        let choice = app.meetingActionButton(identifier)
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); choice.tap()
        XCTAssertTrue(app.waitForMeetingToolsToClose(), "One choice should dismiss the panel")
    }
    private func launch(guest: Bool, russian: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        if guest {
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "gallery-many"
        } else { app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock" }
        app.launchArguments = ["-AppleLanguages", russian ? "(ru)" : "(en)", "-automaticallyHideMeetingControls", "NO"]
        if russian { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        XCUIDevice.shared.orientation = .portrait
        app.launch(); return app
    }
    private func attach(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
    }
}
