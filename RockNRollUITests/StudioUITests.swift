import XCTest
import Vision

final class StudioUITests: XCTestCase {
    func testPrejoinPreviewDismissesToJoinWithoutConnecting() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        defer { app.terminate() }
        let check = app.buttons["studio.prejoin"]
        XCTAssertTrue(check.waitForExistence(timeout: 10))
        if !check.isHittable { app.swipeUp() }
        check.tap()
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
        let status = app.descendants(matching: .any)["studio.preview-status"].firstMatch
        XCTAssertTrue(status.label.contains("Only you"))
        XCTAssertFalse(app.buttons["studio.start-video"].exists)
        app.buttons["studio.done"].tap()
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio.done"].exists)
        XCTAssertTrue(app.buttons["Join jam"].exists)
    }
    func testGuestLongPressOpensPrivatePreviewWithoutTogglingMedia() { checkShortcuts(guest: true) }
    func testJamLongPressOpensPrivatePreviewWithoutTogglingMedia() { checkShortcuts(guest: false) }
    func testNativeShareLongPressOpensPresenterWithoutStartingCapture() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
        app.launchEnvironment["CONFERENCE_TEST_STUDIO"] = "1"
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let share = app.buttons["Share screen"].firstMatch
            XCTAssertTrue(share.waitForExistence(timeout: 10))
            share.press(forDuration: 0.7)
            let presenter = app.segmentedControls["studio.panes"].buttons["Presenter"]
            XCTAssertTrue(presenter.waitForExistence(timeout: 5)); XCTAssertTrue(presenter.isSelected)
            XCTAssertFalse(app.buttons["Stop sharing screen"].exists, "Holding Share must not start capture")
            attach("Share hold opens private Presenter")
            app.buttons["studio.done"].tap()
            XCTAssertTrue(app.buttons["Unmute microphone"].firstMatch.exists)
            XCTAssertTrue(app.buttons["Start video"].firstMatch.exists)
        }
        if #available(iOS 27.0, *) {
            app.buttons["Share screen"].firstMatch.tap()
            XCTAssertTrue(app.buttons["Stop sharing screen"].waitForExistence(timeout: 5), "Short tap must retain the sharing action")
            app.buttons["Stop sharing screen"].tap()
            XCTAssertTrue(app.buttons["Share screen"].waitForExistence(timeout: 5))
        }
    }
    func testLiveNativeShareLongPressOpensPresenter() throws {
        continueAfterFailure = false
        guard let invitation = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_TELEMOST_INVITE"] else { throw XCTSkip("Disposable Telemost room required") }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invitation
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Share Shortcut QA"
        #if targetEnvironment(simulator)
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        #endif
        app.launch()
        defer {
            if app.buttons["studio.done"].exists { app.buttons["studio.done"].tap() }
            if app.buttons["Leave"].exists { app.buttons["Leave"].tap() }
            app.terminate()
        }
        let share = app.buttons["Share screen"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 30))
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: share)
        wait(for: [ready], timeout: 20)
        share.press(forDuration: 0.7)
        let presenter = app.segmentedControls["studio.panes"].buttons["Presenter"]
        XCTAssertTrue(presenter.waitForExistence(timeout: 5)); XCTAssertTrue(presenter.isSelected)
        XCTAssertFalse(app.buttons["Stop sharing screen"].exists)
        attach("Live Telemost Share hold opens Presenter")
    }

    private func checkShortcuts(guest: Bool) {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if guest {
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
            app.launchEnvironment["CONFERENCE_TEST_GUEST_SCENARIO"] = "studio"
        } else {
            app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = "rock"
            app.launchEnvironment["CONFERENCE_TEST_STUDIO"] = "1"
        }
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        app.launch()
        let mic = app.buttons["Unmute microphone"].firstMatch
        let cam = app.buttons["Start video"].firstMatch
        XCTAssertTrue(mic.waitForExistence(timeout: 10))
        mic.tap()
        let mute = app.buttons["Mute microphone"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 5)); mute.tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        cam.tap()
        let stop = app.buttons["Stop video"].firstMatch
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.tap()
        XCTAssertTrue(cam.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio.done"].exists, "Short taps opened settings")
        let output = app.descendants(matching: .any)["call.output"].firstMatch
        XCTAssertTrue(output.exists)
        output.press(forDuration: 0.7)
        XCTAssertTrue(app.segmentedControls["studio.audio-sections"].buttons["Devices"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["studio.audio-sections"].buttons["Devices"].isSelected)
        XCTAssertTrue(app.descendants(matching: .any)["studio.output-device"].firstMatch.exists)
        app.buttons["studio.done"].tap()
        mic.press(forDuration: 0.7)
        XCTAssertTrue(app.buttons["Music"].firstMatch.waitForExistence(timeout: 5))
        let settings = app.buttons["studio.microphone-settings"]
        for _ in 0..<3 { if settings.exists { break }; app.swipeUp() }
        XCTAssertFalse(settings.isEnabled)
        app.buttons["studio.done"].tap()
        XCTAssertTrue(mic.waitForExistence(timeout: 5)); XCTAssertTrue(cam.exists)
        cam.press(forDuration: 0.7)
        let preview = app.descendants(matching: .any)["studio.preview-status"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(preview.label.contains("Only you"))
        XCTAssertTrue(app.buttons["studio.start-video"].waitForExistence(timeout: 5))
        attach("Private preview before broadcasting")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["studio.done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["studio.start-video"].isHittable)
        attach("Landscape camera inspector")
        XCUIDevice.shared.orientation = .portrait
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(mic.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["studio.done"].exists)
        XCTAssertTrue(cam.exists)
        XCTAssertFalse(app.buttons["Stop video"].exists)
        XCTAssertFalse(app.buttons["Mute microphone"].exists)
    }

    func testLivePrivateCameraEffectsAndPublishingHandoff() throws {
        let app = try liveApp()
        defer { endLive(app) }
        let camera = app.buttons["Start video"].firstMatch
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        camera.press(forDuration: 0.7)
        let status = app.descendants(matching: .any)["studio.preview-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Only you"))
        let start = app.buttons["studio.start-video"]
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: start)
        wait(for: [ready], timeout: 8)
        let effects = app.buttons["studio.camera-effects"]
        if !effects.isHittable { app.swipeUp() }
        XCTAssertTrue(effects.isEnabled)
        effects.tap()
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let portrait = system.buttons.matching(NSPredicate(format: "label CONTAINS[c] %@", "Portrait")).firstMatch
        XCTAssertTrue(portrait.waitForExistence(timeout: 5), "Private capture did not expose native video effects")
        portrait.tap()
        attach("Native effects while outgoing video is off")
        portrait.tap() // Restore the system preference after qualification.
        // Activating the app alone does not dismiss Apple's effects overlay.
        // Tap its observed empty backdrop before touching the app's Start button.
        system.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2)).tap()
        let closed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: portrait)
        wait(for: [closed], timeout: 5)
        app.activate()
        XCTAssertTrue(status.label.contains("Only you"))
        attach("Private preview after native effects")
        start.tap()
        XCTAssertTrue(app.buttons["Stop video"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Stop video"].firstMatch.press(forDuration: 0.7)
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertTrue(status.label.contains("Visible to jam"))
        attach("Existing guest camera in settings")
        app.buttons["studio.done"].tap()
        let panelClosed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["studio.done"])
        wait(for: [panelClosed], timeout: 5)
        let stop = app.buttons["Stop video"].firstMatch
        let canStop = expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: stop)
        wait(for: [canStop], timeout: 5)
        stop.tap()
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
    }

    func testLiveLeavingWithCameraOnCannotStartSystemPiP() throws {
        let app = try liveApp()
        defer { app.terminate() }
        app.buttons["Start video"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Stop video"].firstMatch.waitForExistence(timeout: 10))
        let ready = expectation(for: NSPredicate(format: "value == %@", "Floating video available"),
            evaluatedWith: app.buttons["More call options"].firstMatch)
        wait(for: [ready], timeout: 8)
        app.buttons["Leave"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 10))
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        let unexpected = expectation(for: NSPredicate(format: "exists == true"), evaluatedWith: pip)
        unexpected.isInverted = true
        wait(for: [unexpected], timeout: 3)
        app.activate()
        XCTAssertTrue(app.buttons["Join jam"].waitForExistence(timeout: 5))
    }

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
        app.buttons["Audio"].firstMatch.tap()
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
        app.buttons["Camera & sound"].firstMatch.tap()
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
        let studio = app.buttons[russian ? "Камера и звук" : "Camera & sound"].firstMatch
        XCTAssertTrue(studio.waitForExistence(timeout: 5)); studio.tap()
        let camera = app.buttons["studio.camera-effects"]
        XCTAssertTrue(camera.waitForExistence(timeout: 5)); XCTAssertFalse(camera.isEnabled)
        app.buttons[russian ? "Звук" : "Audio"].firstMatch.tap()
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
