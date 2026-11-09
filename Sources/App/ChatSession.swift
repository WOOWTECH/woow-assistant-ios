import AssistantModels
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
        if isSubmitting { return "正在等待模型回覆…" }
        return savedSettings != nil && hasStoredKey ? "模型已設定" : "尚未設定模型"
    }

    func saveSettings() {
        guard !isSubmitting else { return }
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

    func send() {
        guard canSend, let savedSettings else { return }
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
        chatError = nil
        chatNotice = nil
        let client = client
        request = Task { [weak self] in
            do {
                let reply = try await client.complete(messages: messages, configuration: configuration, apiKey: key)
                try Task.checkCancellation()
                guard let self, self.requestID == id else { return }
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
                // Do not surface provider error bodies/URLs: they may contain secrets.
                self.finish(id: id, error: "傳送失敗，草稿已保留。請檢查模型設定或網路後重試。")
            }
        }
        deadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) }
            catch { return }
            guard let self, self.requestID == id else { return }
            self.request?.cancel()
            self.finish(id: id, error: "等待超過 90 秒，已停止等待；草稿已保留，可重試。")
        }
    }

    func cancel() {
        learning.cancelLearning()
        guard let id = requestID else { return }
        request?.cancel()
        finish(id: id)
        chatNotice = "已取消等待，草稿已保留。伺服器可能已收到請求。"
    }

    func newConversation() {
        guard !isSubmitting else { return }
        learning.resetConversationPresentation()
        entries = []; conversationID = UUID().uuidString
        chatError = nil; chatNotice = "已開啟新對話；已確認的記憶與技能保留。"
    }

    private func finish(id: UUID, error: String? = nil) {
        guard requestID == id else { return }
        requestID = nil
        isSubmitting = false
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
