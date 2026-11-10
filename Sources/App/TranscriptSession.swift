import AssistantModels
import AssistantSkills
import Combine
import Foundation

@MainActor final class TranscriptSession: ObservableObject {
    @Published private(set) var review: TranscriptFileReview?
    @Published private(set) var snapshot: TranscriptSnapshot?
    @Published private(set) var result: TranscriptResult?
    @Published private(set) var refusal: String?
    @Published private(set) var destination: String?
    @Published private(set) var running = false
    @Published private(set) var status = "請選取文字稿或字幕檔。"
    @Published private(set) var error: String?
    @Published private(set) var diagnostic = "TRANSCRIPT_DIAGNOSTIC terminal=idle reason=none corrections=0"
    #if DEBUG
    @Published private(set) var audit = TranscriptUITestAudit()
    #endif
    private let files = TranscriptFileAccess()
    private let learning: LearningStore
    private var references: LearningRunSnapshot?
    private var access: ModelAccess?
    private var runtime: TranscriptRuntime?
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var commandFailureReason: TranscriptCommandFailureReason?
    private var formatCorrections = 0

    init(learning: LearningStore) { self.learning = learning }

    #if DEBUG
    /// Read-only task identity for native tests to join actual cancellation.
    var capturedRunCompletion: Task<Void, Never>? { task }
    #endif

    private enum Phase {
        case idle, reading, running, completed, refused, unknownFailure
        case failed(TranscriptError)
        var code: String {
            switch self {
            case .idle: return "idle"
            case .reading: return "reading"
            case .running: return "running"
            case .completed: return "completed"
            case .refused: return "refused"
            case .unknownFailure: return "unknownFailure"
            case .failed(let error): return error.rawValue
            }
        }
    }

    private func recordDiagnostic(_ phase: Phase) {
        diagnostic = "TRANSCRIPT_DIAGNOSTIC terminal=\(phase.code) reason=\(commandFailureReason?.rawValue ?? "none") corrections=\(formatCorrections)"
    }

    private func resetDiagnostic() {
        commandFailureReason = nil; formatCorrections = 0; recordDiagnostic(.idle)
    }

    func select(_ url: URL) {
        cancel(notice: false); snapshot = nil; result = nil; refusal = nil; error = nil
        resetDiagnostic()
        do {
            review = try files.select(url); status = "請核對檔名與讀取範圍，尚未讀取內容。"
            #if DEBUG
            audit.record(.selected)
            #endif
        }
        catch { fail(error) }
    }

