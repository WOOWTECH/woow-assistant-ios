#if os(iOS) || SKILL_EXECUTION_EXPORT_CHECKS
#if !SKILL_EXECUTION_EXPORT_CHECKS
import AssistantSkills
#endif
import SwiftUI
import UniformTypeIdentifiers
#if DEBUG
import Darwin
#endif

/// An immutable UTF-8 snapshot of a completed extraction. FileDocument leaves
/// destination selection and writing to the system exporter, never to a skill.
struct SkillExecutionTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.utf8PlainText] }
    let text: String

    init(text: String) throws {
        guard text.utf8.count <= SkillExecutionLimits.outputBytes else { throw SkillExecutionError.outputTooLarge }
        self.text = text
    }

    init(configuration: ReadConfiguration) throws { try self.init(fileWrapper: configuration.file) }

    init(fileWrapper: FileWrapper) throws {
        guard fileWrapper.isRegularFile, let data = fileWrapper.regularFileContents,
              data.count <= SkillExecutionLimits.outputBytes,
              let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        try self.init(text: text)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { snapshot() }
    func snapshot() -> FileWrapper { FileWrapper(regularFileWithContents: Data(text.utf8)) }
}
#endif

#if os(iOS)
/// Parent integration: present SkillExecutionView() from the documents skill.
/// A configured worker is optional; no endpoint or background upload is created.
struct SkillExecutionView: View {
    private let worker: (any SkillExecutionPDFWorker)?
    @StateObject private var model = SkillExecutionViewModel()
    @State private var choosingFile = false
    @State private var pages = ""
    @State private var password = ""
    @State private var metadataOnly = false
    @State private var useWorker = false
    @State private var exportingText = false
    @State private var exportDocument: SkillExecutionTextDocument?
    @State private var exportPlanID: UUID?
    @State private var exportFilename = "PDF文字"
    @State private var exportStatus: String?

    init(worker: (any SkillExecutionPDFWorker)? = nil) { self.worker = worker }

