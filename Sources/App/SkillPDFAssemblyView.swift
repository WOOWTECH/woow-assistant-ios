import AssistantSkills
import SwiftUI
import UniformTypeIdentifiers
#if DEBUG && os(iOS)
import Darwin
#endif

/// A bounded immutable PDF snapshot. The native exporter owns the destination
/// dialog and any explicit user confirmation to replace an existing file.
struct SkillPDFAssemblyDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }
    let data: Data
    init(data: Data) throws {
        guard data.starts(with: Data("%PDF-".utf8)), data.count <= SkillPDFAssemblyLimits.outputBytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }
    init(configuration: ReadConfiguration) throws {
        guard configuration.file.isRegularFile, let bytes = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try self.init(data: bytes)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        snapshot()
    }
    func snapshot() -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

#if os(iOS)
@MainActor
struct SkillPDFAssemblyView: View {
    @StateObject private var model = SkillPDFAssemblySession()
    @State private var choosingFile = false
    @State private var pickerRequest: SkillPDFAssemblySession.PickerRequest?
    @State private var importChoice: PDFImportChoice = .original
    @State private var exporting = false
    @State private var exportDocument: SkillPDFAssemblyDocument?
    @State private var exportPlanID: UUID?
    @State private var exportStatus: String?
    @FocusState private var orderFocused: Bool
    #if DEBUG
    @State private var pickerObservation = "unobserved"
    @State private var importerCallbacks = 0
    @State private var importerOutcome = "none"
    @State private var totalImporterCallbacks = 0
    #endif

    private var pickerExperiment: PDFNativePickerExperiment.Configuration? {
        #if DEBUG
        return PDFNativePickerExperiment.assemblyConfiguration(arguments: ProcessInfo.processInfo.arguments,
                                                               fixtureNamespace: model.uiTestFixture?.namespace ?? model.uiTestPair?.namespace)
        #else
        return nil
        #endif
    }

