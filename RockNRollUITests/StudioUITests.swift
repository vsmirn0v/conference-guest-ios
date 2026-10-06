import XCTest
import Vision

final class StudioUITests: XCTestCase {
    func testLiveGuestSpeakerAndBackgroundPiP() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_STUDIO_REMOTE_SPEAKER"] == "1" else {
            throw XCTSkip("Requires the controlled speaking browser participant")
        }
        let app = try liveApp()
        defer { XCUIDevice.shared.orientation = .portrait; endLive(app) }
        XCUIDevice.shared.orientation = .landscapeLeft
        let details = app.buttons["Meeting details"]
        let speaking = expectation(for: NSPredicate { _, _ in
            (details.value as? String)?.contains("Synthetic Speaker QA") == true
        }, evaluatedWith: details)
        wait(for: [speaking], timeout: 8)
        attach("Live guest landscape speaker")
        XCUIDevice.shared.orientation = .portrait
        let portrait = expectation(for: NSPredicate { _, _ in app.frame.width < app.frame.height }, evaluatedWith: app)
        wait(for: [portrait], timeout: 5)
        let available = expectation(for: NSPredicate(format: "value == %@", "Floating video available"),
            evaluatedWith: app.buttons["More call options"].firstMatch)
        wait(for: [available], timeout: 5)
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        let read = expectation(for: NSPredicate { _, _ in
            guard pip.exists, !pip.frame.isEmpty else { return false }
            guard let image = pip.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["en-US"]
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.contains { $0.topCandidates(1).first?.string.contains("Synthetic") == true } == true
        }, evaluatedWith: pip)
        wait(for: [read], timeout: 5)
        attach("Live guest PiP speaker")
        let seconds = Double(ProcessInfo.processInfo.environment["ROCKNROLL_TEST_PIP_SECONDS"] ?? "20") ?? 20
        XCTAssertTrue((20...180).contains(seconds))
        Thread.sleep(forTimeInterval: seconds)
        XCTAssertTrue(pip.exists)
        attach("Guest PiP after \(Int(seconds)) seconds")
        if seconds >= 60 {
            func contentPixels() -> Data? {
                guard let image = pip.screenshot().image.cgImage else { return nil }
                return image.cropping(to: CGRect(x: CGFloat(image.width) * 0.1,
                    y: CGFloat(image.height) * 0.24, width: CGFloat(image.width) * 0.8,
                    height: CGFloat(image.height) * 0.42))?.dataProvider?.data as Data?
            }
            let first = contentPixels()
            Thread.sleep(forTimeInterval: 2)
            let second = contentPixels()
            XCTAssertNotNil(first); XCTAssertNotNil(second)
            XCTAssertNotEqual(first, second, "Late PiP content froze despite the moving screen-share source")
        }
        app.activate()
        XCTAssertTrue(app.buttons["Leave"].firstMatch.waitForExistence(timeout: 5))
    }
    func testLiveMusicProfilePreservesCaptureIntent() throws {
        let app = try liveApp()
        defer { endLive(app) }
        openStudio(app)
        let music = app.buttons["Music"].firstMatch
        music.tap()
        let selected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: music)
        wait(for: [selected], timeout: 5)
        XCTAssertFalse(app.buttons["studio.camera-effects"].isEnabled)
        let microphoneSettings = app.buttons["studio.microphone-settings"]
        if !microphoneSettings.exists { app.swipeUp() }
        XCTAssertFalse(microphoneSettings.isEnabled)
        XCTAssertFalse(app.staticTexts["studio.error"].exists)
        attach("Physical Studio · Music while muted")
        app.buttons["studio.done"].tap()
        XCTAssertTrue(app.buttons["Start video"].firstMatch.exists)
        app.buttons["Unmute microphone"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Mute microphone"].firstMatch.waitForExistence(timeout: 5))
        openStudio(app)
        XCTAssertTrue(app.buttons["Music"].firstMatch.isSelected)
        XCTAssertFalse(app.buttons["studio.camera-effects"].isEnabled)
        if !microphoneSettings.exists { app.swipeUp() }
        XCTAssertTrue(microphoneSettings.isEnabled)
        attach("Physical Studio · Music after unmute")
        app.buttons["studio.done"].tap()
        app.buttons["Mute microphone"].firstMatch.tap()
    }

    func testLiveSystemCameraEffects() throws {
        let app = try liveApp()
        defer { endLive(app) }
        app.buttons["Start video"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Stop video"].firstMatch.waitForExistence(timeout: 8))
        openStudio(app)
        let effects = app.buttons["studio.camera-effects"]
        XCTAssertTrue(effects.isEnabled)
        effects.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let panel = system.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Portrait")).firstMatch
        XCTAssertTrue(panel.waitForExistence(timeout: 5), "System effects panel not exposed: \(system.debugDescription)")
        panel.tap()
        print("PHYSICAL_STUDIO_EFFECT: Portrait toggled; observe remote camera now")
        Thread.sleep(forTimeInterval: 6)
        attach("Physical system camera effects")
        panel.tap() // Restore the user's system-effect preference.
        app.activate()
        if app.buttons["studio.done"].exists { app.buttons["studio.done"].tap() }
        XCTAssertTrue(app.buttons["Stop video"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["Stop video"].firstMatch.tap()
    }

    private func liveApp() throws -> XCUIApplication {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires physical capture and native system controls")
        #endif
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_STUDIO_INVITE"] else {
            throw XCTSkip("Opt-in physical Studio meeting")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Device Studio QA"
        app.launch()
        XCTAssertTrue(app.buttons["Unmute microphone"].firstMatch.waitForExistence(timeout: 15))
        return app
    }
    private func openStudio(_ app: XCUIApplication) {
        app.buttons["More call options"].firstMatch.tap()
        app.buttons["Studio"].firstMatch.tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
    }
    private func endLive(_ app: XCUIApplication) {
        if app.buttons["studio.done"].exists { app.buttons["studio.done"].tap() }
        if app.buttons["Leave"].firstMatch.exists { app.buttons["Leave"].firstMatch.tap() }
        app.terminate()
    }
    private func attach(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
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