    func approveRead() {
        guard let review, !running else { return }
        let id = UUID(); operationID = id; running = true; error = nil
        status = "正在讀取核准的文字檔，尚未傳送模型…"
        recordDiagnostic(.reading)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let source = try await self.files.read(approving: review.id)
                guard self.operationID == id, !Task.isCancelled else { return }
                self.snapshot = source; self.review = nil; self.running = false; self.task = nil
                #if DEBUG
                self.audit.record(.fileRead(bytes: source.byteCount))
                #endif
                self.status = "已讀取文字快照。請核對目的服務，再明確開始模型整理。"
                self.recordDiagnostic(.idle)
            } catch {
                guard self.operationID == id else { return }
                self.fail(error)
            }
        }
    }

    func confirmDestination(modelAccess: () throws -> ModelAccess) {
        guard !running else { return }
        do {
            let current = try modelAccess()
            guard let host = current.configuration.baseURL.host, current.configuration.baseURL.scheme == "https" else {
                throw TranscriptError.modelFailed
            }
            access = current
            destination = "https://" + host + (current.configuration.baseURL.port.map { ":\($0)" } ?? "")
                + "\n模型：" + current.configuration.model
            error = nil
        } catch {
            access = nil; destination = nil
            self.error = "無法取得已設定的模型服務，請先儲存模型設定。"
            recordDiagnostic(.failed(.modelFailed))
        }
    }

    func start(format: TranscriptFormat, modelAccess: @escaping () throws -> ModelAccess) {
        guard let source = snapshot, let approvedAccess = access, !running else { return }
        do {
            try validate(approvedAccess, current: modelAccess())
            let runtime = try TranscriptRuntime(source: source, format: format, catalog: .bundled())
            // Retrieval uses the user's format choice, never untrusted source
            // contents, filenames, model output or page text as a new request.
            let snapshot = try learning.captureRunReferences(goal: "文字稿 字幕 " + format.title,
                capabilities: TranscriptRuntime.referenceCapabilities)
            self.runtime = runtime; error = nil; result = nil; refusal = nil
            resetDiagnostic(); recordDiagnostic(.running)
            let id = UUID(); operationID = id; running = true
            references = snapshot
            snapshot.onRevoke = { [weak self] in self?.referencesRevoked(for: id) }
            task = Task { [weak self] in
                do {
                    let configuration = ModelConfiguration(baseURL: approvedAccess.configuration.baseURL,
                        model: approvedAccess.configuration.model, maxOutputTokens: 8192)
                    let outcome = try await runtime.run(client: approvedAccess.client, configuration: configuration,
                        apiKey: approvedAccess.key, references: snapshot.references, validateContext: { [weak self] in
                            guard let self, self.operationID == id else { throw TranscriptError.cancelled }
                            try snapshot.check()
                            try self.validate(approvedAccess, current: modelAccess())
                        }, onEvent: { [weak self] event in
                            guard let self, self.operationID == id else { return }
                            switch event {
                            case .requestingModel(let count):
                                self.status = "正在請模型整理（第 \(count) 回合）…"
                                #if DEBUG
                                self.audit.record(.modelRequest)
                                #endif
                            case .read(let covered, let total):
                                self.status = "模型已讀取 \(covered)／\(total) 位元組。"
                                #if DEBUG
                                self.audit.record(.rangeRead(covered: covered, total: total))
                                #endif
                            case .commandFormatRejected(let reason, let issued):
                                self.commandFailureReason = reason
                                if issued { self.formatCorrections += 1 }
                                self.recordDiagnostic(.running)
                                self.status = issued ? "模型指令格式無效；正在要求一次格式修正，尚未執行該動作。"
                                    : "模型指令格式仍無效，本次整理已停止。"
                            }
                        })
                    guard let self, self.operationID == id, !Task.isCancelled else { return }
                    try snapshot.check()
                    try self.validate(approvedAccess, current: modelAccess())
                    self.releaseReferences()
                    self.running = false; self.operationID = nil; self.task = nil; self.runtime = nil
                    switch outcome {
                    case .completed(let result):
                        self.result = result
                        #if DEBUG
                        self.audit.record(.completed)
                        #endif
                        self.status = "全文讀取與原文證據逐字核對已完成；請再核對整理內容。"
                        self.recordDiagnostic(.completed)
                    case .refused(let reason):
                        self.refusal = reason; self.status = "模型未完成整理，沒有新增記憶或技能。"
                        self.recordDiagnostic(.refused)
                    }
                } catch {
                    guard let self, self.operationID == id else { return }
                    self.fail(error)
                }
            }
        } catch { fail(error) }
    }

    func cancel(notice: Bool = true) {
        let wasRunning = running
        operationID = nil; files.cancel(); task?.cancel(); task = nil; runtime?.cancel(); runtime = nil
        releaseReferences()
        running = false; review = nil
        if notice || wasRunning { recordDiagnostic(.failed(.cancelled)) }
        if notice { status = TranscriptError.cancelled.errorDescription! }
    }

    func hostChanged() {
        cancel(notice: false); access = nil; destination = nil
        if result == nil { recordDiagnostic(.failed(.contextChanged)) }
        status = result == nil ? TranscriptError.contextChanged.errorDescription!
            : "模型設定已變更；已交付的整理與原文仍保留，再次整理前請重新確認目的服務。"
    }

    /// The host has already obtained explicit approval for this exact source.
    /// Loading a snapshot never reads a URL or automatically starts the model.
    func loadApprovedSource(_ source: TranscriptSnapshot) {
        cancel(notice: false); result = nil; refusal = nil; error = nil
        resetDiagnostic()
        access = nil; destination = nil; snapshot = source
        status = "已接收你核准的文字快照。請確認目的服務，再明確開始模型整理。"
    }

    func selectionFailed() { error = "選檔未完成，尚未讀取新的內容。" }

    private func releaseReferences() {
        let snapshot = references; references = nil
        snapshot?.onRevoke = nil; snapshot?.revoke()
    }

    private func referencesRevoked(for id: UUID) {
        guard operationID == id else { return }
        cancel(notice: false); access = nil; destination = nil
        error = "本次參考資料已撤銷；請確認目前設定與目的服務後重新整理。"
        status = "整理已停止，已核准的原文仍保留；晚到回覆不會更新結果。"
        recordDiagnostic(.failed(.contextChanged))
    }

    private func validate(_ prior: ModelAccess, current: ModelAccess) throws {
        guard prior.configuration.baseURL == current.configuration.baseURL,
              prior.configuration.model == current.configuration.model,
              prior.configuration.maxOutputTokens == current.configuration.maxOutputTokens,
              prior.key == current.key else { throw TranscriptError.contextChanged }
    }

    private func fail(_ error: Error) {
        cancel(notice: false); result = nil
        status = "本次文字整理未完成。"
        self.error = (error as? TranscriptError)?.errorDescription ?? "無法完成本次整理，沒有新增記憶或技能。"
        recordDiagnostic((error as? TranscriptError).map { .failed($0) } ?? .unknownFailure)
    }
}
