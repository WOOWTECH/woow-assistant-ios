import AssistantSkills
import SwiftUI

/// Manual host consumer of the typed bridge. User input is captured here; neither
/// source Markdown nor model/MCP output can produce an approval or write a skill.
@MainActor
struct SkillAuthoringView: View {
    @ObservedObject var store: LearningStore
    let catalog: BundledSkillCatalog
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Field?
    @State private var step: Step = .request
    @State private var requestText = ""
    @State private var capturedRequest = ""
    @State private var session: SkillAuthoringBridge?
    @State private var query = ""
    @State private var matches: [SkillAuthoringMatch] = []
    @State private var read: SkillAuthoringRead?
    @State private var replacing: SkillAuthoringRead?
    @State private var markdown = ""
    @State private var review: SkillAuthoringSaveReview?
    @State private var receipt: SkillAuthoringSaveReceipt?
    @State private var failure: String?

    private enum Step { case request, lookup, reading, editing, review, saved }
    private enum Field: Hashable { case request, search, markdown }

    var body: some View {
        Form {
            if let failure {
                Section { Text(verbatim: failure).foregroundStyle(.red).accessibilityIdentifier("authoring.error") }
            }
            switch step {
            case .request: requestSection
            case .lookup: lookupSection
            case .reading: readSection
            case .editing: editorSection
            case .review: reviewSection
            case .saved: savedSection
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) { actions }
                .buttonStyle(.borderedProminent)
                .padding().frame(maxWidth: .infinity).background(.regularMaterial)
        }
        .navigationTitle("編寫個人技能")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(step == .saved ? "完成" : "取消") {
                    session?.cancel(); focused = nil; dismiss()
                }
                .accessibilityIdentifier("authoring.close")
            }
            ToolbarItemGroup(placement: .keyboard) {
                if focused == .markdown {
                    Button("清空全文") { markdown = "" }.accessibilityIdentifier("authoring.keyboard.clear")
                }
                Spacer()
                Button("完成輸入") { focused = nil }.accessibilityIdentifier("authoring.keyboard.done")
            }
        }
        .onDisappear { session?.cancel() }
    }

    private var requestSection: some View {
        Section("這次要建立或修改什麼做法？") {
            Text("請寫下你的要求。接著可查閱原始或個人技能、編寫全文，再核對內容並核准儲存。")
                .accessibilityIdentifier("authoring.intro")
            TextEditor(text: $requestText).frame(minHeight: 110)
                .focused($focused, equals: .request).autocorrectionDisabled()
                .accessibilityLabel("本次要求").accessibilityIdentifier("authoring.request")
            Text("這是手動編寫流程；不會呼叫模型或連線。儲存後先試用，工具操作仍須各自核准。")
                .font(.footnote).accessibilityIdentifier("authoring.scope")
        }
    }

    @ViewBuilder private var lookupSection: some View {
        Section("查閱技能") {
            TextField("搜尋名稱或做法", text: $query)
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focused, equals: .search).submitLabel(.search)
                .onSubmit { search() }.accessibilityIdentifier("authoring.search")
            Button("查詢") { search() }.accessibilityIdentifier("authoring.search.submit")
            Text("找到相近的個人技能時，先讀全文再修改；停用的技能仍會列出供查閱。")
                .font(.footnote)
            ForEach(matches, id: \.reference) { match in
                Button {
                    perform {
                        read = try requireSession().read(match.reference)
                        focused = nil; step = .reading
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: match.name)
                        Text(verbatim: match.description).font(.caption)
                        Text(match.status.map(statusTitle) ?? "原始技能 · 唯讀").font(.caption)
                        if match.hasPendingDraft { Text("已有待確認草稿").font(.caption) }
                    }
                }
                .accessibilityIdentifier("authoring.match." + referenceID(match.reference))
            }
            if matches.isEmpty { Text("找不到符合的技能。").accessibilityIdentifier("authoring.empty") }
        }
    }

    @ViewBuilder private var readSection: some View {
        if let read {
            Section("技能全文") {
                Text("內容供你查閱，讀取不會啟用技能或執行工具。")
                fullText(read.markdown, identifier: "authoring.read.full")
            }
            Section {
                DisclosureGroup("來源與版本") {
                    Text(verbatim: referenceID(read.reference) + "\n" + read.version + "\nSHA-256: " + read.fingerprint)
                        .font(.caption).textSelection(.enabled)
                        .accessibilityIdentifier("authoring.read.source")
                }
            }
        }
    }

    private var editorSection: some View {
        Section(replacing == nil ? "新技能全文" : "修改個人技能") {
            Text("名稱使用小寫英文字母、數字與連字號。填寫描述與五個段落，全文上限 4,000 字。")
                .font(.footnote)
            TextEditor(text: $markdown).frame(minHeight: 260)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled().textInputAutocapitalization(.never)
                .focused($focused, equals: .markdown)
                .accessibilityLabel("技能 Markdown 全文").accessibilityIdentifier("authoring.markdown")
            Text("請勿放入密碼或金鑰。使用反引號標示的工具須為本版本提供的能力。")
                .font(.footnote)
        }
    }

    @ViewBuilder private var reviewSection: some View {
        if let review {
            Section("本次要求") {
                Text(verbatim: review.requestQuote).accessibilityIdentifier("authoring.review.request")
            }
            Section(review.isUpdate ? "將取代同名個人技能" : "將新增個人技能") {
                Text(verbatim: review.name).accessibilityIdentifier("authoring.review.name")
                Text("尚未儲存。請核對完整內容；核准後會儲存為「試用中」，不會執行其中步驟。")
                    .accessibilityIdentifier("authoring.review.state")
                fullText(review.markdown, identifier: "authoring.review.full")
            }
            Section {
                DisclosureGroup("來源與版本") {
                    Text(verbatim: review.original.path + "\n" + review.original.revision
                        + "\n原文 SHA-256: " + review.original.sha256
                        + "\n草稿 SHA-256: " + review.draftFingerprint
                        + (review.replacesFingerprint.map { "\n原版本 SHA-256: " + $0 } ?? ""))
                        .font(.caption).textSelection(.enabled)
                        .accessibilityIdentifier("authoring.review.source")
                }
            }
        }
    }

    @ViewBuilder private var savedSection: some View {
        if let receipt {
            Section("已儲存") {
                Text(verbatim: receipt.name).accessibilityIdentifier("authoring.saved.name")
                Text(receipt.updated ? "已更新個人技能 · 試用中" : "已新增個人技能 · 試用中")
                    .accessibilityIdentifier("authoring.saved.status")
                Text("可到「記憶與資料 › 技能」查看、停用或管理。尚未驗證這份做法的實際成果。")
            }
        }
    }

    @ViewBuilder private var actions: some View {
        switch step {
        case .request:
            Button("開始查閱與編寫") { begin() }
                .disabled(!store.available || requestText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("authoring.begin")
        case .lookup:
            Button("撰寫新技能") {
                replacing = nil; markdown = Self.template; failure = nil; focused = nil; step = .editing
            }.accessibilityIdentifier("authoring.new")
        case .reading:
            if let read, case .personal = read.reference, read.status != .suspended {
                Button("以這份個人技能修改") {
                    replacing = read; markdown = read.markdown; failure = nil; step = .editing
                }.accessibilityIdentifier("authoring.edit.read")
            }
            Button("返回查詢") { failure = nil; step = .lookup }.accessibilityIdentifier("authoring.lookup")
        case .editing:
            Button("檢視完整草稿") { prepare() }.accessibilityIdentifier("authoring.prepare")
            Button("返回查詢") { focused = nil; failure = nil; search(); step = .lookup }
                .accessibilityIdentifier("authoring.lookup")
        case .review:
            Button("核准並儲存這份全文") { save() }
                .disabled(!store.available).accessibilityIdentifier("authoring.approve")
            Button("返回修改") { review = nil; failure = nil; step = .editing }
                .accessibilityIdentifier("authoring.revise")
        case .saved: EmptyView()
        }
    }

    private func begin() {
        perform {
            let request = try SkillAuthoringUserRequest(quote: requestText)
            capturedRequest = request.quote
            session = SkillAuthoringBridge(request: request, store: store, catalog: catalog)
            matches = try requireSession().search(query: "")
            focused = nil; step = .lookup
        }
    }

    private func search() {
        focused = nil
        perform { matches = try requireSession().search(query: query) }
    }

    private func prepare() {
        focused = nil
        perform {
            review = try requireSession().prepareSave(markdown: markdown, quote: capturedRequest, replacing: replacing)
            step = .review
        }
    }

    private func save() {
        // This button is the sole grant issuer. Both operations are synchronous
        // on MainActor; receipt appears only after the encrypted store returns.
        perform {
            guard let review else { throw SkillAuthoringError.reviewChanged }
            let bridge = try requireSession()
            do {
                let approval = try bridge.approve(reviewID: review.id, draftFingerprint: review.draftFingerprint)
                receipt = try bridge.commitReviewedSave(reviewID: review.id,
                    draftFingerprint: review.draftFingerprint, approval: approval)
                self.review = nil; step = .saved
            } catch {
                self.review = nil; step = .editing
                throw error
            }
        }
    }

    private func requireSession() throws -> SkillAuthoringBridge {
        guard let session else { throw SkillAuthoringError.cancelled }
        return session
    }

    private func perform(_ action: () throws -> Void) {
        do { try action(); failure = nil }
        catch { failure = LearningStore.message(error) }
    }

    private func fullText(_ value: String, identifier: String) -> some View {
        Text(verbatim: value).font(.system(.body, design: .monospaced))
            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }

    private func statusTitle(_ status: SkillStatus) -> String {
        switch status {
        case .pending: return "待確認"
        case .trial: return "個人技能 · 試用中"
        case .active: return "個人技能 · 已驗證"
        case .suspended: return "個人技能 · 已停用"
        }
    }

    private func referenceID(_ reference: SkillAuthoringReference) -> String {
        switch reference {
        case .personal(let name): return "personal." + name
        case .bundled(let name): return "bundled." + name
        }
    }

    private static let template = """
    ---
    name:
    display:
    description:
    aliases: []
    ---
    ## 入口

    ## 步驟

    ## 容易出錯的地方

    ## 怎樣算辦成

    ## 什麼時候停下交給使用者

    """
}