    var body: some View {
        let request = pickerRequest
        Form {
            Section("擷取頁面、重排與合併") {
                Text("逐份選取或加入 PDF，最多三份，再依指定順序產生新文件。每個檔案最多 10 MiB，合計最多 200 頁；輸出最多 20 MiB。處理過程不改動原檔，也不會上傳。")
                Text("目前支援一般靜態 PDF；不支援加密、表單、註記、附件、書籤、標記結構、圖層與互動文件，也不會辨識掃描文字。")
                    .font(.caption)
                if model.sources.isEmpty {
                    Button("選取 PDF 文件") { presentPicker(.original) }
                        .accessibilityIdentifier("pdfAssembly.select")
                    Text("匯入副本時，系統會在你選檔時建立副本；App 仍會先請你核准讀取，再另行核准產生新 PDF。")
                        .font(.caption).accessibilityIdentifier("pdfAssembly.importCopy.notice")
                    Button("匯入 PDF 副本") { presentPicker(.importCopy) }
                        .accessibilityIdentifier("pdfAssembly.importCopy")
                }
                #if DEBUG
                if let fixture = model.uiTestFixture {
                    Text("測試文件已建立：\(fixture.filename)")
                        .font(.caption).accessibilityIdentifier("pdfAssembly.uitest.fixture")
                        .accessibilityValue(pickerObservation + " callbacks=\(importerCallbacks)")
                }
                if let pair = model.uiTestPair {
                    Text("測試雙檔已建立")
                        .font(.caption).accessibilityIdentifier("pdfAssembly.uitest.pair")
                        .accessibilityValue("callbacks=\(totalImporterCallbacks) sources=\(model.sources.count)" +
                            (totalImporterCallbacks == 0 && model.sources.isEmpty ? " " + pair.creationProof.accessibilityValue : ""))
                }
                #endif
            }
            if !model.sources.isEmpty {
                Section("來源文件") {
                    ForEach(Array(model.sources.enumerated()), id: \.element.id) { index, source in
                        VStack(alignment: .leading, spacing: 6) {
                            Text("來源 \(index + 1)：\(source.filename)")
                                .accessibilityIdentifier("pdfAssembly.source.\(index + 1)")
                                #if DEBUG
                                .accessibilityValue(model.uiTestPair == nil ? "" :
                                    pickerObservation + " callbacks=\(importerCallbacks) outcome=\(importerOutcome) sources=\(model.sources.count)")
                                #endif
                            if let receipt = model.receipts.first(where: { $0.id == source.id }) {
                                Text("已讀取 \(receipt.pageCount) 頁，\(receipt.byteCount) 位元組")
                                    .accessibilityIdentifier("pdfAssembly.receipt.\(index + 1)")
                                    #if DEBUG
                                    .accessibilityValue(model.uiTestPair == nil ? "" :
                                        "sources=\(model.sources.count) reads=\(model.receipts.count)")
                                    #endif
                            } else {
                                Text(source.disclosure).font(.caption)
                                Button("核准讀取此文件") { orderFocused = false; model.read(source.id) }
                                    .disabled(model.running)
                                    .accessibilityIdentifier("pdfAssembly.read.\(index + 1)")
                            }
                        }
                    }
                    Text("加入文件會保留已選來源，但清除本次讀取核准、頁序及尚未儲存的結果；請重新核准各文件。取消選檔則保留原狀。")
                        .font(.caption).accessibilityIdentifier("pdfAssembly.add.notice")
                    Button("加入 PDF 文件") { presentPicker(.original, adding: true) }
                        .disabled(!model.canAdd || choosingFile || exporting)
                        .accessibilityIdentifier("pdfAssembly.add")
                    Button("加入 PDF 副本") { presentPicker(.importCopy, adding: true) }
                        .disabled(!model.canAdd || choosingFile || exporting)
                        .accessibilityIdentifier("pdfAssembly.addCopy")
                    Text("最多三份來源。匯入副本時，系統會在你選檔時建立副本，仍需另行核准讀取。")
                        .font(.caption)
                }
            }
            if model.receipts.count == model.sources.count && !model.sources.isEmpty && model.result == nil {
                Section("新文件頁序") {
                    Text("格式為「來源編號:頁碼」。例如 1:3,1:1-2,2:1，表示來源 1 的第 3、1、2 頁，再接來源 2 的第 1 頁；頁面可以重複。")
                        .font(.caption)
                    TextField("例如 1:3,1:1-2,2:1", text: $model.orderText, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($orderFocused).disabled(model.running)
                        .accessibilityIdentifier("pdfAssembly.order")
                        .onChange(of: model.orderText) { _, _ in model.invalidatePlan() }
                    Button("檢視頁序") { orderFocused = false; model.prepare() }
                        .disabled(!model.canPrepare).accessibilityIdentifier("pdfAssembly.prepare")
                }
            }
            if let plan = model.plan, model.result == nil {
                Section("核對新文件") {
                    Text("共 \(plan.order.count) 頁").accessibilityIdentifier("pdfAssembly.plan.count")
                    ForEach(Array(plan.order.enumerated()), id: \.offset) { index, page in
                        let number = (model.sources.firstIndex(where: { $0.id == page.sourceID }) ?? -1) + 1
                        Text("第 \(index + 1) 頁 ← 來源 \(number) 第 \(page.number) 頁")
                            .accessibilityIdentifier("pdfAssembly.plan.page.\(index + 1)")
                    }
                    Text("將依以上頁序產生新的 PDF。請在儲存前再次核對內容。")
                    Button("核准並產生新 PDF") { model.assemble() }
                        .disabled(model.running).accessibilityIdentifier("pdfAssembly.assemble")
                }
            }
            if let result = model.result {
                Section("新 PDF") {
                    Text("已產生 \(result.pageCount) 頁，\(result.data.count) 位元組")
                        .accessibilityIdentifier("pdfAssembly.result")
                        #if DEBUG
                        .accessibilityValue(model.uiTestPair == nil ? "" : model.uiTestPairOutput)
                        #endif
                    Text(result.notice).font(.caption)
                    Button("儲存 PDF") { beginExport(result) }
                        .disabled(exporting).accessibilityIdentifier("pdfAssembly.export")
                    Text("請選擇新檔名及儲存位置；若選擇取代既有檔案，系統會請你確認。")
                        .font(.caption)
                    if let exportStatus { Text(exportStatus).accessibilityIdentifier("pdfAssembly.export.status") }
                }
            }
            if model.running { ProgressView("正在處理文件…").accessibilityIdentifier("pdfAssembly.running") }
            if let status = model.status { Text(status).accessibilityIdentifier("pdfAssembly.status") }
            if !model.sources.isEmpty {
                Button(model.running ? "取消處理並清除本次選取" : "清除本次選取", role: .destructive) {
                    resetExport(); model.clear()
                }.accessibilityIdentifier("pdfAssembly.clear")
            }
        }
        .navigationTitle("PDF 頁面處理")
        .accessibilityIdentifier("pdfAssembly.form")
        .onAppear {
            #if DEBUG
            model.seedUITestIfRequested()
            #endif
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起鍵盤") { orderFocused = false }.accessibilityIdentifier("pdfAssembly.keyboardDone")
            }
        }
        .modifier(PDFImportPresentation(isPresented: $choosingFile, choice: importChoice, experiment: pickerExperiment,
                                       allowsMultipleSelection: false,
                                       onCompletion: { receiveSelection($0, request: request) },
                                       onCancellation: {
            guard let request else { return }
            model.cancelPicker(request)
            if pickerRequest == request { pickerRequest = nil }
        },
                                       onObservation: { value in
            #if DEBUG
            pickerObservation = value
            #endif
        }))
        .onChange(of: choosingFile) { _, presented in
            #if DEBUG
            if presented { importerCallbacks = 0; pickerObservation = "unobserved"; importerOutcome = "none" }
            recordPickerEvent("bindingChanged presented=\(presented)")
            #endif
        }
        .fileExporter(isPresented: $exporting, document: exportDocument, contentTypes: [.pdf],
                      defaultFilename: model.result?.suggestedFilename ?? "組裝文件.pdf", onCompletion: { outcome in
            switch outcome {
            case .success: finishExport("PDF 已儲存至所選位置。")
            case .failure: finishExport("未能儲存 PDF，結果仍保留；請重新選擇位置。")
            }
        }, onCancellation: { finishExport("已取消儲存，新 PDF 仍保留。") })
        .onDisappear {
            #if DEBUG
            recordPickerEvent("viewDisappeared choosingFile=\(choosingFile) exporting=\(exporting)")
            #endif
            if !choosingFile && !exporting { resetExport(); model.clear() }
        }
    }

