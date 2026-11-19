import Foundation
import XCTest
@testable import ConferenceCore

final class LocalizationTests: XCTestCase {
    func testRussianConnectionErrorsArePackagedWithTheCore() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "ru", withExtension: "lproj"))
        let russian = try XCTUnwrap(Bundle(url: url))
        XCTAssertEqual(russian.localizedString(forKey: "Enter a complete HTTPS meeting invitation link.", value: nil, table: nil),
                       "Введите полную HTTPS-ссылку-приглашение на встречу.")
        XCTAssertEqual(russian.localizedString(forKey: "This message is too long to send. Shorten it and try again.", value: nil, table: nil),
                       "Сообщение слишком длинное. Сократите его и попробуйте ещё раз.")
    }
}

extension LocalizationTests {
    func testInterfaceLanguagesResolveInsideThePackage() throws {
        for code in ["en", "ru", "es", "ar", "hi", "fr", "de", "zh-Hans", "id"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: code, withExtension: "lproj"), code)
            let resource = try XCTUnwrap(Bundle(url: url))
            let key = "Enter a complete HTTPS meeting invitation link."
            let text = resource.localizedString(forKey: key, value: "__missing__", table: nil)
            XCTAssertNotEqual(text, "__missing__", code)
            if code != "en" { XCTAssertNotEqual(text, key, code) }
        }
        XCTAssertEqual(Localization.englishLanguageName(for: "ar-EG"), "Arabic")
        XCTAssertEqual(Localization.englishLanguageName(for: "de-DE"), "German")
        XCTAssertEqual(Localization.englishLanguageName(for: "zh-Hans"), "Simplified Chinese")
        XCTAssertEqual(Localization.formattingLocale(language: "zh-Hans", region: Locale(identifier: "en_US")).language.script?.identifier, "Hans")
    }
}
