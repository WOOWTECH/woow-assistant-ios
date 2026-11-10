import AssistantSkills
import Combine
import SwiftUI

@MainActor struct TranscriptBrowserView: View {
    @ObservedObject var browser: BrowserSession
    @ObservedObject var chat: ChatSession
    @State private var page: BrowserTranscriptText?
    @State private var source: TranscriptSnapshot?
    @State private var preparing = false
    @State private var showEditor = false
    @State private var error: String?
    @State private var task: Task<Void, Never>?
    @State private var operationID: UUID?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("讀取此頁文字") {
                    Text("讀取目前可見的頁面文字，排除表單輸入與隱藏內容。最多 64 KiB，超過時會停止；這一步不會傳送給模型。")
                    Button(preparing ? "正在讀取…" : "讀取目前頁面文字") { capture() }
                        .disabled(preparing).accessibilityIdentifier("transcript.browser.capture")
                    if let error { Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("transcript.browser.error") }
                }
                if let page {
                    Section("核對來源快照") {
                        Text(verbatim: page.title).accessibilityIdentifier("transcript.browser.title")
                        Text(verbatim: page.url.absoluteString).textSelection(.enabled).accessibilityIdentifier("transcript.browser.url")
                        Text("\(page.text.utf8.count) 位元組 · 擷取於 \(page.capturedAt.formatted())")
                        DisclosureGroup("查看讀取的全文") {
                            Text(verbatim: page.text).textSelection(.enabled).accessibilityIdentifier("transcript.browser.source")
                        }
                        Button("核准使用這份文字，前往確認模型服務") {
                            do {
                                source = try .fromUserApprovedWebPage(title: page.title, text: page.text, url: page.url)
                                showEditor = true; error = nil
                            } catch { self.error = "此頁文字無法建立有效快照，尚未傳送給模型。" }
                        }.accessibilityIdentifier("transcript.browser.approve")
                    }
                }
            }
            .navigationTitle("整理此頁文字")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("關閉") { dismiss() }.accessibilityIdentifier("transcript.browser.close")
                }
            }
            .navigationDestination(isPresented: $showEditor) {
                if let source {
                    TranscriptView(modelAccess: chat.modelAccess,
                        modelChanges: chat.$savedSettings.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                        approvedSource: source)
                }
            }
        }
        .onDisappear { operationID = nil; task?.cancel(); task = nil; preparing = false }
    }

    private func capture() {
        task?.cancel(); page = nil; source = nil; error = nil; preparing = true
        let id = UUID(); operationID = id
        task = Task {
            do {
                let captured = try await browser.textForTranscript()
                guard operationID == id, !Task.isCancelled else { return }
                page = captured; preparing = false; task = nil
            } catch {
                guard operationID == id, !Task.isCancelled else { return }
                preparing = false; task = nil
                self.error = (error as? TranscriptError)?.errorDescription
                    ?? "無法讀取完整的目前頁面文字；頁面可能尚未載入、已變更，或不符合此功能的網址限制。"
            }
        }
    }
}
