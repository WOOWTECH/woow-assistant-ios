import AssistantBrowser
import AssistantSkills
import Combine
import Foundation
#if DEBUG
import Darwin
#endif

#if os(iOS) || SKILL_EXECUTION_EXPORT_CHECKS
#if canImport(AssistantSkills)
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
import Combine

private struct DocumentQueryPresentation: Identifiable {
    let id = UUID()
    let source: DocumentTextSnapshot
}

/// Parent integration: present from the documents skill with current model access.
/// A configured worker is optional; no endpoint or background upload is created.
@MainActor struct SkillExecutionView: View {
    private let learning: LearningStore
    private let modelAccess: () throws -> ModelAccess
    private let modelChanges: AnyPublisher<Void, Never>
    private let suppliedWorker: (any SkillExecutionPDFWorker)?
    @StateObject private var workerSettings = SkillWorkerPreferences()
    private var worker: (any SkillExecutionPDFWorker)? { suppliedWorker ?? workerSettings.worker }
    @StateObject private var model = SkillExecutionViewModel()
    @State private var choosingFile = false
    @State private var importChoice: PDFImportChoice = .original
    @State private var importCopyExpanded = false
    @State private var documentQuery: DocumentQueryPresentation?
    @State private var pages = ""
    @State private var password = ""
    @State private var metadataOnly = false
    @State private var useWorker = false
    @State private var exportingText = false
    @State private var exportDocument: SkillExecutionTextDocument?
    @State private var exportPlanID: UUID?
    @State private var exportFilename = "PDF文字"
    @State private var exportStatus: String?
    #if DEBUG
    @State private var pickerObservation = "尚未觀察選檔器"
    #endif

    private var pickerExperiment: PDFNativePickerExperiment.Configuration? {
        #if DEBUG
        PDFNativePickerExperiment.configuration(arguments: ProcessInfo.processInfo.arguments,
                                                fixtureNamespace: model.uiTestFixture?.namespace)
        #else
        nil
        #endif
    }

    private var pickerObservationNamespace: UUID? {
        #if DEBUG
        model.uiTestFixture?.namespace
        #else
        nil
        #endif
    }

    init(learning: LearningStore, modelAccess: @escaping () throws -> ModelAccess, modelChanges: AnyPublisher<Void, Never>,
         worker: (any SkillExecutionPDFWorker)? = nil, downloadedPDF: BrowserDownloadedPDFSelection? = nil) {
        _model = StateObject(wrappedValue: SkillExecutionViewModel(downloadedPDF: downloadedPDF))
        self.learning = learning; self.modelAccess = modelAccess; self.modelChanges = modelChanges; self.suppliedWorker = worker
    }

