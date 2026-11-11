import Combine
import Foundation
import UserNotifications
import AssistantDomain

@MainActor final class TaskNotificationStore: ObservableObject {
    static let preferenceKey = "task.notifications.enabled.v1"
    static var shared: TaskNotificationStore { applicationStore() }
    private static var stores: [String: TaskNotificationStore] = [:]
    let service: TaskNotificationService
    private let adapter: TaskNotificationCenterAdapter
    #if DEBUG
    var streamingFixtureCompletedAddAttempts: Int { adapter.completedAddAttempts }
    #endif
    @Published private(set) var route: Route?
    struct Route: Identifiable { let id = UUID(); let destination: TaskNotificationDestination }

    static func applicationStore(arguments: [String] = ProcessInfo.processInfo.arguments) -> TaskNotificationStore {
        let configuration: TaskNotificationStoreConfiguration
        do { configuration = try TaskNotificationStoreConfiguration.resolve(arguments: arguments) }
        catch { preconditionFailure("Notification UI tests require exactly one mode and an isolated namespace UUID") }
        if let store = stores[configuration.suite] { return store }
        guard let defaults = UserDefaults(suiteName: configuration.suite) else {
            preconditionFailure("Notification defaults unavailable")
        }
        if configuration.reset { defaults.removeObject(forKey: preferenceKey) }
        let store = TaskNotificationStore(defaults: defaults, center: .current(), scope: configuration.scope,
            languageProvider: { AppLanguageStore.applicationPreferences(arguments: arguments).resolved })
        stores[configuration.suite] = store
        return store
    }

    init(defaults: UserDefaults, center: UNUserNotificationCenter, scope: String = "production",
         languageProvider: @escaping () -> AppDisplayLanguage = { .traditionalChinese }) {
        // Resolve at delivery from the matching preference suite, without replacing this service.
        // Existing delivered notifications remain in their original language.
        adapter = TaskNotificationCenterAdapter(center: center, scope: scope,
            localizer: { AppLocalizer(language: languageProvider()) })
        service = TaskNotificationService(client: adapter, enabled: defaults.bool(forKey: Self.preferenceKey),
            persistEnabled: { defaults.set($0, forKey: TaskNotificationStore.preferenceKey) })
        service.onChange = { [weak self] in self?.objectWillChange.send() }
        adapter.mayPresent = { [weak service] in service?.mayPresent(identifier: $0) ?? false }
        adapter.onDismiss = { [weak service] in service?.dismiss(identifier: $0) }
        adapter.onOpen = { [weak self] in self?.route = Route(destination: $0) }
        #if DEBUG
        adapter.onCompletedAddAttempt = { [weak self] in self?.objectWillChange.send() }
        #endif
    }

    func installDelegate() { adapter.installDelegate() }
    func consumeRoute(_ id: UUID) { if route?.id == id { route = nil } }
}

struct TaskNotificationStoreConfiguration: Equatable {
    let suite: String
    let scope: String
    let reset: Bool
    enum Invalid: Error { case namespace }
    static func resolve(arguments: [String]) throws -> Self {
        let base = "io.woowtech.assistant.notifications.v1"
        #if DEBUG
        let modes = [("-UITestMode", "-UITestNamespace"), ("-LiveModelUITest", "-LiveModelUITestNamespace")]
        let selected = modes.filter { arguments.contains($0.0) }
        if !selected.isEmpty || arguments.contains(where: { $0.hasPrefix("-UITest") || $0.hasPrefix("-Live") }) {
            guard selected.count == 1, let mode = selected.first,
                  arguments.filter({ $0 == mode.0 }).count == 1,
                  arguments.filter({ $0 == mode.1 }).count == 1,
                  !modes.contains(where: { $0.0 != mode.0 && arguments.contains($0.1) }),
                  let index = arguments.firstIndex(of: mode.1), arguments.indices.contains(index + 1),
                  let namespace = UUID(uuidString: arguments[index + 1]) else { throw Invalid.namespace }
            return Self(suite: base + ".test." + namespace.uuidString, scope: namespace.uuidString,
                reset: arguments.contains("-UITestResetStorage") || arguments.contains("-LiveModelUITestCleanup")
                    || arguments.contains("-LiveMCPUITestCleanup"))
        }
        #endif
        return Self(suite: base, scope: "production", reset: false)
    }
}

#if canImport(UIKit)
import UIKit

/// Parent must install this via UIApplicationDelegateAdaptor before launch completes.
@MainActor final class TaskNotificationAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        TaskNotificationStore.shared.installDelegate()
        Task { await TaskNotificationStore.shared.service.refresh() }
        return true
    }
}
#endif
