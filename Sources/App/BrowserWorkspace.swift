import AssistantBrowser
import AssistantPersistence
import Combine
import Foundation
import WebKit

struct BrowserPageDialog: Identifiable {
    enum Kind { case alert, confirm, prompt }
    let id = UUID()
    let kind: Kind
    let host: String
    let message: String
    let initial: String
}

@MainActor
final class BrowserWorkspace: ObservableObject {
    @Published private(set) var library = BrowserLibraryState()
    @Published private(set) var selected: BrowserSession
    @Published private(set) var error: String?
    @Published private(set) var available = false
    @Published private(set) var websiteRecords: [WKWebsiteDataRecord] = []
    @Published private(set) var isClearingWebsiteData = false
    private var sessions: [UUID: BrowserSession] = [:]
    private var vault: EncryptedLearningFile?
    let websiteDataStore: WKWebsiteDataStore

    init() {
        var dataStore = WKWebsiteDataStore.default()
        var scope = "personal"
        var reset = false
        var invalidTestScope = false
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-UITestMode") || args.contains("-LiveModelUITest") || args.contains("-LiveBrowserUITest") {
            let flag = args.contains("-LiveModelUITest") ? "-LiveModelUITestNamespace" : "-UITestNamespace"
            if let index = args.firstIndex(of: flag), args.indices.contains(index + 1), let id = UUID(uuidString: args[index + 1]) {
                scope = "test-" + id.uuidString
                #if os(iOS)
                dataStore = WKWebsiteDataStore(forIdentifier: id)
                #else
                dataStore = .nonPersistent()
                #endif
                reset = args.contains("-UITestResetStorage") || args.contains("-LiveModelUITestCleanup")
            } else { invalidTestScope = true; dataStore = .nonPersistent() }
        }
        #endif
        websiteDataStore = dataStore
        selected = BrowserSession(dataStore: dataStore)
        do {
            guard !invalidTestScope else { throw BrowserLibraryError.invalidState }
            let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true).appendingPathComponent("BrowserLibrary/" + scope, isDirectory: true)
            let file = EncryptedLearningFile(url: root.appendingPathComponent("library.vault"),
                keys: LearningKeychainStore(service: "io.woowtech.assistant.browser.library." + scope))
            if reset {
                if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            }
            let loaded = try file.load(BrowserLibraryState.self) ?? BrowserLibraryState()
            try loaded.validate()
            library = loaded; vault = file; available = true
        } catch { self.error = "瀏覽資料目前無法讀取，不會覆寫原有資料。" }
        selected = makeSession(id: library.selectedID)
        if reset {
            isClearingWebsiteData = true
            dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
                self?.isClearingWebsiteData = false
            }
        }
        // Restore metadata only. Visiting a saved page starts when Browser opens,
        // not during unrelated chat/settings startup or a background relaunch.
    }

    func activateSelected() {
        guard !isClearingWebsiteData, selected.loadedURL == nil, !selected.address.isEmpty, selected.manualLoadDiagnostics == nil else { return }
        selected.openAddress()
    }
    @discardableResult private func update(_ change: (inout BrowserLibraryState) throws -> Void) -> Bool {
        guard available, let vault else { error = "瀏覽資料目前無法儲存。"; return false }
        do {
            var next = library; try change(&next); try next.validate(); try vault.save(next)
            library = next; error = nil; return true
        } catch { self.error = (error as? BrowserLibraryError) == .tabLimit ? "最多開啟 20 個分頁，請先關閉不用的分頁。" : "瀏覽資料未變更，請解鎖裝置後重試。"; return false }
    }
    private func makeSession(id: UUID, configuration: WKWebViewConfiguration? = nil) -> BrowserSession {
        if let session = sessions[id] { return session }
        let session = BrowserSession(dataStore: websiteDataStore, configuration: configuration)
        session.canPresentUI = { [weak self] in self?.library.selectedID == id && self?.isClearingWebsiteData == false }
        session.address = library.tabs.first(where: { $0.id == id })?.url?.absoluteString ?? ""
        session.onPageFinished = { [weak self] url, title in
            _ = self?.update { try $0.visit(tab: id, url: url, title: title) }
        }
        session.onCreateWindow = { [weak self] configuration, _ in
            guard let self, self.library.selectedID == id, !self.isClearingWebsiteData else { return nil }
            var newID: UUID?
            guard self.update({ newID = try $0.addTab() }), let newID else { return nil }
            self.selected.cancelInteraction()
            let popup = self.makeSession(id: newID, configuration: configuration)
            self.selected = popup
            return popup.webView
        }
        session.onCloseWindow = { [weak self] in self?.closeTab(id) }
        sessions[id] = session
        return session
    }
    func newTab() {
        guard !isClearingWebsiteData else { return }
        var newID: UUID?
        guard update({ newID = try $0.addTab() }), let newID else { return }
        suspendSelected(); selected = makeSession(id: newID)
    }
    func selectTab(_ id: UUID) {
        guard id != library.selectedID, !isClearingWebsiteData else { return }
        guard update({ try $0.select(id) }) else { return }
        suspendSelected(); selected = makeSession(id: id); activateSelected()
    }
    func closeTab(_ id: UUID) {
        guard !isClearingWebsiteData, update({ try $0.close(id) }) else { return }
        sessions.removeValue(forKey: id)?.cancel()
        selected = makeSession(id: library.selectedID); activateSelected()
    }
    private func suspendSelected() {
        if selected.isRunning { selected.cancel() }
        selected.cancelInteraction(); selected.resolveDialog(nil)
    }
    func cancelAllWork() {
        for session in sessions.values {
            if session.isRunning { session.cancel() }
            session.cancelInteraction(); session.resolveDialog(nil)
        }
    }
    func open(_ url: URL) {
        guard !isClearingWebsiteData else { return }
        suspendSelected(); selected.address = url.absoluteString; selected.openAddress()
    }
    func addBookmark() {
        guard let url = selected.loadedURL else { return }
        _ = update { try $0.bookmark(url: url, title: selected.pageTitle) }
    }
    func renameBookmark(_ id: UUID, title: String) { _ = update { try $0.renameBookmark(id, title: title) } }
    func removeBookmark(_ id: UUID) { _ = update { $0.removeBookmark(id) } }
    func removeHistory(_ id: UUID) { _ = update { $0.removeHistory(id) } }
    func clearHistory() { _ = update { $0.clearHistory() } }
    func refreshWebsiteRecords() {
        websiteDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] records in
            self?.websiteRecords = records.sorted { $0.displayName < $1.displayName }
        }
    }
    func removeWebsiteData(_ records: [WKWebsiteDataRecord]) {
        guard !isClearingWebsiteData else { return }
        isClearingWebsiteData = true
        for session in sessions.values { session.cancel() }
        // Drop every live page before deleting its store so scripts cannot
        // immediately write the removed cookies/localStorage back.
        sessions.removeAll()
        selected = makeSession(id: library.selectedID)
        websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) { [weak self] in
            guard let self else { return }
            self.isClearingWebsiteData = false; self.refreshWebsiteRecords()
        }
    }
}
