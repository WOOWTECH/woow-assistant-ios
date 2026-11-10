import Combine
import Foundation

public enum SelfConfigurationAppearance: String, CaseIterable, Codable, Sendable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: return "跟隨系統"
        case .light: return "淺色"
        case .dark: return "深色"
        }
    }
}

public struct SelfConfigurationOption: Codable, Equatable, Sendable {
    public let key: String
    public let label: String
    public let value: String
    public let choices: [String]
}

public struct SelfConfigurationReceipt: Equatable, Sendable {
    public let previous: SelfConfigurationAppearance
    /// Read back from the same UserDefaults store after the synchronous write.
    public let appearance: SelfConfigurationAppearance
}

public enum SelfConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case permissionRequired, authorizationChanged, cancelled, invalidRequest
    case invalidCommand, listRequired, unavailableSetting, invalidValue, alreadyUsed
    case timedOut, modelFailed, persistenceFailed

    public var errorDescription: String? {
        switch self {
        case .permissionRequired: return "請先開啟「允許模型調整外觀」。"
        case .authorizationChanged: return "設定或權限已變更，已停止這次操作；請重新提出要求。"
        case .cancelled: return "已取消，之後抵達的模型回應不會套用。"
        case .invalidRequest: return "請輸入外觀調整要求，長度不得超過 2,000 個 UTF-8 位元組。"
        case .invalidCommand: return "模型未回傳有效的設定指令，未套用變更。"
        case .listRequired: return "模型必須先查詢可調整的設定，未套用變更。"
        case .unavailableSetting: return "模型只能調整外觀，未套用其他設定。"
        case .invalidValue: return "外觀只接受跟隨系統、淺色或深色，未套用變更。"
        case .alreadyUsed: return "這次設定操作已結束，請重新提出要求。"
        case .timedOut: return "模型回應逾時，未套用變更。"
        case .modelFailed: return "模型連線或回應失敗，未套用變更。"
        case .persistenceFailed: return "無法讀回外觀設定，請檢查目前外觀。"
        }
    }
}

/// Portable appearance subset of Mika SelfConfigImpl/configure-mika at 0c172724.
/// Phone pace, target-app muting, capsules and keep-screen-on are not supported.
/// Inject the app's existing isolated defaults suite. This store never enumerates
/// defaults, opens Keychain, or exposes another subsystem's settings to a model.
@MainActor public final class SelfConfigurationStore: ObservableObject {
    @Published public private(set) var appearance: SelfConfigurationAppearance
    @Published public private(set) var allowSelfConfiguration: Bool
    private let defaults: UserDefaults
    private static let appearanceKey = "selfConfiguration.appearance.v1"
    private static let permissionKey = "selfConfiguration.allow.v1"
    private static let revisionKey = "selfConfiguration.authorization.v1"

    public init(defaults: UserDefaults) {
        self.defaults = defaults
        appearance = SelfConfigurationAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
        allowSelfConfiguration = defaults.bool(forKey: Self.permissionKey)
    }

    /// Only a direct user action should call this API. It is not a model tool.
    public func setPermissionFromUser(_ allowed: Bool) {
        defaults.set(UUID().uuidString, forKey: Self.revisionKey)
        defaults.set(allowed, forKey: Self.permissionKey)
        allowSelfConfiguration = allowed
    }

    /// Manual appearance changes also invalidate any in-flight model operation.
    public func setAppearanceFromUser(_ value: SelfConfigurationAppearance) {
        defaults.set(UUID().uuidString, forKey: Self.revisionKey)
        defaults.set(value.rawValue, forKey: Self.appearanceKey)
        appearance = value
    }

    struct Authorization {
        let revision: String?
        let appearance: SelfConfigurationAppearance
    }

    func authorize() throws -> Authorization {
        guard allowSelfConfiguration, defaults.bool(forKey: Self.permissionKey) else {
            throw SelfConfigurationError.permissionRequired
        }
        return Authorization(revision: defaults.string(forKey: Self.revisionKey), appearance: readAppearance())
    }

    func validate(_ authorization: Authorization) throws {
        guard allowSelfConfiguration, defaults.bool(forKey: Self.permissionKey),
              defaults.string(forKey: Self.revisionKey) == authorization.revision,
              readAppearance() == authorization.appearance else {
            throw SelfConfigurationError.authorizationChanged
        }
    }

    func options(_ authorization: Authorization) throws -> [SelfConfigurationOption] {
        try validate(authorization)
        return [.init(key: "appearance", label: "外觀", value: readAppearance().rawValue,
                      choices: SelfConfigurationAppearance.allCases.map(\.rawValue))]
    }

    /// Validation and write run on MainActor with no suspension point between
    /// them. A revoked/re-enabled grant never revives an old authorization.
    func apply(_ value: SelfConfigurationAppearance, authorization: Authorization) throws -> SelfConfigurationReceipt {
        try Task.checkCancellation()
        try validate(authorization)
        let previous = readAppearance()
        defaults.set(value.rawValue, forKey: Self.appearanceKey)
        defaults.set(UUID().uuidString, forKey: Self.revisionKey)
        guard defaults.string(forKey: Self.appearanceKey) == value.rawValue else {
            throw SelfConfigurationError.persistenceFailed
        }
        let readback = readAppearance()
        appearance = readback
        return .init(previous: previous, appearance: readback)
    }

    private func readAppearance() -> SelfConfigurationAppearance {
        SelfConfigurationAppearance(rawValue: defaults.string(forKey: Self.appearanceKey) ?? "") ?? .system
    }
}
