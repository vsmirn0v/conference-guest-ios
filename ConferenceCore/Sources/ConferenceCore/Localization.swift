import Foundation

/// Resolve app-owned copy only; invitations, names and meeting content remain verbatim.
public func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}

public enum Localization {
    public static func text(_ key: String, arguments: [CVarArg] = [],
                            bundle: Bundle = .main, locale: Locale? = nil) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        let formattingLocale = locale ?? self.formattingLocale(
            language: bundle.preferredLocalizations.first ?? "en")
        return String(format: format, locale: formattingLocale, arguments: arguments)
    }

    /// The prompt language must be stable regardless of the device's display language.
    public static func englishLanguageName(for identifier: String) -> String {
        let language = Locale(identifier: identifier).language
        guard let code = language.languageCode?.identifier else { return "English" }
        if code == "zh" { return "Simplified Chinese" }
        return Locale(identifier: "en").localizedString(forLanguageCode: code) ?? "English"
    }

    /// App language governs grammatical rules; device region governs formatting.
    public static func formattingLocale(language: String, region: Locale = .current) -> Locale {
        var components = Locale.components(fromIdentifier: region.identifier)
        let selected = Locale.components(fromIdentifier: language)
        components[NSLocale.Key.languageCode.rawValue] = selected[NSLocale.Key.languageCode.rawValue]
        components[NSLocale.Key.scriptCode.rawValue] = selected[NSLocale.Key.scriptCode.rawValue]
        return Locale(identifier: Locale.identifier(fromComponents: components))
    }
}
