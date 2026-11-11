import AssistantModels
import AssistantMCP
import AssistantMemory
import AssistantPersistence
import AssistantSkills
import Combine
import Foundation

struct ModelAccess {
    let client: any ChatModelClient
    let configuration: ModelConfiguration
    let key: String
}

struct ChatEntry: Identifiable {
    let id: UUID
    let role: String
    let content: String
    let pdf: ArchivedPDFAnswer?
    init(id: UUID = UUID(), role: String, content: String, pdf: ArchivedPDFAnswer? = nil) {
        self.id = id; self.role = role; self.content = content
        self.pdf = pdf
    }
}

/// Display-only text from one unfinished plain request. It never becomes a
/// ChatEntry, archive turn, learning utterance or notification completion.
struct ChatReplyPreview: Identifiable, Equatable {
    enum Phase { case receiving, cancelled, failed }
    static let maximumUTF8Bytes = 4 * 1024 * 1024
    let id: UUID
    let text: String
    var phase: Phase
    var status: String {
        switch phase {
        case .receiving: return "回覆產生中・尚未完成，未保存"
        case .cancelled: return "已取消・部分回覆未保存"
        case .failed: return "回覆未完成・部分回覆未保存"
        }
    }
}

struct MCPApprovalRequest: Identifiable {
    let id = UUID()
    let name: String
    let arguments: JSONValue
    var argumentsText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(arguments)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

@MainActor
final class ChatSession: ObservableObject {
    let learning: LearningStore
    let archive: ConversationArchiveStore?
    private var conversationID = UUID().uuidString
    private var conversationDestination: ConversationDestination?
    @Published private(set) var archiveNotice: String?
    private var pendingArchiveSave: (record: ArchivedConversation, expected: ArchivedConversation?)?
    var canRetryArchiveSave: Bool { pendingArchiveSave != nil && !isSubmitting }
    @Published var draft = ""
    @Published var baseURLDraft = ""
    @Published var modelDraft = ""
    @Published var keyDraft = ""
    @Published private(set) var entries: [ChatEntry] = []
    @Published private(set) var replyPreview: ChatReplyPreview?
    @Published private(set) var pdfAttachment: ChatPDFAttachment?
    private var pdfChanges: AnyCancellable?
    @Published private(set) var savedSettings: SavedModelSettings?
    @Published private(set) var hasStoredKey = false
    @Published private(set) var isSubmitting = false
    @Published private(set) var chatError: String?
    @Published private(set) var chatNotice: String?
    @Published private(set) var settingsError: String?
    @Published private(set) var settingsNotice: String?
    @Published var usesMCP = false
    @Published private(set) var pendingMCPApproval: MCPApprovalRequest?
    @Published private(set) var mcpActivity: String?
    @Published private(set) var mcpSteps: [MCPConversationStep] = []
    @Published private(set) var mcpDiagnostics: String?
    @Published private(set) var pendingProfileReview: UserProfileToolReview?
    @Published private(set) var profileReceipt: UserProfileToolReceipt?
    private var profileReceiptRequestID: UUID?
    private var profileApprovalContinuation: CheckedContinuation<Bool, Never>?
    @Published private(set) var pendingMemoryReview: MemoryToolReview?
    @Published private(set) var memoryReceipt: MemoryToolReceipt?
    private var memoryReceiptRequestID: UUID?
    private var memoryApprovalContinuation: CheckedContinuation<Bool, Never>?
    private var mcpPhase = "idle"
    private var mcpModelCalls = 0
    private var mcpFormatCorrections = 0
    private var mcpApprovalContinuation: CheckedContinuation<Bool, Never>?
    private var isMCPRun = false
    private var mcpSentCount = 0

    #if DEBUG
    @Published private(set) var pdfModelRequestEvents = 0
    #endif
    let isUITestMode: Bool
    private let repository: ModelSettingsRepository
    private let client: any ChatModelClient
    private var request: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var requestID: UUID?
    /// Read-only completion handle for joining an already captured task after cancellation.
    var capturedArchiveRequest: Task<Void, Never>? { request }

    init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        let streamFixture: UITestChatStreamingConfiguration?
        let pdfFixture: ChatPDFUITestConfiguration?
        do {
            streamFixture = try UITestChatStreamingConfiguration.resolve(arguments: arguments)
            pdfFixture = try ChatPDFUITestConfiguration.resolve(arguments: arguments)
        }
        catch { preconditionFailure("Chat UI fixture requires one isolated UI test mode and UUID namespace; no Live mode") }
        #endif
        learning = LearningStore()
        archive = ConversationArchiveStore()
        var bootstrapFailure: String?
        #if DEBUG
        precondition(!(arguments.contains("-UITestMode") && arguments.contains("-LiveModelUITest")), "Choose one UI test mode")
        if arguments.contains("-LiveModelUITest") {
            repository = LiveModelUITestSupport.repository(arguments: arguments)
            client = HTTPChatModelClient()
            isUITestMode = false
            do {
                if arguments.contains("-LiveModelUITestCleanup") {
                    try repository.remove()
                } else {
                    try LiveModelUITestSupport.bootstrap(repository, environment: ProcessInfo.processInfo.environment)
                }
            }
            catch { bootstrapFailure = Self.settingsMessage(error) }
        } else if arguments.contains("-UITestMode") {
            repository = UITestModelFixture.repository(arguments: arguments)
            if let pdfFixture { client = UITestPDFChatModelClient(configuration: pdfFixture) }
            else if let streamFixture { client = UITestStreamingChatModelClient(configuration: streamFixture) }
            else { client = UITestChatModelClient() }
            isUITestMode = true
        } else {
            repository = Self.liveRepository()
            client = HTTPChatModelClient()
            isUITestMode = false
        }
        #else
        repository = Self.liveRepository()
        client = HTTPChatModelClient()
        isUITestMode = false
        #endif
        loadSettings()
        if let bootstrapFailure { settingsError = "Live UI 測試設定未完成。\(bootstrapFailure)" }
    }

