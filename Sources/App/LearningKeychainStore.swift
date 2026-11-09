import AssistantPersistence
import Foundation
import Security

/// A separate Keychain service: clearing learned data cannot remove model/MCP keys.
struct LearningKeychainStore: LearningKeyStore {
    let service: String

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    func read(id: String) throws -> Data? {
        var request = query
        request[kSecAttrAccount as String] = id
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = item as? Data else { throw LearningFileError.unavailable }
        return bytes
    }

    func insert(_ key: Data, id: String) throws {
        var request = query
        request[kSecAttrAccount as String] = id
        request[kSecValueData as String] = key
        request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw LearningFileError.unavailable }
    }

    func remove(id: String) throws {
        var request = query
        request[kSecAttrAccount as String] = id
        let status = SecItemDelete(request as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LearningFileError.unavailable }
    }

    func removeAll(except id: String) throws {
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitAll
        var items: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &items)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess, let records = items as? [[String: Any]] else { throw LearningFileError.unavailable }
        for record in records {
            guard let account = record[kSecAttrAccount as String] as? String else { throw LearningFileError.invalidData }
            if account != id { try remove(id: account) }
        }
    }
}
