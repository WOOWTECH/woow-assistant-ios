import AssistantBrowser
import SwiftUI
import WebKit

@MainActor struct ResearchSourceDiscoveryView: View {
    @StateObject private var session: ResearchSourceDiscoverySession
    private let onApply: ([ResearchSourceDiscoveryCandidate]) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editing: Bool

    init(query: String, onApply: @escaping ([ResearchSourceDiscoveryCandidate]) -> Void) {
        _session = StateObject(wrappedValue: ResearchSourceDiscoverySession(query: query))
        self.onApply = onApply
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Form {
                    Section("搜尋服務") {
                        Text(session.provider.title)
                        Text(session.provider.origin.absoluteString).font(.caption)
                        Text(session.provider.disclosure).font(.caption)
                    }
                    Section("尋找網站") {
                        TextField("搜尋詞", text: Binding(get: { session.query }, set: { session.setQuery($0) }), axis: .vertical)
                            .focused($editing).autocorrectionDisabled()
                            .disabled(session.running).accessibilityIdentifier("sourceDiscovery.query")
                        Button("搜尋公開網站") { editing = false; session.search() }
                            .disabled(session.running || session.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("sourceDiscovery.search")
                        Text(session.status).accessibilityIdentifier("sourceDiscovery.status")
                        if session.running {
                            ProgressView()
                            Button("取消搜尋") { session.cancel() }.accessibilityIdentifier("sourceDiscovery.cancel")
                        }
                        if let error = session.error {
                            Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("sourceDiscovery.error")
                        }
                    }
                    if let result = session.result {
                        Section("選取兩至三個不同網站") {
                            Text("選取順序就是研究來源順序。這些連結來自搜尋頁，尚未核對內容；套用後仍需確認來源才會開始研究。")
                                .font(.caption)
                            ForEach(Array(result.candidates.enumerated()), id: \.element.id) { index, candidate in
                                Button { session.toggle(candidate.id) } label: {
                                    HStack(alignment: .top) {
                                        Image(systemName: session.selectedIDs.contains(candidate.id) ? "checkmark.circle.fill" : "circle")
                                        VStack(alignment: .leading, spacing: 5) {
                                            Text(verbatim: candidate.title)
                                            Text(verbatim: candidate.url.absoluteString).font(.caption)
                                        }.foregroundStyle(.primary)
                                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                }
                                .accessibilityIdentifier("sourceDiscovery.candidate.\(index)")
                                .accessibilityValue(candidateValue(candidate))
                            }
                            if result.truncated {
                                Text("只顯示本次搜尋頁可處理的部分結果。").font(.caption)
                            }
                        }
                    }
                }
                .scrollDismissesKeyboard(.interactively)
                .accessibilityIdentifier("sourceDiscovery.form")
                if let browser = session.browser {
                    DiscoveryWebView(webView: browser.webView)
                        .frame(height: 100).allowsHitTesting(false).accessibilityHidden(true)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if session.result != nil {
                    VStack(spacing: 6) {
                        Text("已選取 \(session.selectedIDs.count) 個網站")
                            .font(.caption).accessibilityIdentifier("sourceDiscovery.selectionCount")
                        Button(action: applySelection) {
                            Text("套用並取代來源欄位").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.borderedProminent).disabled(!session.canApply)
                        .accessibilityIdentifier("sourceDiscovery.apply")
                    }.padding(.horizontal).padding(.vertical, 8).background(.regularMaterial)
                }
            }
            .navigationTitle("尋找研究來源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { session.cancel(notice: false); dismiss() }
                        .accessibilityIdentifier("sourceDiscovery.close")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") { editing = false }.accessibilityIdentifier("sourceDiscovery.keyboardDone")
                }
            }
        }
        .onDisappear { session.cancel(notice: false) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.cancel() } }
    }

    private func applySelection() {
        guard let sources = session.selectedSources() else { return }
        session.cancel(notice: false); onApply(sources); dismiss()
    }

    private func candidateValue(_ candidate: ResearchSourceDiscoveryCandidate) -> String {
        let selection = session.selectedIDs.contains(candidate.id) ? "已選取" : "未選取"
        #if DEBUG
        // Observe the same real URL displayed in the row; never seed or select
        // a result. Private native tests need not infer a URL from a title.
        if ProcessInfo.processInfo.arguments.contains("-LiveModelUITest") {
            return selection + "\n" + candidate.url.absoluteString
        }
        #endif
        return selection
    }
}

private struct DiscoveryWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
