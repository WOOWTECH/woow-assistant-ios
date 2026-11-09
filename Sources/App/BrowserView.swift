import SwiftUI
import WebKit

@MainActor
struct BrowserView: View {
    @ObservedObject var browser: BrowserSession
    @ObservedObject var chat: ChatSession
    @State private var showResearch = false
    @FocusState private var addressFocused: Bool
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("https://", text: $browser.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.URL).submitLabel(.go).focused($addressFocused)
                    .onSubmit { open() }.accessibilityIdentifier("browser.address")
                Button("開啟") { open() }.accessibilityIdentifier("browser.open")
            }
            .padding(.horizontal).disabled(browser.isRunning)
            Text(browser.status).font(.caption).accessibilityIdentifier("browser.status")
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("browser.error")
            }
            HStack {
                Button("研究此網站") { addressFocused = false; showResearch = true }
                    .disabled(browser.current == nil).accessibilityIdentifier("browser.research")
                if browser.isRunning {
                    Button("停止") { browser.cancel() }.accessibilityIdentifier("browser.cancel")
                }
            }
            BrowserWebView(webView: browser.webView, coveredByResearch: showResearch)
                .allowsHitTesting(!browser.isRunning)
                .accessibilityHidden(showResearch)
            Text("目前提供公開網站瀏覽與同站唯讀研究；登入、表單提交、分頁及下載仍待整合。")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                .accessibilityIdentifier("browser.explanation")
        }
        .sheet(isPresented: $showResearch) {
            BrowserResearchView(browser: browser, chat: chat)
        }
    }
    private func open() { addressFocused = false; browser.openAddress() }
}

// A presented sheet owns its focus binding. Sharing a FocusState from the
// presenting browser leaves the multiline editor focused on iOS 26.
@MainActor
private struct BrowserResearchView: View {
    @ObservedObject var browser: BrowserSession
    @ObservedObject var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @FocusState private var goalFocused: Bool

    var body: some View {
        NavigationStack {
                Form {
                    Section("網站研究") {
                        Text("頁面文字會傳送到你設定的模型服務。研究只讀取網頁與開啟同站連結。")
                        TextField("這次想查清楚什麼？", text: $browser.goal, axis: .vertical)
                            .focused($goalFocused)
                            .disabled(browser.isRunning).accessibilityIdentifier("browser.goal")
                        Button("開始研究") { goalFocused = false; browser.beginResearch(using: chat) }
                            .disabled(browser.isRunning || browser.goal.isEmpty || !chat.hasStoredKey)
                            .accessibilityIdentifier("browser.start")
                        if browser.isRunning {
                            Button("停止研究") { browser.cancel() }.accessibilityIdentifier("browser.task.cancel")
                        }
                        Text(browser.status).accessibilityIdentifier("browser.task.status")
                    }
                    if let answer = browser.answer {
                        Section("目前結果") { Text(answer).textSelection(.enabled).accessibilityIdentifier("browser.answer") }
                    }
                    if let status = browser.learningStatus {
                        Section("學習結果") { Text(status).accessibilityIdentifier("browser.learning") }
                    }
                    Section("已完成的讀取（\(browser.actions.count)）") {
                        ForEach(Array(browser.actions.enumerated()), id: \.offset) { _, action in
                            VStack(alignment: .leading) {
                                Text(action.observation.title)
                                Text(action.observation.url.absoluteString).font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                }
                .navigationTitle("網站研究")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() }.accessibilityIdentifier("browser.research.close") }
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("完成輸入") { goalFocused = false }.accessibilityIdentifier("browser.goal.done")
                    }
                }
        }
    }
}

@MainActor
private struct BrowserWebView: UIViewRepresentable {
    let webView: WKWebView
    let coveredByResearch: Bool
    func makeUIView(context: Context) -> WKWebView {
        webView.accessibilityElementsHidden = coveredByResearch
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {
        // The presented research sheet owns VoiceOver focus. Hide only the
        // underlying accessibility subtree, including large registry pages;
        // keep the same WKWebView mounted and its renderer/DOM fully running.
        uiView.accessibilityElementsHidden = coveredByResearch
    }
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Void) {
        // BrowserSession retains this view across navigation between App tabs.
        uiView.accessibilityElementsHidden = false
    }
}
