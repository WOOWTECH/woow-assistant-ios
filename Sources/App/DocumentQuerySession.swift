import AssistantModels
import AssistantSkills
import Combine
import Foundation

struct DocumentQueryAudit {
    var modelCalls = 0
    var searches = 0
    var reads = 0
    var results = 0
    var citations = 0
    var corrections = 0
    var evidence: String {
        "DOCUMENT_QUERY_AUDIT modelCalls=\(modelCalls) searches=\(searches) reads=\(reads) results=\(results) citations=\(citations) corrections=\(corrections)"
    }
}

/// Owns only an already extracted immutable PDF text snapshot. It never opens
/// the source URL, accepts a model path, or changes the learning store.
@MainActor final class DocumentQuerySession: ObservableObject {
    let source: DocumentTextSnapshot
    @Published private(set) var question = ""
    @Published private(set) var destination: String?
    @Published private(set) var running = false
    @Published private(set) var result: DocumentQueryResult?
    @Published private(set) var deliveryID: UUID?
    @Published private(set) var refusal: String?
    @Published private(set) var error: String?
    @Published private(set) var status = "請輸入問題，並確認要傳送至哪個模型服務。"
    private(set) var audit = DocumentQueryAudit()
    private var approvedAccess: ModelAccess?
    private var operationID: UUID?
    private var runtime: DocumentQueryRuntime?
    private var task: Task<Void, Never>?
    private let learning: LearningStore
    private var references: LearningRunSnapshot?
    #if DEBUG
    /// Capture before cancellation clears the field; awaiting the real task
    /// observes completion without modifying the query lifecycle.
    var capturedRunCompletion: Task<Void, Never>? { task }
    #endif

    private enum HostError: Error { case changed, cancelled }

    init(source: DocumentTextSnapshot, learning: LearningStore) {
        self.source = source; self.learning = learning
    }

    func setQuestion(_ value: String) {
        guard value != question else { return }
        cancel(notice: false)
        question = value; result = nil; deliveryID = nil; refusal = nil; error = nil
        audit = .init()
        status = "問題已更新，尚未傳送給模型。"
    }

    func confirmDestination(modelAccess: () throws -> ModelAccess) {
        guard !running else { return }
        do {
            let access = try modelAccess()
            guard let host = access.configuration.baseURL.host,
                  access.configuration.baseURL.scheme == "https" else { throw HostError.changed }
            approvedAccess = access
            destination = "https://" + host + (access.configuration.baseURL.port.map { ":\($0)" } ?? "")
                + "\n模型：" + access.configuration.model
            error = nil
        } catch {
            approvedAccess = nil; destination = nil
            self.error = "無法取得已設定的模型服務，請先儲存模型設定。"
        }
    }

    func start(modelAccess: @escaping () throws -> ModelAccess) {
        guard !running else { return }
        guard let approvedAccess, destination != nil else {
            error = "請先確認目前設定的模型目的服務。"; return
        }
        do {
            try validate(approvedAccess, current: modelAccess())
            let runtime = try DocumentQueryRuntime(source: source, question: question)
            let snapshot = try learning.captureRunReferences(goal: question,
                capabilities: DocumentQueryRuntime.referenceCapabilities)
            let id = UUID()
            operationID = id; self.runtime = runtime
            references = snapshot
            snapshot.onRevoke = { [weak self] in self?.referencesRevoked(for: id) }
            result = nil; deliveryID = nil; refusal = nil; error = nil; running = true
            audit = .init()
            status = "正在依問題搜尋與分段讀取已核准的 PDF 文字…"
            task = Task { [weak self] in
                do {
                    let outcome = try await runtime.run(client: approvedAccess.client,
                        configuration: approvedAccess.configuration, apiKey: approvedAccess.key,
                        references: snapshot.references,
                        validateContext: { [weak self] in
                            guard let self, self.operationID == id else { throw HostError.cancelled }
                            try snapshot.check()
                            try self.validate(approvedAccess, current: modelAccess())
                        }, onEvent: { [weak self] event in
                            guard let self, self.operationID == id else { return }
                            switch event {
                            case .requestingModel(let count):
                                self.audit.modelCalls = count
                                self.status = "正在請模型查詢（第 \(count) 回合）…"
                            case .searched(let count, let truncated):
                                self.audit.searches += 1
                                self.status = "搜尋找到 \(count) 處" + (truncated ? "；尚有其他符合位置。" : "。")
                            case .read(let read):
                                self.audit.reads += 1
                                self.status = "已讀取原 PDF 第 \(read.pageNumber) 頁的 \(read.length) 位元組文字。"
                            case .correctingCommand:
                                self.audit.corrections += 1
                                self.status = "模型指令格式無效，正在要求一次格式修正。"
                            }
                        })
                    guard let self, self.operationID == id, !Task.isCancelled else { return }
                    try snapshot.check()
                    try self.validate(approvedAccess, current: modelAccess())
                    self.releaseReferences()
                    self.running = false; self.operationID = nil; self.task = nil; self.runtime = nil
                    switch outcome {
                    case .completed(let result):
                        self.result = result; self.deliveryID = UUID()
                        self.audit.results += 1; self.audit.citations = result.citations.count
                        self.status = "回答引用已與實際讀取的原文逐字核對，請再核對解讀是否正確。"
                    case .refused(let reason):
                        self.refusal = reason
                        self.status = "模型未完成這個問題；已擷取的 PDF 文字仍保留。"
                    }
                } catch {
                    guard let self, self.operationID == id else { return }
                    self.fail(error)
                }
            }
        } catch { fail(error) }
    }

    func cancel(notice: Bool = true) {
        operationID = nil
        task?.cancel(); task = nil; runtime?.cancel(); runtime = nil; running = false
        releaseReferences()
        if notice { status = "已停止查詢，問題與已擷取的文字仍保留。" }
    }

    func hostChanged() {
        cancel(notice: false); approvedAccess = nil; destination = nil
        status = result == nil ? "模型設定已變更；請重新確認目的服務後再查詢。"
            : "模型設定已變更；已完成的回答仍保留，再次查詢前請重新確認目的服務。"
    }

    private func releaseReferences() {
        let snapshot = references; references = nil
        snapshot?.onRevoke = nil; snapshot?.revoke()
    }

    private func referencesRevoked(for id: UUID) {
        guard operationID == id else { return }
        cancel(notice: false); approvedAccess = nil; destination = nil
        error = "本次參考資料已撤銷；請確認目前設定與目的服務後重新查詢。"
        status = "查詢已停止，問題與已擷取的 PDF 文字仍保留；晚到回覆不會更新結果。"
    }

    private func validate(_ prior: ModelAccess, current: ModelAccess) throws {
        guard prior.configuration.baseURL == current.configuration.baseURL,
              prior.configuration.model == current.configuration.model,
              prior.configuration.maxOutputTokens == current.configuration.maxOutputTokens,
              prior.key == current.key else { throw HostError.changed }
    }

    private func fail(_ failure: Error) {
        cancel(notice: false)
        if failure is RunReferenceError {
            approvedAccess = nil; destination = nil
            error = "無法使用本次參考資料；請確認記憶與資料設定後重新查詢。"
        } else if failure is HostError || (failure as? DocumentQueryError) == .contextChanged {
            approvedAccess = nil; destination = nil
            error = "模型設定或本次查詢已變更，請重新確認後再開始。"
        } else {
            error = (failure as? DocumentQueryError)?.errorDescription ?? "無法完成本次 PDF 查詢，未產生可驗證的回答。"
        }
        status = "本次查詢未完成，問題與已擷取的文字仍保留。"
    }
}
