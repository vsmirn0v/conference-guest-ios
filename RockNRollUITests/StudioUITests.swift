import XCTest

final class StudioUITests: XCTestCase {
    func testGuestStudioKeepsMediaMutedAndSurvivesRotation() { check(guest: true, russian: false) }
    func testJamStudioKeepsMediaMutedAndSurvivesRotation() { check(guest: false, russian: false) }
    func testRussianStudio() { check(guest: true, russian: true) }

    private func check(guest: Bool, russian: Bool) {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        if russian { app.launchArguments += ["-AppleLanguages", "(ru)", "-AppleLocale", "ru_RU"] }
        if guest {
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        } else {
            app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
            app.launchEnvironment["CONFERENCE_TEST_STUDIO"] = "1"
        }
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait }
        app.launch()
        let more = app.buttons[russian ? "Другие действия" : "More call options"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 10)); more.tap()
        let studio = app.buttons[russian ? "Студия" : "Studio"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 5)); studio.tap()
        let camera = app.buttons["studio.camera-effects"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5)); XCTAssertFalse(camera.isEnabled)
        let music = app.buttons[russian ? "Музыка" : "Music"].firstMatch
        if !music.isHittable { app.swipeUp() }
        XCTAssertTrue(music.isHittable); music.tap()
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: music)
        wait(for: [selected], timeout: 5)
        let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        portrait.name = "Studio portrait"; portrait.lifetime = .keepAlways; add(portrait)
        XCUIDevice.shared.orientation = .landscapeLeft
        let done = app.buttons["studio.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); XCTAssertTrue(done.isHittable)
        let landscape = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        landscape.name = "Studio landscape"; landscape.lifetime = .keepAlways; add(landscape)
        XCUIDevice.shared.orientation = .portrait
        done.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons[russian ? "Включить микрофон" : "Unmute microphone"].firstMatch.exists)
        XCTAssertTrue(app.buttons[russian ? "Включить видео" : "Start video"].firstMatch.exists)
    }
}
