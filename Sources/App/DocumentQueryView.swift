import AssistantSkills
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor struct DocumentQueryView: View {
    let modelAccess: () throws -> ModelAccess
    let modelChanges: AnyPublisher<Void, Never>
    @StateObject private var session: DocumentQuerySession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var questionFocused: Bool
    @State private var exporting = false
    @State private var exportDocument: SkillExecutionTextDocument?
    @State private var exportDeliveryID: UUID?
    @State private var exportStatus: String?

    init(source: DocumentTextSnapshot, learning: LearningStore, modelAccess: @escaping () throws -> ModelAccess,
         modelChanges: AnyPublisher<Void, Never>) {
        self.modelAccess = modelAccess; self.modelChanges = modelChanges
        _session = StateObject(wrappedValue: DocumentQuerySession(source: source, learning: learning))
    }

    var body: some View {
        Form {
            Section("本次已擷取的 PDF") {
                Text(verbatim: session.source.filename).accessibilityIdentifier("documentQuery.filename")
                Text("選取 \(session.source.pages.count) 頁 · \(session.source.byteCount) 位元組文字")
                Text("文件引文只來自這次擷取的文字；原 PDF 不會重新讀取。")
                    .font(.caption)
                DisclosureGroup("來源資訊") {
                    Text(verbatim: session.source.engine)
                    Text("PDF SHA-256：" + session.source.inputSHA256).font(.caption).textSelection(.enabled)
                    Text("擷取快照 SHA-256：" + session.source.sha256).font(.caption).textSelection(.enabled)
                }
            }
            Section("想查詢什麼") {
                TextEditor(text: Binding(get: { session.question }, set: { session.setQuestion($0) }))
                    .frame(minHeight: 100).focused($questionFocused)
                    .disabled(session.running || exporting)
                    .accessibilityIdentifier("documentQuery.question")
                Button("確認目前設定的目的服務") { session.confirmDestination(modelAccess: modelAccess) }
                    .disabled(session.running || exporting)
                    .accessibilityIdentifier("documentQuery.confirmDestination")
                if let destination = session.destination {
                    Text(verbatim: destination).accessibilityIdentifier("documentQuery.destination")
                }
                Text("開始後，問題、檔名、讀取片段與已啟用的個人檔案、相關記憶及適用技能會傳給上述服務。保存資料只作背景，不是文件證據或操作授權。回答不會自動儲存。")
                    .font(.caption)
                Button("傳送問題並查詢這份 PDF") {
                    questionFocused = false; session.start(modelAccess: modelAccess)
                }
                .disabled(session.running || exporting || session.destination == nil
                          || session.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("documentQuery.start")
            }
            Section {
                statusLabel
                if session.running { ProgressView("查詢中") }
                if let error = session.error {
                    Text(verbatim: error).foregroundStyle(.red).accessibilityIdentifier("documentQuery.error")
                }
                if let refusal = session.refusal {
                    Text(verbatim: refusal).accessibilityIdentifier("documentQuery.refusal")
                }
            }
            if let result = session.result {
                Section("回答") {
                    Text(verbatim: result.question).font(.caption).accessibilityIdentifier("documentQuery.answeredQuestion")
                    Text(verbatim: result.answer).textSelection(.enabled).accessibilityIdentifier("documentQuery.answer")
                    Text("引文已核對本次實際讀過的範圍；這不表示全文已讀，或回答中的解讀均正確。")
                        .font(.caption)
                    ForEach(Array(result.citations.enumerated()), id: \.offset) { index, citation in
                        VStack(alignment: .leading, spacing: 5) {
                            Text("原 PDF 第 \(citation.pageNumber) 頁 · 選取序號 \(citation.pageIndex)")
                                .font(.caption).accessibilityIdentifier("documentQuery.citation.page.\(index)")
                            Text(verbatim: citation.quote).textSelection(.enabled)
                                .accessibilityIdentifier("documentQuery.citation.quote.\(index)")
                        }
                    }
                    Button("匯出回答與引文") { beginExport() }
                        .disabled(exporting || session.running)
                        .accessibilityIdentifier("documentQuery.export")
                    if let exportStatus {
                        Text(exportStatus).accessibilityIdentifier("documentQuery.exportStatus")
                    }
                }
            }
        }
        .accessibilityIdentifier("documentQuery.form")
        .navigationTitle("查詢 PDF")
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { session.cancel(notice: false); dismiss() }
                    .accessibilityIdentifier("documentQuery.close")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("完成輸入") { questionFocused = false }
                    .accessibilityIdentifier("documentQuery.keyboardDone")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if session.running {
                Button("停止查詢") { session.cancel() }
                    .buttonStyle(.borderedProminent).padding()
                    .frame(maxWidth: .infinity).background(.regularMaterial)
                    .accessibilityIdentifier("documentQuery.cancel")
            }
        }
        .fileExporter(isPresented: $exporting, document: exportDocument,
                      contentTypes: [.utf8PlainText], defaultFilename: "PDF-查詢回答",
                      onCompletion: { result in
            switch result {
            case .success: finishExport("回答與引文已儲存至所選位置。")
            case .failure: finishExport("回答未能儲存，請重新選擇位置再試一次。")
            }
        }, onCancellation: { finishExport("已取消匯出，回答與引文仍保留。") })
        .onReceive(modelChanges) { session.hostChanged() }
        .onChange(of: session.deliveryID) { _, _ in resetExport() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active && session.running { session.cancel() }
        }
        .onDisappear { session.cancel(notice: false); resetExport() }
    }

    private var statusLabel: some View {
        #if DEBUG
        Text(session.status).accessibilityIdentifier("documentQuery.status")
            .accessibilityValue(session.audit.evidence)
        #else
        Text(session.status).accessibilityIdentifier("documentQuery.status")
        #endif
    }

    private func beginExport() {
        guard let result = session.result, let id = session.deliveryID, !session.running else { return }
        do {
            exportDocument = try SkillExecutionTextDocument(text: result.textForExport)
            exportDeliveryID = id; exportStatus = nil; exporting = true
        } catch { exportStatus = "回答無法建立文字檔，原回答仍保留。" }
    }

    private func finishExport(_ message: String) {
        guard let exportDeliveryID, exportDeliveryID == session.deliveryID else { return }
        exportStatus = message; self.exportDeliveryID = nil; exportDocument = nil; exporting = false
    }

    private func resetExport() {
        exportDeliveryID = nil; exportDocument = nil; exporting = false; exportStatus = nil
    }
}
