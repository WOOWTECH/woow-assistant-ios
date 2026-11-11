import SwiftUI
import AssistantSkills

@MainActor
struct ContentView: View {
    @State private var selection: AppSection = .chat
    @State private var notificationNavigationID = UUID()
    @StateObject private var session = ChatSession()
    @StateObject private var mcpSession = MCPSession()
    @StateObject private var browserWorkspace = BrowserWorkspace()
    @StateObject private var preferences = SelfConfigurationStore.applicationPreferences()
    @StateObject private var languages = AppLanguageStore.applicationPreferences()
    @StateObject private var notifications = TaskNotificationStore.applicationStore()
    private var browser: BrowserSession { browserWorkspace.selected }
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                switch selection {
                case .chat:
                    ChatView(session: session, mcp: mcpSession)
                case .settings:
                    ModelSettingsView(session: session, preferences: preferences, notifications: notifications, languages: languages)
                case .tools:
                    MCPToolsView(session: mcpSession)
                case .memory:
                    MemoryDataView(store: session.learning, browser: browser, modelAccess: session.modelAccess,
                                   modelChanges: session.$savedSettings.dropFirst().map { _ in () }.eraseToAnyPublisher(),
                                   onOpenBrowser: { selection = .browser })
                case .browser:
                    BrowserView(browser: browser, chat: session, workspace: browserWorkspace)
                }
            }
            .navigationTitle(selection.title)
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                sectionNavigation
            }
        }
        .id(notificationNavigationID)
        #if DEBUG
        .environment(\.notificationRouteObservation,
                     MCPApprovalView.exposesFixtureIdentity(arguments: ProcessInfo.processInfo.arguments)
                     ? "generation=\(notificationNavigationID.uuidString);destination=\(selection.rawValue)" : "")
        #endif
        .environmentObject(preferences)
        .appLanguage(languages)
        .preferredColorScheme(preferences.preferredColorScheme)
        .taskNotifications(chat: session, store: notifications) { destination in
            switch destination {
            case .chat: selection = .chat
            case .browser: selection = .browser
            }
            // Destination-style links are not all represented in NavigationPath.
            // Pop pushed details when the user opens a notification, retaining
            // the root-owned sessions and stores above.
            notificationNavigationID = UUID()
        }
        .onAppear {
            session.learning.onUserChange = { [weak browserWorkspace, weak session] in
                browserWorkspace?.cancelAllWork(preservingFrozenReferences: session?.learning.referenceEditInProgress == true)
                session?.invalidateProfileReview()
            }
            mcpSession.onConnectionChange = { [weak session] in session?.cancelMCP() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { session.pdfEnteredBackground() }
            if phase != .active {
                session.cancelMCP()
                session.invalidateProfileReview()
                browserWorkspace.cancelAllWork()
                if mcpSession.phase == .connected || mcpSession.isBusy { mcpSession.disconnect() }
            }
        }
    }

    // Keep every section reachable in a compact iPhone layout, including while typing.
    private var sectionNavigation: some View {
        VStack(spacing: 0) {
            #if DEBUG
            if (try? ChatPDFUITestConfiguration.resolve(arguments: ProcessInfo.processInfo.arguments)) != nil {
                Text("PDF 模型請求事件測試觀測").font(.caption2)
                    .accessibilityIdentifier("chat.pdf.requestEvents")
                    .accessibilityValue(String(session.pdfModelRequestEvents))
            }
            if (try? UITestChatStreamingConfiguration.resolve(arguments: ProcessInfo.processInfo.arguments)) != nil {
                Text("串流通知送出測試觀測")
                    .font(.caption2)
                    .accessibilityIdentifier("stream.fixture.notifications")
                    .accessibilityValue(String(notifications.streamingFixtureCompletedAddAttempts))
            }
            if MCPApprovalView.exposesFixtureIdentity(arguments: ProcessInfo.processInfo.arguments) {
                // Observe the existing route identity only. No test can mutate
                // it or invoke the notification-open callback through this Text.
                Text("通知導頁測試觀測")
                    .font(.caption2)
                    .accessibilityIdentifier("notifications.routeObservation")
                    .accessibilityValue("generation=\(notificationNavigationID.uuidString);destination=\(selection.rawValue)")
            }
            #endif
            Divider()
            HStack(spacing: 0) {
                ForEach(AppSection.allCases) { section in
                    Button {
                        selection = section
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: section.symbol)
                                .font(.body)
                            Text(section.shortTitle)
                                .font(.caption)
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(selection == section ? Color.accentColor : Color.secondary)
                    .accessibilityLabel(section.title)
                    .accessibilityValue(selection == section ? "已選取" : "未選取")
                    .accessibilityAddTraits(selection == section ? .isSelected : [])
                    .accessibilityIdentifier("navigation.\(section.rawValue)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }
}

private enum AppSection: String, CaseIterable, Identifiable {
    case chat
    case browser
    case tools
    case memory
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: return "對話"
        case .browser: return "瀏覽器"
        case .tools: return "Skills 與 MCP"
        case .memory: return "記憶與資料"
        case .settings: return "設定"
        }
    }

    var shortTitle: String {
        switch self {
        case .tools: return "工具"
        case .memory: return "資料"
        default: return title
        }
    }

    var symbol: String {
        switch self {
        case .chat: return "message"
        case .browser: return "globe"
        case .tools: return "puzzlepiece.extension"
        case .memory: return "folder"
        case .settings: return "gearshape"
        }
    }

    var explanation: String {
        switch self {
        case .chat:
            return "請先到設定填寫模型服務與 API Key。"
        case .browser:
            return "此版本尚未載入網頁，也未進行網站連線驗證。分頁、登入、上傳、下載與頁面操作仍待實作。"
        case .tools:
            return "此版本尚未載入或執行 Skills，也未連接 MCP 伺服器；目前沒有可呼叫的工具。"
        case .memory:
            return "記憶、個人技能與待確認草稿；附件與網站資料另行管理。"
        case .settings:
            return "設定模型服務；通知、語言與外觀設定仍待實作。"
        }
    }
}

@MainActor
private struct ChatView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var mcp: MCPSession
    @FocusState private var isEditingDraft: Bool
    @State private var showsMCPResults = false
    @State private var showsArchive = false
    @State private var showsPDF = false

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 6) {
                Text(session.chatStatus)
                    .font(.headline)
                    .accessibilityIdentifier("chat.status")
                Text("已完成的問答會加密保存在此裝置；未完成任務與未送出的草稿不會保存。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("chat.historyNotice")
                if session.archive != nil {
                    Button("歷史對話") { isEditingDraft = false; showsArchive = true }
                        .disabled(session.isSubmitting)
                        .accessibilityIdentifier("chat.archive")
                }
                if session.isUITestMode {
                    Text("UI 測試模式：固定回覆，不會呼叫網路。")
                        .font(.caption)
                        .accessibilityIdentifier("uitest.banner")
                }
            }
            .multilineTextAlignment(.center)

            LearningChatNotes(store: session.learning)

            HStack {
                Button(session.pdfAttachment == nil ? "附加 PDF" : "檢視 PDF 附件") {
                    isEditingDraft = false; showsPDF = true
                }.disabled(session.isSubmitting).accessibilityIdentifier("chat.pdf.open")
                if let attachment = session.pdfAttachment {
                    Text(verbatim: attachment.plan.filename).lineLimit(1).accessibilityIdentifier("chat.pdf.card")
                    Button("移除") { session.removePDF() }.accessibilityIdentifier("chat.pdf.removeInline")
                }
            }
            if session.pdfAttachment != nil {
                Text(session.usesMCP ? "PDF 查詢不使用 MCP；請先關閉 MCP 選項。" : ChatPDFAttachment.scopeNotice)
                    .font(.caption).accessibilityIdentifier("chat.pdf.boundary")
            }

            if mcp.canUseInConversation || session.usesMCP {
                Toggle("本次對話使用 MCP 工具", isOn: $session.usesMCP)
                    .font(.callout)
                    .disabled(session.isSubmitting)
                    .accessibilityIdentifier("chat.useMCP")
            }
            if let activity = session.mcpActivity {
                Text(activity).font(.caption)
                    .accessibilityIdentifier("chat.mcpActivity")
                    .accessibilityValue(session.mcpDiagnostics ?? "")
            }
            if session.profileReceipt != nil {
                Text("本次對話曾儲存個人檔案；可到資料頁查看目前內容。")
                    .font(.caption).accessibilityIdentifier("chat.profileReceipt")
            }
            if session.memoryReceipt != nil {
                Text("本次對話曾儲存記憶修改；可在資料頁查看目前內容。")
                    .font(.caption).accessibilityIdentifier("chat.memoryReceipt")
            }
            if !session.mcpSteps.isEmpty {
                Button("檢視工具結果（\(session.mcpSteps.count)）") { showsMCPResults = true }
                    .font(.caption).accessibilityIdentifier("chat.mcpResults")
                    .disabled(session.isSubmitting)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if !session.hasStoredKey {
                            Text(AppSection.chat.explanation)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("chat.explanation")
                        }
                        ForEach(Array(session.entries.enumerated()), id: \.element.id) { index, entry in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.role == "user" ? "你" : "助理")
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(entry.content)
                                    .textSelection(.enabled)
                                    .accessibilityIdentifier("chat.message.\(index).\(entry.role)")
                                if let pdf = entry.pdf {
                                    ArchivedPDFEvidenceView(evidence: pdf, identifier: "chat.pdf.saved.\(index)")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(entry.id)
                        }
                        if let preview = session.replyPreview {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(preview.status).font(.caption.bold()).foregroundStyle(.secondary)
                                    .accessibilityIdentifier("chat.partialStatus")
                                Text(preview.text).textSelection(.enabled)
                                    .accessibilityIdentifier("chat.partialReply")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(preview.id)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: session.entries.count) { _, _ in
                    if let id = session.entries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
                .onChange(of: session.replyPreview?.text) { _, _ in
                    if let id = session.replyPreview?.id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }

            if let error = session.chatError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("chat.error")
            }
            if let notice = session.chatNotice {
                Text(notice)
                    .font(.callout)
                    .accessibilityIdentifier("chat.notice")
            }
            if let notice = session.archiveNotice {
                Text(notice).font(.callout).foregroundStyle(.orange)
                    .accessibilityIdentifier("chat.archiveNotice")
                if session.canRetryArchiveSave {
                    Button("重試保存") { session.retryArchiveSave() }
                        .accessibilityIdentifier("chat.archiveRetry")
                }
            }
            TextField("輸入訊息", text: $session.draft)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .focused($isEditingDraft)
                .submitLabel(.done)
                .onSubmit { isEditingDraft = false }
                .disabled(session.isSubmitting)
                .accessibilityLabel("訊息草稿")
                .accessibilityIdentifier("chat.draft")
            HStack {
                Button("新對話") { session.newConversation() }
                    .disabled(session.isSubmitting)
                    .accessibilityIdentifier("chat.newConversation")
                Button("傳送") {
                    isEditingDraft = false
                    session.send(mcp: session.usesMCP ? mcp : nil)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!session.canSend)
                .accessibilityIdentifier("chat.send")
                if session.isSubmitting {
                    ProgressView().accessibilityLabel("等待回覆")
                    Button("取消") { session.cancel() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("chat.cancel")
                }
            }
            .frame(minHeight: 44)
        }
        .padding()
        .sheet(isPresented: $showsPDF) { ChatPDFAttachmentView(session: session) }
        .sheet(isPresented: $showsArchive) {
            if let store = session.archive { ConversationArchiveView(store: store, session: session) }
        }
        .sheet(item: Binding(get: { session.pendingMCPApproval }, set: { _ in })) { proposal in
            MCPApprovalView(proposal: proposal,
                            approve: { session.resolveMCPApproval(id: proposal.id, approved: true) },
                            decline: { session.resolveMCPApproval(id: proposal.id, approved: false) })
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showsMCPResults) { MCPResultsView(steps: session.mcpSteps) }
        .sheet(item: Binding(get: { session.pendingProfileReview }, set: { _ in })) { review in
            UserProfileToolReviewView(review: review,
                approve: { session.resolveProfileReview(id: review.id, approved: true) },
                decline: { session.resolveProfileReview(id: review.id, approved: false) })
                .interactiveDismissDisabled()
        }
        .sheet(item: Binding(get: { session.pendingMemoryReview }, set: { _ in })) { review in
            MemoryToolReviewView(review: review,
                approve: { session.resolveMemoryReview(id: review.id, approved: true) },
                decline: { session.resolveMemoryReview(id: review.id, approved: false) })
                .interactiveDismissDisabled()
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { isEditingDraft = false }
                    .accessibilityIdentifier("chat.dismissKeyboard")
            }
        }
    }
}

