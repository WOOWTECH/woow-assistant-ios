import SwiftUI
import UIKit
import AssistantDomain

@MainActor struct TaskNotificationSettingsView: View {
    @ObservedObject var store: TaskNotificationStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section("本機任務通知") {
                statusRow("任務通知", text: store.service.enabled ? "已開啟" : "已關閉",
                          value: store.service.enabled ? "已開啟" : "已關閉", id: "notifications.enabled")
                Text("任務完成或需要核准時提醒你。通知只顯示固定提示；開啟後仍需在 App 內查看並決定。")
                if store.service.enabled {
                    Button("關閉任務通知") { store.service.disable() }
                        .accessibilityIdentifier("notifications.disable")
                } else {
                    Button("啟用並請求通知權限") { Task { await store.service.enableFromUserGesture() } }
                        .disabled(store.service.requestingAuthorization)
                        .accessibilityIdentifier("notifications.enable")
                }
                Button("傳送測試通知") { Task { _ = await store.service.sendTestFromUserGesture() } }
                    .disabled(!store.service.enabled || store.service.systemSettings.authorization != .authorized
                              || store.service.requestingAuthorization)
                    .accessibilityIdentifier("notifications.test")
            }
            Section("系統設定狀態") {
                statusRow("系統授權", text: authorizationText,
                          value: store.service.systemSettings.authorization.rawValue, id: "notifications.authorization")
                statusRow("系統聲音", text: settingText(store.service.systemSettings.sound),
                          value: store.service.systemSettings.sound.rawValue, id: "notifications.sound")
                statusRow("系統提示", text: settingText(store.service.systemSettings.alert),
                          value: store.service.systemSettings.alert.rawValue, id: "notifications.alert")
                Button("重新整理狀態") { Task { await store.service.refresh() } }
                    .accessibilityIdentifier("notifications.refresh")
                Button("開啟系統通知設定") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }.accessibilityIdentifier("notifications.systemSettings")
                Text("系統拒絕後，請到設定開啟通知。專注模式、通知摘要與靜音可能影響提示和聲音。")
                    .font(.footnote)
            }
            if let notice = store.service.notice {
                Text(notice.message).accessibilityIdentifier("notifications.notice")
            }
        }
        .navigationTitle("任務通知")
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
        switch store.service.systemSettings.authorization {
        case .unknown: return "尚未取得"
        case .notDetermined: return "尚未詢問"
        case .denied: return "已拒絕"
        case .authorized: return "已允許"
        case .provisional: return "暫時允許（安靜通知）"
        case .ephemeral: return "暫時允許（短期）"
        }
    }
    private func settingText(_ setting: TaskNotificationSetting) -> String {
        switch setting {
        case .unknown: return "尚未取得"
        case .notSupported: return "不支援"
        case .disabled: return "已關閉"
        case .enabled: return "已開啟"
        }
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
