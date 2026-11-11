import Foundation

extension AppLocalizer {
    /// Only known codes become display messages. System status is an opaque
    /// decimal code, not a locale-grouped quantity or arbitrary error text.
    static func modelSettingsError(_ error: ModelSettingsError) -> AppText {
        switch error {
        case .invalidURL: return .modelSettingsInvalidURL
        case .missingModel: return .modelSettingsMissingModel
        case .missingKey: return .modelSettingsMissingKey
        case .changedOrigin: return .modelSettingsChangedOrigin
        case .invalidKey: return .modelSettingsInvalidKey
        case .unavailableKeychain: return .modelSettingsUnavailableKeychain
        case .keychainStatus(let status): return .modelSettingsKeychainStatus(code: String(status))
        }
    }
}
