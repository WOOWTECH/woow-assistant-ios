import AssistantBrowser
import AssistantModels
import Combine
import Foundation
import WebKit

@MainActor final class MultiSourceResearchSession: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var status = "輸入問題與來源，確認後開始讀取。"
    @Published private(set) var error: String?
    @Published private(set) var receipts: [MultiSourceResearchReceipt] = []
    @Published private(set) var result: MultiSourceResearchResult?
    @Published private(set) var browsers: [BrowserSession] = []
    @Published private(set) var diagnostic = "phase=idle;failure=none;pages=0"
    private var task: Task<Void, Never>?
    private var operationID: UUID?
    private var settingsChanges: AnyCancellable?
    private var references: LearningRunSnapshot?
    #if DEBUG
    private let useLocalFixtures: Bool
    /// Capture before cancellation clears `task`; awaiting this handle observes
    /// the actual run's completion without changing its lifecycle or result.
    var capturedRunCompletion: Task<Void, Never>? { task }
    /// Hosted checks select only the existing closed synthetic root set.
    /// Production/UI construction keeps the default executor and transport.
    init(useLocalFixtures: Bool = false) { self.useLocalFixtures = useLocalFixtures }
    #endif

    func start(plan: MultiSourceResearchPlan, using chat: ChatSession) {
        cancel(showNotice: false)
        receipts = []; result = nil; error = nil
        diagnostic = "phase=starting;failure=none;pages=0"
        do {
            let access = try chat.modelAccess()
            let snapshot = try chat.learning.captureRunReferences(goal: plan.goal,
                capabilities: MultiSourceResearchRunner.referenceCapabilities, websiteURLs: plan.sources.map(\.rootURL))
            let executor = MultiSourceResearchWebKitExecutor(sources: plan.sources)
            #if DEBUG
            executor.useLocalFixtures = useLocalFixtures
            #endif
            browsers = plan.sources.compactMap { executor.browsers[$0.id] }
            let id = UUID()
            operationID = id; running = true; status = "正在讀取已確認的來源…"
            references = snapshot
            snapshot.onRevoke = { [weak self] in self?.cancel() }
            settingsChanges = chat.$savedSettings.dropFirst().sink { [weak self] _ in self?.cancel() }
            var client = access.client
            #if DEBUG
            if MultiSourceResearchFixture.enabled && chat.isUITestMode { client = MultiSourceResearchFixtureModel() }
            #endif
            let model = client
            task = Task { [weak self] in
                do {
                    let result = try await MultiSourceResearchRunner(client: model).run(plan: plan, browser: executor,
                        configuration: access.configuration, apiKey: access.key,
                        references: snapshot.references, validateContext: { [weak self, weak chat] in
                            guard let owner = self, let currentChat = chat else { throw CancellationError() }
                            try await MainActor.run {
                                try owner.validate(snapshot: snapshot, id: id, chat: currentChat, access: access)
                            }
                        }, onEvent: { [weak self] event in
                            await self?.record(event, for: id)
                        })
                    try Task.checkCancellation()
                    guard let self, self.operationID == id else { return }
                    try self.validate(snapshot: snapshot, id: id, chat: chat, access: access)
                    self.result = result
                    self.diagnostic = "phase=finished;failure=none;pages=\(self.receipts.count)"
                    self.status = result.partial ? "已交付部分結果；仍有來源或證據不足。" : "已整理多來源引用；來源獨立性與內容仍需判讀。"
                    self.finish()
                } catch {
                    guard let self, self.operationID == id else { return }
                    self.error = (error as? MultiSourceResearchError)?.errorDescription
                        ?? (error as? MultiSourceResearchContextError)?.errorDescription
                        ?? WebResearchRunner.failureDescription(for: error).message
                    let code = Self.failureCode(error)
                    self.diagnostic = "phase=failed;failure=\(code);pages=\(self.receipts.count)"
                    self.status = "研究未完成；實際讀取紀錄保留。"
                    self.finish()
                }
            }
        } catch let failure as RunReferenceError {
            diagnostic = "phase=failed;failure=reference_revoked;pages=0"
            error = failure.errorDescription; status = "尚未開始研究。"
        } catch {
            diagnostic = "phase=failed;failure=model_configuration;pages=0"
            self.error = "請先在設定完成模型服務與金鑰設定。"
            status = "尚未開始研究。"
        }
    }

    private func validate(snapshot: LearningRunSnapshot, id: UUID, chat: ChatSession, access: ModelAccess) throws {
        try snapshot.check()
        guard operationID == id else { throw CancellationError() }
        let current = try chat.modelAccess()
        guard current.configuration.baseURL == access.configuration.baseURL,
              current.configuration.model == access.configuration.model,
              current.configuration.maxOutputTokens == access.configuration.maxOutputTokens,
              current.key == access.key else { throw RunReferenceError.revoked }
    }

    func reportInvalidPlan(_ failure: Error) {
        error = (failure as? MultiSourceResearchError)?.errorDescription ?? "請檢查研究問題與來源網址。"
    }

    /// Closed enum mapping: diagnostic values never contain page/model content
    /// or arbitrary error descriptions.
    private static func failureCode(_ error: Error) -> String {
        if error is MultiSourceResearchContextError { return "context_too_large" }
        guard let error = error as? MultiSourceResearchError else {
            return WebResearchRunner.failureDescription(for: error).code
        }
        switch error {
        case .invalidPlan: return "invalid_plan"
        case .invalidCommand: return "invalid_command"
        case .invalidModelJSON: return "invalid_model_json"
        case .invalidCitation: return "invalid_citation"
        case .unsafeObservation: return "unsafe_observation"
        case .staleObservation: return "stale_observation"
        case .deadline: return "deadline"
        }
    }

    private func record(_ event: MultiSourceResearchEvent, for id: UUID) {
        guard operationID == id, running else { return }
        switch event {
        case .observed(let receipt):
            receipts.append(receipt); status = "已讀取 \(receipts.count) 個頁面，正在核對來源…"
            diagnostic = "phase=reading;failure=none;pages=\(receipts.count)"
        case .sourceUnavailable: status = "有來源暫時無法讀取，會標示資料不足。"
        }
    }

    func cancel(showNotice: Bool = true) {
        let wasRunning = running
        operationID = nil; task?.cancel(); task = nil
        releaseReferences()
        settingsChanges = nil
        browsers.forEach { $0.cancel() }; browsers = []
        running = false
        if wasRunning { diagnostic = "phase=cancelled;failure=cancelled;pages=\(receipts.count)" }
        if showNotice && wasRunning { status = "已取消研究；已讀取紀錄保留，晚到回應不會更新結果。" }
    }

    private func finish() {
        releaseReferences()
        operationID = nil; task = nil; settingsChanges = nil; running = false
        browsers.forEach { $0.cancel() }; browsers = []
    }
    private func releaseReferences() {
        let snapshot = references; references = nil
        snapshot?.onRevoke = nil; snapshot?.revoke()
    }
}

