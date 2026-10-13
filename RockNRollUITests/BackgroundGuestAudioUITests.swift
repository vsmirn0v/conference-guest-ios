import XCTest
import Vision

/// Opt-in live test. An independent browser unmutes/joins only after HOME.
/// Read guest-media-recovery.jsonl for background RTP energy/sample evidence.
final class BackgroundGuestAudioUITests: XCTestCase {
    func testGuestShareRestartRecoversInsideBackgroundPiP() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone")
        #endif
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BACKGROUND_SHARE_INVITE"] else {
            throw XCTSkip("Disposable guest room with the controlled LIVE SHARE / FRAME browser fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Background PiP QA"
        app.launchEnvironment["CONFERENCE_TEST_MEDIA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_CAMERA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_APP_AUDIO_SESSION"] = "1"
        app.launch()
        defer { app.activate(); if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 50))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Floating video available"),
                                             object: app.buttons["More call options"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 15))
        assertMovingFixture(in: pip)
        print("GUEST_PIP_STOP_SHARE \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(pip.exists, "A temporary share gap must preserve system PiP")
        attach(pip, name: "Background share gap")
        print("GUEST_PIP_RESTART_SHARE \(Date().timeIntervalSince1970)")
        assertMovingFixture(in: pip)
        // XCTest classifies an app with active PiP as foreground even when its
        // UIApplication state is background. Verify that state in the trace.
        XCTAssertTrue(pip.exists)
        attach(pip, name: "Share restarted without foregrounding")
        app.activate()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 15))
        app.buttons["Leave"].tap()
        XCUIDevice.shared.press(.home)
        let unwanted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
        unwanted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unwanted], timeout: 3), .completed)
    }

    private func assertMovingFixture(in pip: XCUIElement) {
        var first: Int?
        let moving = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard pip.exists, let image = pip.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]; request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image).perform([request])
            guard let line = request.results?.compactMap({ $0.topCandidates(1).first?.string })
                .first(where: { $0.hasPrefix("FRAME") }),
                  let frame = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) else { return false }
            if let first { return frame != first }
            first = frame; return false
        }, object: pip)
        XCTAssertEqual(XCTWaiter.wait(for: [moving], timeout: 25), .completed, "PiP must show fresh fixture frame numbers")
    }
    private func attach(_ element: XCUIElement, name: String) {
        let attachment = XCTAttachment(screenshot: element.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testNewRemoteAudioWhileBackgrounded() throws {
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BACKGROUND_AUDIO_INVITE"] else {
            throw XCTSkip("Authorized disposable guest room with a controlled audio sender")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Background audio QA"
        app.launchEnvironment["CONFERENCE_TEST_MEDIA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_DIRECT_MEDIA"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_APP_AUDIO_SESSION"] = "1"
        app.launch()
        defer { app.activate(); if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 50))
        XCUIDevice.shared.press(.home)
        print("BACKGROUND_AUDIO_HOME \(Date().timeIntervalSince1970)")
        Thread.sleep(forTimeInterval: 60)
        XCTAssertNotEqual(app.state, .notRunning)
        print("BACKGROUND_AUDIO_RETURN \(Date().timeIntervalSince1970)")
        app.activate()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 15))
    }
}
