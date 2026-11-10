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
    let downloads: BrowserDownloadManager
    #if DEBUG
    private var uploadFixtureStarted = false
    private var loginFixtureStarted = false
    #endif

    init(dataStore injectedDataStore: WKWebsiteDataStore? = nil,
         arguments: [String] = ProcessInfo.processInfo.arguments) {
        var dataStore = WKWebsiteDataStore.default()
        var scope = "personal"
        var reset = false
        var invalidTestScope = false
        #if DEBUG
        let args = arguments
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
        if let injectedDataStore { dataStore = injectedDataStore }
        websiteDataStore = dataStore
        let downloadRoot = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let downloadDirectory = downloadRoot.appendingPathComponent("BrowserDownloads/" + (invalidTestScope ? UUID().uuidString : scope), isDirectory: true)
        if reset { try? FileManager.default.removeItem(at: downloadDirectory) }
        downloads = BrowserDownloadManager(directory: downloadDirectory)
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
        #if DEBUG
        if !uploadFixtureStarted, let fixture = BrowserUploadFixture.enabled {
            uploadFixtureStarted = true
            Task { [weak self] in
                do {
                    let url = try await fixture.start()
                    guard let self else { return }
                    while self.isClearingWebsiteData { try await Task.sleep(nanoseconds: 50_000_000) }
                    self.open(url)
                } catch { self?.error = "測試上傳頁面未能啟動。" }
            }
            return
        }
        if !loginFixtureStarted, let fixture = BrowserLoginFixture.enabled {
            loginFixtureStarted = true
            Task { [weak self] in
                do {
                    let url = try await fixture.start()
                    guard let self else { return }
                    while self.isClearingWebsiteData { try await Task.sleep(nanoseconds: 50_000_000) }
                    self.open(url)
                } catch { self?.error = "測試登入頁面未能啟動。" }
            }
            return
        }
        #endif
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
        session.downloads = downloads
        session.canPresentUI = { [weak self] in self?.library.selectedID == id && self?.isClearingWebsiteData == false }
        session.address = library.tabs.first(where: { $0.id == id })?.url?.absoluteString ?? ""
        session.onPageFinished = { [weak self] url, title in
            #if DEBUG
            // Fixture HTTP pages exercise WebKit state, not the public-HTTPS
            // bookmark library. Do not invent persistent public URLs for them.
            if BrowserUploadFixture.enabled?.allows(url) == true || BrowserLoginFixture.enabled?.allows(url) == true { return }
            #endif
            _ = self?.update { try $0.visit(tab: id, url: url, title: title) }
        }
        session.onCreateWindow = { [weak self] configuration, request in
            guard let self, self.library.selectedID == id, !self.isClearingWebsiteData else { return nil }
            var newID: UUID?
            guard self.update({ newID = try $0.addTab() }), let newID else { return nil }
            self.selected.cancelInteraction()
            let popup = self.makeSession(id: newID, configuration: configuration)
            popup.prepareManualPopup(request)
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
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        let selectedNames = Set(records.map(\.displayName))
        var removalEvents: [[String: String]] = []
        // Only the strictly gated synthetic login fixture persists diagnostics.
        // Hosted tests receive the same bounded, value-free phases in stdout.
        let diagnosticURL = BrowserLoginFixture.enabled == nil ? nil : FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("BrowserWebsiteRemovalDiagnostics.json")
        func trace(_ phase: String, _ counts: [String: Int] = [:]) {
            guard removalEvents.count < 64 else { return }
            let elapsed = Int((ProcessInfo.processInfo.systemUptime - started) * 1_000)
            var event = counts.mapValues(String.init)
            event["phase"] = phase; event["elapsedMs"] = String(elapsed)
            removalEvents.append(event)
            print("BROWSER_WEBSITE_REMOVAL " + event.keys.sorted().map { "\($0)=\(event[$0]!)" }.joined(separator: " "))
            if let diagnosticURL,
               let data = try? JSONSerialization.data(withJSONObject: removalEvents, options: [.sortedKeys]),
               data.count <= 16_384 {
                do { try data.write(to: diagnosticURL, options: .atomic) }
                catch { print("BROWSER_WEBSITE_REMOVAL diagnosticWriteFailed=1") }
            }
        }
        trace("begin", ["records": records.count, "sessions": sessions.count,
                        "persistent": websiteDataStore.isPersistent ? 1 : 0])
        #endif
        isClearingWebsiteData = true
        for item in downloads.items where item.status.isActive { downloads.cancel(id: item.id) }
        let oldSessions = Array(sessions.values)
        for session in oldSessions { session.cancel() }
        Task { [weak self] in
            var ready = true
            for (index, session) in oldSessions.enumerated() {
                #if DEBUG
                trace("pageBegin", ["index": index])
                #endif
                let stopped = await session.discardPageForDataRemoval()
                if !stopped { ready = false }
                #if DEBUG
                trace("pageFinished", ["index": index, "stopped": stopped ? 1 : 0])
                #endif
            }
            guard let self else { return }
            self.sessions.removeAll()
            self.selected = self.makeSession(id: self.library.selectedID)
            #if DEBUG
            trace("sessionsReplaced", ["ready": ready ? 1 : 0])
            #endif
            guard ready else {
                self.error = "網頁尚未完全停止，網站資料未清除；請重試。"
                self.isClearingWebsiteData = false; return
            }
            #if DEBUG
            trace("removeRequested")
            #endif
            self.websiteDataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: records) { [weak self] in
                guard let self else { return }
                #if DEBUG
                trace("removeCompleted")
                if BrowserLoginFixture.enabled != nil {
                    self.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                        trace("fixtureCookies", ["remaining": cookies.filter { $0.name == BrowserLoginFixture.cookieName }.count])
                    }
                }
                #endif
                self.isClearingWebsiteData = false
                #if DEBUG
                self.websiteDataStore.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { [weak self] remaining in
                    self?.websiteRecords = remaining.sorted { $0.displayName < $1.displayName }
                    let selected = remaining.filter { selectedNames.contains($0.displayName) }
                    let classifiedTypes: Set<String> = [WKWebsiteDataTypeCookies, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeDiskCache]
                    trace("recordsRefreshed", ["allRecords": remaining.count, "selectedRecords": selected.count,
                                              "selectedCookieRecords": selected.filter { $0.dataTypes.contains(WKWebsiteDataTypeCookies) }.count,
                                              "selectedMemoryCacheRecords": selected.filter { $0.dataTypes.contains(WKWebsiteDataTypeMemoryCache) }.count,
                                              "selectedDiskCacheRecords": selected.filter { $0.dataTypes.contains(WKWebsiteDataTypeDiskCache) }.count,
                                              "selectedOtherDataTypes": Set(selected.flatMap { $0.dataTypes }).subtracting(classifiedTypes).count])
                }
                #else
                self.refreshWebsiteRecords()
                #endif
            }
        }
    }
}