    var body: some View {
        Form {
            Section("PDF 文字擷取") {
                Text("選取檔案後檢視每一步，再分別核准。預設使用裝置上的 PDFKit。")
                    .accessibilityIdentifier("skillExecution.intro")
                Text(verbatim: SkillExecutionDependencies.pdfQueryScope)
                    .font(.caption).accessibilityIdentifier("skillExecution.pdfQuery.scope")
                if model.plan == nil {
                    TextField("頁碼，例如 1,3-5；留空代表全部", text: $pages)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("PDF 密碼（需要時填寫）", text: $password)
                    Toggle("只讀取文件資訊", isOn: $metadataOnly)
                    if worker != nil { Toggle("使用已設定的原版腳本服務", isOn: $useWorker) }
                    if let download = model.downloadedPDF {
                        Text(verbatim: download.filename).accessibilityIdentifier("downloadPDF.filename")
                        Text("來源：此 App 的已完成下載。下載成功尚未授權讀取或擷取。")
                            .font(.caption).accessibilityIdentifier("downloadPDF.source")
                        Button("建立下載 PDF 計畫") {
                            model.prepareDownload(pages: pages, password: password, metadataOnly: metadataOnly,
                                                  worker: useWorker ? worker : nil)
                            password = ""
                        }.disabled(!model.downloadAvailable).accessibilityIdentifier("downloadPDF.prepare")
                    } else {
                        Button("選取 PDF") { presentPicker(.original) }
                            .accessibilityIdentifier("skillExecutionSelectPDF")
                    }
                    if model.downloadedPDF == nil {
                        Button {
                            importCopyExpanded.toggle()
                        } label: {
                            HStack {
                                Text("改用匯入副本")
                                Spacer()
                                Image(systemName: importCopyExpanded ? "chevron.down" : "chevron.right")
                            }
                        }
                        .accessibilityIdentifier("skillExecution.importCopy.options")
                        .accessibilityValue(importCopyExpanded ? "已展開" : "已收合")
                        if importCopyExpanded {
                            Text("選檔後，系統會先建立暫存副本並占用儲存空間，不會更動原檔。App 讀取與後續擷取仍需分別核准。App 最多讀取 10 MiB；系統複製的大小不受此上限限制。")
                                .accessibilityIdentifier("skillExecution.importCopy.notice")
                            Button("選取 PDF 並匯入副本") { presentPicker(.importCopy) }
                                .accessibilityIdentifier("skillExecutionImportPDFCopy")
                        }
                    }
                }
                #if DEBUG
                if let fixture = model.uiTestFixture {
                    Text("測試文件已建立：\(fixture.filename)")
                        .font(.caption).accessibilityIdentifier("skillExecution.uitest.fixture")
                        .accessibilityValue(pickerObservation)
                }
                if let audit = model.uiTestAudit {
                    Text(audit.evidence).font(.caption)
                        .accessibilityIdentifier("skillExecution.uitest.audit")
                }
                if let audit = model.downloadUIAudit, let selection = model.downloadedPDF {
                    Text("download=\(selection.downloadID.uuidString) plan=\(model.plan?.id.uuidString ?? "none") reads=\(audit.reads) extractions=\(audit.extractions) results=\(audit.results)")
                        .font(.caption).accessibilityIdentifier("downloadPDF.audit")
                    if let result = model.result {
                        Text(verbatim: result.inputSHA256).font(.caption)
                            .accessibilityIdentifier("downloadPDF.resultDigest")
                    }
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
                        if result.pages.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                            Button("查詢這份 PDF") { beginQuery(result) }
                                .disabled(model.running || exportingText)
                                .accessibilityIdentifier("skillExecution.query")
                        }
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
        .modifier(PDFImportPresentation(isPresented: $choosingFile, choice: importChoice, experiment: pickerExperiment,
                                       onCompletion: receivePDFSelection, onCancellation: {
            #if DEBUG
            model.recordPickerCancellation()
            #endif
        }, onObservation: { value in
            #if DEBUG
            pickerObservation = value
            #endif
        }, observationNamespace: pickerObservationNamespace))
        .fileExporter(isPresented: $exportingText, document: exportDocument,
                      contentTypes: [.utf8PlainText], defaultFilename: exportFilename,
                      onCompletion: { outcome in
            switch outcome {
            case .success: finishExport("文字已儲存至所選位置。")
            case .failure: finishExport("文字未能儲存，請重新選擇位置再試一次。")
            }
        }, onCancellation: { finishExport("已取消匯出，擷取結果仍保留。") })
        .sheet(item: $documentQuery) { presentation in
            NavigationStack {
                DocumentQueryView(source: presentation.source, learning: learning, modelAccess: modelAccess, modelChanges: modelChanges)
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { SkillWorkerSettingsView(settings: workerSettings) } label: { Text("腳本服務") }
                    .accessibilityIdentifier("skillExecution.workerSettings")
            }
        }
        .onChange(of: model.downloadAvailable) { _, available in
            if model.downloadedPDF != nil && !available { resetExport(); documentQuery = nil }
        }
        .onAppear { workerSettings.reload(); if model.downloadedPDF == nil { model.seedUITestIfRequested() } }
        .onDisappear {
            resetExport()
            // The query sheet owns an immutable completed snapshot. Keep the
            // extraction available when returning; leaving its screen otherwise
            // still invalidates the original execution and its grants.
            if documentQuery == nil { model.clear() }
        }
    }

    private func beginQuery(_ result: SkillExecutionPDFResult) {
        guard let plan = model.plan, !model.running, !exportingText, documentQuery == nil else { return }
        do {
            let source = try DocumentTextSnapshot(result: result, filename: plan.filename, catalog: .bundled())
            documentQuery = DocumentQueryPresentation(source: source)
        } catch { model.status = "這次擷取結果無法建立查詢快照，請確認已擷取可讀取的文字。" }
    }

    private func presentPicker(_ choice: PDFImportChoice) {
        // Every presentation gets an explicit choice; cancelling a copy import
        // cannot change the behavior of the original selection button.
        guard !choosingFile, model.plan == nil else { return }
        importChoice = choice
        #if DEBUG
        model.recordPickerPresentation()
        #endif
        choosingFile = true
    }

    private func receivePDFSelection(_ outcome: Result<[URL], Error>) {
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

#endif

/// Shared execution state: UIKit presentation is separate so the actual caller
/// and its cancellation/publication guards also execute in macOS checks.
@MainActor
final class SkillExecutionViewModel: ObservableObject {
    @Published var plan: SkillExecutionPlan?
    @Published var nextStepID: UUID?
    @Published var completedStepIDs: Set<UUID> = []
    @Published var result: SkillExecutionPDFResult?
    @Published var status: String?
    @Published var running = false
    private var runtime: SkillExecutionRuntime?
    private var task: Task<Void, Never>?
    let downloadedPDF: BrowserDownloadedPDFSelection?
    @Published private(set) var downloadAvailable: Bool
    var executingTask: Task<Void, Never>? { task }

    init(downloadedPDF: BrowserDownloadedPDFSelection? = nil) {
        self.downloadedPDF = downloadedPDF
        downloadAvailable = downloadedPDF?.isValid == true
        #if DEBUG
        if let downloadedPDF, let fixture = BrowserDownloadedPDFFixture.enabled,
           downloadedPDF.filename == fixture.filename { downloadUIAudit = DownloadUIAudit() }
        #endif
        downloadedPDF?.onInvalidated = { [weak self] in
            guard let self else { return }
            self.clear()
            self.downloadAvailable = false
            self.status = "下載檔案已刪除或變更，本次計畫已取消。請重新選取。"
        }
    }

    func prepareDownload(pages: String, password: String, metadataOnly: Bool, worker: (any SkillExecutionPDFWorker)?) {
        clear()
        do {
            guard let downloadedPDF else { throw SkillExecutionError.invalidSelection }
            try prepare(selection: downloadedPDF.selectedFile(), pages: pages, password: password,
                        metadataOnly: metadataOnly, worker: worker)
        } catch { status = (error as? LocalizedError)?.errorDescription ?? "無法建立執行計畫。" }
    }

    private func validateDownload() throws {
        if let downloadedPDF { _ = try downloadedPDF.selectedFile() }
    }
    #if DEBUG
    struct DownloadUIAudit { var reads = 0, extractions = 0, results = 0 }
    @Published private(set) var downloadUIAudit: DownloadUIAudit?
    @Published private(set) var uiTestFixture: SkillExecutionUITestSupport.Fixture?
    @Published private(set) var uiTestAudit: SkillExecutionUITestAudit?
    private var pickerDiagnosticOrdinal = 0
    private var pickerDiagnosticPending = false
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
    func recordPickerPresentation() {
        pickerDiagnosticOrdinal = min(pickerDiagnosticOrdinal + 1, 4)
        pickerDiagnosticPending = true
        guard let fixture = uiTestFixture else { return }
        SkillExecutionUITestSupport.recordReadPickerSnapshot(fixture, phase: "prePicker", ordinal: pickerDiagnosticOrdinal)
    }

    func recordPickerCancellation() {
        guard pickerDiagnosticPending, let fixture = uiTestFixture else { return }
        pickerDiagnosticPending = false
        SkillExecutionUITestSupport.recordReadPickerSnapshot(fixture, phase: "cancelled", ordinal: pickerDiagnosticOrdinal)
    }

    func recordImporterCallback(_ outcome: Result<[URL], Error>) {
        // This fixture exists only after the seeder's strict DEBUG test gates
        // pass. Report delivery/counts only, never URLs or error descriptions.
        guard let fixture = uiTestFixture else { return }
        if pickerDiagnosticPending {
            pickerDiagnosticPending = false
            switch outcome {
            case .success(let urls):
                SkillExecutionUITestSupport.recordReadPickerSnapshot(fixture, phase: "selectionReturned",
                    ordinal: pickerDiagnosticOrdinal, returnedURLs: urls)
            case .failure:
                SkillExecutionUITestSupport.recordReadPickerSnapshot(fixture, phase: "selectionFailure", ordinal: pickerDiagnosticOrdinal)
            }
        }
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
            guard downloadedPDF == nil else { throw SkillExecutionError.invalidSelection }
            try prepare(selection: SkillExecutionSelectedFile(userSelectedURL: url), pages: pages, password: password,
                        metadataOnly: metadataOnly, worker: worker)
            #if DEBUG
            uiTestAudit?.selections += 1
            #endif
        } catch { status = (error as? LocalizedError)?.errorDescription ?? "無法建立執行計畫。" }
    }

    private func prepare(selection: SkillExecutionSelectedFile, pages: String, password: String,
                         metadataOnly: Bool, worker: (any SkillExecutionPDFWorker)?) throws {
        let options = try SkillExecutionPDFOptions(pages: pages, metadataOnly: metadataOnly, password: password.isEmpty ? nil : password)
        let execution = try SkillExecutionRuntime(selectedFile: selection, options: options,
            backend: worker == nil ? .native : .originalWorker, worker: worker, catalog: BundledSkillCatalog.bundled())
        runtime = execution; plan = execution.plan; nextStepID = execution.plan.steps.first?.id
    }

    func execute(stepID: UUID) {
        guard let runtime, !running else { return }
        do { try validateDownload() }
        catch { return } // Invalidation publishes the fixed cancellation notice.
        let id = runtime.plan.id
        running = true; status = nil
        task = Task {
            do {
                let grant = try await runtime.authorize(stepID: stepID)
                try Task.checkCancellation()
                try validateDownload()
                guard plan?.id == id else { return }
                #if DEBUG
                // Count the actual runtime dispatch, before awaiting it. A missing
                // result alone is not evidence that extraction never started.
                if runtime.plan.steps.first(where: { $0.id == stepID })?.capability == .selectedPDFRead {
                    uiTestAudit?.reads += 1; downloadUIAudit?.reads += 1
                } else { uiTestAudit?.extractionAttempts += 1; downloadUIAudit?.extractions += 1 }
                #endif
                let outcome = try await runtime.execute(grant)
                guard plan?.id == id, !Task.isCancelled else { return }
                try validateDownload()
                guard plan?.id == id, !Task.isCancelled else { return }
                switch outcome {
                case .selectedFileRead(let count, _): status = "已讀取 \(count) 位元組。請核准下一個步驟。"
                case .pdf(let value):
                    result = value; status = "擷取完成。"
                    #if DEBUG
                    uiTestAudit?.results += 1; downloadUIAudit?.results += 1
                    #endif
                }
                completedStepIDs.insert(stepID)
                let next = await runtime.nextStep()?.id
                guard plan?.id == id, !Task.isCancelled else { return }
                try validateDownload()
                nextStepID = next
            } catch {
                guard plan?.id == id else { return }
                status = (error as? SkillExecutionError)?.errorDescription ?? "執行未完成。"
            }
            if plan?.id == id { running = false; task = nil }
        }
    }

    func clear() {
        task?.cancel(); task = nil
        if let runtime { Task { await runtime.cancel() } }
        runtime = nil; plan = nil; nextStepID = nil; completedStepIDs = []; result = nil; status = nil; running = false
    }
}
