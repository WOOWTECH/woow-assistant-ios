import AssistantMemory
import AssistantSkills
import Combine
import SwiftUI

@MainActor
struct MemoryDataView: View {
    @ObservedObject var store: LearningStore
    @ObservedObject var browser: BrowserSession
    let modelAccess: () throws -> ModelAccess
    let modelChanges: AnyPublisher<Void, Never>
    let onOpenBrowser: () -> Void
    @State private var segment: LearningSegment = .memories
    @State private var query = ""
    @State private var sheet: LearningSheet?
    @FocusState private var searchFocused: Bool

    // Approval stores guidance; it does not start a task or grant capabilities.
    // Browser references are usable only in the explicitly started research mode.
    private let toolNames = BrowserSession.toolNames

    private var pendingCount: Int {
        store.memory.memories.filter { $0.status == .pending }.count + store.skills.pending.count
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("記憶與資料")
                    .font(.title2.bold())
                    .accessibilityIdentifier("memory.status")
                HStack(spacing: 8) {
                    ForEach(LearningSegment.allCases) { item in
                        Button {
                            segment = item
                        } label: {
                            Text(item == .pending && pendingCount > 0 ? "待確認（\(pendingCount)）" : item.title)
                                .font(.subheadline)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .tint(segment == item ? .accentColor : .secondary)
                        .accessibilityValue(segment == item ? "已選取" : "未選取")
                        .accessibilityAddTraits(segment == item ? .isSelected : [])
                        .accessibilityIdentifier("memory.segment.\(item.rawValue)")
                    }
                }
                if segment != .skills {
                    TextField("搜尋記憶或關鍵字", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .onSubmit { searchFocused = false }
                        .accessibilityIdentifier("memory.search")
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            List {
                if !store.available {
                    Section {
                        Text("記憶資料目前無法讀取；不會以空白資料覆寫原檔。")
                            .accessibilityIdentifier("memory.unavailable")
                        Button("重新讀取") { store.reload() }
                            .accessibilityIdentifier("memory.reload")
                    }
                }
                if let error = store.error {
                    Section {
                        Text(verbatim: error).foregroundStyle(.red)
                            .accessibilityIdentifier("memory.error")
                        Button("關閉提示") { store.dismissNotice() }
                    }
                }
                if let notice = store.notice {
                    Section {
                        Text(verbatim: notice).accessibilityIdentifier("memory.notice")
                        Button("關閉提示") { store.dismissNotice() }
                    }
                }
                if segment == .memories {
                    Section {
                        NavigationLink {
                            UserProfileView(store: store)
                        } label: { Text("個人檔案") }
                            .disabled(!store.available)
                            .accessibilityIdentifier("memory.profile.open")
                    }
                }
                if segment == .skills {
                    Section {
                        Button("Mika 內建技能目錄（6）") { sheet = .catalog }
                            .accessibilityIdentifier("skills.catalog.open")
                        NavigationLink { SkillExecutionView(learning: store, modelAccess: modelAccess, modelChanges: modelChanges) } label: { Text("選取 PDF 並擷取文字") }
                            .accessibilityIdentifier("skills.documents.execute")
                        NavigationLink {
                            SkillAgentView(store: store, modelAccess: modelAccess)
                        } label: { Text("請模型協助編寫技能") }
                            .disabled(!store.available)
                            .accessibilityIdentifier("skills.agent.open")
                        NavigationLink {
                            TranscriptView(learning: store, modelAccess: modelAccess, modelChanges: modelChanges)
                        } label: { Text("整理文字稿與字幕") }
                            .accessibilityIdentifier("skills.transcript.open")
                        Text("閱讀完整原文與授權、匯入 iOS 文字技能，或選取 PDF 執行文件處理；每個執行步驟仍需核准。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if store.available {
                    switch segment {
                    case .memories: memorySections
                    case .skills: skillsSections
                    case .pending: pendingSections
                    }
                }
                preferencesSection
                Section("其他資料") {
                    Button("網站知識與路線（\(store.websites.lessons.count)／\(store.routes.routes.count)）") { sheet = .websites }
                        .accessibilityIdentifier("memory.websites")
                    Text("網站登入資料由 WebKit 儲存，可在瀏覽器的網站頁面查看與清除。")
                        .accessibilityIdentifier("memory.browserPending")
                    Button("到瀏覽器管理網站資料") { onOpenBrowser() }
                        .accessibilityIdentifier("memory.manageWebsites")
                    Text("網頁路線以實際讀取與完成判定建立；目前只支援公開網站的導覽與核對。")
                        .accessibilityIdentifier("memory.routesPending")
                }
                Section {
                    Button("清除所有記憶與 Skills", role: .destructive) {
                        store.dismissNotice()
                        sheet = .clear
                    }
                    .accessibilityIdentifier("memory.clear")
                    Text("需要兩次確認，並包含個人檔案。模型設定、模型金鑰與 MCP 端點不會被清除。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .id(segment)
        }
        .sheet(item: $sheet) { destination in
            NavigationStack {
                switch destination {
                case .memory(let item):
                    MemoryEditor(store: store, item: item)
                case .importSkill:
                    SkillEditor(store: store, draft: nil, toolNames: toolNames) { segment = .pending }
                case .editSkill(let draft):
                    SkillEditor(store: store, draft: draft, toolNames: toolNames) { segment = .skills }
                case .fullText(let title, let markdown):
                    SkillTextView(title: title, markdown: markdown)
                case .clear:
                    LearningClearView(store: store)
                case .websites:
                    WebsiteDataView(store: store, browser: browser, modelAccess: modelAccess, onOpenBrowser: onOpenBrowser)
                case .catalog:
                    SkillCatalogView(store: store, modelAccess: modelAccess, modelChanges: modelChanges)
                }
            }
        }
    }

    @ViewBuilder private var memorySections: some View {
        let items = matchingMemories(status: .active)
        if items.isEmpty {
            Section {
                Text(query.isEmpty ? "尚未儲存記憶。" : "找不到符合的記憶。")
                    .accessibilityIdentifier("memory.empty")
            }
        }
        ForEach(memoryKinds, id: \.rawValue) { kind in
            let rows = items.filter { $0.kind == kind }
            if !rows.isEmpty {
                Section(memoryKindTitle(kind)) {
                    ForEach(rows) { item in memoryRow(item, pending: false) }
                }
            }
        }
        Section {
            Button("手動新增記憶") {
                store.dismissNotice()
                sheet = .memory(nil)
            }
            .accessibilityIdentifier("memory.add")
        }
    }

    @ViewBuilder private var pendingSections: some View {
        let items = matchingMemories(status: .pending)
        if items.isEmpty && store.skills.pending.isEmpty {
            Section {
                Text(query.isEmpty ? "沒有待確認的內容。" : "找不到符合的待確認記憶。")
                    .accessibilityIdentifier("memory.pending.empty")
            }
        }
        if !items.isEmpty {
            Section("待確認的做法") {
                ForEach(items) { item in memoryRow(item, pending: true) }
            }
        }
        if !store.skills.pending.isEmpty {
            Section("Skills 草稿（搜尋僅篩選記憶）") {
                ForEach(store.skills.pending) { draft in draftRow(draft) }
            }
        }
    }

    private func memoryRow(_ item: MemoryItem, pending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: item.content)
                .accessibilityIdentifier("memory.item.\(item.id.uuidString)")
            Text(item.source.type == "manual" ? "你手動填寫的" : "來自你的對話 · \(item.source.at.formatted(date: .abbreviated, time: .omitted))")
                .font(.caption).foregroundStyle(.secondary)
            if item.pinned {
                Text("已置頂").font(.caption)
                    .accessibilityIdentifier("memory.pinned.\(item.id.uuidString)")
            }
            if let previous = item.replaces {
                Text("原內容：\(previous)").font(.caption).foregroundStyle(.secondary)
            }
            if !item.keywords.isEmpty {
                Text(item.keywords.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                if pending {
                    Button("核准") { store.mutateMemory { try $0.approve(id: item.id) } }
                        .accessibilityIdentifier("memory.approve.\(item.id.uuidString)")
                    Button("不要", role: .destructive) { store.mutateMemory { _ = try $0.delete(id: item.id) } }
                        .accessibilityIdentifier("memory.reject.\(item.id.uuidString)")
                } else {
                    Button("編輯") { store.dismissNotice(); sheet = .memory(item) }
                        .accessibilityIdentifier("memory.edit.\(item.id.uuidString)")
                    Button(item.pinned ? "取消置頂" : "置頂") {
                        store.mutateMemory { try $0.setPinned(id: item.id, pinned: !item.pinned) }
                    }
                    .accessibilityIdentifier("memory.pin.\(item.id.uuidString)")
                    Button("刪除", role: .destructive) { store.mutateMemory { _ = try $0.delete(id: item.id) } }
                        .accessibilityIdentifier("memory.delete.\(item.id.uuidString)")
                }
            }
            .buttonStyle(.borderless)
            .frame(minHeight: 44)
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder private var skillsSections: some View {
        Section("我的 Skills") {
            Text("核准並啟用的 Skills 可作為模型對話的文字參考，不會執行程式、控制其他 App 或授予工具權限。試用中不代表已驗證成功。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("skills.scope")
            if store.skills.installed.isEmpty {
                Text("尚未核准任何 Skills。")
                    .accessibilityIdentifier("skills.empty")
            }
            ForEach(store.skills.installed.sorted { $0.name < $1.name }) { skill in
                installedSkillRow(skill)
            }
        }
        Section {
            Button("匯入 Skill 全文") {
                store.dismissNotice()
                sheet = .importSkill
            }
            .accessibilityIdentifier("skills.import")
            Text("貼上 SKILL.md；匯入後先進入待確認，不會立即啟用。")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func draftRow(_ draft: SkillDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: skillTitle(draft.document)).font(.headline)
                .accessibilityIdentifier("skills.draft.\(draft.name)")
            Text(verbatim: draft.document.description)
            Text(draft.source == .imported ? "由你匯入 · 尚未核准" : "待你核准")
                .font(.caption).foregroundStyle(.secondary)
            if let previous = store.skills.installed.first(where: { $0.name == draft.replacesName }) {
                Text("更新草稿；核准前仍保留目前版本。")
                    .font(.caption)
                    .accessibilityIdentifier("skills.update.\(draft.name)")
                Text(verbatim: changedLines(from: previous.markdown, to: draft.markdown))
                    .font(.caption).lineLimit(6)
            }
            HStack(spacing: 16) {
                Button("核准試用") {
                    store.mutateSkills { _ = try $0.approveDraft(id: draft.id, availableToolNames: toolNames) }
                }
                .accessibilityIdentifier("skills.approve.\(draft.name)")
                Button("編輯後核准") { store.dismissNotice(); sheet = .editSkill(draft) }
                    .accessibilityIdentifier("skills.edit.\(draft.name)")
            }
            HStack(spacing: 20) {
                Button("查看全文") { sheet = .fullText(skillTitle(draft.document), draft.markdown) }
                    .accessibilityIdentifier("skills.draftFullText.\(draft.name)")
                Button("不要", role: .destructive) { store.mutateSkills { try $0.rejectDraft(id: draft.id) } }
                    .accessibilityIdentifier("skills.reject.\(draft.name)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
    }

    private func installedSkillRow(_ skill: PersonalSkill) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: skillTitle(skill.document)).font(.headline)
                .accessibilityIdentifier("skills.item.\(skill.name)")
            Text(verbatim: skill.document.description)
            Text(skill.status == .suspended ? "已停用" : skill.status == .trial ? "試用中 · 尚未驗證" : "已啟用")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("skills.state.\(skill.name)")
            Toggle("啟用文字參考", isOn: Binding(get: { skill.isEnabled }, set: { enabled in
                store.mutateSkills {
                    if enabled { try $0.resume(name: skill.name) }
                    else { try $0.suspend(name: skill.name) }
                }
            }))
            .accessibilityIdentifier("skills.enabled.\(skill.name)")
            HStack(spacing: 20) {
                Button("查看全文") { sheet = .fullText(skillTitle(skill.document), skill.markdown) }
                    .accessibilityIdentifier("skills.fullText.\(skill.name)")
                if let shared = try? store.skills.exportMarkdown(name: skill.name) {
                    ShareLink(item: shared, subject: Text(skillTitle(skill.document))) { Text("分享") }
                        .accessibilityIdentifier("skills.share.\(skill.name)")
                }
                Button("刪除", role: .destructive) { store.mutateSkills { try $0.remove(name: skill.name) } }
                    .accessibilityIdentifier("skills.delete.\(skill.name)")
            }
            if let previous = store.skills.revisions.reversed().first(where: { $0.name == skill.name && $0.canRestore }) {
                Button("還原上一版") {
                    store.mutateSkills {
                        _ = try $0.restoreRevision(id: previous.id, expectedCurrentHash: skill.fingerprint, availableToolNames: toolNames)
                    }
                }
                .accessibilityIdentifier("skills.rollback.\(skill.name)")
            }
        }
        .buttonStyle(.borderless)
        .padding(.vertical, 8)
    }

    private var preferencesSection: some View {
        Section("記憶與學習設定") {
            Toggle("使用記憶", isOn: preference(\.useMemory))
                .accessibilityIdentifier("memory.toggle.useMemory")
            Toggle("自動記住我說過的事", isOn: preference(\.autoRemember))
                .accessibilityIdentifier("memory.toggle.autoRemember")
            Toggle("從完成的任務學習 Skills", isOn: preference(\.learnSkills))
                .accessibilityIdentifier("memory.toggle.learnSkills")
            Text("使用記憶不影響已核准技能；技能請用各自開關停用。學習技能開關只控制起草，不影響匯入或使用已核准技能。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("memory.preferenceScope")
            Text("網站研究達到學習條件後會提出技能草稿，需核准才會使用。一般模型對話不會直接被當成技能驗證成功。")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("skills.learningLimit")
            if store.isLearning { ProgressView("正在整理對話記憶…") }
        }
        .disabled(!store.available)
    }

    private func preference(_ keyPath: WritableKeyPath<MemoryPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { store.memory.preferences[keyPath: keyPath] }, set: { value in
            store.updatePreferences { $0[keyPath: keyPath] = value }
        })
    }

    private func matchingMemories(status: MemoryStatus) -> [MemoryItem] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.memory.search(text, limit: 500, includePending: true)
            .filter { $0.status == status }
    }
}

private enum LearningSegment: String, CaseIterable, Identifiable {
    case memories, skills, pending
    var id: String { rawValue }
    var title: String {
        switch self { case .memories: return "記憶"; case .skills: return "技能"; case .pending: return "待確認" }
    }
}

private enum LearningSheet: Identifiable {
    case memory(MemoryItem?), importSkill, editSkill(SkillDraft), fullText(String, String), clear, websites, catalog
    var id: String {
        switch self {
        case .memory(let item): return "memory-" + (item?.id.uuidString ?? "new")
        case .importSkill: return "import"
        case .editSkill(let draft): return "edit-" + draft.id.uuidString
        case .fullText: return "fulltext"
        case .clear: return "clear"
        case .websites: return "websites"
        case .catalog: return "catalog"
        }
    }
}

private let memoryKinds: [MemoryKind] = [.fact, .preference, .procedure]
private func memoryKindTitle(_ kind: MemoryKind) -> String {
    switch kind { case .fact: return "關於你"; case .preference: return "偏好"; case .procedure: return "做法" }
}
private func skillTitle(_ document: SkillDocument) -> String {
    document.frontMatter["display"]?.stringValue ?? document.name
}
private func changedLines(from old: String, to new: String) -> String {
    let before = old.components(separatedBy: .newlines).filter { !$0.isEmpty }
    let after = new.components(separatedBy: .newlines).filter { !$0.isEmpty }
    return (after.filter { !before.contains($0) }.map { "+ \($0)" }
        + before.filter { !after.contains($0) }.map { "− \($0)" }).joined(separator: "\n")
}

@MainActor
private struct MemoryEditor: View {
    @ObservedObject var store: LearningStore
    let item: MemoryItem?
    @Environment(\.dismiss) private var dismiss
    @FocusState private var contentFocused: Bool
    @State private var kind: MemoryKind
    @State private var content: String
    @State private var keywords: String

    init(store: LearningStore, item: MemoryItem?) {
        self.store = store; self.item = item
        _kind = State(initialValue: item?.kind ?? .fact)
        _content = State(initialValue: item?.content ?? "")
        _keywords = State(initialValue: item?.keywords.joined(separator: " ") ?? "")
    }

    var body: some View {
        Form {
            if item == nil {
                Picker("種類", selection: $kind) {
                    ForEach(memoryKinds, id: \.rawValue) { value in
                        Text(memoryKindTitle(value)).tag(value)
                            .accessibilityIdentifier("memory.kind.\(value.rawValue)")
                    }
                }
                .pickerStyle(.segmented)
            }
            Section("記憶內容（最多 200 個 UTF-16 字元）") {
                TextEditor(text: $content).frame(minHeight: 100)
                    .focused($contentFocused).autocorrectionDisabled()
                    .accessibilityIdentifier("memory.editor.content")
                TextField("關鍵字，以空白分隔", text: $keywords)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("memory.editor.keywords")
            }
            if kind == .procedure {
                Text("做法會先進入待確認，核准後才可供對話參考；不會自動執行操作。")
            }
            if let error = store.error {
                Text(verbatim: error).foregroundStyle(.red)
                    .accessibilityIdentifier("memory.editor.error")
            }
        }
        .navigationTitle(item == nil ? "新增記憶" : "編輯記憶")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("memory.editor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("儲存") { save() }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.available)
                    .accessibilityIdentifier("memory.editor.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button("清空內容") { content = "" }
                    .accessibilityIdentifier("memory.editor.clear")
                Spacer()
                Button("完成輸入") { contentFocused = false }
                    .accessibilityIdentifier("memory.editor.done")
            }
        }
        .interactiveDismissDisabled(!content.isEmpty)
    }

    private func save() {
        let words = keywords.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let succeeded = store.mutateMemory { memory in
            if let item { _ = try memory.edit(id: item.id, content: content, keywords: words) }
            else { _ = try memory.add(kind: kind, content: content, keywords: words) }
        }
        if succeeded { dismiss() }
    }
}

@MainActor
private struct SkillEditor: View {
    @ObservedObject var store: LearningStore
    let draft: SkillDraft?
    let toolNames: Set<String>
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editing: Bool
    @State private var markdown: String

    init(store: LearningStore, draft: SkillDraft?, toolNames: Set<String>, onSaved: @escaping () -> Void) {
        self.store = store; self.draft = draft; self.toolNames = toolNames; self.onSaved = onSaved
        _markdown = State(initialValue: draft?.markdown ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft == nil ? "貼上完整 SKILL.md。有效內容會進入待確認，不會立即啟用。" : "檢查全文後核准試用；不會執行程式或授予工具權限。")
                .font(.callout)
            TextEditor(text: $markdown)
                .focused($editing)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier("skills.editor.markdown")
            if let error = store.error {
                Text(verbatim: error).foregroundStyle(.red)
                    .accessibilityIdentifier("skills.editor.error")
            }
        }
        .padding()
        .navigationTitle(draft == nil ? "匯入 Skill" : "編輯後核准")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("skills.editor.cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(draft == nil ? "匯入" : "核准") {
                    let succeeded = store.mutateSkills { skills in
                        if let draft { _ = try skills.approveDraft(id: draft.id, editedMarkdown: markdown, availableToolNames: toolNames) }
                        else { _ = try skills.importMarkdown(markdown, availableToolNames: toolNames) }
                    }
                    if succeeded { onSaved(); dismiss() }
                }
                .disabled(markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.available)
                .accessibilityIdentifier("skills.editor.save")
            }
            ToolbarItemGroup(placement: .keyboard) {
                Button("清空全文") { markdown = "" }.accessibilityIdentifier("skills.editor.clear")
                Spacer()
                Button("完成輸入") { editing = false }.accessibilityIdentifier("skills.editor.done")
            }
        }
        .interactiveDismissDisabled(!markdown.isEmpty)
    }
}

private struct SkillTextView: View {
    let title: String
    let markdown: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            Text(verbatim: markdown).font(.body.monospaced()).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading).padding()
                .accessibilityIdentifier("skills.document")
        }
        .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") { dismiss() }.accessibilityIdentifier("skills.document.close")
            }
        }
    }
}

@MainActor
private struct LearningClearView: View {
    @ObservedObject var store: LearningStore
    @Environment(\.dismiss) private var dismiss
    @State private var stage = 1

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(stage == 1 ? "第一步：確認清除範圍" : "第二步：最後確認")
                    .font(.headline).accessibilityIdentifier("memory.clear.stage")
                Text("將清除所有記憶、Skills、待確認草稿、網站知識、路線與版本紀錄。模型設定、模型金鑰與 MCP 端點會保留。此操作無法復原。")
                if stage == 1 {
                    Button("繼續") { stage = 2 }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("memory.clear.continue")
                } else {
                    Button("確認全部清除", role: .destructive) {
                        if store.clearAll() { dismiss() }
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("memory.clear.confirm")
                }
                if let error = store.error {
                    Text(verbatim: error).foregroundStyle(.red)
                        .accessibilityIdentifier("memory.clear.error")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding()
        }
        .navigationTitle("清除資料").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { dismiss() }.accessibilityIdentifier("memory.clear.cancel")
            }
        }
    }
}
