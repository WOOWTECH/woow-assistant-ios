import AssistantSkills
import Combine
import SwiftUI

/// Source archive with explicit entry points to supported local capabilities.
@MainActor
struct SkillCatalogView: View {
    @ObservedObject var store: LearningStore
    let modelAccess: () throws -> ModelAccess
    let modelChanges: AnyPublisher<Void, Never>
    @Environment(\.dismiss) private var dismiss
    @State private var catalog: BundledSkillCatalog?
    @State private var failure: String?
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Mika 內建技能目錄")
                .font(.headline).accessibilityIdentifier("catalog.status")
            if let catalog {
                Text("共 \(catalog.entries.count) 項原始技能 · 符合 \(catalog.search(query).count) 項")
                    .font(.subheadline).accessibilityIdentifier("catalog.count")
                TextField("搜尋名稱、全文或支援檔案", text: $query)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled()
                    .focused($searchFocused).onSubmit { searchFocused = false }
                    .submitLabel(.search).accessibilityIdentifier("catalog.search")
                List {
                    Section {
                        Text("原文與腳本僅供閱讀，不會執行。iOS 文字改寫須先匯入待確認，再由你核准；核准後為試用中，不代表原版功能已完成對齊。")
                            .accessibilityIdentifier("catalog.scope")
                        Text("受控瀏覽器與 MCP 對話有各自的能力限制和核准流程；匯入 Skill 不會授予工具權限或自動派送工具。")
                            .font(.footnote).accessibilityIdentifier("catalog.capabilities")
                    }
                    Section("原始技能與 iOS 文字改寫") {
                        ForEach(catalog.search(query)) { entry in
                            NavigationLink {
                                SkillCatalogDetail(store: store, catalog: catalog, entry: entry, modelAccess: modelAccess, modelChanges: modelChanges)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: entry.title)
                                    Text(verbatim: entry.id).font(.caption).foregroundStyle(.secondary)
                                    Text(verbatim: entry.readiness).font(.caption)
                                }
                            }
                            .accessibilityIdentifier("catalog.entry.\(entry.id)")
                        }
                        if catalog.search(query).isEmpty {
                            Text("找不到符合的技能。")
                                .accessibilityIdentifier("catalog.empty")
                        }
                    }
                    Section("來源與授權") {
                        Text("Mika · 固定來源版本 \(BundledSkillCatalog.pinnedCommit)")
                            .font(.caption).textSelection(.enabled)
                            .accessibilityIdentifier("catalog.provenance")
                        documentLink(catalog.license, title: "Apache-2.0 授權全文", identifier: "catalog.license")
                        documentLink(catalog.notice, title: "原始 NOTICE", identifier: "catalog.notice")
                    }
                }
                .scrollDismissesKeyboard(.interactively)
            } else if let failure {
                Text(verbatim: failure).accessibilityIdentifier("catalog.error")
                Button("重新讀取") { load() }.accessibilityIdentifier("catalog.retry")
                Spacer()
            } else {
                ProgressView("讀取本機目錄")
                Spacer()
            }
        }
        .padding(.horizontal)
        .navigationTitle("內建目錄")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("關閉") { dismiss() }.accessibilityIdentifier("catalog.close")
            }
        }
        .task { if catalog == nil { load() } }
    }

    private func load() {
        do { catalog = try BundledSkillCatalog.bundled(); failure = nil }
        catch { failure = (error as? SkillCatalogError)?.errorDescription ?? "內建技能目錄無法讀取。" }
    }

    private func documentLink(_ document: SkillCatalogDocument, title: String, identifier: String) -> some View {
        NavigationLink {
            CatalogTextView(title: title, text: document.content, document: document)
        } label: { Text(verbatim: title) }
        .accessibilityIdentifier(identifier)
    }
}

@MainActor
private struct SkillCatalogDetail: View {
    @ObservedObject var store: LearningStore
    @EnvironmentObject private var preferences: SelfConfigurationStore
    let catalog: BundledSkillCatalog
    let entry: SkillCatalogEntry
    let modelAccess: () throws -> ModelAccess
    let modelChanges: AnyPublisher<Void, Never>
    @State private var failure: String?

    private var pending: Bool { store.skills.pending.contains { $0.name == entry.adaptationName } }
    private var installed: Bool { store.skills.installed.contains { $0.name == entry.adaptationName } }

