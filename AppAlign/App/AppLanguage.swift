import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case japanese = "ja"

    static let defaultsKey = "AppAlignLanguage"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    static func selected(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: defaultsKey) ?? "") ?? .english
    }

    static func select(_ language: AppLanguage, in defaults: UserDefaults = .standard) {
        defaults.set(language.rawValue, forKey: defaultsKey)
    }
}

enum L10n {
    static func string(_ english: String, language: AppLanguage = .selected(), bundle resourceBundle: Bundle = .main) -> String {
        guard language == .japanese,
              let path = resourceBundle.path(forResource: language.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return english }
        let exact = bundle.localizedString(forKey: english, value: english, table: nil)
        if exact != english { return exact }

        guard let numbers = try? NSRegularExpression(pattern: "[0-9]+") else { return english }
        let range = NSRange(english.startIndex ..< english.endIndex, in: english)
        let matches = numbers.matches(in: english, range: range)
        guard !matches.isEmpty, matches.count <= 3 else { return english }
        let format = numbers.stringByReplacingMatches(in: english, range: range, withTemplate: "%lld")
        let translated = bundle.localizedString(forKey: format, value: format, table: nil)
        guard translated != format else { return english }
        let values: [CVarArg] = matches.compactMap { match in
            Range(match.range, in: english).flatMap { Int64(english[$0]) }
        }
        guard values.count == matches.count else { return english }
        return String(format: translated, locale: language.locale, arguments: values)
    }
}
