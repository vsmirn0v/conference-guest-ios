import Foundation
import XCTest
@testable import RockNRoll

final class LocalizationTests: XCTestCase {
    private func language(_ code: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: code, ofType: "lproj"))
        return try XCTUnwrap(Bundle(path: path))
    }
    private func catalog(_ bundle: Bundle, _ suffix: String) throws -> [String: Any] {
        let url = try XCTUnwrap(bundle.url(forResource: "Localizable", withExtension: suffix))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }
    func testRussianCatalogCoversEnglishCopyAndFormatArguments() throws {
        let english = try catalog(language("en"), "strings") as! [String: String]
        let russian = try catalog(language("ru"), "strings") as! [String: String]
        XCTAssertEqual(Set(english.keys), Set(russian.keys))
        let format = try NSRegularExpression(pattern: #"%(?:\d+\$)?(?:@|ld|lld|d)"#)
        func placeholders(_ value: String) -> [String] {
            let source = value as NSString
            return format.matches(in: value, range: NSRange(location: 0, length: source.length))
                .map { source.substring(with: $0.range) }.sorted()
        }
        for (key, value) in english {
            let translated = try XCTUnwrap(russian[key])
            XCTAssertFalse(translated.isEmpty, key)
            XCTAssertEqual(placeholders(value), placeholders(translated), key)
        }
        XCTAssertEqual(Set(try catalog(language("en"), "stringsdict").keys),
                       Set(try catalog(language("ru"), "stringsdict").keys))
    }
    func testRussianPluralFormsUseFoundationRules() throws {
        let ru = try language("ru")
        for (count, ending) in [(0, "участников"), (1, "участник"), (2, "участника"), (5, "участников"),
                                (11, "участников"), (21, "участник"), (22, "участника"), (25, "участников"),
                                (101, "участник"), (111, "участников")] {
            XCTAssertEqual(Localization.text("%ld participants", arguments: [count], bundle: ru,
                                              locale: Locale(identifier: "ru_RU")), "\(count) \(ending)")
        }
        let locale = Localization.formattingLocale(language: "ru", region: Locale(identifier: "en_US"))
        XCTAssertEqual(locale.regionCode, "US")
        XCTAssertEqual(Localization.text("Chat, %ld unread", arguments: [2], bundle: ru, locale: locale),
                       "Чат, 2 непрочитанных сообщения")
        XCTAssertEqual(Localization.text("Catch up, %ld missed sections", arguments: [1], bundle: ru, locale: locale),
                       "Пропущен 1 фрагмент")
        XCTAssertEqual(Localization.text("%ld characters over the limit", arguments: [11], bundle: ru, locale: locale),
                       "Лишние 11 символов")
    }
    func testInterpolationPreservesNamesAndEnglishFallback() throws {
        let name = "Ani %@ / Ани"
        XCTAssertEqual(Localization.text("Joining as %@", arguments: [name], bundle: try language("ru")),
                       "Вход под именем " + name)
        XCTAssertEqual(Localization.text("Joining as %@", arguments: [name], bundle: try language("en")),
                       "Joining as " + name)
        XCTAssertEqual(Localization.text("Unknown future message", bundle: try language("ru")), "Unknown future message")
    }
    func testPermissionExplanationsAndPreviewTitlesAreLocalized() throws {
        let ru = try language("ru")
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSContactsUsageDescription", "NSBluetoothAlwaysUsageDescription"] {
            let explanation = ru.localizedString(forKey: key, value: nil, table: "InfoPlist")
            XCTAssertNotEqual(explanation, key)
            XCTAssertTrue(explanation.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, key)
        }
        XCTAssertEqual(Localization.text("Entire screen", bundle: ru), "Весь экран")
        XCTAssertEqual(Localization.text("Pause sharing preview", bundle: ru), "Приостановить предпросмотр")
    }

    func testBroadcastExtensionsIncludeRussianResources() throws {
        for target in ["GuestBroadcast", "RockBroadcast"] {
            let root = try XCTUnwrap(Bundle.main.url(forResource: target, withExtension: "appex", subdirectory: "PlugIns"))
            let ru = try XCTUnwrap(Bundle(url: root.appendingPathComponent("ru.lproj")))
            let name = ru.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist")
            XCTAssertTrue(name.contains("экран"), target)
            if target == "GuestBroadcast" {
                XCTAssertEqual(ru.localizedString(forKey: "The meeting has ended.", value: nil, table: nil), "Встреча завершена.")
            }
        }
    }
}
