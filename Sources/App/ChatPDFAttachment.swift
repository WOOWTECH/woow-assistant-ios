import AssistantModels
import AssistantPersistence
import AssistantSkills
import Combine
import Foundation

/// One native selection. This object and its grants are never Codable.
@MainActor final class ChatPDFAttachment: ObservableObject, Identifiable {
    enum Phase { case awaitingRead, reading, awaitingExtraction, extracting, ready, failed, removed }
    static let retentionNotice = "只保存已完成問答的擷取文字與引文，不保存原始 PDF；要再次查詢原 PDF，請重新選取並核准。"
    static let scopeNotice = "本次查詢這份 PDF 與目前問題，並可使用已啟用的個人檔案、相關記憶及適用技能作背景；不使用 MCP、不修改記憶、不傳送舊對話。"
    let id = UUID()
    let plan: SkillExecutionPlan
    @Published private(set) var phase: Phase = .awaitingRead
    @Published private(set) var step: SkillExecutionStep?
    @Published private(set) var source: DocumentTextSnapshot?
    @Published private(set) var error: String?
    @Published private(set) var destinationLabel: String?
    private var approvedAccess: ModelAccess?
    private var approvedDestination: ConversationDestination?
    private let runtime: SkillExecutionRuntime
    private let catalog: BundledSkillCatalog
    private var operationID: UUID?
    private var preparation: Task<Void, Never>?
    var capturedPreparation: Task<Void, Never>? { preparation }
    var isReady: Bool { phase == .ready && source != nil && approvedAccess != nil && approvedDestination != nil }

    init(userSelectedURL: URL, pages: String? = nil, password: String? = nil) throws {
        let catalog = try BundledSkillCatalog.bundled()
        let runtime = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: userSelectedURL),
            options: .init(pages: pages, password: password), catalog: catalog)
        self.catalog = catalog; self.runtime = runtime; plan = runtime.plan; step = runtime.plan.steps[0]
    }

    func approve(stepID: UUID) {
        guard preparation == nil, let step, step.id == stepID,
              phase == .awaitingRead || phase == .awaitingExtraction else { return }
        let id = UUID(); operationID = id; error = nil
        phase = step.capability == .selectedPDFRead ? .reading : .extracting
        preparation = Task { [weak self, runtime] in
            do {
                try Task.checkCancellation()
                let grant = try await runtime.authorize(stepID: stepID)
                let result = try await runtime.execute(grant)
                try Task.checkCancellation()
                guard let self, self.operationID == id else { return }
                switch result {
                case .selectedFileRead:
                    self.phase = .awaitingExtraction; self.step = self.plan.steps[1]
                case .pdf(let result):
                    self.source = try DocumentTextSnapshot(result: result, filename: self.plan.filename, catalog: self.catalog)
                    self.phase = .ready; self.step = nil
                }
                self.preparation = nil; self.operationID = nil
            } catch {
                guard let self, self.operationID == id else { return }
                self.phase = .failed; self.step = nil; self.operationID = nil; self.preparation = nil
                self.error = (error as? SkillExecutionError)?.errorDescription
                    ?? (error as? DocumentQueryError)?.errorDescription ?? "無法擷取這份 PDF；請重新選取。"
            }
        }
    }

    func confirmDestination(access: ModelAccess, destination: ConversationDestination) {
        guard phase == .ready, source != nil,
              destination.baseURL == access.configuration.baseURL.absoluteString,
              destination.model == access.configuration.model else { return }
        approvedAccess = access; approvedDestination = destination
        destinationLabel = destination.baseURL + "\n模型：" + destination.model
    }

    func validate(access: ModelAccess, destination: ConversationDestination?) throws {
        guard isReady, let prior = approvedAccess, approvedDestination == destination,
              prior.configuration.baseURL == access.configuration.baseURL,
              prior.configuration.model == access.configuration.model,
              prior.configuration.maxOutputTokens == access.configuration.maxOutputTokens,
              prior.key == access.key else {
            revokeDestination(); throw DocumentQueryError.contextChanged
        }
    }

    func revokeDestination() { approvedAccess = nil; approvedDestination = nil; destinationLabel = nil }

    /// Leaving preparation withdraws its pending result. PDFKit may finish a
    /// synchronous operation already entered; no late result becomes usable.
    func stopPreparation() {
        guard preparation != nil else { return }
        operationID = nil; preparation?.cancel(); preparation = nil
        phase = .failed; step = nil; source = nil; revokeDestination()
        error = "已停止附件準備；請移除後重新選取。"
        Task { await runtime.cancel() }
    }

    func remove() {
        operationID = nil; preparation?.cancel(); preparation = nil
        phase = .removed; step = nil; source = nil; error = nil; revokeDestination()
        Task { await runtime.cancel() }
    }

    static func archive(_ result: DocumentQueryResult) throws -> ArchivedPDFAnswer {
        let citations = try result.citations.map { citation -> ArchivedPDFAnswer.Citation in
            guard let read = result.reads.first(where: { $0.id == citation.readID }),
                  read.pageIndex == citation.pageIndex, read.pageNumber == citation.pageNumber,
                  read.sourceSHA256 == result.source.sha256, citation.sourceSHA256 == result.source.sha256
            else { throw DocumentQueryError.invalidEvidence }
            return .init(readID: read.id, pageIndex: citation.pageIndex, readOffset: read.offset,
                         readLength: read.length, offset: citation.offset, quote: citation.quote)
        }
        return try ArchivedPDFAnswer(filename: result.source.filename, inputSHA256: result.source.inputSHA256,
            originalPageCount: result.source.pageCount, pages: result.source.pages.map { .init(number: $0.pageNumber, text: $0.text) },
            citations: citations)
    }
}
