import XCTest
import ImageIO

final class PresenterUITests: XCTestCase {
    func testImagePickersPresentFromSourceAndScrolledBackgroundControls() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        defer { app.terminate() }
        app.launch(); open(app)
        let source = app.buttons["presenter.source"]
        if !source.isHittable { app.descendants(matching: .any)["studio.settings"].firstMatch.swipeDown() }
        source.tap(); app.buttons["Choose slide or background"].tap()
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "Source selection must present its image picker")
        cancel.tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
        let file = app.staticTexts["Open image file"].firstMatch
        for _ in 0..<5 { if file.isHittable { break }; app.descendants(matching: .any)["studio.settings"].firstMatch.swipeUp() }
        XCTAssertTrue(file.waitForExistence(timeout: 5))
        file.tap()
        let fileCancel = XCUIApplication(bundleIdentifier: "com.apple.DocumentManagerUICore.Service").buttons["Cancel"].firstMatch
        XCTAssertTrue(fileCancel.waitForExistence(timeout: 30), "File picker must survive the source row scrolling out of view")
        fileCancel.tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
    }
    func testExpandedEditorFitsLandscapeAndReturnsPreview() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        app.launchEnvironment["CONFERENCE_TEST_PRESENTER_WARM"] = "1"
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        app.launch(); open(app)
        app.buttons["presenter.expand"].tap()
        let done = app.navigationBars["Canvas"].buttons["Done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        waitForOrientation(app, landscape: true)
        waitForHittable(done)
        let tools = app.segmentedControls["presenter.expanded-tools"]
        let draw = tools.buttons["Draw"]
        XCTAssertTrue(draw.isHittable)
        draw.tap()
        XCTAssertTrue(app.buttons["presenter.clear"].isHittable)
        let canvas = app.descendants(matching: .any)["presenter.preview"].firstMatch
        assertCanvasPixels(canvas)
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.3)).press(forDuration: 0.05,
            thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.6)))
        XCTAssertTrue(app.buttons["presenter.undo"].isEnabled)
        app.buttons["presenter.clear"].tap()
        XCTAssertTrue(app.buttons["presenter.undo"].isEnabled)
        app.buttons["presenter.undo"].tap()
        done.tap()
        XCUIDevice.shared.orientation = .portrait
        waitForOrientation(app, landscape: false)
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
        for _ in 0..<4 { if app.buttons["presenter.expand"].isHittable { break }; app.descendants(matching: .any)["studio.settings"].firstMatch.swipeDown() }
        XCTAssertTrue(app.descendants(matching: .any)["presenter.preview"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Preview · Only you"].exists)
        assertCanvasPixels(app.descendants(matching: .any)["presenter.preview"].firstMatch)
        app.buttons["presenter.expand"].tap()
        assertCanvasPixels(app.descendants(matching: .any)["presenter.preview"].firstMatch)
        app.buttons["studio.done"].tap()
        assertCanvasPixels(app.descendants(matching: .any)["presenter.preview"].firstMatch)
    }

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
        for _ in 0..<4 { if scene.isHittable { break }; app.descendants(matching: .any)["studio.settings"].firstMatch.swipeUp() }
        scene.tap()
        app.buttons["Warm"].tap()
        app.buttons["presenter.start"].tap()
        XCTAssertTrue(app.buttons["presenter.stop"].waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if app.switches["presenter.camera"].isHittable { break }
            app.descendants(matching: .any)["studio.settings"].firstMatch.swipeDown()
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
        // Exercise the sender teardown race from the report, not just a single
        // start. Private scene/camera intent must survive each handover.
        for _ in 0..<2 {
            let start = app.buttons["presenter.start"]
            waitForHittable(start)
            let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
            wait(for: [enabled], timeout: 10)
            start.tap()
            XCTAssertTrue(app.buttons["presenter.stop"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["presenter.error"].exists)
            app.buttons["presenter.stop"].tap()
        }
    }
    private func open(_ app: XCUIApplication) {
        app.buttons["More call options"].firstMatch.tap()
        app.buttons["Presenter"].firstMatch.tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
        let source = app.buttons["presenter.source"]
        waitForHittable(source); source.tap()
        XCTAssertTrue(app.buttons["Blank canvas"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["Blank canvas"].tap()
    }
    private func assertCanvasPixels(_ canvas: XCUIElement) {
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        let visible = expectation(for: NSPredicate { _, _ in
            let png = canvas.screenshot().pngRepresentation
            guard let source = CGImageSourceCreateWithData(png as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            let width = 32, height = 32
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            return pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                let bytes = raw.bindMemory(to: UInt8.self)
                let bright = stride(from: 0, to: bytes.count, by: 4).filter { bytes[$0] > 25 && bytes[$0 + 1] > 8 }.count
                return bright > width * height / 3
            }
        }, evaluatedWith: canvas)
        let result = XCTWaiter.wait(for: [visible], timeout: 5)
        if result != .completed {
            let crop = XCTAttachment(screenshot: canvas.screenshot())
            crop.name = "Canvas pixel crop"; crop.lifetime = .keepAlways; add(crop)
            let capture = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            capture.name = "Canvas rendering failure"; capture.lifetime = .keepAlways; add(capture)
        }
        XCTAssertEqual(result, .completed)
    }
    private func waitForOrientation(_ app: XCUIApplication, landscape: Bool) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            landscape ? app.frame.width > app.frame.height : app.frame.height > app.frame.width
        }, object: app)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
    private func waitForHittable(_ element: XCUIElement) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }
}
