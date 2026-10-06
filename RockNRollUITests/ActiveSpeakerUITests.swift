import XCTest

final class ActiveSpeakerUITests: XCTestCase {
    private func change(_ app: XCUIApplication, to name: String) {
        let more = app.buttons["More call options"]
        XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
        app.buttons["Test speaker: \(name)"].tap()
    }
    private func assertSpeaker(_ element: XCUIElement, _ name: String?) {
        let predicate = NSPredicate { _, _ in
            let value = [element.label, element.value as? String].compactMap { $0 }.joined(separator: " ")
            return name.map { value.contains($0) } ?? !value.contains("Speaking:")
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 5), .completed)
    }

    func testGuestLandscapeMetadataDoesNotMovePinnedZoomedShare() throws {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-automaticallyHideMeetingControls", "NO"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "speaker"
        app.launch()
        let viewport = app.scrollViews["Shared screen viewport"]
        XCTAssertTrue(viewport.waitForExistence(timeout: 10))
        viewport.pinch(withScale: 2, velocity: 1)
        app.buttons["Pin Ani’s arrangement screen share"].tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let header = app.otherElements["Compact meeting header"]
        let details = app.buttons["Meeting details"]
        let settled = NSPredicate { _, _ in app.frame.width > app.frame.height && header.exists && header.frame.height == 44 && details.isHittable }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)], timeout: 5), .completed)
        let videoFrame = viewport.frame, zoom = try XCTUnwrap(viewport.value as? String)
        for name in ["Aram", "long name", "You"] {
            change(app, to: name)
            assertSpeaker(details, name == "long name" ? "Николай Александрович" : name)
            XCTAssertEqual(header.frame.height, 44)
            XCTAssertEqual(viewport.frame, videoFrame)
            XCTAssertEqual(viewport.value as? String, zoom)
            XCTAssertTrue(app.buttons["Unpin Ani’s arrangement screen share"].exists)
        }
        change(app, to: "Hold"); assertSpeaker(details, nil)
        change(app, to: "Aram"); assertSpeaker(details, nil)
        change(app, to: "Resume"); assertSpeaker(details, "Aram")
        let snapshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); snapshot.name = "Landscape speaker inside unchanged header"; snapshot.lifetime = .keepAlways; add(snapshot)
        app.buttons["Hide controls"].tap()
        XCTAssertFalse(header.exists)
        XCTAssertFalse(app.buttons["Meeting details"].exists)
        viewport.tap()
        XCTAssertTrue(details.waitForExistence(timeout: 5)); assertSpeaker(details, "Aram")
        XCTAssertEqual(viewport.value as? String, zoom)
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 5))
    }

    func testCommunityLandscapeUsesSameSpeakerLayout() {
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-automaticallyHideMeetingControls", "NO"]
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
        app.launchEnvironment["CONFERENCE_TEST_SPEAKER"] = "1"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        change(app, to: "Aram")
        let details = app.buttons["Meeting details"]
        assertSpeaker(details, "Aram")
        XCTAssertEqual(app.otherElements["Compact meeting header"].frame.height, 44)
        change(app, to: "Silence"); assertSpeaker(details, nil)
    }

    func testRussianPiPSpeakerChangesWithoutArrivingVideo() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "speaker-pip"
        app.launch()
        let speaker = app.descendants(matching: .any)["Floating active speaker"]
        for (input, output) in [("Aram", "Aram"), ("long name", "Николай Александрович"), ("You", "Вы")] {
            app.buttons["Test speaker: \(input)"].tap()
            XCTAssertTrue(speaker.waitForExistence(timeout: 5))
            assertSpeaker(speaker, output)
            XCTAssertFalse(speaker.frame.intersects(app.descendants(matching: .any)["Floating microphone status"].frame))
            XCTAssertTrue(app.staticTexts["Static shared screen"].exists)
        }
        let snapshot = XCTAttachment(screenshot: app.screenshot()); snapshot.name = "Russian PiP speaker and microphone status"; snapshot.lifetime = .keepAlways; add(snapshot)
        app.buttons["Test speaker: Hold"].tap()
        XCTAssertFalse(speaker.exists)
        app.buttons["Test speaker: Aram"].tap()
        XCTAssertFalse(speaker.exists)
        app.buttons["Test speaker: Resume"].tap()
        XCTAssertTrue(speaker.waitForExistence(timeout: 5))
        app.buttons["Test speaker: Silence"].tap()
        XCTAssertFalse(speaker.exists)
    }
}
