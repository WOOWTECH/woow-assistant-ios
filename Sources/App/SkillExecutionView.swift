#if os(iOS)
import AssistantSkills
import SwiftUI
import UniformTypeIdentifiers

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
                    Button("清除本次計畫", role: .destructive) { model.clear(); password = "" }
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
            switch outcome {
            case .success(let urls):
                guard let url = urls.first, urls.count == 1 else { return }
                model.prepare(url: url, pages: pages, password: password, metadataOnly: metadataOnly, worker: useWorker ? worker : nil)
                password = ""
            case .failure: model.status = "未能選取檔案，請重試。"
            }
        }
        .onAppear { model.seedUITestIfRequested() }
        .onDisappear { model.clear() }
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
