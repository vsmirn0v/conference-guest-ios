import XCTest

final class MacAudioDeviceUITests: XCTestCase {
    func testSeparateDeviceListsAndSelectionInEnglishAndRussian() {
        for language in ["en", "ru"] {
            let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
            app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
            app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = "mac-audio"
            app.launch()
            let list = app.tables["Mac audio device list"]
            XCTAssertTrue(list.waitForExistence(timeout: 10))
            let output = list.cells["Mac audio output 20"]
            let input = list.cells["Mac audio input 20"]
            XCTAssertTrue(output.isHittable)
            XCTAssertTrue(input.isHittable)
            XCTAssertTrue(list.cells["Mac audio output 10"].isSelected)
            XCTAssertTrue(list.cells["Mac audio input 30"].isSelected)
            XCTAssertFalse(list.cells["Mac audio output 30"].exists)
            XCTAssertFalse(list.cells["Mac audio input 10"].exists)
            output.tap()
            XCTAssertTrue(output.isSelected)
            XCTAssertTrue(list.cells["Mac audio input 30"].isSelected)
            input.tap()
            XCTAssertTrue(input.isSelected)
            XCTAssertTrue(output.isSelected)
            let note = language == "ru"
                ? "Выбор меняет системные аудиоустройства Mac, в том числе для других приложений."
                : "Selections change your Mac’s system audio devices for other apps too."
            XCTAssertTrue(app.staticTexts[note].exists)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Mac audio device lists — \(language)"
            attachment.lifetime = .keepAlways
            add(attachment)
            app.terminate()
        }
    }
}