    /// Dependency boundary for exercising actual App transactions and request
    /// lifecycles with isolated storage; production uses the initializer above.
    init(learning: LearningStore, repository: ModelSettingsRepository, client: any ChatModelClient,
         archive: ConversationArchiveStore? = nil) {
        self.learning = learning
        self.archive = archive
        self.repository = repository
        self.client = client
        isUITestMode = false
        loadSettings()
    }

    private func loadSettings() {
        do {
            savedSettings = try repository.load()
            if let savedSettings {
                baseURLDraft = savedSettings.baseURL.absoluteString
                modelDraft = savedSettings.model
                _ = try repository.key(for: savedSettings)
                hasStoredKey = true
            }
        } catch {
            settingsError = Self.settingsMessage(error)
        }
    }

    var canSend: Bool {
        savedSettings != nil && hasStoredKey && !isSubmitting
            && (conversationDestination == nil || conversationDestination == archiveDestination)
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (pdfAttachment == nil || (pdfAttachment?.isReady == true && !usesMCP))
    }

    var archiveDestination: ConversationDestination? {
        guard let savedSettings, let account = UUID(uuidString: savedSettings.credentialAccount) else { return nil }
        return try? ConversationDestination(baseURL: savedSettings.baseURL.absoluteString,
            model: savedSettings.model, credentialAccount: account)
    }

    func canOpenConversation(_ record: ArchivedConversation) -> Bool {
        archive?.available == true && hasStoredKey && archiveDestination == record.destination
    }

    @discardableResult func openConversation(id: UUID) -> Bool {
        guard let record = archive?.state.conversations.first(where: { $0.id == id }),
              canOpenConversation(record) else { return false }
        // Publish restored entries only after submitting and approvals have ended.
        // Restored text cannot complete a notification ticket or resume a task.
        cancel()
        newConversation()
        usesMCP = false
        conversationID = record.id.uuidString
        conversationDestination = record.destination
        draft = ""
        entries = record.turns.flatMap { [ChatEntry(id: $0.userID, role: "user", content: $0.userText, pdf: $0.pdf),
                                         ChatEntry(id: $0.assistantID, role: "assistant", content: $0.assistantText)] }
        chatNotice = "已開啟保存的對話；尚未傳送任何訊息。"
        return true
    }

    @discardableResult func deleteConversation(id: UUID) -> Bool {
        if conversationID == id.uuidString { cancel() }
        guard archive?.delete(id: id) == true else { return false }
        if conversationID == id.uuidString { newConversation(); draft = "" }
        return true
    }

    func retryArchiveSave() {
        guard canRetryArchiveSave, let pendingArchiveSave, let archive else { return }
        do {
            try archive.save(pendingArchiveSave.record, expected: pendingArchiveSave.expected)
            self.pendingArchiveSave = nil; archiveNotice = nil
        } catch { archiveNotice = Self.archiveSaveFailure }
    }

    private static let archiveSaveFailure = "回覆已顯示，但本次對話未能保存；關閉程序後可能遺失。原有保存內容保留，沒有自動刪除舊對話。"

    func modelAccess() throws -> ModelAccess {
        guard let savedSettings, hasStoredKey else { throw HTTPChatModelError.invalidConfiguration }
        return ModelAccess(client: client, configuration: savedSettings.configuration,
                           key: try repository.key(for: savedSettings))
    }

    var chatStatus: String {
        if pendingProfileReview != nil { return "等待你核對個人檔案修改…" }
        if pendingMemoryReview != nil { return "等待你核對記憶修改…" }
        if pendingMCPApproval != nil { return "等待你核准 MCP 工具…" }
        if isSubmitting && isMCPRun { return "正在使用 MCP 處理對話…" }
        if isSubmitting { return "正在等待模型回覆…" }
        return savedSettings != nil && hasStoredKey ? "模型已設定" : "尚未設定模型"
    }

    func saveSettings() {
        guard !isSubmitting else { return }
        learning.onUserChange?()
        learning.cancelLearning()
        settingsError = nil
        settingsNotice = nil
        do {
            let result = try repository.save(baseURL: baseURLDraft, model: modelDraft, newKey: keyDraft)
            let changed = savedSettings?.baseURL != result.record.baseURL
                || savedSettings?.model != result.record.model
                || savedSettings?.credentialAccount != result.record.credentialAccount
            savedSettings = result.record
            hasStoredKey = true
            baseURLDraft = result.record.baseURL.absoluteString
            modelDraft = result.record.model
            keyDraft = ""
            if changed {
                pdfAttachment?.revokeDestination()
                entries = []
                replyPreview = nil
                conversationDestination = nil; archiveNotice = nil; pendingArchiveSave = nil
                profileReceipt = nil
                profileReceiptRequestID = nil
                memoryReceipt = nil
                memoryReceiptRequestID = nil
                conversationID = UUID().uuidString
                learning.resetConversationPresentation()
            }
            chatError = nil
            chatNotice = nil
            settingsNotice = result.cleanupFailed
                ? "新設定已儲存，尚未驗證連線。舊金鑰清理失敗，可用移除功能清除此 App 的模型金鑰。"
                : "設定已儲存，尚未驗證連線。"
        } catch {
            settingsError = Self.settingsMessage(error)
        }
    }

