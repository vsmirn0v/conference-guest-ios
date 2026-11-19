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
        XCTAssertTrue(Set(english.keys).subtracting(russian.keys).isEmpty,
                      "Missing Russian keys: \(Set(english.keys).subtracting(russian.keys).sorted())")
        XCTAssertTrue(Set(russian.keys).subtracting(english.keys).isEmpty,
                      "Missing English keys: \(Set(russian.keys).subtracting(english.keys).sorted())")
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
        XCTAssertEqual(Localization.text("Rejoin %@ on %@", arguments: [name, "example.test"], bundle: try language("ru")),
                       "Снова войти в " + name + " на сайте example.test")
        XCTAssertEqual(Localization.text("Rejoin %@ on %@", arguments: [name, "example.test"], bundle: try language("en")),
                       "Rejoin " + name + " on example.test")
        XCTAssertEqual(Localization.text("Unknown future message", bundle: try language("ru")), "Unknown future message")
    }
    func testPermissionExplanationsAndPreviewTitlesAreLocalized() throws {
        let ru = try language("ru")
        for key in ["NSCameraUsageDescription", "NSMicrophoneUsageDescription",
                    "NSBluetoothAlwaysUsageDescription"] {
            let explanation = ru.localizedString(forKey: key, value: nil, table: "InfoPlist")
            XCTAssertNotEqual(explanation, key)
            XCTAssertTrue(explanation.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }, key)
        }
        XCTAssertEqual(Localization.text("Entire screen", bundle: ru), "Весь экран")
        XCTAssertEqual(Localization.text("Pause sharing preview", bundle: ru), "Приостановить предпросмотр")
    }

    func testNoAddressBookPermissionIsRequested() {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "NSContactsUsageDescription"))
    }

    func testBroadcastExtensionsIncludeRussianResources() throws {
        for target in ["RockBroadcast"] {
            let root = try XCTUnwrap(Bundle.main.url(forResource: target, withExtension: "appex", subdirectory: "PlugIns"))
            let ru = try XCTUnwrap(Bundle(url: root.appendingPathComponent("ru.lproj")))
            let name = ru.localizedString(forKey: "CFBundleDisplayName", value: nil, table: "InfoPlist")
            XCTAssertTrue(name.contains("экран"), target)
        }
    }
}

extension LocalizationTests {
    func testAllNineLanguagesShipAppAndExtensionCopy() throws {
        let en = try language("en")
        let source = try XCTUnwrap(catalog(en, "strings") as? [String: String])
        let basePluralKeys = Set(try catalog(en, "stringsdict").keys)
        let formats = try NSRegularExpression(pattern: #"%([1-9]\d*\$)?([-+0#]?\d*(?:\.\d+)?(?:ll|l|h|z)?[@diuoxXfFeEgGsc%])"#)
        func types(_ format: String) -> [Int: String] {
            let text = format as NSString
            var result: [Int: String] = [:]
            var next = 1
            for match in formats.matches(in: format, range: NSRange(location: 0, length: text.length)) {
                let type = text.substring(with: match.range(at: 2))
                if type == "%" { continue }
                let field = match.range(at: 1)
                let index = field.location == NSNotFound ? next : Int(text.substring(with: field).dropLast()) ?? -1
                result[index] = type
                next += 1
            }
            return result
        }
        let signatures = source.mapValues(types)
        for code in ["en", "ru", "es", "ar", "hi", "fr", "de", "zh-Hans", "id"] {
            let bundle = try language(code)
            let values = try XCTUnwrap(catalog(bundle, "strings") as? [String: String])
            XCTAssertEqual(Set(source.keys), Set(values.keys), code)
            XCTAssertEqual(Set(try catalog(bundle, "stringsdict").keys), basePluralKeys, code)
            for (key, value) in values {
                XCTAssertEqual(types(value), signatures[key], "\(code), \(key)")
            }
            let mic = bundle.localizedString(forKey: "NSMicrophoneUsageDescription", value: "__missing__", table: "InfoPlist")
            XCTAssertNotEqual(mic, "__missing__", code)
            if code != "en" { XCTAssertNotEqual(mic, en.localizedString(forKey: "NSMicrophoneUsageDescription", value: nil, table: "InfoPlist")) }
            for (target, key, table) in [("RockBroadcast", "CFBundleDisplayName", "InfoPlist"),
                                         ("MeetingActivity", "Meeting in progress", "Localizable")] {
                let url = try XCTUnwrap(Bundle.main.url(forResource: target, withExtension: "appex", subdirectory: "PlugIns"))
                let localized = try XCTUnwrap(Bundle(url: url.appendingPathComponent(code + ".lproj")), "\(target), \(code)")
                XCTAssertNotEqual(localized.localizedString(forKey: key, value: "__missing__", table: table), "__missing__", "\(target), \(code)")
            }
        }
    }
}
