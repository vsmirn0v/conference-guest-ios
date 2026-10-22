import XCTest
import Vision

/// Opt-in live test. An independent browser unmutes/joins only after HOME.
/// Read guest-media-recovery.jsonl for background RTP energy/sample evidence.
final class BackgroundGuestAudioUITests: XCTestCase {
    func testBoundedGuestAudioAndPiPActivityThenLeave() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Physical activity/cleanup qualification")
        #endif
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BOUNDED_PROFILE"] == "1",
              let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BACKGROUND_SHARE_INVITE"] else {
            throw XCTSkip("Opt-in two short activity intervals with a controlled share")
        }
        executionTimeAllowance = 300
        continueAfterFailure = false
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-experiments.firstBackgroundPiP", "NO", "-experiments.backgroundAudioJoin", "NO"]
        app.launchEnvironment["CONFERENCE_TEST_INVITE"] = invite
        app.launchEnvironment["CONFERENCE_TEST_NAME"] = "Bounded activity QA"
        app.launchEnvironment["CONFERENCE_TEST_MEDIA_TRACE"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launchEnvironment["CONFERENCE_TEST_APP_AUDIO_SESSION"] = "1"
        app.launch()
        defer { app.activate(); if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Unmute microphone"].waitForExistence(timeout: 50))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Floating video available"),
                                             object: app.buttons["call.reactions"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        app.openMeetingMore(.view)
        app.meetingActionButton("Audio only").tap()
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        calculator.activate()
        print("GUEST_PROFILE_AUDIO \(Date().timeIntervalSince1970)"); fflush(stdout)
        Thread.sleep(forTimeInterval: 80)
        app.activate()
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        app.openMeetingMore(.view)
        app.meetingActionButton("All video").tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "Floating video available"),
            object: app.buttons["call.reactions"])], timeout: 35), .completed)
        calculator.activate()
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 15)); assertMovingFixture(in: pip)
        print("GUEST_PROFILE_PIP \(Date().timeIntervalSince1970)"); fflush(stdout)
        Thread.sleep(forTimeInterval: 80)
        assertMovingFixture(in: pip)
        XCTAssertEqual(calculator.state, .runningForeground)
        app.activate()
        XCTAssertTrue(app.buttons["Unmute microphone"].exists)
        app.buttons["Leave"].tap(); calculator.activate()
        print("GUEST_PROFILE_LEFT \(Date().timeIntervalSince1970)"); fflush(stdout)
        let unwanted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
        unwanted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unwanted], timeout: 15), .completed)
    }

    func testRestoreNetworkingAfterInterruptedOutageCheck() throws {
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_RESTORE_NETWORK"] == "1" else {
            throw XCTSkip("Recovery only after this test suite changed device networking")
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        for _ in 0..<6 where !settings.switches["Airplane Mode"].exists {
            guard settings.navigationBars.buttons.firstMatch.exists else { break }
            settings.navigationBars.buttons.firstMatch.tap()
        }
        let airplane = settings.switches["Airplane Mode"]
        XCTAssertTrue(airplane.waitForExistence(timeout: 5))
        if airplane.value as? String != "0" { airplane.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(airplane.value as? String, "0")
        settings.cells.containing(.staticText, identifier: "Wi-Fi").firstMatch.tap()
        let wifi = settings.switches["Wi-Fi"]
        XCTAssertTrue(wifi.waitForExistence(timeout: 5))
        if wifi.value as? String != "1" { wifi.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() }
        XCTAssertEqual(wifi.value as? String, "1")
    }
    func testGuestShareRestartRecoversInsideBackgroundPiP() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone")
        #endif
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BACKGROUND_SHARE_INVITE"] else {
            throw XCTSkip("Disposable guest room with the controlled LIVE SHARE / FRAME browser fixture")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-experiments.firstBackgroundPiP", "NO", "-experiments.backgroundAudioJoin", "NO"]
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
                                             object: app.buttons["call.reactions"])
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 35), .completed)
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 15))
        assertMovingFixture(in: pip)
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SHARE_HANDOVER"] == "1" { assertSender("A", in: pip) }
        print("GUEST_PIP_STOP_SHARE \(Date().timeIntervalSince1970)"); fflush(stdout)
        Thread.sleep(forTimeInterval: 10)
        XCTAssertTrue(pip.exists, "A temporary share gap must preserve system PiP")
        attach(pip, name: "Background share gap")
        print("GUEST_PIP_RESTART_SHARE \(Date().timeIntervalSince1970)"); fflush(stdout)
        assertMovingFixture(in: pip)
        // XCTest classifies an app with active PiP as foreground even when its
        // UIApplication state is background. Verify that state in the trace.
        XCTAssertTrue(pip.exists)
        attach(pip, name: "Share restarted without foregrounding")
        if ProcessInfo.processInfo.environment["ROCKNROLL_TEST_SHARE_HANDOVER"] == "1" {
            assertSender("B", in: pip)
            print("GUEST_PIP_DIRECT_HANDOVER \(Date().timeIntervalSince1970)"); fflush(stdout)
            assertSender("A", in: pip)
            assertMovingFixture(in: pip)
            attach(pip, name: "Direct presenter handover without foregrounding")
        }
        app.activate()
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 15))
        app.buttons["Leave"].tap()
        XCUIDevice.shared.press(.home)
        let unwanted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
        unwanted.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [unwanted], timeout: 3), .completed)
    }

    func testFirstRemoteShareCanStartExperimentalPiPWhileBackgrounded() throws {
        try firstRemoteShare(experimental: true)
    }

    func testGuestPiPSurvivesWiFiCellularTransition() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("USB-connected iPhone with cellular data required")
        #endif
        guard ProcessInfo.processInfo.environment["ROCKNROLL_TEST_NETWORK_SWITCH"] == "1",
              let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_BACKGROUND_SHARE_INVITE"] else {
            throw XCTSkip("Explicit opt-in required to change device Wi-Fi temporarily")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-experiments.firstBackgroundPiP", "NO", "-experiments.backgroundAudioJoin", "NO"]
        app.launchEnvironment = ["CONFERENCE_TEST_INVITE": invite, "CONFERENCE_TEST_NAME": "Network PiP QA",
            "CONFERENCE_TEST_MEDIA_TRACE": "1", "CONFERENCE_TEST_CAMERA_TRACE": "1",
            "CONFERENCE_TEST_RESET_FLOATING_VIDEO": "1"]
        app.launch()
        defer { app.activate(); if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        guard app.buttons["Unmute microphone"].waitForExistence(timeout: 50) else {
            XCTFail("A connected meeting is required before changing Wi-Fi"); return
        }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Floating video available"),
                                             object: app.buttons["call.reactions"])
        guard XCTWaiter.wait(for: [ready], timeout: 35) == .completed else {
            XCTFail("A decoded video baseline is required before backgrounding"); return
        }
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        settings.launch()
        for _ in 0..<6 where !settings.switches["Airplane Mode"].exists {
            guard settings.navigationBars.buttons.firstMatch.exists else { break }
            settings.navigationBars.buttons.firstMatch.tap()
        }
        guard settings.switches["Airplane Mode"].value as? String == "0" else {
            throw XCTSkip("Preserve the owner's current Airplane Mode setting")
        }
        settings.cells.containing(.staticText, identifier: "Wi-Fi").firstMatch.tap()
        let wifi = settings.switches["Wi-Fi"]
        guard wifi.waitForExistence(timeout: 5), wifi.value as? String == "1" else {
            throw XCTSkip("Preserve the owner's current Wi-Fi setting")
        }
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        guard pip.waitForExistence(timeout: 15) else { XCTFail("No baseline PiP"); return }
        assertMovingFixture(in: pip)
        defer { if wifi.value as? String != "1" { wifi.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap() } }
        wifi.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(wifi.value as? String, "0")
        print("GUEST_CELLULAR_PIP \(Date().timeIntervalSince1970)"); fflush(stdout)
        Thread.sleep(forTimeInterval: 15)
        assertMovingFixture(in: pip); assertSender("A", in: pip)
        wifi.coordinate(withNormalizedOffset: .init(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(wifi.value as? String, "1")
        print("GUEST_WIFI_PIP \(Date().timeIntervalSince1970)"); fflush(stdout)
        Thread.sleep(forTimeInterval: 10)
        assertMovingFixture(in: pip); assertSender("A", in: pip)
        attach(pip, name: "Moving PiP after Wi-Fi cellular Wi-Fi transition")
    }

    func testFirstRemoteShareDoesNotOpenPiPByDefault() throws {
        try firstRemoteShare(experimental: false)
    }

    private func firstRemoteShare(experimental: Bool) throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Actual first-time AVKit acceptance requires a physical iPhone")
        #endif
        guard let invite = ProcessInfo.processInfo.environment["ROCKNROLL_TEST_FIRST_PIP_INVITE"] else {
            throw XCTSkip("Disposable guest room initially without any camera or share")
        }
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
            "-experiments.firstBackgroundPiP", "NO", "-experiments.backgroundAudioJoin", "NO"]
        app.launchEnvironment = ["CONFERENCE_TEST_INVITE": invite, "CONFERENCE_TEST_NAME": "First background PiP QA",
            "CONFERENCE_TEST_MEDIA_TRACE": "1", "CONFERENCE_TEST_CAMERA_TRACE": "1",
            "CONFERENCE_TEST_RESET_FLOATING_VIDEO": "1", "CONFERENCE_EXPERIMENT_BACKGROUND_PIP": experimental ? "1" : "0"]
        app.launch()
        defer { app.activate(); if app.buttons["Leave"].exists { app.buttons["Leave"].tap() } }
        XCTAssertTrue(app.buttons["Leave"].waitForExistence(timeout: 50))
        XCTAssertTrue(app.buttons["Unmute microphone"].firstMatch.waitForExistence(timeout: 20))
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        calculator.activate()
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard").windows["PIP-SBInteractionPassThroughView"]
        let premature = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
        premature.isInverted = true
        guard XCTWaiter.wait(for: [premature], timeout: 5) == .completed else {
            XCTFail("The first-start test must begin without an existing PiP window"); return
        }
        print("GUEST_FIRST_PIP_START_SHARE enabled=\(experimental) \(Date().timeIntervalSince1970)"); fflush(stdout)
        if !experimental {
            let unwanted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
            unwanted.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [unwanted], timeout: 15), .completed)
            XCTAssertEqual(calculator.state, .runningForeground)
            return
        }
        guard pip.waitForExistence(timeout: 25) else {
            XCTFail("A first remote share must request actual system PiP"); return
        }
        assertMovingFixture(in: pip)
        assertSender("A", in: pip)
        XCTAssertEqual(calculator.state, .runningForeground, "PiP must not replace the other foreground app")
        attach(pip, name: "Experimental first share opened PiP from background")
    }

    private func assertSender(_ sender: String, in pip: XCUIElement) {
        let matching = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard pip.exists, let image = pip.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]; request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.contains { $0.topCandidates(1).first?.string.contains("SENDER " + sender) == true } == true
        }, object: pip)
        XCTAssertEqual(XCTWaiter.wait(for: [matching], timeout: 25), .completed,
                       "PiP must display pixels from sender \(sender)")
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