    func removeSettings() {
        guard !isSubmitting else { return }
        learning.onUserChange?()
        learning.cancelLearning()
        settingsError = nil
        settingsNotice = nil
        do {
            try repository.remove()
            pdfAttachment?.revokeDestination()
            savedSettings = nil
            hasStoredKey = false
            baseURLDraft = ""
            modelDraft = ""
            keyDraft = ""
            entries = []
            replyPreview = nil
            conversationDestination = nil; archiveNotice = nil; pendingArchiveSave = nil
            profileReceipt = nil
            profileReceiptRequestID = nil
            memoryReceipt = nil
            memoryReceiptRequestID = nil
            conversationID = UUID().uuidString
            learning.resetConversationPresentation()
            chatError = nil
            chatNotice = nil
            settingsNotice = "已移除此 App 的模型設定與金鑰；訊息草稿保留。"
        } catch {
            settingsError = Self.settingsMessage(error)
        }
    }

    func send(mcp: MCPSession? = nil) {
        guard canSend, let savedSettings else { return }
        if let pdfAttachment { sendPDF(pdfAttachment); return }
        let mcpConnection: ((any MCPDiscovering), [MCPTool], [MCPResource])?
        if usesMCP {
            do {
                guard let mcp else { throw MCPError.notInitialized }
                mcpConnection = try mcp.conversationConnection()
            } catch {
                chatError = "請先連線並選取 MCP 工具，或關閉對話的 MCP 選項；草稿已保留。"
                return
            }
        } else { mcpConnection = nil }
        learning.cancelLearning()
        let key: String
        do { key = try repository.key(for: savedSettings) }
        catch {
            hasStoredKey = false
            chatError = "無法讀取金鑰，草稿已保留。請在設定確認或重新儲存金鑰。"
            return
        }
        let prompt = draft
        let archiveID = UUID(uuidString: conversationID)!
        let destination = archiveDestination
        let archivePrior = archive?.state.conversations.first { $0.id == archiveID }
        let window: ChatContextWindow
        do {
            window = try ChatContextWindow(
                history: entries.map { ModelMessage(role: $0.role, content: $0.content) },
                context: learning.contextMessages(for: prompt), prompt: prompt)
        } catch {
            chatError = ((error as? ChatContextWindowError)?.errorDescription ?? "無法準備本次對話。")
                + "草稿已保留。"
            return
        }
        let messages = window.messages
        let learningGeneration = learning.generation
        let profileState = learning.profile
        let memoryState = learning.memory
        let useLearningTools = learning.available && learning.memory.preferences.useMemory
        let configuration = savedSettings.configuration
        let id = UUID()
        requestID = id
        replyPreview = nil
        isSubmitting = true
        isMCPRun = mcpConnection != nil
        mcpActivity = nil
        mcpSteps = []
        mcpSentCount = 0
        mcpModelCalls = 0; mcpFormatCorrections = 0; mcpPhase = "starting"; updateMCPDiagnostics()
        chatError = nil
        chatNotice = window.omittedTurns == 0 ? nil
            : "本次傳送最近 \(window.retainedTurns) 輪對話、本輪完整訊息及參考資料；較早 \(window.omittedTurns) 輪仍在畫面中，但未傳送。"
        let client = client
        request = Task { [weak self] in
            do {
                let reply: String
                if let (connection, tools, resources) = mcpConnection {
                    reply = try await self?.completeWithMCP(messages: messages, utterance: prompt,
                        profileState: profileState, memoryState: memoryState, generation: learningGeneration,
                        allowsLearning: useLearningTools, configuration: configuration,
                        key: key, client: client, connection: connection, tools: tools, resources: resources, requestID: id) ?? ""
                } else if useLearningTools {
                    reply = try await self?.completeWithProfile(messages: messages, utterance: prompt,
                        state: profileState, memoryState: memoryState, generation: learningGeneration, configuration: configuration,
                        key: key, client: client, requestID: id) ?? ""
                } else {
                    reply = try await self?.completePlain(messages: messages, configuration: configuration,
                        key: key, client: client, requestID: id) ?? ""
                }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                if mcpConnection != nil { self.mcpPhase = "finished"; self.updateMCPDiagnostics() }
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finish(id: id, error: "模型回傳空白內容，草稿已保留，請重試。")
                    return
                }
                let userEntry = ChatEntry(role: "user", content: prompt)
                let assistantEntry = ChatEntry(role: "assistant", content: reply)
                if let archive = self.archive {
                    self.pendingArchiveSave = nil
                    do {
                        guard let destination else { throw ConversationArchiveError.invalidData }
                        let all = self.entries + [userEntry, assistantEntry]
                        let turns = try stride(from: 0, to: all.count, by: 2).map { index in
                            try ArchivedConversationTurn(userID: all[index].id, assistantID: all[index + 1].id,
                                userText: all[index].content, assistantText: all[index + 1].content, pdf: all[index].pdf)
                        }
                        let record = try ArchivedConversation(id: archiveID, destination: destination,
                            updatedAt: Date(), turns: turns)
                        self.pendingArchiveSave = (record, archivePrior)
                        try archive.save(record, expected: archivePrior)
                        self.pendingArchiveSave = nil
                        self.archiveNotice = nil
                    } catch {
                        self.archiveNotice = Self.archiveSaveFailure
                    }
                }
                self.conversationDestination = destination
                self.replyPreview = nil
                self.entries.append(userEntry)
                self.entries.append(assistantEntry)
                if self.draft == prompt { self.draft = "" }
                self.finish(id: id)
                // Deliver first. A separate, bounded extraction call receives only
                // the user's own utterance, never the model reply or MCP/web content.
                self.learning.rememberAfterReply(utterance: prompt, conversationID: self.conversationID,
                    expectedGeneration: learningGeneration, client: client, configuration: configuration, apiKey: key,
                    preservingToolNotes: self.memoryReceiptRequestID == id ? [self.memoryReceipt?.note].compactMap { $0 } : [])
            } catch {
                guard let self, self.requestID == id else { return }
                if mcpConnection != nil {
                    let category = (error as? MCPConversationError)?.rawValue
                        ?? (error as? MCPChatStop)?.reason.rawValue
                        ?? (error is CancellationError ? "cancelled" : "unknown")
                    self.updateMCPDiagnostics(failure: category)
                }
                // Do not surface provider error bodies/URLs: they may contain secrets.
                let message = (error as? MCPChatStop)?.message
                    ?? (error as? ProfileChatStop)?.message
                    ?? Self.profileFailureMessage(error)
                    ?? Self.modelFailureMessage(error as? MCPConversationError)
                    ?? ((error as? MCPConversationError) == .invalidCommand
                        ? "模型仍未提供可用的單一步驟指令，已停止；草稿與先前工具結果保留。" : nil)
                    ?? (mcpConnection == nil ? "傳送失敗，草稿已保留。請檢查模型設定或網路後重試。"
                        : "MCP 對話未完成，草稿與已收到的工具結果保留；請先確認已送出操作，不會自動重試。")
                if self.memoryReceiptRequestID == id {
                    self.finish(id: id, error: "記憶修改已儲存，但後續模型回覆未完成；請先查看保存結果或撤銷，避免重複修改。草稿保留。")
                } else {
                    self.finish(id: id, error: self.profileReceiptRequestID != id ? message
                        : "個人檔案已儲存，但後續模型回覆未完成；請先查看已保存內容，避免重複修改。草稿保留。")
                }
            }
        }
        deadline = Task { [weak self] in
            let seconds: UInt64 = mcpConnection == nil ? 90 : 180
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self, self.requestID == id else { return }
            self.request?.cancel()
            if mcpConnection != nil { self.updateMCPDiagnostics(failure: "hostDeadline") }
            if self.memoryReceiptRequestID == id {
                self.finish(id: id, error: "記憶修改已儲存，但後續回覆等待超過 \(seconds) 秒；請先查看保存結果或撤銷。草稿保留。")
            } else {
                self.finish(id: id, error: self.profileReceiptRequestID != id
                    ? "等待超過 \(seconds) 秒，已停止等待；草稿已保留，可重試。"
                    : "個人檔案已儲存，但後續回覆等待超過 \(seconds) 秒；請先查看保存內容。草稿保留。")
            }
        }
    }

    /// Native picker callback only. Selecting creates a plan, never reads bytes.
    func selectPDF(url: URL, pages: String? = nil, password: String? = nil) {
        guard !isSubmitting else { return }
        do {
            let selected = try ChatPDFAttachment(userSelectedURL: url, pages: pages, password: password)
            removePDF()
            pdfAttachment = selected
            pdfChanges = selected.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            chatError = nil
        } catch {
            chatError = (error as? SkillExecutionError)?.errorDescription ?? "無法選取這份 PDF。"
        }
    }

    func removePDF() {
        if pdfAttachment != nil && isSubmitting { cancel() }
        pdfAttachment?.remove(); pdfChanges = nil; pdfAttachment = nil
    }

    func pdfEnteredBackground() {
        guard let attachment = pdfAttachment else { return }
        if isSubmitting { cancel() }
        attachment.stopPreparation()
        attachment.revokeDestination()
    }

    func confirmPDFDestination() {
        guard !isSubmitting, let attachment = pdfAttachment, let destination = archiveDestination else { return }
        do { attachment.confirmDestination(access: try currentPDFModelAccess(), destination: destination); chatError = nil }
        catch { chatError = "無法確認模型服務，請先檢查已儲存的設定。" }
    }

    private func currentPDFModelAccess() throws -> ModelAccess {
        guard let stored = try repository.load(), let savedSettings,
              stored.baseURL == savedSettings.baseURL, stored.model == savedSettings.model,
              stored.credentialAccount == savedSettings.credentialAccount else { throw DocumentQueryError.contextChanged }
        return try modelAccess()
    }

    private func sendPDF(_ attachment: ChatPDFAttachment) {
        guard !usesMCP, let source = attachment.source else { return }
        let prompt = draft
        let archiveID = UUID(uuidString: conversationID)!
        let archivePrior = archive?.state.conversations.first { $0.id == archiveID }
        do {
            let access = try currentPDFModelAccess()
            try attachment.validate(access: access, destination: archiveDestination)
            guard let destination = archiveDestination else { throw DocumentQueryError.contextChanged }
            let runtime = try DocumentQueryRuntime(source: source, question: prompt)
            learning.cancelLearning()
            let references = try learning.captureRunReferences(goal: prompt, capabilities: DocumentQueryRuntime.referenceCapabilities)
            let id = UUID(); requestID = id; replyPreview = nil; chatError = nil
            isMCPRun = false; isSubmitting = true
            #if DEBUG
            pdfModelRequestEvents = 0
            #endif
            chatNotice = nil // The attached card already displays the disclosure; keep the composer reachable.
            references.onRevoke = { [weak self] in
                guard let self, self.requestID == id else { return }
                self.cancel(); self.chatError = "本次參考資料已撤銷，PDF 查詢已停止；請重新確認後再傳送。"
            }
            request = Task { [weak self] in
                defer { references.onRevoke = nil; references.revoke() }
                do {
                    let outcome = try await runtime.run(client: access.client, configuration: access.configuration,
                        apiKey: access.key, references: references.references, validateContext: { [weak self] in
                            guard let self, self.requestID == id, self.pdfAttachment?.id == attachment.id,
                                  self.draft == prompt, !Task.isCancelled else { throw DocumentQueryError.contextChanged }
                            try references.check()
                            try attachment.validate(access: self.currentPDFModelAccess(), destination: self.archiveDestination)
                        }, onEvent: { [weak self] event in
                            #if DEBUG
                            guard let self, self.requestID == id else { return }
                            if case .requestingModel(let count) = event { self.pdfModelRequestEvents = count }
                            #endif
                        })
                    guard let self, self.requestID == id else { return }
                    guard self.pdfAttachment?.id == attachment.id, self.draft == prompt, !Task.isCancelled
                    else { throw DocumentQueryError.contextChanged }
                    try references.check()
                    try attachment.validate(access: self.currentPDFModelAccess(), destination: self.archiveDestination)
                    guard case .completed(let result) = outcome else {
                        self.finish(id: id, error: "模型未完成 PDF 查詢；問題與擷取文字保留，未保存完成問答。")
                        return
                    }
                    let evidence = try ChatPDFAttachment.archive(result)
                    let user = ChatEntry(role: "user", content: prompt, pdf: evidence)
                    let assistant = ChatEntry(role: "assistant", content: result.answer)
                    if let archive = self.archive {
                        self.pendingArchiveSave = nil
                        do {
                            let all = self.entries + [user, assistant]
                            let turns = try stride(from: 0, to: all.count, by: 2).map { i in
                                try ArchivedConversationTurn(userID: all[i].id, assistantID: all[i + 1].id,
                                    userText: all[i].content, assistantText: all[i + 1].content, pdf: all[i].pdf)
                            }
                            let record = try ArchivedConversation(id: archiveID, destination: destination, updatedAt: Date(), turns: turns)
                            self.pendingArchiveSave = (record, archivePrior)
                            try archive.save(record, expected: archivePrior)
                            self.pendingArchiveSave = nil; self.archiveNotice = nil
                        } catch { self.archiveNotice = Self.archiveSaveFailure }
                    }
                    self.conversationDestination = destination
                    self.entries.append(user); self.entries.append(assistant)
                    if self.draft == prompt { self.draft = "" }
                    self.finish(id: id)
                    self.removePDF()
                    // Deliberately no rememberAfterReply: source text is not a user utterance.
                } catch {
                    guard let self, self.requestID == id else { return }
                    if (error as? DocumentQueryError) == .contextChanged { attachment.revokeDestination() }
                    self.finish(id: id, error: (error as? DocumentQueryError)?.errorDescription
                        ?? "PDF 查詢未完成；問題與擷取文字保留，未保存完成問答。")
                }
            }
        } catch {
            attachment.revokeDestination()
            chatError = (error as? DocumentQueryError)?.errorDescription ?? "無法開始 PDF 查詢；請確認目的服務與來源。"
        }
    }

    private func completePlain(messages: [ModelMessage], configuration: ModelConfiguration,
                               key: String, client: any ChatModelClient, requestID id: UUID) async throws -> String {
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        guard let streaming = client as? any StreamingChatModelClient else {
            return try await client.complete(messages: messages, configuration: configuration, apiKey: key)
        }
        var text = "", bytes = 0
        for try await delta in streaming.stream(messages: messages, configuration: configuration, apiKey: key) {
            try Task.checkCancellation()
            guard requestID == id else { throw CancellationError() }
            guard delta.utf8.count <= ChatReplyPreview.maximumUTF8Bytes - bytes else {
                throw HTTPChatModelError.responseTooLarge
            }
            guard !delta.isEmpty else { continue }
            bytes += delta.utf8.count; text += delta
            replyPreview = ChatReplyPreview(id: id, text: text, phase: .receiving)
        }
        try Task.checkCancellation()
        guard requestID == id else { throw CancellationError() }
        return text
    }

    private func stopPreview(id: UUID, phase: ChatReplyPreview.Phase) {
        guard var preview = replyPreview, preview.id == id, preview.phase == .receiving else { return }
        preview.phase = phase; replyPreview = preview
    }

    private static func modelFailureMessage(_ error: MCPConversationError?) -> String? {
        let reason: String
        switch error {
        case .modelAuthenticationRejected:
            reason = "模型服務拒絕驗證，請檢查模型金鑰與存取權限。"
        case .modelRateLimited:
            reason = "模型服務目前限制請求，請稍後再試。"
        case .modelServiceUnavailable:
            reason = "模型服務暫時無法處理請求，請稍後再試。"
        case .modelRequestRejected, .modelHTTPRejected:
            reason = "模型服務拒絕這次請求，請檢查服務與模型設定。"
        case .modelTimedOut:
            reason = "等待模型回覆已逾時。"
        case .modelTransportFailed:
            reason = "無法連線至模型服務，請檢查網路。"
        case .localUnavailable:
            reason = "本次對話未啟用記憶與個人檔案工具，修改要求已停止。"
        case .localLeaseExpired:
            reason = "這次記憶工具操作已失效，修改要求已停止。"
        case .invalidLocalResult:
            reason = "本機記憶工具未傳回完整結果，對話已停止。"
        default: return nil
        }
        return reason + "草稿與已收到的工具結果保留；沒有自動重送操作。"
    }

    func cancel() {
        learning.cancelLearning()
        guard let id = requestID else { return }
        pdfAttachment?.revokeDestination()
        if isMCPRun { updateMCPDiagnostics(failure: "cancelled") }
        stopPreview(id: id, phase: .cancelled)
        request?.cancel()
        finish(id: id)
        chatNotice = "已取消等待，草稿已保留。伺服器可能已收到請求。"
    }

    func cancelMCP() {
        guard isMCPRun else { return }
        cancel()
    }

    /// Ordinary pending model replies remain deliverable after memory clearing;
    /// a profile review is invalidated immediately, and late proposals recheck
    /// generation/master-switch state before they can even be shown.
    func invalidateProfileReview() {
        guard pendingProfileReview != nil || pendingMemoryReview != nil else { return }
        cancel()
    }

    private func completeWithProfile(messages: [ModelMessage], utterance: String,
                                     state: UserProfileState, memoryState: MemoryState, generation: UUID,
                                     configuration: ModelConfiguration, key: String,
                                     client: any ChatModelClient, requestID: UUID) async throws -> String {
        let flow = try UserProfileChatFlow(messages: messages)
        var memoryRun = MemoryToolRun(state: memoryState, utterances: [utterance])
        defer { flow.cancel() }
        while true {
            let step = try await flow.advance(client: client, configuration: configuration, apiKey: key)
            try Task.checkCancellation()
            guard self.requestID == requestID else { throw CancellationError() }
            switch step {
            case .answer(let answer): return answer
            case .proposedEdit(let arguments):
                guard learning.available, learning.memory.preferences.useMemory,
                      learning.generation == generation, learning.profile.revision == state.revision else {
                    throw UserProfileToolError.staleRevision
                }
                // Only the actual draft sent for this run is evidence. Context,
                // old messages and model replies cannot authorize an edit.
                let proposal = try UserProfileToolRequest.parse(arguments).prepare(state: state, utterances: [utterance])
                let approved = await approveProfile(proposal, requestID: requestID)
                try Task.checkCancellation()
                guard self.requestID == requestID else { throw CancellationError() }
                guard approved else { throw ProfileChatStop.declined }
                try flow.validateReview()
                let receipt = try learning.commitProfileTool(proposal, expectedGeneration: generation)
                profileReceipt = receipt // Retained even if the next model call fails.
                profileReceiptRequestID = requestID
                try flow.recordCommitted(entryID: receipt.id)
            case .memorySearch(let arguments):
                try validateMemoryRun(memoryRun, generation: generation)
                let found = try memoryRun.search(argumentsJSON: arguments)
                try flow.recordMemorySearchResult(found.resultJSON())
            case .proposedMemoryChange(let toolName, let arguments):
                try validateMemoryRun(memoryRun, generation: generation)
                let review = try memoryRun.prepare(toolName: toolName, argumentsJSON: arguments)
                let approved = await approveMemory(review, requestID: requestID)
                try Task.checkCancellation()
                guard self.requestID == requestID else { throw CancellationError() }
                guard approved else { throw MemoryChatStop.declined }
                try flow.validateReview()
                let receipt = try learning.commitMemoryTool(review, expectedGeneration: generation,
                    conversationID: conversationID)
                memoryReceipt = receipt
                memoryReceiptRequestID = requestID
                try flow.recordMemoryCommitted(toolName: toolName, resultJSON: receipt.resultJSON())
            }
        }
    }

    private func validateMemoryRun(_ run: MemoryToolRun, generation: UUID) throws {
        guard learning.available, learning.memory.preferences.useMemory,
              learning.generation == generation, learning.memory.revision == run.baseRevision else {
            throw MemoryToolError.staleRevision
        }
    }

    func resolveMemoryReview(id: UUID, approved: Bool) {
        guard pendingMemoryReview?.id == id else { return }
        pendingMemoryReview = nil
        let continuation = memoryApprovalContinuation
        memoryApprovalContinuation = nil
        continuation?.resume(returning: approved)
    }

    private func approveMemory(_ review: MemoryToolReview, requestID: UUID) async -> Bool {
        guard self.requestID == requestID, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.requestID == requestID, !Task.isCancelled else {
                    continuation.resume(returning: false); return
                }
                memoryApprovalContinuation = continuation
                pendingMemoryReview = review
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID, let review = self.pendingMemoryReview else { return }
                self.resolveMemoryReview(id: review.id, approved: false)
            }
        }
    }

    func resolveProfileReview(id: UUID, approved: Bool) {
        guard pendingProfileReview?.id == id else { return }
        pendingProfileReview = nil
        let continuation = profileApprovalContinuation
        profileApprovalContinuation = nil
        continuation?.resume(returning: approved)
    }

    private func approveProfile(_ review: UserProfileToolReview, requestID: UUID) async -> Bool {
        guard self.requestID == requestID, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.requestID == requestID, !Task.isCancelled else {
                    continuation.resume(returning: false); return
                }
                profileApprovalContinuation = continuation
                pendingProfileReview = review
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID, let proposal = self.pendingProfileReview else { return }
                self.resolveProfileReview(id: proposal.id, approved: false)
            }
        }
    }

    private static func profileFailureMessage(_ error: Error) -> String? {
        if error is LearningFileError {
            return "學習資料無法儲存，這次修改未發布；原有資料與草稿保留，請確認裝置儲存狀態後再試。"
        }
        if let stopped = error as? MemoryChatStop { return stopped.message }
        if error is MemoryToolError || error is MemoryError {
            return "記憶工具未通過來源、目標或資料狀態檢查，已停止；草稿保留。已完成的儲存會另外顯示。"
        }
        if error is UserProfileToolError || error is UserProfileError || error is UserProfileChatError {
            return "個人檔案工具未通過檢查或已超過執行限制，已停止；草稿保留。已完成的儲存會另外顯示。"
        }
        return nil
    }

    private func completeWithMCP(messages: [ModelMessage], utterance: String,
                                 profileState: UserProfileState, memoryState: MemoryState,
                                 generation: UUID, allowsLearning: Bool, configuration: ModelConfiguration,
                                 key: String, client: any ChatModelClient,
                                 connection: any MCPDiscovering, tools: [MCPTool], resources: [MCPResource], requestID: UUID) async throws -> String {
        let turn = MCPLearningTurn(profile: profileState, memory: memoryState,
                                   utterance: utterance, generation: generation)
        let local: MCPLocalHandler?
        if allowsLearning {
            local = { [weak self] proposal, lease in
                guard let self else { throw CancellationError() }
                return try await self.performMCPLocal(proposal, lease: lease, turn: turn, requestID: requestID)
            }
        } else { local = nil }
        let result = try await MCPConversationRunner(client: client).run(
            messages: messages, configuration: configuration, apiKey: key,
            tools: tools, resources: resources, executor: connection,
            approve: { [weak self] proposal in
                switch proposal.action {
                case .callTool(let name, let arguments):
                    return await self?.approveMCP(name: name, arguments: arguments, requestID: requestID) ?? false
                case .readResource(let uri):
                    return await self?.approveMCP(name: "讀取 MCP 資源", arguments: .object(["uri": .string(uri)]), requestID: requestID) ?? false
                }
            }, onEvent: { [weak self] event in
                await self?.receiveMCP(event, requestID: requestID)
            }, handleLocal: local)
        guard result.stopReason == .finished, let answer = result.answer else { throw MCPChatStop(reason: result.stopReason) }
        return answer
    }

    /// Local learning and the remote MCP connection are separate capabilities.
    /// Every proposal is validated against this turn's captured user utterance;
    /// remote catalogs/results cannot supply that authority or replace its IDs.
    private func performMCPLocal(_ proposal: MCPLocalProposal, lease: MCPLocalLease,
                                 turn: MCPLearningTurn, requestID: UUID) async throws -> MCPLocalOutcome {
        try lease.check()
        guard self.requestID == requestID else { throw CancellationError() }
        switch proposal.action {
        case .memorySearch:
            try validateMemoryRun(turn.memory, generation: turn.generation)
            let result = try turn.memory.search(argumentsJSON: proposal.argumentsJSON)
            return .searchResult(json: try result.resultJSON())
        case .profileEdit:
            guard learning.available, learning.memory.preferences.useMemory,
                  learning.generation == turn.generation, learning.profile.revision == turn.profile.revision else {
                throw UserProfileToolError.staleRevision
            }
            let review = try UserProfileToolRequest.parse(proposal.argumentsJSON)
                .prepare(state: turn.profile, utterances: [turn.utterance])
            let approved = await approveProfile(review, requestID: requestID)
            // No suspension between this lease/request check and the store's
            // generation/master/revision checks plus atomic write.
            try lease.check()
            guard self.requestID == requestID else { throw CancellationError() }
            guard approved else { return .declined }
            let receipt = try learning.commitProfileTool(review, expectedGeneration: turn.generation)
            profileReceipt = receipt
            profileReceiptRequestID = requestID
            let data = try JSONEncoder().encode(receipt)
            return .committedReceipt(json: String(decoding: data, as: UTF8.self))
        case .memorySave, .memoryEdit:
            try validateMemoryRun(turn.memory, generation: turn.generation)
            let review = try turn.memory.prepare(toolName: proposal.action.rawValue,
                                                 argumentsJSON: proposal.argumentsJSON)
            let approved = await approveMemory(review, requestID: requestID)
            try lease.check()
            guard self.requestID == requestID else { throw CancellationError() }
            guard approved else { return .declined }
            let receipt = try learning.commitMemoryTool(review, expectedGeneration: turn.generation,
                                                        conversationID: conversationID)
            memoryReceipt = receipt
            memoryReceiptRequestID = requestID
            return .committedReceipt(json: try receipt.resultJSON())
        }
    }

    private func receiveMCP(_ event: MCPConversationEvent, requestID: UUID) {
        guard self.requestID == requestID else { return }
        switch event {
        case .requestingModel(let count): mcpPhase = "requestingModel"; mcpModelCalls = count
        case .correctingCommand: mcpPhase = "correctingCommand"; mcpFormatCorrections += 1
        case .awaitingApproval: mcpPhase = "awaitingApproval"
        case .executing: mcpPhase = "executing"; mcpSentCount += 1
        case .completed(let step): mcpPhase = "receivedResult"; mcpSteps.append(step)
        }
        mcpActivity = "MCP 嘗試呼叫 \(mcpSentCount) 次；已收到 \(mcpSteps.count) 次結果；工具錯誤 \(mcpSteps.filter(\.isError).count) 次。"
        updateMCPDiagnostics()
    }

    /// Test-only, fixed enums and counters. Never include proposals, tool
    /// outputs, model text, endpoint, or underlying error descriptions.
    private func updateMCPDiagnostics(failure: String = "none") {
        #if DEBUG
        guard isUITestMode || ProcessInfo.processInfo.arguments.contains("-LiveMCPConversationUITest") else { return }
        mcpDiagnostics = "phase=\(mcpPhase);modelCalls=\(mcpModelCalls);formatCorrections=\(mcpFormatCorrections);attempts=\(mcpSentCount);results=\(mcpSteps.count);toolErrors=\(mcpSteps.filter(\.isError).count);failure=\(failure)"
        #endif
    }

    func resolveMCPApproval(id: UUID, approved: Bool) {
        guard pendingMCPApproval?.id == id else { return }
        pendingMCPApproval = nil
        let continuation = mcpApprovalContinuation
        mcpApprovalContinuation = nil
        continuation?.resume(returning: approved)
    }

    private func approveMCP(name: String, arguments: JSONValue, requestID: UUID) async -> Bool {
        guard self.requestID == requestID, !Task.isCancelled else { return false }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard self.requestID == requestID, !Task.isCancelled else {
                    continuation.resume(returning: false); return
                }
                mcpApprovalContinuation = continuation
                pendingMCPApproval = MCPApprovalRequest(name: name, arguments: arguments)
            }
        } onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.requestID == requestID, let proposal = self.pendingMCPApproval else { return }
                self.resolveMCPApproval(id: proposal.id, approved: false)
            }
        }
    }

    func newConversation() {
        guard !isSubmitting else { return }
        removePDF()
        learning.resetConversationPresentation()
        entries = []; conversationID = UUID().uuidString
        replyPreview = nil
        conversationDestination = nil; archiveNotice = nil; pendingArchiveSave = nil
        mcpActivity = nil; mcpSteps = []; mcpSentCount = 0
        mcpDiagnostics = nil
        profileReceipt = nil
        profileReceiptRequestID = nil
        memoryReceipt = nil
        memoryReceiptRequestID = nil
        chatError = nil; chatNotice = "已開啟新對話；已確認的記憶與技能保留。"
    }

    private func finish(id: UUID, error: String? = nil) {
        guard requestID == id else { return }
        if error != nil { stopPreview(id: id, phase: .failed) }
        if let pending = pendingMCPApproval { resolveMCPApproval(id: pending.id, approved: false) }
        if let pending = pendingProfileReview { resolveProfileReview(id: pending.id, approved: false) }
        if let pending = pendingMemoryReview { resolveMemoryReview(id: pending.id, approved: false) }
        requestID = nil
        isSubmitting = false
        isMCPRun = false
        request = nil
        deadline?.cancel()
        deadline = nil
        chatError = error
    }

    private static func liveRepository() -> ModelSettingsRepository {
        ModelSettingsRepository(defaults: .standard, credentials: KeychainModelCredentials(service: "io.woowtech.assistant.model-credentials.v1"))
    }

    private static func settingsMessage(_ error: Error) -> String {
        (error as? ModelSettingsError)?.errorDescription ?? "無法讀取或儲存模型設定，請移除設定後重新填寫。"
    }
}

