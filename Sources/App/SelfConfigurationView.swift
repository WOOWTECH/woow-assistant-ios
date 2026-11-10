#if os(iOS)
import AssistantSkills
import SwiftUI

/// Parent integration:
/// @StateObject var preferences = SelfConfigurationStore(defaults: isolatedDefaults)
/// root.preferredColorScheme(preferences.preferredColorScheme)
/// SelfConfigurationView(store: preferences, modelAccess: { try session.modelAccess() })
@MainActor struct SelfConfigurationView: View {
    @ObservedObject var store: SelfConfigurationStore
    let modelAccess: () throws -> ModelAccess
    @StateObject private var session = SelfConfigurationSession()
    @State private var request = ""
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section("外觀") {
                Picker("目前外觀", selection: Binding(get: { store.appearance }, set: {
                    session.cancel(); store.setAppearanceFromUser($0)
                })) {
                    ForEach(SelfConfigurationAppearance.allCases, id: \.self) { value in
                        Text(value.label).tag(value)
                    }
                }.accessibilityIdentifier("selfConfiguration.appearance")
                Text(colorScheme == .dark ? "目前顯示：深色" : "目前顯示：淺色")
                    .accessibilityIdentifier("selfConfiguration.appliedAppearance")
                Text("選擇後立即生效；跟隨系統會使用裝置目前的外觀。")
                    .font(.footnote)
            }
            Section("模型權限") {
                Toggle("允許模型調整外觀", isOn: Binding(get: { store.allowSelfConfiguration }, set: {
                    session.cancel(); store.setPermissionFromUser($0)
                })).accessibilityIdentifier("selfConfiguration.permission")
                Text("預設關閉。開啟後，模型只可查詢及切換外觀；模型、金鑰、登入、刪除資料及網路設定均不提供給此工具。")
                    .font(.footnote)
            }
            if store.allowSelfConfiguration {
                Section("請模型調整外觀") {
                    Text("要求會傳送至你已設定的模型。請勿填入密碼或金鑰。")
                        .font(.footnote)
                    TextEditor(text: $request).frame(minHeight: 100).focused($editing)
                        .autocorrectionDisabled().accessibilityLabel("外觀調整要求")
                        .accessibilityIdentifier("selfConfiguration.request")
                    if let question = session.question {
                        Text(verbatim: question).accessibilityIdentifier("selfConfiguration.question")
                    }
                    if session.running {
                        Button("停止調整") { session.cancel() }
                            .accessibilityIdentifier("selfConfiguration.cancel")
                    } else {
                        Button("送出外觀要求") {
                            editing = false
                            session.start(request: request, store: store, modelAccess: modelAccess)
                        }
                        .disabled(request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || request.utf8.count > 2000)
                        .accessibilityIdentifier("selfConfiguration.start")
                    }
                }
            }
            Section("結果") {
                Text(session.message).accessibilityIdentifier("selfConfiguration.status")
                if let error = session.error {
                    Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("selfConfiguration.error")
                }
                ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                    Text(step).font(.caption).accessibilityIdentifier("selfConfiguration.step.\(index)")
                }
            }
        }
        .navigationTitle("外觀與模型權限")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成輸入") { editing = false }
                    .accessibilityIdentifier("selfConfiguration.keyboard.done")
            }
        }
        .onChange(of: store.allowSelfConfiguration) { _ in session.cancel() }
        .onDisappear { session.cancel(showNotice: false) }
    }
}
#endif