@MainActor
private struct LearningChatNotes: View {
    @ObservedObject var store: LearningStore
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if store.isLearning {
                Text("正在整理你說過的事…")
                    .font(.caption).accessibilityIdentifier("chat.learning")
            }
            if let notice = store.notice {
                Text(notice).font(.caption).accessibilityIdentifier("chat.learningNotice")
            }
            if let error = store.error {
                Text(error).font(.caption).foregroundStyle(.orange)
                    .accessibilityIdentifier("chat.learningError")
            }
            ForEach(Array(store.notes.enumerated()), id: \.element.memoryID) { index, note in
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.noteText(note)).font(.caption)
                        .accessibilityIdentifier("chat.memoryNote.\(index)")
                    HStack {
                        if store.canReviewMemory(note) {
                            Button("批准") { store.approvePendingMemory(note) }
                                .accessibilityIdentifier("chat.approveMemory.\(index)")
                            Button("拒絕") { store.rejectPendingMemory(note) }
                                .accessibilityIdentifier("chat.rejectMemory.\(index)")
                        }
                        if note.undoToken != nil {
                            Button("撤銷") { store.undo(note) }
                                .accessibilityIdentifier("chat.undoMemory.\(index)")
                        }
                    }
                    .font(.caption)
                }
            }
        }
    }
}

