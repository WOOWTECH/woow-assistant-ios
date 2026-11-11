import SwiftUI
import UIKit
import AssistantDomain

@MainActor struct TaskNotificationSettingsView: View {
    @Environment(\.appLocalizer) private var localizer
    @ObservedObject var store: TaskNotificationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section(localizer.text(.notificationLocal)) {
                statusRow(localizer.text(.notificationTitle), text: store.service.enabled ? localizer.text(.notificationOn) : localizer.text(.notificationOff),
                          value: store.service.enabled ? localizer.text(.notificationOn) : localizer.text(.notificationOff), id: "notifications.enabled")
                Text(localizer.text(.notificationHelp))
                if store.service.enabled {
                    Button(localizer.text(.notificationDisable)) { store.service.disable() }
                        .accessibilityIdentifier("notifications.disable")
                } else {
                    Button(localizer.text(.notificationEnable)) { Task { await store.service.enableFromUserGesture() } }
                        .disabled(store.service.requestingAuthorization)
                        .accessibilityIdentifier("notifications.enable")
                }
                Button(localizer.text(.notificationTest)) { Task { _ = await store.service.sendTestFromUserGesture() } }
                    .disabled(!store.service.enabled || store.service.systemSettings.authorization != .authorized
                              || store.service.requestingAuthorization)
                    .accessibilityIdentifier("notifications.test")
            }
            Section(localizer.text(.notificationSystemState)) {
                statusRow(localizer.text(.notificationAuthorization), text: authorizationText,
                          value: store.service.systemSettings.authorization.rawValue, id: "notifications.authorization")
                statusRow(localizer.text(.notificationSound), text: settingText(store.service.systemSettings.sound),
                          value: store.service.systemSettings.sound.rawValue, id: "notifications.sound")
                statusRow(localizer.text(.notificationAlert), text: settingText(store.service.systemSettings.alert),
                          value: store.service.systemSettings.alert.rawValue, id: "notifications.alert")
                Button(localizer.text(.notificationRefresh)) { Task { await store.service.refresh() } }
                    .accessibilityIdentifier("notifications.refresh")
                Button(localizer.text(.notificationOpenSettings)) {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }.accessibilityIdentifier("notifications.systemSettings")
                Text(localizer.text(.notificationSystemHelp))
                    .font(.footnote)
            }
            if let notice = store.service.notice {
                Text(localizer.text(AppLocalizer.notificationNotice(notice))).accessibilityIdentifier("notifications.notice")
            }
        }
        .navigationTitle(localizer.text(.notificationTitle))
        .task { await store.service.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await store.service.refresh() } }
        }
    }

    private func statusRow(_ title: String, text: String, value: String, id: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(text).accessibilityValue(value).accessibilityIdentifier(id)
        }.accessibilityElement(children: .contain)
    }

    private var authorizationText: String {
        localizer.text(AppLocalizer.notificationAuthorization(store.service.systemSettings.authorization))
    }
    private func settingText(_ setting: TaskNotificationSetting) -> String {
        localizer.text(AppLocalizer.notificationSetting(setting))
    }

}

@MainActor private final class TaskNotificationBridgeOwner: ObservableObject {
    private var bridge: TaskNotificationChatBridge?
    private weak var session: ChatSession?
    func bind(_ chat: ChatSession, service: TaskNotificationService) {
        guard session !== chat else { return }
        bridge?.invalidate(); session = chat
        bridge = TaskNotificationChatBridge(session: chat, service: service)
    }
}

@MainActor private struct TaskNotificationModifier: ViewModifier {
    let chat: ChatSession
    @ObservedObject var store: TaskNotificationStore
    let onOpen: (TaskNotificationDestination) -> Void
    @StateObject private var owner = TaskNotificationBridgeOwner()
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .onAppear {
                owner.bind(chat, service: store.service)
                openPendingRoute()
            }
            .task { await store.service.refresh() }
            .onChange(of: store.route?.id) { _, _ in openPendingRoute() }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await store.service.refresh() } }
                else { store.service.invalidateApprovals() }
            }
    }
    private func openPendingRoute() {
        guard let route = store.route else { return }
        onOpen(route.destination); store.consumeRoute(route.id)
    }
}

extension View {
    @MainActor func taskNotifications(chat: ChatSession, store: TaskNotificationStore,
                                     onOpen: @escaping (TaskNotificationDestination) -> Void) -> some View {
        modifier(TaskNotificationModifier(chat: chat, store: store, onOpen: onOpen))
    }
}
