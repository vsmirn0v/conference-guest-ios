#if NATIVE_DIRECT_UPDATES
import Foundation

enum SupportCopy {
    static let settingsTab = 9
    static let bundle = Bundle.main.url(forResource: "SupportLanguage", withExtension: "bundle").flatMap(Bundle.init(url:))
    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }
    private static let russianTimeZones: Set<String> = [
        "Europe/Kaliningrad", "Europe/Moscow", "Europe/Kirov", "Europe/Volgograd",
        "Europe/Astrakhan", "Europe/Saratov", "Europe/Ulyanovsk", "Europe/Samara",
        "Asia/Yekaterinburg", "Asia/Omsk", "Asia/Novosibirsk", "Asia/Barnaul",
        "Asia/Tomsk", "Asia/Novokuznetsk", "Asia/Krasnoyarsk", "Asia/Irkutsk",
        "Asia/Chita", "Asia/Yakutsk", "Asia/Khandyga", "Asia/Vladivostok",
        "Asia/Ust-Nera", "Asia/Magadan", "Asia/Sakhalin", "Asia/Srednekolymsk",
        "Asia/Kamchatka", "Asia/Anadyr", "W-SU",
    ]
    static var russian: Bool { language.lowercased().hasPrefix("ru") }
    static func isOutsideRussia(locale: Locale = .current, timeZone: TimeZone = .current) -> Bool {
        if locale.region?.identifier.uppercased() == "RU" { return false }
        if russianTimeZones.contains(timeZone.identifier) { return false }
        return true
    }
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
