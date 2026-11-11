import AssistantPersistence
import SwiftUI

@MainActor struct ChatPDFAttachmentView: View {
    @ObservedObject var session: ChatSession
    @Environment(\.dismiss) private var dismiss
    @State private var choosing = false
    @State private var pages = ""
    @State private var password = ""
    @State private var selectionError: String?
    #if DEBUG
    @State private var fixtureFilename: String?
    #endif
    @FocusState private var editing: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(ChatPDFAttachment.scopeNotice).accessibilityIdentifier("chat.pdf.scope")
                    Text("單一文字型 PDF，最多 10 MiB、200 個選取頁次與 2 MiB 擷取文字；不提供 OCR。")
                    Text(ChatPDFAttachment.retentionNotice).accessibilityIdentifier("chat.pdf.retention")
                }
                #if DEBUG
                if (try? ChatPDFUITestConfiguration.resolve(arguments: ProcessInfo.processInfo.arguments)) != nil {
                    Text("PDF 模型請求事件測試觀測")
                        .accessibilityIdentifier("chat.pdf.requestEvents")
                        .accessibilityValue(String(session.pdfModelRequestEvents))
                }
                if let fixtureFilename {
                    Text(verbatim: fixtureFilename).accessibilityIdentifier("chat.pdf.fixtureFilename")
                }
                #endif
                if let attachment = session.pdfAttachment {
                    ChatPDFReview(attachment: attachment, session: session)
                } else {
                    Section("選取來源") {
                        TextField("頁碼範圍（留空為全部）", text: $pages)
                            .autocorrectionDisabled().focused($editing).accessibilityIdentifier("chat.pdf.pages")
                        SecureField("PDF 密碼（需要時填寫）", text: $password)
                            .focused($editing).accessibilityIdentifier("chat.pdf.password")
                        Button("選取 PDF") { editing = false; choosing = true }
                            .disabled(session.isSubmitting).accessibilityIdentifier("chat.pdf.select")
                        if let selectionError { Text(selectionError).foregroundStyle(.red).accessibilityIdentifier("chat.pdf.selectionError") }
                    }
                }
            }
            .navigationTitle("聊天 PDF 附件")
            .onDisappear { session.pdfAttachment?.stopPreparation() }
            .task {
                #if DEBUG
                do { fixtureFilename = try ChatPDFUITestSupport.seedIfRequested() }
                catch { selectionError = "無法建立隔離測試文件。" }
                #endif
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { editing = false; dismiss() }.accessibilityIdentifier("chat.pdf.done")
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer(); Button("完成輸入") { editing = false }.accessibilityIdentifier("chat.pdf.dismissKeyboard")
                }
            }
            .modifier(PDFImportPresentation(isPresented: $choosing, choice: .original, experiment: nil, onCompletion: { result in
                switch result {
                case .success(let urls):
                    guard urls.count == 1, let url = urls.first else { selectionError = "請選取單一 PDF。"; return }
                    session.selectPDF(url: url, pages: pages, password: password.isEmpty ? nil : password)
                    password = ""
                    selectionError = session.pdfAttachment == nil ? session.chatError : nil
                case .failure:
                    selectionError = "未能取得選取的 PDF；未讀取或傳送檔案。"
                }
            }))
        }
    }
}