/// Mutable search candidates belong to exactly one MainActor conversation.
/// Captured snapshots are never refreshed from model or remote-tool output.
@MainActor private final class MCPLearningTurn {
    let profile: UserProfileState
    var memory: MemoryToolRun
    let utterance: String
    let generation: UUID

    init(profile: UserProfileState, memory: MemoryState, utterance: String, generation: UUID) {
        self.profile = profile
        self.memory = MemoryToolRun(state: memory, utterances: [utterance])
        self.utterance = utterance
        self.generation = generation
    }
}

private enum ProfileChatStop: Error {
    case declined
    var message: String { "你已拒絕這次個人檔案修改；尚未儲存，訊息草稿已保留。" }
}

private enum MemoryChatStop: Error {
    case declined
    var message: String { "你已拒絕這次記憶修改；尚未儲存，訊息草稿已保留。" }
}

private struct MCPChatStop: Error {
    let reason: MCPConversationStopReason
    var message: String {
        switch reason {
        case .approvalDenied: return "你已拒絕這次呼叫，MCP 對話已停止；草稿與先前工具結果保留。"
        case .toolError: return "工具回報錯誤，已停止；請檢視工具結果。草稿保留，不會自動重試。"
        case .localCallLimit: return "本次對話的記憶搜尋或修改額度已用完，已停止；草稿與先前結果保留。"
        default: return "已達 MCP 執行限制或偵測到重複呼叫；草稿與已收到的工具結果保留。"
        }
    }
}
