import XCTest

final class ParticipantMediaBadgeUITests: XCTestCase {
    func testCaptionsFitEnglishAndRussianThroughRotation() {
        defer { XCUIDevice.shared.orientation = .portrait }
        for language in ["en", "ru"] {
            let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
            app.launchArguments = ["-AppleLanguages", "(\(language))"]
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "participant-badges"
            app.launch()
            let badges = app.staticTexts.matching(identifier: "Participant name")
            XCTAssertTrue(badges.firstMatch.waitForExistence(timeout: 10))
            for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
                XCUIDevice.shared.orientation = orientation
                let landscape = orientation == .landscapeLeft
                let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                    let tile = app.otherElements["badge-tile.0"]
                    return (app.frame.width > app.frame.height) == landscape && tile.exists &&
                        (tile.frame.width > tile.frame.height) == landscape
                }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
                XCTAssertEqual(badges.count, 4)
                let values = badges.allElementsBoundByIndex.compactMap { $0.value as? String }
                XCTAssertEqual(values.filter { $0 == (language == "ru" ? "Микрофон выключен" : "Microphone off") }.count, 2)
                XCTAssertEqual(values.filter { $0 == (language == "ru" ? "Микрофон включён" : "Microphone on") }.count, 1)
                XCTAssertEqual(values.filter { $0 == (language == "ru" ? "Говорит" : "Speaking") }.count, 1)
                for badge in badges.allElementsBoundByIndex {
                    XCTAssertGreaterThan(badge.frame.width, 38)
                    XCTAssertTrue(app.windows.firstMatch.frame.contains(badge.frame))
                    XCTAssertGreaterThan(badge.label.count, 30)
                }
                let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                attachment.name = "Participant status \(language) \(orientation.rawValue)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
            app.terminate()
        }
    }
}