@MainActor private struct ChatPDFReview: View {
    @ObservedObject var attachment: ChatPDFAttachment
    @ObservedObject var session: ChatSession
    var body: some View {
        Section("本次附件") {
            Text(verbatim: attachment.plan.filename).accessibilityIdentifier("chat.pdf.filename")
            Text(status).accessibilityIdentifier("chat.pdf.phase")
                .accessibilityValue(String(describing: attachment.phase))
            if let step = attachment.step {
                Text(verbatim: step.disclosure)
                Button(step.capability == .selectedPDFRead ? "核准讀取此 PDF" : "核准在裝置上擷取文字") {
                    attachment.approve(stepID: step.id)
                }
                .disabled(attachment.phase != .awaitingRead && attachment.phase != .awaitingExtraction)
                .accessibilityIdentifier(step.capability == .selectedPDFRead ? "chat.pdf.approveRead" : "chat.pdf.approveExtract")
            }
            if let source = attachment.source {
                Text("已擷取 \(source.pages.count) 頁，\(source.byteCount) 位元組文字。")
                    .accessibilityIdentifier("chat.pdf.extracted")
                if let destination = attachment.destinationLabel {
                    Text(verbatim: destination).accessibilityIdentifier("chat.pdf.destination")
                    Text("已確認目的服務；關閉此頁後輸入問題並傳送。")
                } else {
                    if let destination = session.archiveDestination {
                        Text(verbatim: destination.baseURL + "\n模型：" + destination.model)
                            .accessibilityIdentifier("chat.pdf.proposedDestination")
                    }
                    Text("問題、檔名、讀取片段與已啟用的個人檔案、相關記憶及適用技能會傳給此模型服務。保存資料只作背景，不是文件證據或操作授權。")
                        .accessibilityIdentifier("chat.pdf.transmissionNotice")
                    Button("確認傳送問題、必要文件文字與已啟用參考資料") { session.confirmPDFDestination() }
                        .disabled(!session.hasStoredKey || session.isSubmitting)
                        .accessibilityIdentifier("chat.pdf.confirmDestination")
                }
            }
            if let error = attachment.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("chat.pdf.error") }
            Button("移除附件", role: .destructive) { session.removePDF() }.accessibilityIdentifier("chat.pdf.remove")
        }
    }
    private var status: String {
        switch attachment.phase {
        case .awaitingRead: return "尚未讀取；等待你核准。"
        case .reading: return "正在讀取已核准的 PDF。"
        case .awaitingExtraction: return "已讀取；尚未擷取文字，等待另一次核准。"
        case .extracting: return "正在裝置上擷取文字。"
        case .ready: return "文字已擷取；尚未傳送問題。"
        case .failed: return "未完成擷取；請移除後重新選取。"
        case .removed: return "附件已移除。"
        }
    }
}

/// Restored evidence can be inspected, never executed or implicitly resent.
@MainActor struct ArchivedPDFEvidenceView: View {
    let evidence: ArchivedPDFAnswer
    let identifier: String
    @State private var isExpanded = false
    @State private var arePagesExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button { isExpanded.toggle() } label: {
                HStack(spacing: 8) {
                    Text(verbatim: "PDF：" + evidence.filename)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
            .accessibilityValue(isExpanded ? "已展開" : "已收合")
            .accessibilityHint("顯示或收合已保存的 PDF 引文與擷取文字")

            Text("已保存擷取文字與引文；再次查詢原 PDF 請重新選取。")
                .font(.caption).accessibilityIdentifier(identifier + ".reselectNotice")

            if isExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ChatPDFAttachment.retentionNotice).font(.caption)
                    Text("引文已核對實際讀取範圍；不表示全文已讀或解讀已證實。")
                    ForEach(Array(evidence.citations.enumerated()), id: \.offset) { index, citation in
                        Text("第 \(evidence.pages[citation.pageIndex - 1].number) 頁（選取序號 \(citation.pageIndex)）")
                        Text(verbatim: citation.quote).textSelection(.enabled)
                            .accessibilityIdentifier(identifier + ".citation.\(index)")
                    }
                    Button { arePagesExpanded.toggle() } label: {
                        HStack(spacing: 8) {
                            Text("已保存的擷取文字")
                            Spacer(minLength: 8)
                            Image(systemName: arePagesExpanded ? "chevron.down" : "chevron.right")
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(identifier + ".pages")
                    .accessibilityValue(arePagesExpanded ? "已展開" : "已收合")
                    .accessibilityHint("顯示或收合已保存的 PDF 擷取文字")
                    if arePagesExpanded {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(evidence.pages.enumerated()), id: \.offset) { index, page in
                                Text("第 \(page.number) 頁（選取序號 \(index + 1)）")
                                Text(verbatim: page.text).textSelection(.enabled)
                                    .accessibilityIdentifier(identifier + ".page.\(index)")
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
                .padding(.leading, 16)
            }
        }
    }
}
