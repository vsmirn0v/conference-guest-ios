import XCTest

final class PresenterUITests: XCTestCase {
    func testPresenterStartsPrivatelyAndSurvivesSmallScreenRotation() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.buttons["More call options"].firstMatch.waitForExistence(timeout: 10))
        open(app)
        let start = app.buttons["presenter.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10)); XCTAssertTrue(start.isHittable)
        XCTAssertTrue(app.staticTexts["Preview · Only you"].exists)
        start.tap()
        XCTAssertTrue(app.buttons["presenter.stop"].waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForHittable(app.buttons["presenter.stop"])
        XCUIDevice.shared.orientation = .portrait
        waitForHittable(app.buttons["presenter.stop"])
        app.buttons["presenter.stop"].tap()
        app.buttons["studio.done"].tap()
        XCTAssertTrue(app.buttons["Start video"].firstMatch.exists)
        XCTAssertTrue(app.buttons["Unmute microphone"].firstMatch.exists)
    }

    /// Optional remote browser qualification; invitation remains outside source.
    func testLiveGuestCanvasReachesScreenShareTransport() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_INVITE"] else {
            throw XCTSkip("Opt-in remote receiver qualification")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Presenter QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        defer {
            if app.buttons["studio.done"].exists { app.buttons["studio.done"].tap() }
            if app.buttons["Leave"].firstMatch.exists { app.buttons["Leave"].firstMatch.tap() }
            app.terminate()
        }
        app.launch()
        XCTAssertTrue(app.buttons["Unmute microphone"].firstMatch.waitForExistence(timeout: 30))
        open(app)
        XCTAssertTrue(app.buttons["presenter.start"].waitForExistence(timeout: 10))
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_CAMERA"] == "1" {
            let camera = app.switches["presenter.camera"]
            camera.coordinate(withNormalizedOffset: CGVector(dx: 0.93, dy: 0.5)).tap()
            XCTAssertEqual(camera.value as? String, "1", app.debugDescription)
        }
        // A warm canvas distinguishes outgoing composition from a black idle tile.
        let scene = app.descendants(matching: .any)["presenter.scene"].firstMatch
        for _ in 0..<4 { if scene.isHittable { break }; app.swipeUp() }
        scene.tap()
        app.buttons["Warm"].tap()
        app.buttons["presenter.start"].tap()
        XCTAssertTrue(app.buttons["presenter.stop"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.switches["presenter.camera"].isHittable { break }
            app.swipeDown()
        }
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PRESENTER_CAMERA"] == "1" {
            XCTAssertEqual(app.switches["presenter.camera"].value as? String, "1", app.debugDescription)
        }
        let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        capture.name = "Live Presenter canvas"; capture.lifetime = .keepAlways; add(capture)
        // This functional observation window is not a CPU/energy profiling run.
        Thread.sleep(forTimeInterval: 90)
        XCTAssertTrue(app.buttons["presenter.stop"].exists)
        app.buttons["presenter.stop"].tap()
    }
    private func open(_ app: XCUIApplication) {
        app.buttons["More call options"].firstMatch.tap()
        app.buttons["Presenter"].firstMatch.tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
    }
    private func waitForHittable(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
