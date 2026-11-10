import AssistantBrowser
import SwiftUI
import WebKit

@MainActor struct MultiSourceResearchView: View {
    @ObservedObject var chat: ChatSession
    @StateObject private var session = MultiSourceResearchSession()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var root1 = ""
    @State private var root2 = ""
    @State private var root3 = ""
    @State private var goal = ""
    @State private var discoveringSources = false
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("問題與來源") {
                        TextField("想核對的問題、地區與時間範圍", text: $goal, axis: .vertical)
                            .focused($editing).accessibilityIdentifier("multiResearch.goal")
                        Button("搜尋可用的研究來源") { editing = false; discoveringSources = true }
                            .accessibilityIdentifier("multiResearch.discoverSources")
                        rootField("來源一 HTTPS 網址", text: $root1, number: 1)
                        rootField("來源二 HTTPS 網址", text: $root2, number: 2)
                        rootField("來源三（選填）", text: $root3, number: 3)
                        Text("確認後會讀取這些公開來源及同站連結，並將頁面摘錄傳給已設定的模型。研究使用獨立網站資料，不使用手動瀏覽的登入狀態。")
                            .font(.caption)
                        Button("確認來源並開始研究", action: start)
                            .disabled(session.running).accessibilityIdentifier("multiResearch.start")
                    }.disabled(session.running)
                    Section("進度") {
                        Text(session.status).accessibilityIdentifier("multiResearch.status")
                            .accessibilityValue(testDiagnostic)
                        if let error = session.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("multiResearch.error") }
                        if session.running {
                            Button("取消研究") { session.cancel() }.accessibilityIdentifier("multiResearch.cancel")
                        }
                    }
                    if let result = session.result {
                        Section("研究結果") {
                            Text(result.partial ? "部分結果" : "已整理來源引用").accessibilityIdentifier("multiResearch.result")
                            Text("已引用 \(result.citedSourceCount) 個網站").accessibilityIdentifier("multiResearch.citedSourceCount")
                            Text("引文已對應實際讀取頁面；不代表來源互相獨立或結論已證實。網站知識與路線不會自動寫入。")
                                .font(.caption)
                            ForEach(result.findings) { finding in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(finding.kind == .inference ? "推論" : "來源內容").font(.caption)
                                    Text(verbatim: finding.text)
                                    ForEach(Array(finding.citations.enumerated()), id: \.offset) { _, citation in
                                        citationView(citation)
                                    }
                                }
                            }
                            ForEach(Array(result.limitations.enumerated()), id: \.offset) { _, limitation in
                                Text(verbatim: limitation).font(.caption)
                            }
                        }
                    }
                    if !session.receipts.isEmpty {
                        Section("實際讀取紀錄") {
                            ForEach(session.receipts) { receipt in
                                VStack(alignment: .leading) {
                                    Text(verbatim: receipt.observation.title).font(.caption)
                                    Text(verbatim: receipt.observation.url.absoluteString)
                                        .accessibilityIdentifier("multiResearch.receipt.\(receipt.id)")
                                    Text(receipt.observation.capturedAt, format: .dateTime).font(.caption)
                                }
                            }
                        }
                    }
                }.scrollDismissesKeyboard(.interactively)
                // Keep every isolated view in the scene, including covered
                // sources. No page controls or dialogs are available here.
                if !session.browsers.isEmpty {
                    ZStack {
                        ForEach(Array(session.browsers.enumerated()), id: \.offset) { index, browser in
                            MultiSourceWebView(webView: browser.webView).opacity(index == 0 ? 1 : 0)
                        }
                    }.frame(height: 100).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .navigationTitle("多網站研究")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { session.cancel(); dismiss() }.accessibilityIdentifier("multiResearch.close")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editing = false }.accessibilityIdentifier("multiResearch.keyboardDone")
                }
            }
        }
        .sheet(isPresented: $discoveringSources) {
            ResearchSourceDiscoveryView(query: goal) { sources in
                guard !session.running, (2...3).contains(sources.count) else { return }
                root1 = sources[0].url.absoluteString
                root2 = sources[1].url.absoluteString
                root3 = sources.count == 3 ? sources[2].url.absoluteString : ""
            }
        }
        .onDisappear { session.cancel() }
        .onChange(of: scenePhase) { _, value in if value == .background { session.cancel() } }
    }

    private var testDiagnostic: String {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-LiveModelUITest") || MultiSourceResearchFixture.enabled { return session.diagnostic }
        #endif
        return ""
    }

    private func rootField(_ label: String, text: Binding<String>, number: Int) -> some View {
        TextField(label, text: text).keyboardType(.URL).textInputAutocapitalization(.never)
            .autocorrectionDisabled().focused($editing).accessibilityIdentifier("multiResearch.rootText\(number)")
    }

    private func start() {
        editing = false
        do {
            let roots = [root1, root2] + (root3.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? [] : [root3])
            let plan = try MultiSourceResearchPlan(goal: goal, rootAddresses: roots)
            session.start(plan: plan, using: chat)
        } catch { session.reportInvalidPlan(error) }
    }

    private func citationView(_ citation: MultiSourceResearchCitation) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(verbatim: citation.quote).font(.callout)
                .accessibilityIdentifier("multiResearch.quote.\(citation.receipt.sourceID)")
            Link(destination: citation.receipt.observation.url) {
                Text(verbatim: citation.receipt.observation.title + " — " + citation.receipt.observation.url.absoluteString)
            }
            Text("讀取時間：" + citation.receipt.observation.capturedAt.formatted(date: .numeric, time: .standard))
                .font(.caption)
            Text("發布日期：未確認；請參考原文引句。") .font(.caption)
        }
    }
}

private struct MultiSourceWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
