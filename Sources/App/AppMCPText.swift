import Foundation

extension AppLocalizer {
    static func mcpSettingsError(_ error: MCPSettingsError) -> AppText {
        switch error {
        case .keychainStatus(let code): return .mcpKeychainStatus(code: String(code))
        case .invalidEndpoint: return .mcpInvalidEndpoint
        case .unavailableKeychain: return .mcpKeychainUnavailable
        case .invalidTestNamespace: return .mcpInvalidNamespace
        case .missingLiveTestEndpoint: return .mcpMissingLiveEndpoint
        }
    }
}