    private func presentPicker(_ choice: PDFImportChoice, adding: Bool = false) {
        guard !choosingFile, !exporting, let request = model.beginPicker(adding: adding) else { return }
        pickerRequest = request
        importChoice = choice
        choosingFile = true
    }

    private func receiveSelection(_ outcome: Result<[URL], Error>, request: SkillPDFAssemblySession.PickerRequest?) {
        guard let request else { return }
        #if DEBUG
        importerCallbacks = min(importerCallbacks + 1, 16)
        totalImporterCallbacks = min(totalImporterCallbacks + 1, 16)
        let category: String
        switch outcome {
        case .success(let urls): category = urls.isEmpty ? "empty" : urls.count == 1 ? "one" : "multiple"
        case .failure: category = "failure"
        }
        importerOutcome = category
        recordPickerEvent("completion outcome=\(category)")
        #endif
        switch outcome {
        case .success(let urls):
            if model.finishPicker(request, urls: urls) { resetExport() }
        case .failure: model.pickerFailed(request)
        }
        if pickerRequest == request { pickerRequest = nil }
    }

    #if DEBUG
    private func recordPickerEvent(_ event: String) {
        guard let configuration = pickerExperiment, importerCallbacks < 16 else { return }
        let source = importChoice == .importCopy ? "user-copy" : configuration.source
        print("SKILL_PDF_ASSEMBLY_PICKER namespace=\(configuration.namespace.uuidString) source=\(source) event=\(event) callbacks=\(importerCallbacks) sampledAt=\(Date().timeIntervalSince1970)")
        fflush(stdout)
    }
    #endif

    private func beginExport(_ result: SkillPDFAssemblyResult) {
        do {
            exportDocument = try SkillPDFAssemblyDocument(data: result.data)
            exportPlanID = result.plan.id; exportStatus = nil; exporting = true
        } catch { exportStatus = "無法準備輸出文件，請重新處理來源文件。" }
    }
    private func finishExport(_ message: String) {
        if exportPlanID == model.result?.plan.id { exportStatus = message }
        #if DEBUG
        model.observeUITestPairOutput()
        #endif
        exportDocument = nil; exportPlanID = nil
    }
    private func resetExport() {
        exporting = false; exportDocument = nil; exportPlanID = nil; exportStatus = nil
    }
}
#endif
