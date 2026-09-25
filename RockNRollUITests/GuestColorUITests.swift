import CoreGraphics
import XCTest

final class GuestColorUITests: XCTestCase {
    func testStudioRangeRampKeepsBlacksAndWhitesInTheMainView() {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "guest-color"
        app.launch()
        let original = app.otherElements["Original video"]
        let corrected = app.otherElements["Corrected video"]
        XCTAssertTrue(original.waitForExistence(timeout: 10))
        XCTAssertTrue(corrected.waitForExistence(timeout: 10))
        let ready = expectation(for: NSPredicate(format: "value == %@", "Rendered"), evaluatedWith: corrected)
        wait(for: [ready], timeout: 5)
        let image = XCUIScreen.main.screenshot().image.cgImage!
        let screenWidth = app.windows.firstMatch.frame.width
        let originalBlack = brightness(in: image, at: CGPoint(x: original.frame.minX + original.frame.width / 6,
                                                               y: original.frame.midY), screenWidth: screenWidth)
        let correctedBlack = brightness(in: image, at: CGPoint(x: corrected.frame.minX + corrected.frame.width / 6,
                                                                y: corrected.frame.midY), screenWidth: screenWidth)
        let originalWhite = brightness(in: image, at: CGPoint(x: original.frame.maxX - original.frame.width / 6,
                                                               y: original.frame.midY), screenWidth: screenWidth)
        let correctedWhite = brightness(in: image, at: CGPoint(x: corrected.frame.maxX - corrected.frame.width / 6,
                                                                y: corrected.frame.midY), screenWidth: screenWidth)
        XCTAssertGreaterThan(originalBlack, correctedBlack + 8, "Video-range black must be black in the main view")
        XCTAssertGreaterThan(correctedWhite, originalWhite + 8, "Video-range white must fill the display range")
    }

    private func brightness(in image: CGImage, at point: CGPoint, screenWidth: CGFloat) -> Int {
        let scale = CGFloat(image.width) / screenWidth
        let crop = CGRect(x: (point.x * scale).rounded(), y: (point.y * scale).rounded(), width: 1, height: 1)
        guard let pixel = image.cropping(to: crop) else { XCTFail("Pixel is outside screenshot"); return -1 }
        var rgba = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &rgba, width: 1, height: 1, bitsPerComponent: 8,
                                      bytesPerRow: 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            XCTFail("Could not decode screenshot pixel"); return -1
        }
        context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (Int(rgba[0]) + Int(rgba[1]) + Int(rgba[2])) / 3
    }
}