    var body: some View {
        Form {
            Section("PDF 文字擷取") {
                Text("選取檔案後檢視每一步，再分別核准。預設使用裝置上的 PDFKit。")
                    .accessibilityIdentifier("skillExecution.intro")
                if model.plan == nil {
                    TextField("頁碼，例如 1,3-5；留空代表全部", text: $pages)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("PDF 密碼（需要時填寫）", text: $password)
                    Toggle("只讀取文件資訊", isOn: $metadataOnly)
                    if worker != nil { Toggle("使用已設定的原版腳本服務", isOn: $useWorker) }
                    Button("選取 PDF") { choosingFile = true }
                        .accessibilityIdentifier("skillExecutionSelectPDF")
                }
                #if DEBUG
                if let fixture = model.uiTestFixture {
                    Text("測試文件已建立：\(fixture.filename)")
                        .font(.caption).accessibilityIdentifier("skillExecution.uitest.fixture")
                }
                if let audit = model.uiTestAudit {
                    Text(audit.evidence).font(.caption)
                        .accessibilityIdentifier("skillExecution.uitest.audit")
                }
                #endif
            }
            if let plan = model.plan {
                Section("本次計畫") {
                    Text(plan.filename).accessibilityIdentifier("skillExecution.filename")
                    Text(plan.metadataOnly ? "只讀取文件資訊" : "頁碼：\(plan.pages ?? "全部（最多 200 頁）")")
                    ForEach(plan.steps) { step in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(step.title).font(.headline)
                            Text(step.disclosure)
                            Text(model.completedStepIDs.contains(step.id) ? "已完成" :
                                (step.availability.available ? "能力已連接；此步驟仍需核准" : "能力尚未連接"))
                                .font(.caption)
                            if model.nextStepID == step.id {
                                Button(model.running ? "執行中…" : "核准並執行此步驟") { model.execute(stepID: step.id) }
                                    .disabled(model.running || !step.availability.available)
                                    .accessibilityIdentifier("skillExecutionApproveStep")
                                    .accessibilityValue(step.title)
                            }
                        }
                    }
                    DisclosureGroup("原版來源與雜湊") {
                        Text("計畫指紋：\(plan.fingerprint)").font(.caption).textSelection(.enabled)
                            .accessibilityIdentifier("skillExecution.fingerprint")
                        ForEach(plan.steps.first?.provenance ?? [], id: \.path) { source in
                            Text("\(source.path)\n\(source.revision)\nSHA-256：\(source.sha256)").font(.caption).textSelection(.enabled)
                        }
                        Text("這是經過限定的 iOS 能力實作，並非完整執行原版技能。")
                    }
                    .accessibilityIdentifier("skillExecution.sources")
                    Button("清除本次計畫", role: .destructive) { resetExport(); model.clear(); password = "" }
                        .accessibilityIdentifier("skillExecutionClearPlan")
                }
            }
            if let result = model.result {
                Section("擷取結果") {
                    Text("共 \(result.pageCount) 頁；引擎：\(result.engine)")
                        .accessibilityIdentifier("skillExecution.result.summary")
                    Text(result.notice)
                    if !result.text.isEmpty {
                        Text(result.text).textSelection(.enabled).accessibilityIdentifier("skillExecution.result.text")
                        Button("匯出文字檔") { beginExport(result) }
                            .disabled(exportingText)
                            .accessibilityIdentifier("skillExecutionExportText")
                    }
                    if let exportStatus {
                        Text(exportStatus).accessibilityIdentifier("skillExecution.export.status")
                    }
                    ForEach(result.metadata.keys.sorted(), id: \.self) { key in
                        Text("\(key)：\(result.metadata[key] ?? "")").textSelection(.enabled)
                    }
                }
            }
            if let status = model.status { Section { Text(status).accessibilityIdentifier("skillExecutionStatus") } }
        }
        .accessibilityIdentifier("skillExecution.form")
        .navigationTitle("執行 PDF 技能")
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.pdf], allowsMultipleSelection: false) { outcome in
            #if DEBUG
            model.recordImporterCallback(outcome)
            #endif
            switch outcome {
            case .success(let urls):
                guard let url = urls.first, urls.count == 1 else {
                    model.status = "未能取得選取的 PDF，請重新選取一個檔案。"
                    return
                }
                model.prepare(url: url, pages: pages, password: password, metadataOnly: metadataOnly, worker: useWorker ? worker : nil)
                password = ""
            case .failure: model.status = "未能選取檔案，請重試。"
            }
        }
        .fileExporter(isPresented: $exportingText, document: exportDocument,
                      contentTypes: [.utf8PlainText], defaultFilename: exportFilename,
                      onCompletion: { outcome in
            switch outcome {
            case .success: finishExport("文字已儲存至所選位置。")
            case .failure: finishExport("文字未能儲存，請重新選擇位置再試一次。")
            }
        }, onCancellation: { finishExport("已取消匯出，擷取結果仍保留。") })
        .onAppear { model.seedUITestIfRequested() }
        .onDisappear { resetExport(); model.clear() }
    }

    private func beginExport(_ result: SkillExecutionPDFResult) {
        guard let plan = model.plan, !model.running, !result.text.isEmpty else { return }
        do {
            exportDocument = try SkillExecutionTextDocument(text: result.text)
            exportPlanID = plan.id
            exportFilename = URL(fileURLWithPath: plan.filename).deletingPathExtension().lastPathComponent + "-文字"
            exportStatus = nil
            exportingText = true
        } catch { exportStatus = "文字結果過大，請縮小頁碼範圍後再匯出。" }
    }

    private func finishExport(_ message: String) {
        // A late dialog callback must not affect a cleared or replaced plan.
        if let exportPlanID, model.plan?.id == exportPlanID { exportStatus = message }
        exportDocument = nil; exportPlanID = nil
    }

    private func resetExport() {
        exportPlanID = nil; exportingText = false; exportDocument = nil; exportStatus = nil
    }
}

