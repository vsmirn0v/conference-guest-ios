import XCTest
import Vision

final class PiPMicrophoneUITests: XCTestCase {
    func testStatusRedrawsInSystemPiPWithoutVideoFrames() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("System video-call PiP requires a physical iPhone.")
        #endif
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "pip-microphone"
        app.launchEnvironment["CONFERENCE_TEST_RESET_FLOATING_VIDEO"] = "1"
        app.launch()
        defer { app.terminate() }
        app.buttons["Test microphone in PiP"].tap()
        XCUIDevice.shared.press(.home)
        let pip = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .windows["PIP-SBInteractionPassThroughView"]
        XCTAssertTrue(pip.waitForExistence(timeout: 5))
        assertStatus("Muted", in: pip)
        assertStatus("Aram", in: pip)
        let calculator = XCUIApplication(bundleIdentifier: "com.apple.calculator")
        calculator.activate()
        assertStatus("Mic on", in: pip)
        assertStatus("Ani", in: pip)
        XCTAssertTrue(pip.exists)
        XCTAssertEqual(calculator.state, .runningForeground)
        assertStatus("Mic unavailable", in: pip)
        XCTAssertTrue(pip.exists)
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
        wait(for: [visible], timeout: 8)
        let attachment = XCTAttachment(screenshot: pip.screenshot())
        attachment.name = "Physical PiP · \(text)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
