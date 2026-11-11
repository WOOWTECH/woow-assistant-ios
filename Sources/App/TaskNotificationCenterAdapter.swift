import Foundation
import UserNotifications
import AssistantDomain

/// Real OS adapter. No center is accessed until explicitly constructed by the app.
@MainActor final class TaskNotificationCenterAdapter: NSObject, TaskNotificationClient, UNUserNotificationCenterDelegate {
    private let center: UNUserNotificationCenter
    private let scope: String
    private let localizer: () -> AppLocalizer
    var onOpen: ((TaskNotificationDestination) -> Void)?
    var onDismiss: ((String) -> Void)?
    var mayPresent: ((String) -> Bool)?
    #if DEBUG
    private(set) var completedAddAttempts = 0
    var onCompletedAddAttempt: (() -> Void)?
    #endif

    init(center: UNUserNotificationCenter, scope: String = "production",
         localizer: @escaping () -> AppLocalizer = { AppLocalizer(language: .traditionalChinese) }) {
        precondition(scope == "production" || UUID(uuidString: scope)?.uuidString == scope)
        self.center = center; self.scope = scope; self.localizer = localizer; super.init()
    }
    func installDelegate() { center.delegate = self }

    func settings() async -> TaskNotificationSettings {
        let settings = await center.notificationSettings()
        let authorization: TaskNotificationAuthorization
        switch settings.authorizationStatus {
        case .notDetermined: authorization = .notDetermined
        case .denied: authorization = .denied
        case .authorized: authorization = .authorized
        case .provisional: authorization = .provisional
        #if os(iOS)
        case .ephemeral: authorization = .ephemeral
        #endif
        @unknown default: authorization = .unknown
        }
        return TaskNotificationSettings(authorization: authorization,
                                        sound: Self.setting(settings.soundSetting), alert: Self.setting(settings.alertSetting))
    }

    func requestAuthorization() async throws {
        _ = try await center.requestAuthorization(options: [.alert, .sound])
    }

    static func request(_ payload: TaskNotificationPayload, sound: Bool, scope: String = "production",
                        localizer: AppLocalizer = AppLocalizer(language: .traditionalChinese)) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = localizer.notificationTitle(payload.kind)
        content.body = localizer.notificationBody(payload.kind)
        content.sound = sound ? .default : nil
        // No userInfo, subtitle, thread/category identifiers, badges, attachments or actions.
        return UNNotificationRequest(identifier: scopedIdentifier(payload.identifier, scope: scope), content: content, trigger: nil)
    }

    func add(_ payload: TaskNotificationPayload, sound: Bool) async throws {
        #if DEBUG
        if payload.kind == .completed {
            completedAddAttempts += 1
            onCompletedAddAttempt?()
        }
        #endif
        try await center.add(Self.request(payload, sound: sound, scope: scope, localizer: localizer()))
    }

    func remove(identifiers: [String]) async {
        let own = identifiers.filter { TaskNotificationPayload.destination(for: $0) != nil }
            .map { Self.scopedIdentifier($0, scope: scope) }
        guard !own.isEmpty else { return }
        center.removePendingNotificationRequests(withIdentifiers: own)
        center.removeDeliveredNotifications(withIdentifiers: own)
    }

    func removeAllOwned() async {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map { $0.request.identifier }
        let own = Set(pending + delivered).filter { $0.hasPrefix(Self.prefix(scope)) }
        center.removePendingNotificationRequests(withIdentifiers: Array(own))
        center.removeDeliveredNotifications(withIdentifiers: Array(own))
    }

    private static func prefix(_ scope: String) -> String { TaskNotificationPayload.identifierPrefix + scope + "." }
    static func scopedIdentifier(_ identifier: String, scope: String) -> String {
        prefix(scope) + identifier.dropFirst(TaskNotificationPayload.identifierPrefix.count)
    }
    static func logicalIdentifier(_ identifier: String, scope: String) -> String? {
        guard identifier.hasPrefix(prefix(scope)) else { return nil }
        let logical = TaskNotificationPayload.identifierPrefix + identifier.dropFirst(prefix(scope).count)
        return TaskNotificationPayload.destination(for: logical) == nil ? nil : logical
    }

    private static func setting(_ setting: UNNotificationSetting) -> TaskNotificationSetting {
        switch setting {
        case .notSupported: return .notSupported
        case .disabled: return .disabled
        case .enabled: return .enabled
        @unknown default: return .unknown
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let identifier = notification.request.identifier
        let hasSound = notification.request.content.sound != nil
        Task { @MainActor [weak self] in
            guard let self, let logical = Self.logicalIdentifier(identifier, scope: self.scope),
                  self.mayPresent?(logical) == true else { completionHandler([]); return }
            // Focus/summary/sound switches are ultimately governed by the system.
            completionHandler(hasSound ? [.banner, .list, .sound] : [.banner, .list])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let isDefault = response.actionIdentifier == UNNotificationDefaultActionIdentifier
        Task { @MainActor [weak self] in
            defer { completionHandler() }
            guard let self, let logical = Self.logicalIdentifier(identifier, scope: self.scope),
                  let destination = TaskNotificationPayload.destination(for: logical) else { return }
            self.onDismiss?(logical)
            if isDefault { self.onOpen?(destination) }
            // No custom response, text input or forged action can authorize an operation.
        }
    }
}
