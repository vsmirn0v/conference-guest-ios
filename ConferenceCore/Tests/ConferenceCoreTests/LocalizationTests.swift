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
