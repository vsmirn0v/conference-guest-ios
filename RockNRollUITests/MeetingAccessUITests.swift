import XCTest

final class MeetingAccessUITests: XCTestCase {
    func testGuestGalleryPagingSharesRowWithDirectToolsInBothOrientations() {
        exerciseGalleryRow(guest: true)
    }
    func testNativeGalleryPagingSharesRowWithDirectToolsInBothOrientations() {
        exerciseGalleryRow(guest: false)
    }
    private func exerciseGalleryRow(guest: Bool) {
        let app = launch(guest: guest, gallery: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        choose(app, "meeting.view.layout.gallery")
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let previous = app.buttons["Previous participants"], next = app.buttons["Next participants"]
            let view = app.buttons["call.view"], more = app.buttons["call.more"]
            let aligned = NSPredicate { _, _ in
                previous.exists && next.exists && view.exists && more.exists && next.isHittable && view.isHittable && more.isHittable &&
                    abs(next.frame.midY - view.frame.midY) < 1 && abs(view.frame.midY - more.frame.midY) < 1 &&
                    next.frame.maxX + 7 <= view.frame.minX
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: aligned, object: nil)], timeout: 10), .completed)
            for button in [previous, next, view, more] {
                XCTAssertGreaterThanOrEqual(button.frame.width, 44)
                XCTAssertGreaterThanOrEqual(button.frame.height, 44)
            }
            if !next.isEnabled { previous.tap() }
            let position = app.staticTexts["Gallery page"], before = position.label
            next.tap()
            XCTAssertNotEqual(position.label, before)
            XCTAssertTrue(previous.isEnabled)
            previous.tap()
            XCTAssertEqual(position.label, before)
            exerciseDirectAccess(app)
            attach(guest ? "Guest single context row" : "Native single context row")
        }
    }
    func testGuestDirectMoreAndViewKeepGalleryAndReceiveChoicesIndependent() {
        let app = launch(guest: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        exerciseDirectAccess(app)
        choose(app, "meeting.view.layout.gallery")
        XCTAssertTrue(app.buttons["call.view"].label.contains("Gallery"))
        choose(app, "meeting.view.receive.audio")
        XCTAssertTrue(app.buttons["call.view"].label.contains("Audio only"))
        XCTAssertEqual(app.buttons["call.view"].value as? String, "Layout: Gallery")
        attach("Guest audio only participant gallery")
        app.openMeetingMore(.view)
        XCTAssertTrue(app.buttons["meeting.view.layout.gallery"].isEnabled)
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

    func testFocusedShareUsesWholeWindowForPinchAndRetainsZoomWhenControlsToggle() throws {
        let app = launch(guest: true)
        defer { app.terminate(); XCUIDevice.shared.orientation = .portrait }
        func covers(_ frame: CGRect, _ bounds: CGRect) -> Bool {
            abs(frame.minX - bounds.minX) < 0.5 && abs(frame.minY - bounds.minY) < 0.5 &&
                abs(frame.maxX - bounds.maxX) < 0.5 && abs(frame.maxY - bounds.maxY) < 0.5
        }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let gestureApp = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
            let viewport = gestureApp.scrollViews.matching(identifier: "share").firstMatch
            XCTAssertTrue(viewport.waitForExistence(timeout: 15))
            // iPadOS can expose an empty system window before the call window.
            let window = try XCTUnwrap(gestureApp.windows.containing(.scrollView, identifier: "share")
                .allElementsBoundByIndex.first { !$0.frame.isEmpty })
            let fillsWindow = NSPredicate { _, _ in
                let bounds = window.frame
                return (bounds.width > bounds.height) == orientation.isLandscape && covers(viewport.frame, bounds)
            }
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: fillsWindow, object: nil)], timeout: 8), .completed)
            let viewButton = gestureApp.buttons["call.view"]
            XCTAssertTrue(viewButton.isHittable)
            if viewport.value as? String != "100%" {
                gestureApp.buttons["Shared screen scale"].tap()
                let fit = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "100%"), object: viewport)
                XCTAssertEqual(XCTWaiter.wait(for: [fit], timeout: 5), .completed)
            }
            // A larger spread clears UIKit's touch threshold on regular-width iPads.
            // The viewport was independently checked against the containing window.
            viewport.pinch(withScale: 3, velocity: 1)
            let magnified = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard let value = viewport.value as? String,
                      let percent = Int(value.replacingOccurrences(of: "%", with: "")) else { return false }
                return percent > 110
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [magnified], timeout: 5), .completed)
            let zoom = try XCTUnwrap(viewport.value as? String)
            let tap = window.coordinate(withNormalizedOffset: CGVector(dx: 0.32, dy: 0.55))
            tap.tap()
            // The stage waits for its double-tap zoom recognizer before hiding chrome.
            let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: viewButton)
            XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 5), .completed)
            XCTAssertTrue(covers(viewport.frame, window.frame))
            XCTAssertEqual(viewport.value as? String, zoom)
            tap.tap()
            XCTAssertTrue(viewButton.waitForExistence(timeout: 5))
            XCTAssertEqual(viewport.value as? String, zoom)
            attach("Full-window share with floating controls \(orientation.rawValue)")
        }
    }

    func testScreenSharingOnlyShowsParticipantsInGalleryAndFocus() {
        let app = launch(guest: false, gallery: true)
        defer { app.terminate() }
        choose(app, "meeting.view.receive.shares")
        let tile = app.otherElements["camera-off.person-1"]
        XCTAssertTrue(tile.isHittable)
        choose(app, "meeting.view.layout.focus")
        let name = app.staticTexts.matching(identifier: "Participant name").firstMatch
        XCTAssertTrue(name.isHittable)
        app.buttons["Focus participant.person-1.camera"].tap()
        XCTAssertEqual(name.label, "Полина")
        choose(app, "meeting.view.layout.gallery")
        XCTAssertTrue(tile.isHittable)
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
    private func launch(guest: Bool, russian: Bool = false, gallery: Bool = false) -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        if guest {
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "gallery-many"
        } else if gallery { app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "meeting-gallery" }
        else { app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock" }
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
