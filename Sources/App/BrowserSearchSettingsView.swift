import AssistantBrowser
import SwiftUI

@MainActor
struct BrowserSearchSettingsView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var template = ""
    private enum Field { case name, template }
    @FocusState private var focusedField: Field?

    var body: some View {
        NavigationStack {
            Form {
                Section("搜尋引擎") {
                    ForEach(workspace.library.searchSettings.all) { engine in
                        HStack {
                            Button { workspace.selectSearchEngine(engine.id) } label: {
                                HStack {
                                    Text(engine.name)
                                    Spacer()
                                    if workspace.library.searchSettings.selectedID == engine.id {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }.accessibilityIdentifier("browser.searchEngine.select.\(engine.id)")
                                .accessibilityValue(workspace.library.searchSettings.selectedID == engine.id ? "已選取" : "未選取")
                            if engine.id.hasPrefix("custom:") {
                                Button("刪除", role: .destructive) { workspace.removeSearchEngine(engine.id) }
                                    .accessibilityLabel("刪除 \(engine.name)")
                                    .accessibilityIdentifier("browser.searchEngine.remove.\(engine.id)")
                            }
                        }.buttonStyle(.borderless)
                    }
                }
                Section("新增自訂引擎") {
                    TextField("名稱", text: $name).autocorrectionDisabled()
                        .focused($focusedField, equals: .name).submitLabel(.next)
                        .onSubmit { focusedField = .template }
                        .accessibilityIdentifier("browser.searchEngine.name")
                    TextField("https://example.com/search?q=%s", text: $template)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .focused($focusedField, equals: .template).submitLabel(.done)
                        .onSubmit { focusedField = nil }
                        .accessibilityIdentifier("browser.searchEngine.template")
                    Text("以 %s 代表搜尋文字，只接受公開 HTTPS；不接受網址帳密、登入參數或 #。最多 20 個。")
                        .font(.caption)
                    Button("新增並使用") {
                        focusedField = nil
                        if workspace.addSearchEngine(name: name, template: template) { name = ""; template = "" }
                    }.accessibilityIdentifier("browser.searchEngine.add")
                }
                if let error = workspace.error {
                    Text(error).foregroundStyle(.red).accessibilityIdentifier("browser.searchEngine.error")
                }
                Text("變更引擎會用於下一次手動搜尋；目前頁面不會重新載入。搜尋結果網址會沿用瀏覽歷史的儲存與清除設定。")
                    .font(.caption)
            }
            .scrollDismissesKeyboard(.interactively)
            .disabled(!workspace.available || workspace.isClearingWebsiteData)
            .navigationTitle("搜尋引擎")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("browser.searchEngine.close")
                }
            }
        }
    }
}
