import XCTest

final class CameraBackgroundUITests: XCTestCase {
    func testPrivateAndLiveCameraPreviewSurviveFrontRearSwitch() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real front/rear camera capture requires a physical iPhone")
        #else
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_INVITE"] else {
            throw XCTSkip("Provide a disposable meeting")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launch()
        defer {
            if app.buttons["studio.done"].exists { app.buttons["studio.done"].tap() }
            if app.buttons["Stop video"].exists { app.buttons["Stop video"].tap() }
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        let camera = app.buttons["Start video"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 60))
        camera.press(forDuration: 0.7)
        let status = app.descendants(matching: .any)["studio.preview-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let start = app.buttons["studio.start-video"]
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)], timeout: 15)
        XCTAssertTrue(status.label.contains("Only you"))
        shot(app, "Private front camera mirror")
        let flip = app.buttons["studio.flip-camera"]
        if !flip.exists || !flip.isHittable { app.swipeUp() }
        XCTAssertTrue(flip.isEnabled)
        flip.tap(); sleep(3)
        app.swipeDown()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)], timeout: 15)
        shot(app, "Private rear camera unmirrored")
        if !flip.isHittable { app.swipeUp() }
        flip.tap(); sleep(3)
        app.swipeDown()
        wait(for: [expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)], timeout: 15)
        start.tap()
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        XCTAssertTrue(app.buttons["Stop video"].waitForExistence(timeout: 20))
        app.buttons["Stop video"].firstMatch.press(forDuration: 0.7)
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertTrue(status.label.contains("Visible to jam"))
        sleep(3); shot(app, "Live front camera mirror")
        if !flip.exists || !flip.isHittable { app.swipeUp() }
        flip.tap(); sleep(3)
        app.swipeDown()
        shot(app, "Live rear camera unmirrored")
        if !flip.isHittable { app.swipeUp() }
        flip.tap(); sleep(3)
        app.swipeDown()
        shot(app, "Live front camera restored")
        #endif
    }

    func testOutgoingCameraKeepsRunningInBackground() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Real camera and system video-call PiP require a physical iPhone")
        #else
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_INVITE"] else {
            throw XCTSkip("Provide a disposable meeting with an independent receiver")
        }
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_CAMERA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer {
            app.activate()
            if app.buttons["Stop video"].exists { app.buttons["Stop video"].tap() }
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
        }
        XCTAssertTrue(app.buttons["Start video"].waitForExistence(timeout: 60))
        app.buttons["Start video"].tap()
        if app.buttons["Continue"].waitForExistence(timeout: 2) { app.buttons["Continue"].tap() }
        let permission = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if permission.waitForExistence(timeout: 2) { permission.tap() }
        XCTAssertTrue(app.buttons["Stop video"].waitForExistence(timeout: 30))
        sleep(10)
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_CAMERA_PIN_LOCAL"] == "1" {
            let pins = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Pin ' AND label ENDSWITH ' video'"))
            if let local = pins.allElementsBoundByIndex.last { local.tap() }
            sleep(3)
        }
        shot(app, "Camera foreground baseline")
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 10))
        sleep(10); shot(pip, "Camera background 10 seconds")
        sleep(60)
        XCTAssertTrue(pip.exists, "Camera PiP must remain visible after the background transition")
        shot(pip, "Camera background 70 seconds")
        // The trace and independent receiver qualify continuing capture/encoding;
        // screenshot differences alone cannot prove motion in a stationary scene.
        app.activate()
        XCTAssertTrue(app.buttons["Stop video"].waitForExistence(timeout: 10))
        sleep(5)
        app.buttons["Stop video"].tap()
        app.buttons["Leave"].tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home); sleep(3)
        XCTAssertFalse(pip.exists, "Leaving must retire the local-camera PiP source")
        app.activate()
        #endif
    }
    private func shot(_ element: XCUIElement, _ title: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
