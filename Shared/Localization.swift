import Foundation

/// Resolve app-owned copy only; invitations, names and meeting content remain verbatim.
func L(_ key: String, _ arguments: CVarArg...) -> String {
    Localization.text(key, arguments: arguments)
}

enum Localization {
    static func text(_ key: String, arguments: [CVarArg] = [],
                     bundle: Bundle = .main, locale: Locale? = nil) -> String {
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        let formattingLocale = locale ?? self.formattingLocale(
            language: bundle.preferredLocalizations.first ?? "en")
        return String(format: format, locale: formattingLocale, arguments: arguments)
    }

    /// App language governs grammatical rules; device region governs formatting.
    static func formattingLocale(language: String, region: Locale = .current) -> Locale {
        var components = Locale.components(fromIdentifier: region.identifier)
        components[NSLocale.Key.languageCode.rawValue] = language
        return Locale(identifier: Locale.identifier(fromComponents: components))
    }
}
