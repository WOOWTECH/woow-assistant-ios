import Foundation
import Combine
@testable import AssistantSkills
@main enum LanguageChecks {
    @MainActor static func main() async throws {
        var passed = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "language-check", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            passed += 1
        }
        let mappings: [([String], AppDisplayLanguage)] = [
            ([], .traditionalChinese), (["fr-FR", "ja-JP"], .traditionalChinese), (["en-GB"], .english),
            (["zh-TW"], .traditionalChinese), (["zh-HK"], .traditionalChinese),
            (["zh-MO"], .traditionalChinese), (["zh-Hant-US"], .traditionalChinese),
            (["zh-CN"], .simplifiedChinese), (["zh-SG"], .simplifiedChinese),
            (["zh-Hans-TW"], .simplifiedChinese), (["ja-JP", "zh-TW"], .traditionalChinese),
            (["en-US", "zh-TW"], .english), (["zh-CN", "en-US"], .simplifiedChinese)]
        for (preferences, expected) in mappings {
            try check(AppLanguage.system.resolve(preferredLanguages: preferences) == expected, "system language matching")
        }
        for (choice, expected) in [(AppLanguage.traditionalChinese, AppDisplayLanguage.traditionalChinese),
                                   (.simplifiedChinese, .simplifiedChinese), (.english, .english)] {
            for preferences in [[], ["ja-JP"], ["zh-HK"], ["en-GB"]] {
                try check(choice.resolve(preferredLanguages: preferences) == expected, "explicit selection ignores system language")
            }
        }
        let suite = "woow.language.foundation.check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var preferences = ["zh-TW"]
        let language = AppLanguageStore(defaults: defaults, preferredLanguages: { preferences })
        let appearance = SelfConfigurationStore(defaults: defaults)
        try check(language.language == .system && language.resolved == .traditionalChinese, "missing key resolves system")
        try check(defaults.object(forKey: AppLanguageStore.preferenceKey) == nil, "read does not persist a default")
        appearance.setPermissionFromUser(true)
        appearance.setAppearanceFromUser(.dark)
        let authorized = try appearance.authorize()
        let before = defaults.persistentDomain(forName: suite)!
        try check(language.setFromUser(.english), "manual language readback")
        let after = defaults.persistentDomain(forName: suite)!.filter { $0.key != AppLanguageStore.preferenceKey }
        try check(NSDictionary(dictionary: before).isEqual(to: after), "only the language key changes")
        try appearance.validate(authorized)
        try check(appearance.appearance == .dark && appearance.allowSelfConfiguration, "appearance and permission unchanged")
        let options = try appearance.options(authorized)
        try check(options.count == 1 && options[0].key == "appearance", "language is not advertised to model settings tools")
        let receipt = try appearance.apply(.light, authorization: authorized)
        try check(receipt.appearance == .light && language.language == .english, "valid existing appearance operation survives language change")
        let reopened = AppLanguageStore(defaults: defaults, preferredLanguages: { preferences })
        try check(reopened.language == .english && reopened.resolved == .english, "language persists through a fresh store")
        preferences = ["zh-CN"]; reopened.refreshSystemLanguages()
        try check(reopened.resolved == .english, "system refresh cannot override explicit language")
        try check(reopened.setFromUser(.system) && reopened.resolved == .simplifiedChinese, "restoring system follows latest language")
        preferences = ["zh-HK"]; reopened.refreshSystemLanguages()
        try check(reopened.resolved == .traditionalChinese, "system language change refreshes resolution")
        let revoked = try appearance.authorize()
        appearance.setPermissionFromUser(false)
        try check(reopened.setFromUser(.english), "language does not require model permission")
        do { try appearance.validate(revoked); throw NSError(domain: "missing-revocation", code: 1) }
        catch SelfConfigurationError.authorizationChanged { passed += 1 }
        try check(!appearance.allowSelfConfiguration, "language does not revive model permission")
        defaults.set("unknown-future-language", forKey: AppLanguageStore.preferenceKey)
        let unknown = AppLanguageStore(defaults: defaults, preferredLanguages: { ["en-US"] })
        try check(unknown.language == .system && unknown.resolved == .english, "unknown stored value safely resolves system")
        try check(defaults.string(forKey: AppLanguageStore.preferenceKey) == "unknown-future-language", "loading an unknown value does not rewrite stored data")
        let resourceChecks = try LanguageResourceChecks.run(resourceRoot: URL(fileURLWithPath: CommandLine.arguments[1]))
        passed += resourceChecks
        passed += try await LanguageHTTPChecks.run()
        print("{\"passed\":\(passed),\"failed\":0,\"actual_userdefaults\":true,\"actual_self_configuration_store\":true,\"native_ios_ui\":false,\"live_model_http_attempts\":0,\"loopback_http_requests\":4}")
    }
}
