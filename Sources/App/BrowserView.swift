import SwiftUI
import WebKit
import AssistantBrowser

@MainActor
struct BrowserView: View {
    @Environment(\.appLocalizer) private var localizer
    @ObservedObject var browser: BrowserSession
    @ObservedObject var chat: ChatSession
    @ObservedObject var workspace: BrowserWorkspace
    @State private var showResearch = false
    @State private var showInteractions = false
    @State private var showLibrary = false
    @State private var showTranscript = false
    @State private var showMultiResearch = false
    @State private var showSearchSettings = false
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var addressFocused: Bool
    private var pageCovered: Bool {
        showResearch || showInteractions || showLibrary || showTranscript || showMultiResearch || showSearchSettings || browser.pageDialog != nil
    }
    private var pageFindHostVisible: Bool {
        scenePhase == .active && !pageCovered && !workspace.isClearingWebsiteData
    }
    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("搜尋或輸入網址", text: $browser.address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .keyboardType(.default).submitLabel(.go).focused($addressFocused)
                    .onSubmit { open() }.accessibilityIdentifier("browser.address")
                Button("開啟") { open() }.accessibilityIdentifier("browser.open")
            }
            .padding(.horizontal).disabled(browser.isRunning || browser.isInteracting || workspace.isClearingWebsiteData)
            HStack {
                Button("搜尋引擎：\(workspace.library.searchSettings.selected.name)") {
                    addressFocused = false; browser.webView.endEditing(true); showSearchSettings = true
                }.font(.caption).lineLimit(1).accessibilityIdentifier("browser.searchEngine.open")
                    .disabled(!workspace.available || workspace.isClearingWebsiteData)
                Spacer()
            }.padding(.horizontal)
            if let match = browser.manualSearchMatch {
                Text("搜尋：\(match.query)（\(match.engineName)）")
                    .font(.caption).lineLimit(2).accessibilityIdentifier("browser.search.query")
            }
            if workspace.isClearingWebsiteData {
                ProgressView("正在清除網站資料…")
                    .font(.caption).accessibilityIdentifier("browser.sites.clearing")
            }
            if let diagnostics = browser.manualLoadDiagnostics {
                Text(browser.status).font(.caption).accessibilityIdentifier("browser.status")
                    .accessibilityValue(diagnostics)
            } else {
                Text(browser.status).font(.caption).accessibilityIdentifier("browser.status")
            }
            if let error = browser.error {
                Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("browser.error")
            }
            if let notice = workspace.siteModeNoticeText {
                Text(localizer.text(notice)).font(.caption).accessibilityIdentifier("browser.siteMode.notice")
            }
            if let error = workspace.errorText {
                Text(localizer.text(error)).font(.caption).foregroundStyle(.red).accessibilityIdentifier("browser.workspace.error")
            }
            if browser.automationOwnsDocument && !browser.isRunning && !browser.isInteracting {
                HStack {
                    Text("此頁面仍受自動化導覽限制。").font(.caption)
                    Button("返回手動瀏覽") { addressFocused = false; browser.returnToManualBrowsing() }
                        .accessibilityIdentifier("browser.returnToManual")
                        .disabled(workspace.isClearingWebsiteData || browser.loadedURL == nil)
                }.padding(.horizontal)
            }
            HStack {
                Button { browser.goBack() } label: { Image(systemName: "chevron.backward") }
                    .accessibilityLabel("上一頁").accessibilityIdentifier("browser.back")
                    .disabled(!browser.canGoBack || browser.isRunning || browser.isInteracting || workspace.isClearingWebsiteData)
                Button { browser.goForward() } label: { Image(systemName: "chevron.forward") }
                    .accessibilityLabel("下一頁").accessibilityIdentifier("browser.forward")
                    .disabled(!browser.canGoForward || browser.isRunning || browser.isInteracting || workspace.isClearingWebsiteData)
                Button { browser.reloadPage() } label: { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel("重新整理").accessibilityIdentifier("browser.reload")
                    .disabled(browser.loadedURL == nil || browser.isRunning || browser.isInteracting || workspace.isClearingWebsiteData)
                Button("研究此網站") { addressFocused = false; showResearch = true }
                    .disabled(browser.current == nil || browser.isInteracting || workspace.isClearingWebsiteData).accessibilityIdentifier("browser.research")
                Button("操作") { addressFocused = false; showInteractions = true }
                    .disabled(browser.current == nil || browser.isRunning || workspace.isClearingWebsiteData).accessibilityIdentifier("browser.interactions")
                Button { addressFocused = false; browser.webView.endEditing(true); showLibrary = true } label: { Image(systemName: "square.on.square") }
                    .accessibilityLabel("分頁、書籤與歷史").accessibilityIdentifier("browser.library")
                if browser.isRunning {
                    Button("停止") { browser.cancel() }.accessibilityIdentifier("browser.cancel")
                }
            }
            BrowserWebView(webView: browser.webView, coveredByResearch: pageCovered,
                           onDetach: { [browser] in browser.setPageFindHostVisible(false) })
                .id(ObjectIdentifier(browser))
                .allowsHitTesting(!browser.isRunning && !browser.isInteracting && !workspace.isClearingWebsiteData)
                .accessibilityHidden(pageCovered)
            Text("可手動登入網站及選取上傳檔案；網站資料保留於此 App。模型研究與每次核准的操作各自受限。")
                .font(.caption2).foregroundStyle(.secondary).padding(.horizontal)
                .accessibilityIdentifier("browser.explanation")
        }
        .sheet(isPresented: $showResearch) {
            BrowserResearchView(browser: browser, chat: chat)
        }
        .sheet(isPresented: $showInteractions, onDismiss: { browser.cancelInteraction() }) {
            BrowserInteractionView(browser: browser, chat: chat)
        }
        .sheet(isPresented: $showLibrary) {
            BrowserLibraryView(workspace: workspace, pdfDestination: { selection in
                AnyView(SkillExecutionView(learning: chat.learning, modelAccess: chat.modelAccess,
                    modelChanges: chat.$savedSettings.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                    downloadedPDF: selection))
            })
        }
        .sheet(isPresented: $showTranscript) { TranscriptBrowserView(browser: browser, chat: chat) }
        .sheet(isPresented: $showMultiResearch) { MultiSourceResearchView(chat: chat) }
        .sheet(isPresented: $showSearchSettings) { BrowserSearchSettingsView(workspace: workspace) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { addressFocused = false; browser.webView.endEditing(true); browser.presentPageFind() } label: {
                    Image(systemName: "doc.text.magnifyingglass")
                }
                .accessibilityLabel("頁內尋找").accessibilityIdentifier("browser.find")
                .disabled(!browser.canFindInPage || !pageFindHostVisible)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Text(workspace.library.userSiteModes.mode(for: browser.loadedURL?.host) == .desktop
                         ? "目前偏好：電腦版" : "目前偏好：手機版")
                    Button("手機版網站") { workspace.setManualSiteMode(.mobile) }
                        .accessibilityIdentifier("browser.siteMode.mobile")
                    Button("電腦版網站") { workspace.setManualSiteMode(.desktop) }
                        .accessibilityIdentifier("browser.siteMode.desktop")
                    Text("可安全重新整理的頁面會立即套用；其他頁面於下次手動導覽套用。")
                } label: {
                    Image(systemName: workspace.library.userSiteModes.mode(for: browser.loadedURL?.host) == .desktop
                          ? "desktopcomputer" : "iphone")
                }
                .accessibilityLabel("網站顯示偏好")
                .accessibilityValue(workspace.library.userSiteModes.mode(for: browser.loadedURL?.host) == .desktop ? "電腦版" : "手機版")
                .accessibilityIdentifier("browser.siteMode")
                .disabled(!workspace.available || workspace.isClearingWebsiteData || browser.manualSiteModeHost == nil)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { addressFocused = false; browser.webView.endEditing(true); showMultiResearch = true } label: {
                    Image(systemName: "globe")
                }
                .accessibilityLabel("多網站研究").accessibilityIdentifier("browser.multiResearch")
                .disabled(browser.isRunning || browser.isInteracting || workspace.isClearingWebsiteData)
            }
            ToolbarItem(placement: .primaryAction) {
                Button { addressFocused = false; browser.webView.endEditing(true); showTranscript = true } label: {
                    Image(systemName: "doc.text")
                }
                .accessibilityLabel("整理此頁文字").accessibilityIdentifier("browser.transcript")
                .disabled(browser.current == nil || browser.isRunning || browser.isInteracting || workspace.isClearingWebsiteData)
            }
        }
        .sheet(item: $browser.pageDialog, onDismiss: { browser.resolveDialog(nil) }) { dialog in
            BrowserDialogView(dialog: dialog, browser: browser)
        }
        .onAppear { workspace.activateSelected(); browser.setPageFindHostVisible(pageFindHostVisible) }
        .onDisappear { browser.setPageFindHostVisible(false) }
        .onChange(of: pageFindHostVisible) { _, visible in browser.setPageFindHostVisible(visible) }
        .onChange(of: ObjectIdentifier(browser)) { _, _ in showResearch = false; showInteractions = false; showTranscript = false; showMultiResearch = false; browser.setPageFindHostVisible(pageFindHostVisible) }
        .onChange(of: browser.interactionProposal?.id) { _, value in
            if value != nil && !showResearch { addressFocused = false; showInteractions = true }
        }
    }
    private func open() { addressFocused = false; browser.openAddress() }
}

