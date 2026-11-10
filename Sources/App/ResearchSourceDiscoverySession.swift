import AssistantBrowser
import Combine
import Foundation
import WebKit

@MainActor protocol ResearchSourceDiscovering: AnyObject {
    var webView: WKWebView { get }
    func search(query: String) async throws -> ResearchSourceDiscoveryResult
    func cancel()
}

extension ResearchSourceDiscoveryWebKit: ResearchSourceDiscovering {}

/// Search results propose addresses only. Applying them never calls the model,
/// reads a candidate page, or starts the separately confirmed research task.
@MainActor final class ResearchSourceDiscoverySession: ObservableObject {
    let provider: ResearchSourceDiscoveryProvider = .duckDuckGoHTML
    @Published private(set) var query: String
    @Published private(set) var browser: (any ResearchSourceDiscovering)?
    @Published private(set) var result: ResearchSourceDiscoveryResult?
    @Published private(set) var selectedIDs: [UUID] = []
    @Published private(set) var running = false
    @Published private(set) var status = "尚未搜尋"
    @Published private(set) var error: String?
    private var operationID: UUID?
    private var task: Task<Void, Never>?
    private let makeBrowser: @MainActor () -> any ResearchSourceDiscovering

    init(query: String, makeBrowser: @escaping @MainActor () -> any ResearchSourceDiscovering = {
        ResearchSourceDiscoveryWebKit(provider: .duckDuckGoHTML)
    }) {
        self.query = query; self.makeBrowser = makeBrowser
    }

    func setQuery(_ value: String) {
        guard value != query else { return }
        cancel(notice: false)
        query = value; result = nil; selectedIDs = []; error = nil; status = "尚未搜尋"
    }

    func search() {
        guard !running else { return }
        do { _ = try provider.searchURL(query: query) }
        catch { self.error = error.localizedDescription; return }
        cancel(notice: false)
        let id = UUID(), query = query
        let browser = makeBrowser()
        operationID = id; self.browser = browser
        running = true; result = nil; selectedIDs = []; error = nil; status = "正在搜尋公開來源…"
        task = Task { @MainActor [weak self] in
            do {
                let result = try await browser.search(query: query)
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.result = result; self.status = "找到 \(result.candidates.count) 個候選來源；尚未讀取網頁正文。"
                self.finish(id: id)
            } catch {
                guard let self, self.operationID == id, !Task.isCancelled else { return }
                self.error = (error as? ResearchSourceDiscoveryError)?.errorDescription ?? "搜尋未能完成，請稍後再試。"
                self.status = "這次搜尋未完成"; self.finish(id: id)
            }
        }
    }

    func toggle(_ candidateID: UUID) {
        guard !running, let result else { return }
        if selectedIDs.contains(candidateID) {
            selectedIDs.removeAll { $0 == candidateID }; error = nil; return
        }
        do {
            _ = try result.selected(candidateIDs: selectedIDs + [candidateID])
            selectedIDs.append(candidateID); error = nil
        } catch { self.error = "請選取最多三個不同網站的來源。" }
    }

    var canApply: Bool {
        guard !running, (2...3).contains(selectedIDs.count), let result else { return false }
        return (try? result.selected(candidateIDs: selectedIDs)) != nil
    }

    func selectedSources() -> [ResearchSourceDiscoveryCandidate]? {
        guard canApply, let result else { return nil }
        return try? result.selected(candidateIDs: selectedIDs)
    }

    func cancel(notice: Bool = true) {
        let wasRunning = running
        let hadResult = result != nil
        operationID = nil; task?.cancel(); task = nil
        browser?.cancel(); browser = nil; running = false
        // A completed search is still an apply capability. Leaving the sheet
        // or backgrounding must revoke it, as well as any in-flight request.
        result = nil; selectedIDs = []
        if (wasRunning || hadResult) && notice { status = "搜尋已取消，搜尋詞仍保留。" }
    }

    private func finish(id: UUID) {
        guard operationID == id else { return }
        operationID = nil; task = nil; running = false
        browser?.cancel(); browser = nil
    }
}
