import Foundation

public enum TaskNotificationAuthorization: String, Sendable {
    case unknown, notDetermined, denied, authorized, provisional, ephemeral
    public var allowsDelivery: Bool { self == .authorized || self == .provisional || self == .ephemeral }
}

public enum TaskNotificationSetting: String, Sendable {
    case unknown, notSupported, disabled, enabled
}

public struct TaskNotificationSettings: Equatable, Sendable {
    public let authorization: TaskNotificationAuthorization
    public let sound: TaskNotificationSetting
    public let alert: TaskNotificationSetting
    public init(authorization: TaskNotificationAuthorization = .unknown,
                sound: TaskNotificationSetting = .unknown, alert: TaskNotificationSetting = .unknown) {
        self.authorization = authorization; self.sound = sound; self.alert = alert
    }
}

/// Coarse navigation only. There is intentionally no approval/action/run payload.
public enum TaskNotificationDestination: String, Sendable { case chat, browser }
public enum TaskNotificationKind: String, Sendable { case completed, approval, test }

public struct TaskNotificationTicket: Hashable, Sendable {
    let id: UUID
    init() { id = UUID() }
}

public enum TaskNotificationEvent: Sendable {
    case requiresApproval(id: UUID, expiresAt: Date)
    case approvalResolved(id: UUID)
    case completed, cancelled, expired, failed
}

/// Only enums and a newly generated random identifier cross the OS boundary.
/// This type cannot accept model output, titles, tool parameters, URLs or personal data.
public struct TaskNotificationPayload: Equatable, Sendable {
    public static let identifierPrefix = "woow.task.v1."
    public let identifier: String
    public let kind: TaskNotificationKind
    public let destination: TaskNotificationDestination
    public var title: String {
        switch kind {
        case .completed: return "任務已完成"
        case .approval: return "有操作需要你核准"
        case .test: return "通知測試"
        }
    }
    public var body: String {
        switch kind {
        case .completed: return "開啟渥屋助理查看結果。"
        case .approval: return "請開啟渥屋助理查看並決定；通知不會核准操作。"
        case .test: return "這是渥屋助理的測試通知。"
        }
    }
    public init(kind: TaskNotificationKind, destination: TaskNotificationDestination) {
        self.kind = kind; self.destination = destination
        identifier = Self.identifierPrefix + destination.rawValue + "." + kind.rawValue + "." + UUID().uuidString
    }
    public static func destination(for identifier: String) -> TaskNotificationDestination? {
        guard identifier.hasPrefix(identifierPrefix), identifier.utf8.count < 100 else { return nil }
        let parts = identifier.dropFirst(identifierPrefix.count).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let destination = TaskNotificationDestination(rawValue: String(parts[0])),
              TaskNotificationKind(rawValue: String(parts[1])) != nil,
              let uuid = UUID(uuidString: String(parts[2])), uuid.uuidString == parts[2] else { return nil }
        return destination
    }
}

@MainActor public protocol TaskNotificationClient: AnyObject {
    func settings() async -> TaskNotificationSettings
    func requestAuthorization() async throws
    func add(_ payload: TaskNotificationPayload, sound: Bool) async throws
    func remove(identifiers: [String]) async
    /// Remove only this feature's pending AND delivered notifications, including previous launches.
    func removeAllOwned() async
}

public enum TaskNotificationNotice: String, Sendable {
    case authorizationUnavailable, deliveryUnavailable
    public var message: String {
        switch self {
        case .authorizationUnavailable: return "無法完成系統權限請求，請重新整理狀態後再試。"
        case .deliveryUnavailable: return "這次通知未能送出，請直接在 App 查看任務。"
        }
    }
}
