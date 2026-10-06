import XCTest
import Vision

final class PiPMicrophoneUITests: XCTestCase {
    func testEndedVideoDoesNotReturnAfterLateSourceUpdatesOrBackgrounding() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone.")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "pip-microphone"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer { app.terminate() }
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .windows["PIP-SBInteractionPassThroughView"]
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(pip.waitForExistence(timeout: 5), "The baseline must have working PiP")
        app.activate()
        app.buttons["End test video"].tap()
        for manual in [false, true] {
            if manual { app.buttons["Test microphone in PiP"].tap() }
            XCUIDevice.shared.press(.home)
            let unwanted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: pip)
            unwanted.isInverted = true
            XCTAssertEqual(XCTWaiter.wait(for: [unwanted], timeout: 3), .completed)
            app.activate()
        }
        // Ending one meeting must not disable PiP in a new session.
        app.terminate()
        app.launch()
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        app.activate()
        app.buttons["End test video"].tap()
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "Ended video stays closed after scene/source updates"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testStatusRedrawsInSystemPiPWithoutVideoFrames() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone.")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "pip-microphone"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer { app.terminate() }
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        assertStatus("Aram", in: pip)
        assertStatus("You", in: pip)
        let mutedBadge = badgePixels(in: pip)
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        calculator.activate()
        assertStatus("Ani", in: pip)
        assertStatus("You", in: pip)
        XCTAssertNotEqual(mutedBadge, badgePixels(in: pip), "The compact microphone icon did not update")
        XCTAssertTrue(pip.exists)
        XCTAssertEqual(calculator.state, .runningForeground)
        assertStatus("Mic unavailable", in: pip)
        XCTAssertTrue(pip.exists)
    }

    private func badgePixels(in pip: XCUIElement) -> Data? {
        guard let image = pip.screenshot().image.cgImage else { return nil }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        return image.cropping(to: CGRect(x: width * 0.76, y: height * 0.77,
                                        width: width * 0.2, height: height * 0.17))
            .map { UIImage(cgImage: $0).pngData() } ?? nil
    }

    private func assertStatus(_ text: String, in pip: XCUIElement) {
        let visible = expectation(for: NSPredicate { _, _ in
            guard let image = pip.screenshot().image.cgImage else { return false }
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["en-US"]
            request.recognitionLevel = .accurate
            try? VNImageRequestHandler(cgImage: image).perform([request])
            return request.results?.contains {
                $0.topCandidates(1).first?.string.contains(text) == true
            } == true
        }, evaluatedWith: pip)
        wait(for: [visible], timeout: 15)
        let attachment = XCTAttachment(screenshot: pip.screenshot())
        attachment.name = "Physical PiP · \(text)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
