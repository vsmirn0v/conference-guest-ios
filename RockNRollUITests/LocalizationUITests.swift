import XCTest

final class LocalizationUITests: XCTestCase {
    private func launch(_ fixture: String? = nil, layout: String? = nil, language: String = "ru") -> XCUIApplication {
        let app = XCUIApplication(bundleIdentifier: "dev.vsmirn0v.conferenceguest")
        app.launchArguments = ["-AppleLanguages", "(\(language))", "-AppleLocale", "en_US"]
        app.launchEnvironment["CONFERENCE_TEST_SYNC_FIXTURE"] = "available"
        if let fixture { app.launchEnvironment["CONFERENCE_TEST_UI_FIXTURE"] = fixture }
        if let layout { app.launchEnvironment["CONFERENCE_TEST_LAYOUT_FIXTURE"] = layout }
        app.launch()
        return app
    }
    private func attach(_ app: XCUIApplication, _ title: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = title; image.lifetime = .keepAlways; add(image)
    }
    private func assertVisible(_ element: XCUIElement, app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(element.isHittable, element.label)
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, window.minX - 1)
        XCTAssertLessThanOrEqual(element.frame.maxX, window.maxX + 1)
    }
    func testRussianHomeSettingsAndEnglishRelaunch() {
        let app = launch()
        assertVisible(app.textFields["Ссылка-приглашение"], app: app)
        XCTAssertTrue(app.buttons["Войти в джем"].exists)
        app.buttons["Профиль и настройки"].tap()
        XCTAssertTrue(app.navigationBars["Профиль и настройки"].waitForExistence(timeout: 10))
        assertVisible(app.textFields["Ваше имя"], app: app)
        assertVisible(app.buttons["Выбрать свой контакт"], app: app)
        XCTAssertTrue(app.staticTexts["Совместимый сайт встреч"].exists)
        attach(app, "Russian settings")
        app.navigationBars.buttons["Готово"].tap()
        attach(app, "Russian home")
        app.terminate()
        let english = launch(language: "en")
        XCTAssertTrue(english.textFields["Invitation link"].waitForExistence(timeout: 10))
        XCTAssertTrue(english.buttons["Profile and settings"].exists)
    }
    func testRussianConversationAndContentStayDistinctAcrossRotation() {
        let app = launch("conversation")
        defer { XCUIDevice.shared.orientation = .portrait }
        let modes = app.segmentedControls["Режим беседы"]
        XCTAssertTrue(modes.waitForExistence(timeout: 10))
        XCTAssertTrue(modes.buttons["Чат"].isSelected)
        XCTAssertTrue(app.buttons["Отправить сообщение"].exists)
        let draft = app.textViews["Сообщение в чат"]
        draft.tap(); draft.typeText("Ani — проверка %@")
        for orientation: UIDeviceOrientation in [.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            assertVisible(app.buttons["Выйти"], app: app)
            assertVisible(app.buttons["Закрыть беседу"], app: app)
            XCTAssertTrue((draft.value as? String)?.contains("Ani — проверка %@") == true)
        }
        app.buttons["Отправить сообщение"].tap()
        let hideKeyboard = app.keyboards.buttons["Скрыть клавиатуру"]
        if hideKeyboard.exists { hideKeyboard.tap() }
        XCTAssertTrue(modes.waitForExistence(timeout: 5))
        modes.buttons["Текст"].tap()
        XCTAssertTrue(app.textViews["Расшифровка джема"].waitForExistence(timeout: 10))
        XCTAssertTrue((app.textViews["Расшифровка джема"].value as? String)?.contains("We will meet Friday at six thirty.") == true)
        modes.buttons["Пропущено"].tap()
        XCTAssertTrue(app.staticTexts["Другой звонок"].waitForExistence(timeout: 10))
        attach(app, "Russian missed sections")
    }
    func testRussianCallAndParticipantControlsFitRotation() {
        let app = launch(layout: "rock")
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation: UIDeviceOrientation in [.portrait, .landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            for title in ["Выйти", "Включить микрофон", "Включить видео", "Транслировать экран", "Другие действия"] {
                assertVisible(app.buttons[title], app: app)
            }
        }
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Музыканты")).firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Музыканты"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Rock QA (вы)"].exists)
        XCTAssertTrue(app.staticTexts["Микрофон выкл. · Видео выкл."].exists)
        attach(app, "Russian participants")
    }
    func testRussianSharingPreviewUsesTranslatedControls() throws {
        let app = launch(layout: "local-share")
        let preview = app.buttons["Увеличить предпросмотр трансляции"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Остановить свою трансляцию экрана"].exists)
        preview.tap()
        assertVisible(app.buttons["Закрыть предпросмотр"], app: app)
        assertVisible(app.buttons["Остановить трансляцию"], app: app)
        let refresh = try XCTUnwrap(app.buttons.matching(identifier: "Обновить предпросмотр")
            .allElementsBoundByIndex.first { $0.isHittable })
        assertVisible(refresh, app: app)
        attach(app, "Russian local sharing preview")
    }
}
