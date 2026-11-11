import Foundation

struct AppLocalizedText: Equatable {
    let text: String
    let language: AppDisplayLanguage
    let usedFallback: Bool
}

/// Explicit bundle and locale selection; does not mutate process/system locale.
/// Construct again when the observed language changes. Stored state retains the
/// typed message, never an eagerly translated status or error string.
struct AppLocalizer {
    let language: AppDisplayLanguage
    private let bundles: [AppDisplayLanguage: Bundle]

    init(language: AppDisplayLanguage, bundle: Bundle = .main) {
        self.language = language
        var localized: [AppDisplayLanguage: Bundle] = [:]
        for choice in AppDisplayLanguage.allCases {
            if let url = bundle.url(forResource: choice.rawValue, withExtension: "lproj"),
               let resource = Bundle(url: url) { localized[choice] = resource }
        }
        bundles = localized
    }

    func text(_ message: AppText) -> String { resolve(message).text }

    func resolve(_ message: AppText) -> AppLocalizedText {
        let missing = "__WOOW_MISSING_TRANSLATION__"
        for candidate in [language, .traditionalChinese] {
            guard let bundle = bundles[candidate] else { continue }
            let format = bundle.localizedString(forKey: message.key, value: missing, table: "App")
            guard format != missing else { continue }
            return AppLocalizedText(text: String(format: format, locale: Locale(identifier: candidate.rawValue),
                                                 arguments: message.arguments),
                                    language: candidate, usedFallback: candidate != language)
        }
        return AppLocalizedText(text: String(format: message.traditionalFallback,
                                              locale: Locale(identifier: "zh-Hant"), arguments: message.arguments),
                                language: .traditionalChinese, usedFallback: true)
    }

    func languageName(_ choice: AppLanguage) -> String {
        switch choice {
        case .system: return text(.languageSystem)
        case .traditionalChinese: return text(.languageTraditional)
        case .simplifiedChinese: return text(.languageSimplified)
        case .english: return text(.languageEnglish)
        }
    }

    var resolvedLanguageName: String {
        languageName(AppLanguage(rawValue: language.rawValue) ?? .traditionalChinese)
    }
}