@MainActor
private struct ModelSettingsView: View {
    @ObservedObject var session: ChatSession
    @ObservedObject var preferences: SelfConfigurationStore
    @ObservedObject var notifications: TaskNotificationStore
    @ObservedObject var languages: AppLanguageStore
    @FocusState private var editingField: Field?
    private enum Field: Hashable { case baseURL, model, key }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("模型設定")
                    .font(.title2.bold())
                    .accessibilityIdentifier("settings.status")
                Text(session.hasStoredKey ? "已儲存金鑰；留空可沿用同一服務的金鑰。" : "尚未儲存金鑰。")
                    .font(.callout)
                    .accessibilityIdentifier("settings.keyStatus")
                HStack {
                    Text("HTTPS Base URL")
                    Spacer()
                    Button("清除網址") {
                        session.baseURLDraft = ""
                        editingField = .baseURL
                    }
                    .accessibilityIdentifier("settings.clearBaseURL")
                }
                TextField("https://api.example.com/v1", text: $session.baseURLDraft)
                    .keyboardType(.URL)
                    .focused($editingField, equals: .baseURL)
                    .accessibilityIdentifier("settings.baseURL")
                Text("模型名稱")
                TextField("供應商提供的模型名稱", text: $session.modelDraft)
                    .focused($editingField, equals: .model)
                    .accessibilityIdentifier("settings.model")
                Text("API Key")
                SecureField("輸入金鑰；已儲存時可留空", text: $session.keyDraft)
                    .focused($editingField, equals: .key)
                    .privacySensitive()
                    .accessibilityIdentifier("settings.apiKey")
                HStack {
                    Button("儲存設定") {
                        editingField = nil
                        session.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isSubmitting)
                    .accessibilityIdentifier("settings.save")
                    Button("移除設定與金鑰", role: .destructive) {
                        editingField = nil
                        session.removeSettings()
                    }
                    .buttonStyle(.bordered)
                    .disabled(session.isSubmitting)
                    .accessibilityIdentifier("settings.remove")
                }
                if let error = session.settingsError {
                    Text(error)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("settings.error")
                }
                if let notice = session.settingsNotice {
                    Text(notice)
                        .accessibilityIdentifier("settings.notice")
                }
                Text("金鑰只儲存在此裝置的 Keychain。更換主機或連接埠必須重新輸入金鑰。")
                Text("更換服務、模型或金鑰會開始新的對話，草稿保留。移除設定會清除本次對話及此 App 的模型金鑰。")
                Text("儲存只代表設定已保存；首次傳送才會連線至你設定的服務。")
                NavigationLink {
                    SelfConfigurationView(store: preferences, modelAccess: session.modelAccess, languages: languages)
                } label: { Text("外觀與模型調整權限") }
                    .accessibilityIdentifier("settings.appearance")
                NavigationLink {
                    TaskNotificationSettingsView(store: notifications)
                } label: { Text("任務通知") }
                    .accessibilityIdentifier("settings.notifications")
            }
            .textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .onSubmit { editingField = nil }
            .padding()
        }
        .scrollDismissesKeyboard(.interactively)
        .onDisappear { session.keyDraft = "" }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成") { editingField = nil }
                    .accessibilityIdentifier("settings.dismissKeyboard")
            }
        }
    }
}

private struct FeaturePlaceholder: View {
    let section: AppSection

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: section.symbol)
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("\(section.title)尚未實作")
                    .font(.title2.bold())
                    .accessibilityIdentifier("\(section.rawValue).status")
                Text(section.explanation)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(section.rawValue).explanation")
            }
            .multilineTextAlignment(.center)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding()
        }
    }
}