    var body: some View {
        List {
            if entry.id == "content-transcribe" {
                Section("整理文字稿與字幕") {
                    NavigationLink { TranscriptView(modelAccess: modelAccess, modelChanges: modelChanges) } label: {
                        Text("選取文字稿或字幕檔")
                    }.accessibilityIdentifier("catalog.content-transcribe.open")
                    Text("核准讀檔並確認目的服務後，由模型分段閱讀原文、整理內容與核對引文。")
                        .font(.caption)
                }
            }
            if entry.id == "configure-mika" {
                Section("調整本 App 外觀") {
                    NavigationLink { SelfConfigurationView(store: preferences, modelAccess: modelAccess) } label: {
                        Text("外觀與模型調整權限")
                    }.accessibilityIdentifier("catalog.configure-mika.open")
                    Text("可設定跟隨系統、淺色或深色；允許模型調整的開關預設關閉。")
                        .font(.caption)
                }
            }
            if entry.id == "skill-authoring" {
                Section("編寫個人技能") {
                    NavigationLink { SkillAuthoringView(store: store, catalog: catalog) } label: {
                        Text("查閱、編寫與審閱儲存")
                    }
                    .disabled(!store.available)
                    .accessibilityIdentifier("catalog.skill-authoring.open")
                    NavigationLink { SkillAgentView(store: store, modelAccess: modelAccess) } label: {
                        Text("請模型協助編寫技能")
                    }
                    .disabled(!store.available)
                    .accessibilityIdentifier("catalog.skill-authoring.agent")
                    Text("可自行編寫，或請模型查詢、讀取原文並提出草稿；核對全文並核准後，才會儲存至個人技能。")
                        .font(.caption)
                }
            }
            if entry.id == "documents" {
                Section("實際文件處理") {
                    NavigationLink { SkillExecutionView(modelAccess: modelAccess, modelChanges: modelChanges) } label: { Text("選取 PDF 並擷取文字") }
                        .accessibilityIdentifier("catalog.documents.execute")
                    NavigationLink { SkillPDFAssemblyView() } label: { Text("擷取頁面、重排與合併 PDF") }
                        .accessibilityIdentifier("catalog.documents.assemble")
                    Text("在裝置上處理你選取的 PDF；逐步核准，不會自動上傳文件。")
                        .font(.caption)
                }
            }
            Section("iOS 文字改寫 · 非完整原版功能") {
                Text(verbatim: entry.adaptationScope).accessibilityIdentifier("catalog.adaptation.scope")
                NavigationLink {
                    CatalogTextView(title: "iOS 文字改寫全文", text: entry.adaptationMarkdown)
                } label: { Text("閱讀 iOS 文字改寫全文") }
                .accessibilityIdentifier("catalog.adaptation.fullText")
                Button("匯入文字版至待確認") {
                    if store.importCatalogSkill(id: entry.id, catalog: catalog) { failure = nil }
                    else { failure = store.error ?? "未匯入；原資料保留。" }
                }
                .disabled(!store.available || pending || installed)
                .accessibilityIdentifier("catalog.import")
                if pending {
                    Text("已儲存至待確認，尚未啟用。請關閉目錄後到待確認審閱與核准。")
                        .accessibilityIdentifier("catalog.import.pending")
                } else if installed {
                    Text("此文字版已在你的技能清單；啟用、試用或驗證狀態請到技能清單查看。")
                        .accessibilityIdentifier("catalog.import.installed")
                }
                if !store.available {
                    Text("儲存空間目前不可用；仍可閱讀，但不能匯入。")
                        .accessibilityIdentifier("catalog.import.unavailable")
                }
                if let failure { Text(verbatim: failure).foregroundStyle(.red).accessibilityIdentifier("catalog.import.error") }
            }
            Section("原版所需能力與限制") {
                Text(verbatim: entry.readiness).accessibilityIdentifier("catalog.readiness")
                ForEach(entry.requirements, id: \.rawValue) { requirement in
                    Text(verbatim: requirement.title)
                        .accessibilityIdentifier("catalog.requirement.\(requirement.rawValue)")
                }
            }
            Section("固定版本的完整原文 · 唯讀") {
                NavigationLink {
                    CatalogTextView(title: entry.id + "/SKILL.md", text: entry.original.content, document: entry.original)
                } label: { Text("閱讀原始 SKILL.md 全文") }
                .accessibilityIdentifier("catalog.original")
                ForEach(entry.assets) { asset in
                    NavigationLink {
                        CatalogTextView(title: URL(fileURLWithPath: asset.path).lastPathComponent,
                                        text: asset.content, document: asset)
                    } label: {
                        Text(verbatim: asset.path.components(separatedBy: "/").suffix(2).joined(separator: "/"))
                    }
                    .accessibilityIdentifier("catalog.asset.\(URL(fileURLWithPath: asset.path).lastPathComponent)")
                }
                Text("Copyright 2026 wangzan101 · Apache-2.0。原文及支援檔案逐位元組保留；iOS 改寫是另外的修改版本。完整 LICENSE 與 NOTICE 見目錄首頁。")
                    .font(.footnote).accessibilityIdentifier("catalog.attribution")
            }
        }
        .navigationTitle(entry.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// Verbatim text prevents Markdown links, embedded HTML and source code from
/// becoming actions. Even files whose upstream manifest says runnable are inert.
private struct CatalogTextView: View {
    let title: String
    let text: String
    var document: SkillCatalogDocument? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("唯讀文字，不會執行工具、程式或開啟文內連結。")
                    .font(.footnote).accessibilityIdentifier("catalog.document.safety")
                if let document {
                    Text(verbatim: document.path + "\nSHA-256: " + document.sha256 + "\n" + document.sourceURL.absoluteString)
                        .font(.caption).textSelection(.enabled)
                        .accessibilityIdentifier("catalog.document.provenance")
                }
                Text(verbatim: text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("catalog.document")
            }
            .padding()
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
