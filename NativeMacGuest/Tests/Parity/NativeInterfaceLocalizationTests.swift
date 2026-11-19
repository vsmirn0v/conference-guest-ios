import ConferenceCore
import XCTest

final class NativeInterfaceLocalizationTests: XCTestCase {
    private let locales = ["en", "ru", "es", "ar", "hi", "fr", "de", "zh-Hans", "id"]

    private func resources(_ locale: String) throws -> Bundle {
        let path = try XCTUnwrap(Bundle.main.path(forResource: locale, ofType: "lproj"), "Missing app locale \(locale)")
        return try XCTUnwrap(Bundle(path: path))
    }

    private func table(_ bundle: Bundle, file: String, ext: String) throws -> [String: Any] {
        let url = try XCTUnwrap(bundle.url(forResource: file, withExtension: ext))
        return try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any])
    }

    private func arguments(in value: String, matching formats: NSRegularExpression) -> [Int: String] {
        let text = value as NSString
        var arguments: [Int: String] = [:]
        var next = 1
        for match in formats.matches(in: value, range: NSRange(location: 0, length: text.length)) {
            let type = text.substring(with: match.range(at: 2))
            if type == "%" { continue }
            let position = match.range(at: 1)
            let index = position.location == NSNotFound ? next : Int(text.substring(with: position)) ?? -1
            arguments[index] = type
            next += 1
        }
        return arguments
    }

    func testEveryInterfaceLanguageShipsWithMatchingCatalogsAndPermissions() throws {
        let formats = try NSRegularExpression(pattern: #"%(?:([1-9]\d*)\$)?((?:[-+0#]?\d*(?:\.\d+)?)(?:ll|l|h|z)?[@diuoxXfFeEgGsc%])"#)
        let source = try resources("en")
        let expected = try table(source, file: "Localizable", ext: "strings")
        let formatArguments = expected.compactMapValues { value in
            (value as? String).map { arguments(in: $0, matching: formats) }
        }
        let plurals = try table(source, file: "Localizable", ext: "stringsdict")
        let privacy = try table(source, file: "InfoPlist", ext: "strings")
        for locale in locales {
            let bundle = try resources(locale)
            let copy = try table(bundle, file: "Localizable", ext: "strings")
            let grammar = try table(bundle, file: "Localizable", ext: "stringsdict")
            let permissions = try table(bundle, file: "InfoPlist", ext: "strings")
            XCTAssertEqual(Set(copy.keys), Set(expected.keys), locale)
            XCTAssertEqual(Set(grammar.keys), Set(plurals.keys), locale)
            XCTAssertEqual(Set(permissions.keys), Set(privacy.keys), locale)
            for (key, signature) in formatArguments {
                let value = try XCTUnwrap(copy[key] as? String, key)
                XCTAssertFalse(value.isEmpty, "\(locale), \(key)")
                XCTAssertEqual(arguments(in: value, matching: formats), signature, "\(locale), \(key)")
            }
            if locale != "en" {
                XCTAssertNotEqual(bundle.localizedString(forKey: "Settings", value: nil, table: nil), "Settings", locale)
                XCTAssertNotEqual(permissions["NSMicrophoneUsageDescription"] as? String,
                                  privacy["NSMicrophoneUsageDescription"] as? String, locale)
            }
            let name = "Aki / آكي / %@"
            XCTAssertTrue(Localization.text("Rejoin %@ on %@", arguments: [name, "example.test"],
                                            bundle: bundle).contains(name), locale)
        }
    }
}
