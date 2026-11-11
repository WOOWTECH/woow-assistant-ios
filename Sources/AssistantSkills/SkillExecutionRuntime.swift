import Foundation

/// Only host-supplied adapters can execute. No Markdown-to-command interpreter.
public protocol SkillExecutionPDFWorker: Sendable {
    var destination: String { get }
    func extract(data: Data, options: SkillExecutionPDFOptions) async throws -> SkillExecutionPDFResult
}

public enum SkillExecutionPDFBackend: Sendable { case native, originalWorker }

/// One plan per runtime. Replace the runtime when input/options/destination changes.
/// Call authorize only from an explicit user action after showing that exact step.
public actor SkillExecutionRuntime {
    public nonisolated let plan: SkillExecutionPlan
    private let selection: SkillExecutionSelectedFile
    private let options: SkillExecutionPDFOptions
    private let worker: (any SkillExecutionPDFWorker)?
    private let clock: @Sendable () -> Date
    private var index = 0
    private var grants: [UUID: SkillExecutionApproval] = [:]
    private var bytes: Data?
    private var busy = false
    private var cancelled = false

    public init(selectedFile: SkillExecutionSelectedFile, options: SkillExecutionPDFOptions,
                backend: SkillExecutionPDFBackend = .native, worker: (any SkillExecutionPDFWorker)? = nil,
                catalog: BundledSkillCatalog, clock: @escaping @Sendable () -> Date = { Date() }) throws {
        guard let entry = catalog.entry(id: "documents") else { throw SkillCatalogError.notFound }
        self.selection = selectedFile; self.options = options; self.worker = worker; self.clock = clock
        let provenance = ([entry.original] + entry.assets).map(SkillExecutionProvenance.init)
        let native = backend == .native
        let capability: SkillExecutionCapability = native ? .nativePDFText : .originalPDFWorker
        let available = native ? SkillExecutionPDF.available : worker != nil
        let detail = native ? "在裝置上以 PDFKit 擷取文字；不會上傳。" :
            worker.map { "檔案與提供的 PDF 密碼會傳送至 \($0.destination)，執行固定版本原始腳本。" } ??
            "尚未設定工作服務；不會建立連線或自動部署。"
        let steps = [
            SkillExecutionStep(id: UUID(), capability: .selectedPDFRead, title: "讀取選取的 PDF",
                disclosure: "只讀取本次選取的檔案，最多 10 MiB；不會掃描資料夾。",
                availability: SkillExecutionAvailability(capability: .selectedPDFRead, available: true, detail: selectedFile.accessDetail), provenance: provenance),
            SkillExecutionStep(id: UUID(), capability: capability, title: native ? "在裝置上擷取 PDF" : "上傳 PDF 並執行原版腳本",
                disclosure: detail,
                availability: SkillExecutionAvailability(capability: capability, available: available, detail: detail), provenance: provenance)
        ]
        let id = UUID()
        let filename = String(selectedFile.url.lastPathComponent.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.map(String.init).joined().prefix(160))
        let canonical: [String: Any] = ["id": id.uuidString, "selection": selectedFile.id.uuidString,
            "selectionOrigin": selectedFile.browserDownloadID == nil ? "documentPicker" : "browserDownload",
            "downloadID": selectedFile.browserDownloadID?.uuidString ?? "",
            "filename": filename, "pages": options.pages ?? "", "metadata": options.metadataOnly,
            "passwordProvided": options.password != nil, "backend": capability.rawValue,
            "destination": native ? "device" : (worker?.destination ?? "unavailable"),
            "steps": steps.map { ["id": $0.id.uuidString, "capability": $0.capability.rawValue,
                "title": $0.title, "disclosure": $0.disclosure, "available": $0.availability.available,
                "availabilityDetail": $0.availability.detail] as [String: Any] },
            "sources": provenance.map { [$0.repository, $0.path, $0.revision, $0.sha256] }]
        let fingerprint = skillExecutionDigest(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys]))
        plan = SkillExecutionPlan(id: id, skillID: entry.id, filename: filename, pages: options.pages,
            metadataOnly: options.metadataOnly, includesPassword: options.password != nil, steps: steps, fingerprint: fingerprint)
    }

    public func nextStep() -> SkillExecutionStep? {
        guard !cancelled, index < plan.steps.count else { return nil }
        return plan.steps[index]
    }

    public func authorize(stepID: UUID) throws -> SkillExecutionApproval {
        guard !cancelled else { throw SkillExecutionError.cancelled }
        guard !busy else { throw SkillExecutionError.busy }
        guard let step = nextStep(), step.id == stepID else { throw SkillExecutionError.stalePlan }
        guard step.availability.available else { throw SkillExecutionError.unavailable }
        let grant = SkillExecutionApproval(id: UUID(), planID: plan.id, stepID: stepID, expiresAt: clock().addingTimeInterval(120))
        grants.removeAll(); grants[grant.id] = grant
        return grant
    }

    public func cancel() {
        cancelled = true; grants.removeAll(); bytes = nil
    }

    public func execute(_ approval: SkillExecutionApproval) async throws -> SkillExecutionStepResult {
        guard !cancelled else { throw SkillExecutionError.cancelled }
        guard !busy else { throw SkillExecutionError.busy }
        guard let issued = grants.removeValue(forKey: approval.id), issued.planID == plan.id,
              issued.stepID == nextStep()?.id else { throw SkillExecutionError.approvalRequired }
        guard clock() < issued.expiresAt else { throw SkillExecutionError.expiredApproval }
        guard let step = nextStep(), step.availability.available else { throw SkillExecutionError.unavailable }
        busy = true
        defer { busy = false }
        do {
            try Task.checkCancellation()
            let result: SkillExecutionStepResult
            if step.capability == .selectedPDFRead {
                let data = try SkillExecutionPDF.read(selection)
                bytes = data
                result = .selectedFileRead(byteCount: data.count, sha256: skillExecutionDigest(data))
            } else {
                guard let data = bytes else { throw SkillExecutionError.stalePlan }
                if step.capability == .nativePDFText {
                    result = .pdf(try SkillExecutionPDF.extract(data, options: options))
                } else {
                    guard let worker else { throw SkillExecutionError.unavailable }
                    let remote = try await worker.extract(data: data, options: options)
                    guard remote.inputSHA256 == skillExecutionDigest(data),
                          remote.originalScriptSHA256 == SkillExecutionHTTPWorker.scriptSHA256,
                          remote.pageCount > 0, remote.pageCount <= 100_000 else { throw SkillExecutionError.invalidWorkerResponse }
                    let expected = options.metadataOnly ? [] : try SkillExecutionPageRange.parse(options.pages, pageCount: remote.pageCount)
                    guard remote.pages.map(\.number) == expected,
                          remote.emptyPages == remote.pages.filter({ $0.text.isEmpty }).map(\.number),
                          remote.text.utf8.count + remote.metadata.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= SkillExecutionLimits.outputBytes else {
                        throw SkillExecutionError.invalidWorkerResponse
                    }
                    result = .pdf(remote)
                }
            }
            try Task.checkCancellation()
            guard !cancelled else { throw SkillExecutionError.cancelled }
            index += 1; grants.removeAll()
            if index == plan.steps.count { bytes = nil }
            return result
        } catch is CancellationError {
            cancel(); throw SkillExecutionError.cancelled
        } catch {
            // A failed step needs fresh user approval. Never retry/upload implicitly.
            if cancelled { throw SkillExecutionError.cancelled }
            throw error
        }
    }
}