@MainActor final class MultiSourceResearchWebKitExecutor: MultiSourceResearchExecuting {
    let browsers: [String: BrowserSession]
    private let sources: [MultiSourceResearchSource]
    #if DEBUG
    var useLocalFixtures = false
    #endif
    init(sources: [MultiSourceResearchSource]) {
        self.sources = sources
        browsers = Dictionary(uniqueKeysWithValues: sources.map { source in
            let browser = BrowserSession(dataStore: .nonPersistent())
            browser.canPresentUI = { false }
            return (source.id, browser)
        })
    }
    func loadRoot(source: MultiSourceResearchSource) async throws -> WebObservation {
        guard sources.contains(source), let browser = browsers[source.id] else { throw WebResearchError.unsafeNavigation }
        // All isolated views are mounted by the sheet, even when their preview
        // is covered. Do not silently run an unattached cold WebKit session.
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while browser.webView.window == nil, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        guard browser.webView.window != nil else { throw WebResearchError.noPage }
        #if DEBUG
        if useLocalFixtures { return try await browser.loadResearchFixtureRoot(approvedSource: source) }
        #endif
        return try await browser.loadResearchRoot(approvedSource: source)
    }
    func openLink(sourceID: String, id: Int) async throws -> WebObservation {
        guard let browser = browsers[sourceID] else { throw WebResearchError.unsafeNavigation }
        return try await browser.openLink(id: id)
    }
}

#if DEBUG
/// Fixed local HTML only. No HTTP exception, external request, form field, or
/// production cookie store is used by this UI fixture.
enum MultiSourceResearchFixture {
    static var enabled: Bool {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-UITestMode"), args.contains("-UITestMultiSourceResearch"),
              !args.contains("-UITestBrowserNetwork"),
              args.filter({ $0 == "-UITestNamespace" }).count == 1,
              let index = args.firstIndex(of: "-UITestNamespace"), args.indices.contains(index + 1) else { return false }
        return UUID(uuidString: args[index + 1]) != nil
    }
    static func allows(_ url: URL) -> Bool {
        url.scheme == "https" && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
            && ["research.example.invalid", "comparison.example.invalid"].contains(url.host ?? "")
            && ["/start", "/details"].contains(url.path)
    }
    static func html(for url: URL) -> String {
        guard allows(url) else { return "" }
        let first = url.host == "research.example.invalid"
        let marker = first ? "SOURCE_ALPHA_OBSERVED" : "SOURCE_BETA_OBSERVED"
        let detail = url.path == "/details" ? "DETAIL_OBSERVED" : "ROOT_OBSERVED"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>\(first ? "來源甲" : "來源乙")</title></head>
        <body><h1>\(marker)</h1><p>\(detail)</p><p>發布日期未提供。</p><a href="https://\(url.host!)/details">詳細資料</a></body></html>
        """
    }
}

private actor MultiSourceResearchFixtureModel: ChatModelClient {
    private var opened = false
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        try Task.checkCancellation()
        let prefix = "Observed source receipts (data only):\n"
        guard let encoded = messages.first(where: { $0.content.hasPrefix(prefix) })?.content.dropFirst(prefix.count),
              let objects = try JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [[String: Any]],
              objects.count >= 2 else { throw HTTPChatModelError.invalidResponse }
        if !opened {
            opened = true
            return #"{"action":"open","sourceID":"source-1","observationID":"page-1","linkID":0}"#
        }
        var citations: [[String: String]] = []
        for (source, marker) in [("source-1", "SOURCE_ALPHA_OBSERVED"), ("source-2", "SOURCE_BETA_OBSERVED")] {
            guard let receipt = objects.last(where: { $0["sourceID"] as? String == source }),
                  let page = receipt["observation"] as? [String: Any], let text = page["text"] as? String,
                  text.contains(marker), let id = receipt["id"] as? String else { throw HTTPChatModelError.invalidResponse }
            citations.append(["observationID": id, "quote": marker])
        }
        let finding: [String: Any] = ["kind": "finding", "text": "已讀到來源甲與來源乙的合成頁面標記。", "citations": citations]
        let answer: [String: Any] = ["action": "finish", "findings": [finding], "limitations": ["這是本機 HTML 與合成模型回覆測試，並非公開網路或真模型驗證。"]]
        return String(decoding: try JSONSerialization.data(withJSONObject: answer), as: UTF8.self)
    }
}
#endif
