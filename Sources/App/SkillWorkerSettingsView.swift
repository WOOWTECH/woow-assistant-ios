import SwiftUI

@MainActor struct SkillWorkerSettingsView: View {
    @ObservedObject var settings: SkillWorkerPreferences
    @FocusState private var editing: Bool

    var body: some View {
        Form {
            Section("原版 PDF 腳本服務") {
                Text("填入你部署的 Mika PDF 擷取服務完整 HTTPS 網址與專用存取金鑰。設定不會上傳文件。")
                TextField("https://服務主機/v1/extract-pdf", text: $settings.endpointDraft)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($editing).accessibilityIdentifier("skillWorker.endpoint")
                SecureField("Bearer 存取金鑰；同一服務可留空沿用", text: $settings.tokenDraft)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                    .focused($editing).accessibilityIdentifier("skillWorker.token")
                Button("儲存服務設定") { editing = false; settings.save() }
                    .accessibilityIdentifier("skillWorker.save")
                Button("移除服務設定與金鑰", role: .destructive) { editing = false; settings.remove() }
                    .accessibilityIdentifier("skillWorker.remove")
            }
            Section {
                Text(settings.worker == nil ? "目前使用裝置上的 PDFKit。" : "服務已設定；每次仍須選擇使用服務，並核准讀檔與上傳。")
                    .accessibilityIdentifier("skillWorker.status")
                Text("文件、選頁與 PDF 密碼會在你核准上傳後傳給這個服務。存取金鑰獨立儲存在裝置 Keychain；不會沿用模型的 API Key。")
                if let error = settings.error { Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("skillWorker.error") }
                if let notice = settings.notice { Text(verbatim: notice).accessibilityIdentifier("skillWorker.notice") }
            }
        }
        .navigationTitle("腳本服務設定")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer(); Button("完成輸入") { editing = false }.accessibilityIdentifier("skillWorker.keyboard.done")
            }
        }
        .onDisappear { settings.tokenDraft = "" }
    }
}
