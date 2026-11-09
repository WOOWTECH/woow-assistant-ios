import Foundation
import Security

enum MCPSettingsError: Error, LocalizedError {
    case keychainStatus(OSStatus)
    case invalidEndpoint, unavailableKeychain, invalidTestNamespace, missingLiveTestEndpoint

    var errorDescription: String? {
        switch self {
        case .keychainStatus(let status):
            return "MCP Keychain 存取失敗（系統代碼 \(status)）。"
        case .invalidEndpoint:
            return "請輸入完整 HTTPS MCP 端點，不可含帳密、片段或空白。查詢參數會與整個端點一起安全儲存。"
        case .unavailableKeychain:
            return "無法存取 MCP Keychain，請解鎖裝置後再試。"
        case .invalidTestNamespace:
            return "UI 測試缺少有效的隔離命名空間；不會讀取正式設定。"
        case .missingLiveTestEndpoint:
            return "Live MCP UI 測試設定未完成，未取得私密端點。"
        }
    }
}

protocol MCPEndpointStoring {
    func load() throws -> URL?
    func save(endpoint: String) throws
    func remove() throws
}

/// The WHOLE webhook URL is a credential, including host, path and query.
/// No endpoint, hostname, or secret is written to UserDefaults or diagnostic output.
struct MCPSettingsStore: MCPEndpointStoring {
    let service: String
    var failWrites = false

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "endpoint",
         kSecAttrSynchronizable as String: false]
    }

    static func validate(_ text: String) throws -> URL {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !address.isEmpty, address.utf8.count <= 16_384,
              !address.unicodeScalars.contains(where: forbidden.contains),
              let parts = URLComponents(string: address),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              let url = parts.url else { throw MCPSettingsError.invalidEndpoint }
        return url
    }

    func load() throws -> URL? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw MCPSettingsError.keychainStatus(status) }
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8) else {
            throw MCPSettingsError.unavailableKeychain
        }
        return try Self.validate(value)
    }

    func save(endpoint: String) throws {
        let url = try Self.validate(endpoint)
        guard !failWrites else { throw MCPSettingsError.unavailableKeychain }
        let attributes: [String: Any] = [
            kSecValueData as String: Data(url.absoluteString.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        // Update the existing item atomically; never delete the old credential first.
        let update = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw MCPSettingsError.keychainStatus(update) }
        let item = query.merging(attributes) { _, new in new }
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw MCPSettingsError.keychainStatus(status) }
    }

    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MCPSettingsError.keychainStatus(status)
        }
    }

    static func makeDefault(arguments: [String] = ProcessInfo.processInfo.arguments,
                            environment: [String: String]? = nil) throws -> MCPSettingsStore {
        let productionService = "io.woowtech.assistant.mcp-endpoint.v1"
        #if DEBUG
        let liveMCP = arguments.contains("-LiveMCPUITest")
        let cleanupMCP = arguments.contains("-LiveMCPUITestCleanup")
        let liveConversation = arguments.contains("-LiveMCPConversationUITest")
        let regular = arguments.contains("-UITestNamespace") || arguments.contains("-UITestMode") || liveMCP || cleanupMCP
        let live = arguments.contains("-LiveModelUITestNamespace") || arguments.contains("-LiveModelUITest")
        guard !(regular && live) else { throw MCPSettingsError.invalidTestNamespace }
        guard !liveConversation || (live && arguments.contains("-LiveModelUITest")) else {
            throw MCPSettingsError.invalidTestNamespace
        }
        if liveMCP || cleanupMCP {
            guard arguments.contains("-UITestMode") else { throw MCPSettingsError.invalidTestNamespace }
        }
        if regular || live {
            let flag = regular ? "-UITestNamespace" : "-LiveModelUITestNamespace"
            guard arguments.filter({ $0 == flag }).count == 1,
                  let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
                  let id = UUID(uuidString: arguments[index + 1]) else {
                throw MCPSettingsError.invalidTestNamespace
            }
            let kind = regular ? "uitest" : "liveuitest"
            let store = MCPSettingsStore(service: productionService + "." + kind + "." + id.uuidString,
                                         failWrites: arguments.contains("-UITestKeychainWriteFailure"))
            if (regular && arguments.contains("-UITestResetStorage"))
                || (live && arguments.contains("-LiveModelUITestCleanup")) || cleanupMCP {
                try store.remove()
            }
            // Only this explicit DEBUG mode bootstraps a real endpoint. Cleanup never
            // reads the environment, and regular UI tests cannot inherit this secret.
            if (liveMCP && !cleanupMCP) || (liveConversation && !arguments.contains("-LiveModelUITestCleanup")) {
                guard let endpoint = (environment ?? ProcessInfo.processInfo.environment)["WOOW_LIVE_MCP_URL"] else {
                    throw MCPSettingsError.missingLiveTestEndpoint
                }
                try store.save(endpoint: endpoint)
            }
            if regular && arguments.contains("-UITestMode") && arguments.contains("-UITestMCPFixture") {
                try store.save(endpoint: "https://fixture.invalid/mcp")
            }
            return store
        }
        #endif
        return MCPSettingsStore(service: productionService)
    }

    static func networkAllowed(arguments: [String] = ProcessInfo.processInfo.arguments) -> Bool {
        #if DEBUG
        let testFlags = ["-UITestNamespace", "-UITestMode", "-LiveModelUITestNamespace", "-LiveModelUITest",
                         "-LiveMCPUITest", "-LiveMCPUITestCleanup", "-LiveMCPConversationUITest"]
        if arguments.contains(where: testFlags.contains) {
            if arguments.contains("-LiveModelUITest"), arguments.contains("-LiveMCPConversationUITest"),
               !arguments.contains("-LiveModelUITestCleanup"), !arguments.contains("-UITestMode"),
               !arguments.contains("-UITestNamespace"),
               arguments.filter({ $0 == "-LiveModelUITestNamespace" }).count == 1,
               let index = arguments.firstIndex(of: "-LiveModelUITestNamespace"), arguments.indices.contains(index + 1),
               UUID(uuidString: arguments[index + 1]) != nil { return true }
            guard arguments.contains("-UITestMode"), arguments.contains("-LiveMCPUITest"),
                  !arguments.contains("-LiveMCPUITestCleanup"),
                  !arguments.contains("-LiveModelUITestNamespace"), !arguments.contains("-LiveModelUITest"),
                  arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
                  let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
                  UUID(uuidString: arguments[index + 1]) != nil else { return false }
            return true
        }
        #endif
        return true
    }
}