@MainActor
private final class SkillExecutionViewModel: ObservableObject {
    @Published var plan: SkillExecutionPlan?
    @Published var nextStepID: UUID?
    @Published var completedStepIDs: Set<UUID> = []
    @Published var result: SkillExecutionPDFResult?
    @Published var status: String?
    @Published var running = false
    private var runtime: SkillExecutionRuntime?
    private var task: Task<Void, Never>?
    #if DEBUG
    @Published private(set) var uiTestFixture: SkillExecutionUITestSupport.Fixture?
    @Published private(set) var uiTestAudit: SkillExecutionUITestAudit?
    #endif

    func seedUITestIfRequested() {
        #if DEBUG
        guard uiTestFixture == nil else { return }
        do {
            uiTestFixture = try SkillExecutionUITestSupport.seedIfRequested()
            if uiTestFixture != nil { uiTestAudit = SkillExecutionUITestAudit() }
        } catch { status = "測試 PDF 無法建立；請檢查測試命名空間與檔案設定。" }
        #endif
    }

    #if DEBUG
    func recordImporterCallback(_ outcome: Result<[URL], Error>) {
        // This fixture exists only after the seeder's strict DEBUG test gates
        // pass. Report delivery/counts only, never URLs or error descriptions.
        guard let fixture = uiTestFixture else { return }
        let outcomeName: String
        let count: String
        switch outcome {
        case .success(let urls): outcomeName = "success"; count = String(urls.count)
        case .failure: outcomeName = "failure"; count = "none"
        }
        print("SKILL_PDF_IMPORTER_CALLBACK namespace=\(fixture.namespace.uuidString) outcome=\(outcomeName) count=\(count) sampledAt=\(Date().timeIntervalSince1970)")
        fflush(stdout)
    }
    #endif

    func prepare(url: URL, pages: String, password: String, metadataOnly: Bool, worker: (any SkillExecutionPDFWorker)?) {
        clear()
        do {
            let options = try SkillExecutionPDFOptions(pages: pages, metadataOnly: metadataOnly, password: password.isEmpty ? nil : password)
            let execution = try SkillExecutionRuntime(selectedFile: SkillExecutionSelectedFile(userSelectedURL: url), options: options,
                backend: worker == nil ? .native : .originalWorker, worker: worker, catalog: BundledSkillCatalog.bundled())
            runtime = execution; plan = execution.plan; nextStepID = execution.plan.steps.first?.id
            #if DEBUG
            uiTestAudit?.selections += 1
            #endif
        } catch { status = (error as? LocalizedError)?.errorDescription ?? "無法建立執行計畫。" }
    }

    func execute(stepID: UUID) {
        guard let runtime, !running else { return }
        let id = runtime.plan.id
        running = true; status = nil
        task = Task {
            do {
                let grant = try await runtime.authorize(stepID: stepID)
                #if DEBUG
                // Count the actual runtime dispatch, before awaiting it. A missing
                // result alone is not evidence that extraction never started.
                if runtime.plan.steps.first(where: { $0.id == stepID })?.capability == .selectedPDFRead {
                    uiTestAudit?.reads += 1
                } else { uiTestAudit?.extractionAttempts += 1 }
                #endif
                let outcome = try await runtime.execute(grant)
                guard plan?.id == id, !Task.isCancelled else { return }
                switch outcome {
                case .selectedFileRead(let count, _): status = "已讀取 \(count) 位元組。請核准下一個步驟。"
                case .pdf(let value):
                    result = value; status = "擷取完成。"
                    #if DEBUG
                    uiTestAudit?.results += 1
                    #endif
                }
                completedStepIDs.insert(stepID)
                nextStepID = await runtime.nextStep()?.id
            } catch {
                guard plan?.id == id else { return }
                status = (error as? SkillExecutionError)?.errorDescription ?? "執行未完成。"
            }
            if plan?.id == id { running = false }
        }
    }

    func clear() {
        task?.cancel(); task = nil
        if let runtime { Task { await runtime.cancel() } }
        runtime = nil; plan = nil; nextStepID = nil; completedStepIDs = []; result = nil; status = nil; running = false
    }
}
#endif