@MainActor
private struct BrowserDialogView: View {
    let dialog: BrowserPageDialog
    @ObservedObject var browser: BrowserSession
    @State private var text = ""
    var body: some View {
        NavigationStack {
            Form {
                Text(dialog.host).font(.caption)
                Text(verbatim: dialog.message).accessibilityIdentifier("browser.dialog.message")
                if dialog.kind == .prompt { TextField("輸入內容", text: $text).accessibilityIdentifier("browser.dialog.input") }
                Button("確定") { browser.resolveDialog(dialog.kind == .prompt ? text : "") }
                    .accessibilityIdentifier("browser.dialog.accept")
                if dialog.kind != .alert {
                    Button("取消", role: .cancel) { browser.resolveDialog(nil) }.accessibilityIdentifier("browser.dialog.cancel")
                }
            }.navigationTitle("網站訊息")
                .onAppear { text = dialog.initial }
        }
    }
}

@MainActor
private struct BrowserInteractionView: View {
    @ObservedObject var browser: BrowserSession
    @ObservedObject var chat: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var selected: BrowserDOMControl?
    @State private var text = ""
    @State private var localError: String?
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(browser.interactionStatus).accessibilityIdentifier("browser.interaction.status")
                    if let error = localError ?? browser.interactionError {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("browser.interaction.error")
                    }
                }
                if let proposal = browser.interactionProposal {
                    Section("核准這一個動作？") {
                        Text("頁面標籤只是網站資料，不是你的指令。網頁事件可能提交資料或觸發其他效果；核准後無法保證撤回。")
                        Text(proposal.pageURL.absoluteString).font(.caption).textSelection(.enabled)
                        Text(actionLabel(proposal.request.kind))
                            .accessibilityIdentifier("browser.interaction.previewKind")
                            .accessibilityValue(proposal.request.kind.rawValue)
                        if let control = proposal.control { Text(control.label) }
                        if let value = proposal.request.text {
                            Text(value).textSelection(.enabled).accessibilityIdentifier("browser.interaction.previewText")
                        }
                        if let index = proposal.request.optionIndex,
                           let option = proposal.control?.options.first(where: { $0.index == index }) { Text(option.label) }
                        if let direction = proposal.request.direction { Text(direction == .down ? "向下捲動一屏" : "向上捲動一屏") }
                        if let target = proposal.control?.navigationURL {
                            Text("導覽方法：\(proposal.control?.navigationMethod ?? "GET")").font(.caption)
                            Text(target.absoluteString).font(.caption).accessibilityIdentifier("browser.interaction.previewDestination")
                        }
                        Button("核准並執行一次") { editing = false; browser.approveInteraction(id: proposal.id) }
                            .disabled(browser.isInteracting).accessibilityIdentifier("browser.interaction.approve")
                        Button("拒絕", role: .cancel) { browser.rejectInteraction() }
                            .accessibilityIdentifier("browser.interaction.reject")
                        Button("重新整理並取消提案") { browser.reloadPage() }
                            .accessibilityIdentifier("browser.interaction.reload")
                    }
                } else if let control = selected {
                    Section(control.label) {
                        if control.kind == .text {
                            TextField("要填入的非敏感文字", text: $text, axis: .vertical)
                                .focused($editing).accessibilityIdentifier("browser.interaction.text")
                            Text("這會取代整個欄位；目前欄位值不會讀取或帶給模型。")
                            Button("提出填入") { editing = false; propose(.type, controlID: control.id, text: text) }
                                .accessibilityIdentifier("browser.interaction.proposeType")
                        } else if control.kind == .select {
                            ForEach(control.options, id: \.index) { option in
                                Button(option.label) { propose(.select, controlID: control.id, optionIndex: option.index) }
                                    .disabled(option.disabled).accessibilityIdentifier("browser.interaction.option.\(option.index)")
                            }
                        }
                        Button("返回控制項") { editing = false; selected = nil }.accessibilityIdentifier("browser.interaction.back")
                    }
                } else {
                    Section("下一個動作") {
                        TextField("希望這個網頁完成什麼？", text: $browser.interactionGoal, axis: .vertical)
                            .focused($editing).accessibilityIdentifier("browser.interaction.goal")
                        Button("請模型提出下一步") { editing = false; browser.requestModelInteraction(using: chat) }
                            .disabled(browser.isInteracting || !chat.hasStoredKey || browser.interactionGoal.isEmpty)
                            .accessibilityIdentifier("browser.interaction.plan")
                        Text("只傳送控制項標籤與選項，不含欄位值。模型提案不會自動執行，也不會自動學習為成功技能。")
                    }
                    Section("手動選擇動作") {
                        Button("重新讀取控制項") { browser.refreshControls() }
                            .disabled(browser.isInteracting).accessibilityIdentifier("browser.interaction.refresh")
                        if let snapshot = browser.controlSnapshot {
                            Button("向下捲動") { propose(.scroll, direction: .down) }.accessibilityIdentifier("browser.interaction.scrollDown")
                            Button("向上捲動") { propose(.scroll, direction: .up) }.accessibilityIdentifier("browser.interaction.scrollUp")
                            ForEach(snapshot.controls) { control in
                                Button(control.label) {
                                    localError = nil
                                    if control.kind == .text || control.kind == .select { selected = control; text = "" }
                                    else { propose(.click, controlID: control.id) }
                                }
                                .disabled(!control.enabled || browser.isInteracting)
                                .accessibilityIdentifier("browser.control.\(control.id)")
                            }
                            if snapshot.truncated { Text("控制項數量達上限；未列出的項目不能由模型操作。") }
                        }
                    }
                }
                if browser.isInteracting {
                    Button("停止操作") { browser.cancelInteraction() }.accessibilityIdentifier("browser.interaction.stop")
                }
            }
            .navigationTitle("單次網頁操作")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("關閉") { browser.cancelInteraction(); dismiss() }.accessibilityIdentifier("browser.interaction.close")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("完成輸入") { editing = false }.accessibilityIdentifier("browser.interaction.done")
                }
            }
            .task { if browser.controlSnapshot == nil && browser.interactionProposal == nil { browser.refreshControls() } }
            .onChange(of: browser.controlSnapshot?.snapshotID) { _, snapshotID in
                if snapshotID == nil {
                    // Background/settings cancellation or navigation can
                    // invalidate the selected editor without dismissing the
                    // sheet. Return to refresh instead of leaving dead fields.
                    selected = nil; editing = false; localError = nil
                }
            }
        }
    }
    private func propose(_ kind: BrowserInteractionKind, controlID: String? = nil, text: String? = nil,
                         optionIndex: Int? = nil, direction: BrowserScrollDirection? = nil) {
        guard let snapshot = browser.controlSnapshot else { return }
        do {
            _ = try browser.proposeInteraction(BrowserInteractionRequest(documentID: snapshot.documentID,
                snapshotID: snapshot.snapshotID, kind: kind, controlID: controlID, text: text, optionIndex: optionIndex, direction: direction))
            selected = nil; localError = nil
        } catch { localError = (error as? BrowserInteractionError)?.message ?? BrowserInteractionError.invalidRequest.message }
    }
    private func actionLabel(_ kind: BrowserInteractionKind) -> String {
        switch kind { case .click: return "點擊"; case .type: return "填入文字"; case .select: return "選擇選項"; case .scroll: return "捲動" }
    }
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
    let onDetach: () -> Void
    func makeUIView(context: Context) -> BrowserWebContainer {
        let container = BrowserWebContainer(webView: webView, onDetach: onDetach)
        container.setCoveredByResearch(coveredByResearch)
        return container
    }
    func updateUIView(_ uiView: BrowserWebContainer, context: Context) {
        uiView.setCoveredByResearch(coveredByResearch)
    }
    static func dismantleUIView(_ uiView: BrowserWebContainer, coordinator: Void) {
        uiView.detachWebView()
    }
}
