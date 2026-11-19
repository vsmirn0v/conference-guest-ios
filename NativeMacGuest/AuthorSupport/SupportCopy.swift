#if NATIVE_DIRECT_UPDATES
import Foundation

enum SupportCopy {
    static let settingsTab = 9
    static let bundle = Bundle.main.url(forResource: "SupportLanguage", withExtension: "bundle").flatMap(Bundle.init(url:))
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var russian: Bool { language.lowercased().hasPrefix("ru") }
    static var locale: Locale {
        var components = Locale.Components(identifier: language)
        components.region = Locale.current.region
        return Locale(components: components)
    }
    static func text(_ key: String, _ arguments: CVarArg...) -> String {
        let languagePath = bundle?.path(forResource: language, ofType: "lproj") ?? bundle?.path(forResource: "en", ofType: "lproj")
        let localized = languagePath.flatMap(Bundle.init(path:))?.localizedString(forKey: key, value: key, table: "AuthorSupport") ?? key
        return arguments.isEmpty ? localized : String(format: localized, locale: locale, arguments: arguments)
    }
    static func money(_ value: Decimal, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = code == "USD" ? .currencyISOCode : .currency
        formatter.currencyCode = code
        if code == "RUB" { formatter.maximumFractionDigits = 0 }
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value) \(code)"
    }
}
#endif
