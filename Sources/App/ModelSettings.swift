import AssistantModels
import Foundation
import Security

struct SavedModelSettings: Codable {
    let baseURL: URL
    let model: String
    // This is a Keychain item identifier, never the key itself.
    let credentialAccount: String

    var configuration: ModelConfiguration {
        ModelConfiguration(baseURL: baseURL, model: model)
    }
}

enum ModelSettingsError: Error, LocalizedError {
    case invalidURL, missingModel, missingKey, changedOrigin, invalidKey, unavailableKeychain
    case keychainStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "請輸入完整的 HTTPS Base URL，不可包含帳密、查詢參數或片段。"
        case .missingModel:
            return "請填寫服務供應商提供的模型名稱。"
        case .missingKey:
            return "請輸入 API Key。已有儲存的金鑰時，同一服務可留空沿用。"
        case .changedOrigin:
            return "服務主機或連接埠已變更，請重新輸入該服務的 API Key；不會自動沿用舊金鑰。"
        case .invalidKey:
            return "API Key 不可包含空白或控制字元。"
        case .unavailableKeychain:
            return "無法存取 Keychain，設定未變更。請解鎖裝置後再試。"
        case .keychainStatus(let status):
            return "Keychain 存取失敗（系統代碼 \(status)），設定未變更。"
        }
    }
}

protocol ModelCredentialStoring {
    func read(account: String) throws -> String?
    func insert(_ key: String, account: String) throws
    func remove(account: String) throws
    func removeAll() throws
}

struct KeychainModelCredentials: ModelCredentialStoring {
    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    func read(account: String) throws -> String? {
        var query = query
        query[kSecAttrAccount as String] = account
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw ModelSettingsError.keychainStatus(status) }
        guard status == errSecSuccess, let data = item as? Data,
              let key = String(data: data, encoding: .utf8) else {
            throw ModelSettingsError.unavailableKeychain
        }
        return key
    }

    func insert(_ key: String, account: String) throws {
        var query = query
        query[kSecAttrAccount as String] = account
        query[kSecValueData as String] = Data(key.utf8)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ModelSettingsError.keychainStatus(status) }
    }

    func remove(account: String) throws {
        var query = query
        query[kSecAttrAccount as String] = account
        try delete(query)
    }

    func removeAll() throws {
        // Always service-scoped: never clear the system Keychain or another app's items.
        try delete(query)
    }

    private func delete(_ query: [String: Any]) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ModelSettingsError.keychainStatus(status)
        }
    }
}

final class ModelSettingsRepository {
    static let configurationKey = "model.configuration.v1"
    private let defaults: UserDefaults
    private let credentials: any ModelCredentialStoring

    init(defaults: UserDefaults, credentials: any ModelCredentialStoring) {
        self.defaults = defaults
        self.credentials = credentials
    }

    static func validate(baseURL: String, model: String) throws -> ModelConfiguration {
        let address = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !address.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }),
              let components = URLComponents(string: address),
              components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.port.map({ (1...65535).contains($0) }) ?? true,
              let url = components.url else { throw ModelSettingsError.invalidURL }
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty, !model.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ModelSettingsError.missingModel
        }
        return ModelConfiguration(baseURL: url, model: model)
    }

    func load() throws -> SavedModelSettings? {
        guard let data = defaults.data(forKey: Self.configurationKey) else { return nil }
        let record = try JSONDecoder().decode(SavedModelSettings.self, from: data)
        _ = try Self.validate(baseURL: record.baseURL.absoluteString, model: record.model)
        guard UUID(uuidString: record.credentialAccount) != nil else { throw ModelSettingsError.missingKey }
        return record
    }

    func key(for record: SavedModelSettings) throws -> String {
        guard let key = try credentials.read(account: record.credentialAccount), !key.isEmpty else {
            throw ModelSettingsError.missingKey
        }
        return key
    }

    func save(baseURL: String, model: String, newKey: String) throws -> (record: SavedModelSettings, cleanupFailed: Bool) {
        let configuration = try Self.validate(baseURL: baseURL, model: model)
        let previous = try load()
        let newKey = newKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let account: String
        if newKey.isEmpty {
            guard let previous else { throw ModelSettingsError.missingKey }
            guard Self.sameOrigin(previous.baseURL, configuration.baseURL) else { throw ModelSettingsError.changedOrigin }
            _ = try key(for: previous)
            account = previous.credentialAccount
        } else {
            guard !newKey.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0) }) else {
                throw ModelSettingsError.invalidKey
            }
            account = UUID().uuidString
        }
        let record = SavedModelSettings(baseURL: configuration.baseURL, model: configuration.model, credentialAccount: account)
        let data = try JSONEncoder().encode(record)
        if !newKey.isEmpty { try credentials.insert(newKey, account: account) }
        // Publish the nonsecret record only after Keychain succeeds. A new item avoids
        // associating a replacement key with the old host if interrupted during save.
        defaults.set(data, forKey: Self.configurationKey)
        var cleanupFailed = false
        if let previous, previous.credentialAccount != account {
            do { try credentials.remove(account: previous.credentialAccount) }
            catch { cleanupFailed = true }
        }
        return (record, cleanupFailed)
    }

    func remove() throws {
        try credentials.removeAll()
        defaults.removeObject(forKey: Self.configurationKey)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? 443) == (rhs.port ?? 443)
    }
}
