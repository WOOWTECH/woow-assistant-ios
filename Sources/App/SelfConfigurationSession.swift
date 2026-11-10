import AssistantSkills
import Combine
import Foundation

@MainActor final class SelfConfigurationSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var message = "尚未提出外觀調整要求。"
    @Published private(set) var question: String?
    @Published private(set) var error: String?
    @Published private(set) var steps: [String] = []
    private var task: Task<Void, Never>?
    private var runtime: SelfConfigurationRuntime?
    private var operationID: UUID?

    func start(request: String, store: SelfConfigurationStore, modelAccess: () throws -> ModelAccess) {
        cancel(showNotice: false)
        question = nil; error = nil; steps = []
        do {
            // Refuse before resolving credentials or starting a model request.
            guard let original = try BundledSkillCatalog.bundled().entry(id: "configure-mika")?.original else {
                throw SkillCatalogError.notFound
            }
            let reference = "來源：\(original.path)\n版本：\(BundledSkillCatalog.pinnedCommit)\nSHA-256：\(original.sha256)\n\n" + original.content
            let runtime = try SelfConfigurationRuntime(request: request, store: store, sourceReference: reference)
            let access = try modelAccess()
            self.runtime = runtime
            let id = UUID()
            operationID = id
            running = true
            message = "正在查詢並調整外觀……"
            task = Task { [weak self] in
                do {
                    let outcome = try await runtime.run(client: access.client, configuration: access.configuration,
                        apiKey: access.key, onStep: { [weak self] step in
                            guard let self, self.operationID == id else { return }
                            self.steps.append(step)
                        })
                    guard let self, self.operationID == id, !Task.isCancelled else { return }
                    switch outcome {
                    case .changed(let receipt):
                        self.message = "已讀回外觀：\(receipt.appearance.label)。已立即套用。"
                    case .needsClarification(let question):
                        self.question = question
                        self.message = "尚未變更外觀；請補充要求後重新送出。"
                    case .unchanged: self.message = "這次沒有變更外觀。"
                    }
                    self.finish()
                } catch {
                    guard let self, self.operationID == id else { return }
                    self.error = (error as? SelfConfigurationError)?.errorDescription ?? "模型連線或回應失敗，未套用變更。"
                    self.message = "這次外觀調整已停止。"
                    self.finish()
                }
            }
        } catch {
            self.error = (error as? SelfConfigurationError)?.errorDescription ?? "請先在模型設定完成連線設定。"
            message = "尚未開始外觀調整。"
        }
    }

    func cancel(showNotice: Bool = true) {
        let wasRunning = running
        operationID = nil
        runtime?.cancel(); task?.cancel()
        runtime = nil; task = nil; running = false
        if showNotice && wasRunning { message = "已停止；之後抵達的模型回應不會套用。" }
    }

    private func finish() {
        operationID = nil; runtime = nil; task = nil; running = false
    }
}
