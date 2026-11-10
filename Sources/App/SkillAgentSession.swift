import AssistantModels
import AssistantSkills
import Combine
import Foundation

@MainActor final class SkillAgentSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var activity = "輸入要建立或修改的做法。"
    @Published private(set) var question: String?
    @Published private(set) var review: SkillAuthoringSaveReview?
    @Published private(set) var receipt: SkillAuthoringSaveReceipt?
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    @Published private(set) var steps: [String] = []
    private var runtime: SkillToolSession?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var access: ModelAccess?
    private var storeGeneration: UUID?
    private(set) var committing = false

    func start(request: String, store: LearningStore, modelAccess: () throws -> ModelAccess) {
        cancel(showNotice: false)
        receipt = nil; message = nil; error = nil; steps = []
        do {
            let access = try modelAccess()
            let request = try SkillAuthoringUserRequest(quote: request)
            runtime = try SkillToolSession(request: request, store: store, catalog: .bundled())
            self.access = access; storeGeneration = store.generation
            advance()
        } catch { fail(error) }
    }

    func answer(_ value: String, store: LearningStore, modelAccess: () throws -> ModelAccess) {
        guard question != nil, !running else { return }
        do { try validateContext(store: store, modelAccess: modelAccess); advance(answer: value) }
        catch { fail(error) }
    }

    func approve(store: LearningStore, modelAccess: () throws -> ModelAccess) {
        guard let review, let runtime, !running else { return }
        committing = true
        defer { committing = false }
        do {
            try validateContext(store: store, modelAccess: modelAccess)
            let result = try runtime.approve(reviewID: review.id, fingerprint: review.draftFingerprint)
            self.review = nil; receipt = result; self.runtime = nil; access = nil
            activity = result.updated ? "已更新個人技能 · 試用中" : "已新增個人技能 · 試用中"
        } catch { fail(error) }
    }

    func cancel(showNotice: Bool = true) {
        operationID = nil; task?.cancel(); task = nil; runtime?.cancel(); runtime = nil
        access = nil; storeGeneration = nil; running = false; question = nil; review = nil
        if showNotice { activity = "已取消，尚未儲存。" }
    }

    /// Host changes invalidate pending reviews as well as in-flight model calls.
    func hostChanged() {
        guard !committing, runtime != nil else { return }
        cancel(showNotice: false)
        activity = "本次協作已停止，尚未儲存。"
        error = "模型設定或技能資料已變更，本次協作已停止；請重新開始。"
    }

    private func validateContext(store: LearningStore, modelAccess: () throws -> ModelAccess) throws {
        let current = try modelAccess()
        guard let access, access.configuration.baseURL == current.configuration.baseURL,
              access.configuration.model == current.configuration.model,
              access.key == current.key, storeGeneration == store.generation else {
            throw SkillAuthoringError.storageChanged
        }
    }

    private func advance(answer: String? = nil) {
        guard let runtime, let access else { return }
        let id = UUID(); operationID = id; running = true; question = nil; error = nil
        // Skill documents can be longer than ordinary chat answers. Stay within
        // the existing HTTP client's supported 8192-token maximum.
        let configuration = ModelConfiguration(baseURL: access.configuration.baseURL,
            model: access.configuration.model, maxOutputTokens: 8192)
        task = Task { [weak self] in
            do {
                let outcome = try await runtime.advance(client: access.client, configuration: configuration,
                    apiKey: access.key, answer: answer) { [weak self] event in
                    guard let self, self.operationID == id else { return }
                    switch event {
                    case .requestingModel(let count): self.activity = "正在請模型協作（第 \(count) 回合）…"
                    case .executed(let name, let succeeded):
                        let label = ["skill_search": "查詢技能", "skill_read": "讀取技能全文", "skill_save": "準備待審草稿"][name] ?? "技能工具"
                        self.steps.append(label + (succeeded ? "：完成" : "：未通過檢查"))
                    }
                }
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.running = false; self.task = nil
                switch outcome {
                case .review(let review): self.review = review; self.activity = "草稿待你核對，尚未儲存。"
                case .question(let question): self.question = question; self.activity = "等待你補充要求。"
                case .finished(let message):
                    self.message = message; self.activity = "模型已結束，本次尚未儲存。"
                    self.runtime = nil; self.access = nil
                }
            } catch {
                guard let self, self.operationID == id else { return }
                self.fail(error)
            }
        }
    }

    private func fail(_ error: Error) {
        cancel(showNotice: false)
        activity = "技能協作未完成，尚未儲存。"
        self.error = Self.explain(error)
    }

    private static func explain(_ error: Error) -> String {
        if let error = error as? SkillToolError { return error.errorDescription ?? "技能協作未完成。" }
        if let error = error as? HTTPChatModelError, error == .invalidConfiguration {
            return "請先在模型設定儲存服務網址、模型名稱與 API Key。"
        }
        if error is ModelSettingsError {
            return "無法取得已設定模型的憑證，尚未開始協作。請解鎖裝置並檢查模型設定。"
        }
        return LearningStore.message(error)
    }
}
