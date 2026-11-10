import AssistantModels
import AssistantMCP
import Combine
import Foundation

struct ModelAccess {
    let client: any ChatModelClient
    let configuration: ModelConfiguration
    let key: String
}

struct ChatEntry: Identifiable {
    let id = UUID()
    let role: String
    let content: String
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
    let learning = LearningStore()
    private var conversationID = UUID().uuidString
    @Published var draft = ""
    @Published var baseURLDraft = ""
    @Published var modelDraft = ""
    @Published var keyDraft = ""
    @Published private(set) var entries: [ChatEntry] = []
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
    private var mcpPhase = "idle"
    private var mcpModelCalls = 0
    private var mcpFormatCorrections = 0
    private var mcpApprovalContinuation: CheckedContinuation<Bool, Never>?
    private var isMCPRun = false
    private var mcpSentCount = 0

    let isUITestMode: Bool
    private let repository: ModelSettingsRepository
    private let client: any ChatModelClient
    private var request: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var requestID: UUID?

    init() {
        var bootstrapFailure: String?
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
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
            client = UITestChatModelClient()
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
        if let bootstrapFailure { settingsError = "Live UI 測試設定未完成。\(bootstrapFailure)" }
    }

    var canSend: Bool {
        savedSettings != nil && hasStoredKey && !isSubmitting
            && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func modelAccess() throws -> ModelAccess {
        guard let savedSettings, hasStoredKey else { throw HTTPChatModelError.invalidConfiguration }
        return ModelAccess(client: client, configuration: savedSettings.configuration,
                           key: try repository.key(for: savedSettings))
    }

    var chatStatus: String {
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
                entries = []
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
            savedSettings = nil
            hasStoredKey = false
            baseURLDraft = ""
            modelDraft = ""
            keyDraft = ""
            entries = []
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
        let messages = entries.map { ModelMessage(role: $0.role, content: $0.content) }
            + learning.contextMessages(for: prompt)
            + [ModelMessage(role: "user", content: prompt)]
        let learningGeneration = learning.generation
        let configuration = savedSettings.configuration
        let id = UUID()
        requestID = id
        isSubmitting = true
        isMCPRun = mcpConnection != nil
        mcpActivity = nil
        mcpSteps = []
        mcpSentCount = 0
        mcpModelCalls = 0; mcpFormatCorrections = 0; mcpPhase = "starting"; updateMCPDiagnostics()
        chatError = nil
        chatNotice = nil
        let client = client
        request = Task { [weak self] in
            do {
                let reply: String
                if let (connection, tools, resources) = mcpConnection {
                    reply = try await self?.completeWithMCP(messages: messages, configuration: configuration,
                        key: key, client: client, connection: connection, tools: tools, resources: resources, requestID: id) ?? ""
                } else {
                    reply = try await client.complete(messages: messages, configuration: configuration, apiKey: key)
                }
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
                if mcpConnection != nil { self.mcpPhase = "finished"; self.updateMCPDiagnostics() }
                guard !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.finish(id: id, error: "模型回傳空白內容，草稿已保留，請重試。")
                    return
                }
                self.entries.append(ChatEntry(role: "user", content: prompt))
                self.entries.append(ChatEntry(role: "assistant", content: reply))
                if self.draft == prompt { self.draft = "" }
                self.finish(id: id)
                // Deliver first. A separate, bounded extraction call receives only
                // the user's own utterance, never the model reply or MCP/web content.
                self.learning.rememberAfterReply(utterance: prompt, conversationID: self.conversationID,
                    expectedGeneration: learningGeneration, client: client, configuration: configuration, apiKey: key)
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
                    ?? ((error as? MCPConversationError) == .invalidCommand
                        ? "模型仍未提供可用的單一步驟指令，已停止；草稿與先前工具結果保留。" : nil)
                    ?? (mcpConnection == nil ? "傳送失敗，草稿已保留。請檢查模型設定或網路後重試。"
                        : "MCP 對話未完成，草稿與已收到的工具結果保留；請先確認已送出操作，不會自動重試。")
                self.finish(id: id, error: message)
            }
        }
        deadline = Task { [weak self] in
            let seconds: UInt64 = mcpConnection == nil ? 90 : 180
            do { try await Task.sleep(nanoseconds: seconds * 1_000_000_000) }
            catch { return }
            guard let self, self.requestID == id else { return }
            self.request?.cancel()
            if mcpConnection != nil { self.updateMCPDiagnostics(failure: "hostDeadline") }
            self.finish(id: id, error: "等待超過 \(seconds) 秒，已停止等待；草稿已保留，可重試。")
        }
    }

    func cancel() {
        learning.cancelLearning()
        guard let id = requestID else { return }
        if isMCPRun { updateMCPDiagnostics(failure: "cancelled") }
        request?.cancel()
        finish(id: id)
        chatNotice = "已取消等待，草稿已保留。伺服器可能已收到請求。"
    }

    func cancelMCP() {
        guard isMCPRun else { return }
        cancel()
    }

    private func completeWithMCP(messages: [ModelMessage], configuration: ModelConfiguration,
                                 key: String, client: any ChatModelClient,
                                 connection: any MCPDiscovering, tools: [MCPTool], resources: [MCPResource], requestID: UUID) async throws -> String {
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
            })
        guard result.stopReason == .finished, let answer = result.answer else { throw MCPChatStop(reason: result.stopReason) }
        return answer
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
        learning.resetConversationPresentation()
        entries = []; conversationID = UUID().uuidString
        mcpActivity = nil; mcpSteps = []; mcpSentCount = 0
        mcpDiagnostics = nil
        chatError = nil; chatNotice = "已開啟新對話；已確認的記憶與技能保留。"
    }

    private func finish(id: UUID, error: String? = nil) {
        guard requestID == id else { return }
        if let pending = pendingMCPApproval { resolveMCPApproval(id: pending.id, approved: false) }
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

private struct MCPChatStop: Error {
    let reason: MCPConversationStopReason
    var message: String {
        switch reason {
        case .approvalDenied: return "你已拒絕這次呼叫，MCP 對話已停止；草稿與先前工具結果保留。"
        case .toolError: return "工具回報錯誤，已停止；請檢視工具結果。草稿保留，不會自動重試。"
        default: return "已達 MCP 執行限制或偵測到重複呼叫；草稿與已收到的工具結果保留。"
        }
    }
}
