import ImageIO
import XCTest

final class SharedTextUITests: XCTestCase {
    func testCapturedShareRemainsFullCanvasAndVisibleAcrossRotationWithUsableMeetingControls() {
        let app = launch()
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        let entry = app.buttons["Select shared text"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        let view = app.buttons["call.view"], more = app.buttons["call.more"]
        XCTAssertEqual(entry.frame.midY, view.frame.midY, accuracy: 1, "OCR must share View/More's row")
        XCTAssertEqual(entry.frame.midY, more.frame.midY, accuracy: 1)
        XCTAssertGreaterThanOrEqual(entry.frame.width, 44); XCTAssertGreaterThanOrEqual(entry.frame.height, 44)
        entry.tap()
        let live = app.buttons["Return to live share"]
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        let canvas = app.scrollViews["Captured image viewport"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 5))
        assertPixels(canvas)
        let fit = app.buttons["Fit captured image"]
        fit.tap()
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let landscape = orientation != .portrait
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                (app.frame.width > app.frame.height) == landscape
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 6), .completed)
            XCTAssertGreaterThan(canvas.frame.width, app.frame.width * 0.90, "Snapshot must use the live canvas width")
            XCTAssertGreaterThan(canvas.frame.height, app.frame.height * 0.90, "Header/footer must not shrink the captured image")
            assertPixels(canvas)
            let microphone = app.buttons["call.microphone"].exists ? app.buttons["call.microphone"] : app.buttons["Unmute microphone"]
            for control in [live, fit, app.buttons["Capture current shared frame"], app.buttons["Captured share more"], microphone] {
                XCTAssertTrue(control.isHittable, control.identifier)
                XCTAssertGreaterThanOrEqual(control.frame.width, 43, control.identifier)
                XCTAssertGreaterThanOrEqual(control.frame.height, 43, control.identifier)
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "Full captured share \(orientation.rawValue)"; shot.lifetime = .keepAlways; add(shot)
        }
        // Tapping aspect-fit margin must not dismiss this temporary mode.
        fit.tap()
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.10, dy: 0.25)).tap()
        XCTAssertTrue(live.exists)
        app.buttons["Captured share more"].tap()
        let actions = app.descendants(matching: .any)["meeting.actions.list"].firstMatch
        XCTAssertTrue(actions.waitForExistence(timeout: 5), "More must present over the captured canvas")
        let done = app.buttons["reactions.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        XCTAssertTrue(live.waitForExistence(timeout: 5))
        live.tap()
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        XCTAssertFalse(canvas.exists)
    }

    private func launch() -> XCUIApplication {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US", "-automaticallyHideMeetingControls", "NO"]
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-call"
        app.launch()
        return app
    }
    private func assertPixels(_ canvas: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let pixelsReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let source = CGImageSourceCreateWithData(canvas.screenshot().pngRepresentation as CFData, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return false }
            let side = 24
            var pixels = [UInt8](repeating: 0, count: side * side * 4)
            return pixels.withUnsafeMutableBytes { raw in
                guard let context = CGContext(data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
                let bytes = raw.bindMemory(to: UInt8.self)
                // The synthetic share is a grey checkerboard. Sample its middle,
                // away from glass controls, so their pixels cannot hide a black image.
                var nonblack = 0
                for y in 8..<16 {
                    for x in 4..<20 {
                        let offset = (y * side + x) * 4
                        if bytes[offset] > 35 && bytes[offset + 1] > 35 && bytes[offset + 2] > 35 { nonblack += 1 }
                    }
                }
                return nonblack > 24
            }
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [pixelsReady], timeout: 8), .completed,
            "Captured image must still render after zoom/rotation", file: file, line: line)
    }
}
