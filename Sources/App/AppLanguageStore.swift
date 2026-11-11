import Combine
import Foundation

/// Inject an isolated preferences suite at the App composition root.
/// This store owns exactly one key; it cannot change appearance/model grants.
@MainActor final class AppLanguageStore: ObservableObject {
    static let preferenceKey = "app.uiLanguage.v1"
    @Published private(set) var language: AppLanguage
    @Published private(set) var resolved: AppDisplayLanguage
    private let defaults: UserDefaults
    private let preferredLanguages: () -> [String]

    init(defaults: UserDefaults, preferredLanguages: @escaping () -> [String] = { Locale.preferredLanguages }) {
        self.defaults = defaults
        self.preferredLanguages = preferredLanguages
        let choice = AppLanguage(rawValue: defaults.string(forKey: Self.preferenceKey) ?? "") ?? .system
        language = choice
        resolved = choice.resolve(preferredLanguages: preferredLanguages())
    }

    /// Direct user action only; intentionally absent from settings_set tools.
    @discardableResult func setFromUser(_ choice: AppLanguage) -> Bool {
        defaults.set(choice.rawValue, forKey: Self.preferenceKey)
        guard defaults.string(forKey: Self.preferenceKey) == choice.rawValue else { return false }
        language = choice
        resolved = choice.resolve(preferredLanguages: preferredLanguages())
        return true
    }

    /// Host calls when returning active or when the OS locale changes.
    func refreshSystemLanguages() {
        let next = language.resolve(preferredLanguages: preferredLanguages())
        if next != resolved { resolved = next }
    }
}
