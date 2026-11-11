import AssistantPersistence
import SwiftUI

@MainActor struct ConversationArchiveView: View {
    @ObservedObject var store: ConversationArchiveStore
    @ObservedObject var session: ChatSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("僅保存已完成的問答。未完成任務、未送出的草稿與工具操作不會還原；開啟歷史不會自動傳送。")
                        .font(.footnote).accessibilityIdentifier("archive.boundary")
                    if let error = store.error {
                        Text(error).foregroundStyle(.red).accessibilityIdentifier("archive.error")
                        Button("重新讀取") { store.reload() }.accessibilityIdentifier("archive.reload")
                    }
                }
                Section("已保存的對話（\(store.conversations.count)）") {
                    if store.conversations.isEmpty {
                        Text("尚無保存的對話").accessibilityIdentifier("archive.empty")
                    }
                    ForEach(store.conversations) { record in
                        NavigationLink {
                            ConversationArchiveDetail(store: store, session: session, id: record.id) {
                                if session.openConversation(id: record.id) { dismiss() }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(record.title).lineLimit(2)
                                Text("\(record.turns.count) 輪 · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("archive.row." + record.id.uuidString)
                        .accessibilityLabel(record.title)
                    }
                }
            }
            .navigationTitle("歷史對話")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }.accessibilityIdentifier("archive.close")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("新對話") { session.newConversation(); dismiss() }
                        .disabled(session.isSubmitting).accessibilityIdentifier("archive.new")
                }
            }
        }
    }
}

@MainActor private struct ConversationArchiveDetail: View {
    @ObservedObject var store: ConversationArchiveStore
    @ObservedObject var session: ChatSession
    let id: UUID
    let open: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmsDelete = false

    var body: some View {
        Group {
            if let record = store.state.conversations.first(where: { $0.id == id }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("保存時的模型：\(record.destination.model)")
                        Text(record.destination.baseURL).font(.caption).textSelection(.enabled)
                        if !session.canOpenConversation(record) {
                            Text("模型服務、模型或金鑰身分與目前設定不同；僅供檢視，不會帶入目前服務。")
                                .accessibilityIdentifier("archive.destinationMismatch")
                        }
                        ForEach(Array(record.turns.enumerated()), id: \.element.userID) { index, turn in
                            Text("你").font(.caption.bold())
                            Text(turn.userText).textSelection(.enabled)
                                .accessibilityIdentifier("archive.turn.\(index).user")
                            Text("助理").font(.caption.bold())
                            Text(turn.assistantText).textSelection(.enabled)
                                .accessibilityIdentifier("archive.turn.\(index).assistant")
                            if let pdf = turn.pdf {
                                ArchivedPDFEvidenceView(evidence: pdf, identifier: "archive.turn.\(index).pdf")
                            }
                        }
                        if let error = store.error { Text(error).foregroundStyle(.red).accessibilityIdentifier("archive.error") }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding()
                }
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Button("刪除對話", role: .destructive) { confirmsDelete = true }
                            .accessibilityIdentifier("archive.delete")
                        Spacer()
                        Button("開啟此對話", action: open)
                            .disabled(!session.canOpenConversation(record) || session.isSubmitting)
                            .accessibilityIdentifier("archive.open")
                    }.padding().background(.bar)
                }
            } else { Text("此對話已刪除").accessibilityIdentifier("archive.deleted") }
        }
        .navigationTitle("保存的問答")
        .alert("刪除此對話？", isPresented: $confirmsDelete) {
            Button("取消", role: .cancel) {}
            Button("刪除", role: .destructive) {
                if session.deleteConversation(id: id) { dismiss() }
            }.accessibilityIdentifier("archive.delete.confirm")
        } message: { Text("會移除已保存的問答、附件擷取文字與引文；已確認的記憶與個人檔案保留。") }
    }
}
