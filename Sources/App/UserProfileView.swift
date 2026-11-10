import AssistantMemory
import SwiftUI

@MainActor
struct UserProfileView: View {
    @ObservedObject var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    @State private var editor: ProfileEditorDestination?
    @State private var historyExpanded = false

    var body: some View {
        List {
            Section {
                Text("個人檔案記錄你的背景與偏好，最多 20 條。修改會在下一次任務使用，當次要求優先。")
                    .accessibilityIdentifier("profile.scope")
                Text("現用 \(store.profile.snapshot().entries.count)／20 條")
                    .accessibilityIdentifier("profile.count")
                if !store.memory.preferences.useMemory {
                    Text("「使用記憶」已關閉；個人檔案仍會保留，但不會加入對話。")
                        .accessibilityIdentifier("profile.disabled")
                }
            }
            if !store.available {
                Section {
                    Text("資料目前無法讀取；原檔保留且不會被覆寫。")
                        .accessibilityIdentifier("profile.unavailable")
                    Button("重新讀取") { store.reload() }
                        .accessibilityIdentifier("profile.reload")
                }
            }
            if let error = store.error {
                Text(verbatim: error).foregroundStyle(.red)
                    .accessibilityIdentifier("profile.error")
            }
            if store.available {
                Section("現用個人檔案") {
                    if store.profile.snapshot().entries.isEmpty {
                        Text("尚未儲存個人檔案。")
                            .accessibilityIdentifier("profile.empty")
                    }
                    ForEach(store.profile.snapshot().entries) { entry in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(verbatim: entry.text)
                                .accessibilityIdentifier("profile.item.\(entry.id.uuidString)")
                            HStack(spacing: 24) {
                                Button("編輯") { store.dismissNotice(); editor = .init(entry: entry) }
                                    .accessibilityIdentifier("profile.edit.\(entry.id.uuidString)")
                                Button("刪除", role: .destructive) {
                                    store.deleteProfileReference(segment: entry.text)
                                }
                                .accessibilityIdentifier("profile.delete.\(entry.id.uuidString)")
                            }
                            .buttonStyle(.borderless)
                            .frame(minHeight: 44)
                        }
                    }
                    Button("新增個人檔案") { store.dismissNotice(); editor = .init(entry: nil) }
                        .accessibilityIdentifier("profile.add")
                }
                if let notice = store.notice {
                    Text(verbatim: notice).accessibilityIdentifier("profile.notice")
                }
                let history = store.profile.entries.filter { $0.status == .superseded }
                if !history.isEmpty {
                    Section {
                        // A DisclosureGroup identifier propagates to its rows
                        // on iOS 18/26, replacing their individual AX identifiers.
                        // Keep the disclosure control and history rows siblings.
                        Button {
                            historyExpanded.toggle()
                        } label: {
                            HStack {
                                Text("已替換或刪除的紀錄（\(history.count)）")
                                Spacer()
                                Image(systemName: historyExpanded ? "chevron.down" : "chevron.right")
                            }
                        }
                        .accessibilityIdentifier("profile.history")
                        .accessibilityValue(historyExpanded ? "已展開" : "已收合")
                        if historyExpanded {
                            ForEach(history.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: entry.text)
                                        .accessibilityIdentifier("profile.history.item.\(entry.id.uuidString)")
                                    Text("已替換或刪除 · \(entry.supersededAt!.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("歷史紀錄不會加入對話；清除所有記憶與 Skills 也會清除個人檔案及其歷史。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("個人檔案")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("profile.list")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("返回") { dismiss() }.accessibilityIdentifier("profile.close")
            }
        }
        .sheet(item: $editor) { destination in
            NavigationStack { UserProfileEditor(store: store, entry: destination.entry) }
        }
    }
}

private struct ProfileEditorDestination: Identifiable {
    let id = UUID()
    let entry: UserProfileEntry?
}

@MainActor
private struct UserProfileEditor: View {
    @ObservedObject var store: LearningStore
    let entry: UserProfileEntry?
    @State private var baseRevision: UUID
    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.dismiss) private var dismiss

    init(store: LearningStore, entry: UserProfileEntry?) {
        self.store = store; self.entry = entry
        _baseRevision = State(initialValue: store.profile.revision)
        _text = State(initialValue: entry?.text ?? "")
    }

    var body: some View {
        Form {
            Section("一句話描述背景或偏好") {
                TextEditor(text: $text)
                    .frame(minHeight: 140)
                    .focused($focused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("個人檔案內容")
                    .accessibilityIdentifier("profile.editor.text")
                Text("\(text.utf16.count)／160 字元；部分符號會占多個字元。")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("profile.editor.count")
                Text("請使用單句，不要包含換行、密碼、驗證碼或金鑰。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let error = store.error {
                Text(verbatim: error).foregroundStyle(.red)
                    .accessibilityIdentifier("profile.editor.error")
            }
        }
        .navigationTitle(entry == nil ? "新增個人檔案" : "編輯個人檔案")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("profile.editor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") {
                    let saved: Bool
                    if let entry {
                        saved = store.replaceProfileReference(segment: entry.text, replacement: text,
                                                              expectedRevision: baseRevision)
                    } else {
                        saved = store.mutateProfile { state in
                            guard state.revision == baseRevision else { throw MemoryError.stalePlan }
                            try state.add(text: text)
                        }
                    }
                    if saved { dismiss() }
                }
                .disabled(!store.available)
                .accessibilityIdentifier("profile.editor.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button("清空") { text = "" }.accessibilityIdentifier("profile.editor.clear")
                Spacer()
                Button("收起鍵盤") { focused = false }.accessibilityIdentifier("profile.editor.done")
            }
        }
    }
}
