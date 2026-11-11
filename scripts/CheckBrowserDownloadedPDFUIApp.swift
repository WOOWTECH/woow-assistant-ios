import Foundation
import CryptoKit
import WebKit
import AssistantBrowser
import AssistantSkills
import AssistantPersistence
#if os(macOS)
import AppKit
#endif

#if BROWSER_DOWNLOADED_PDF_UI_APP_STANDALONE && os(macOS)
@main enum BrowserDownloadedPDFUIAppChecks {
    struct Failure: Error { let check: String }
    @MainActor final class Counter {
        var count = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(check: name) }; count += 1
        }
    }
    private final class Keys: LearningKeyStore {
        var values: [String: Data] = [:]
        func read(id: String) throws -> Data? { values[id] }
        func insert(_ value: Data, id: String) throws { values[id] = value }
        func remove(id: String) throws { values.removeValue(forKey: id) }
        func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
    }
    @MainActor static func wait(_ name: String, _ condition: () -> Bool) async throws {
        let end = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 20_000_000) }
        guard condition() else { throw Failure(check: name) }
    }
    @MainActor static func fixtureFlow() async throws -> Int {
        let c = Counter()
        let flags = ["-UITestMode", "-UITestNamespace", UUID().uuidString, "-UITestBrowserDownloadedPDF"]
        #if DEBUG
        let invalidCases: [[String]] = [[], ["-UITestMode"], ["-UITestBrowserDownloadedPDF"], flags + ["-UITestMode"],
                        flags + ["-UITestNamespace", UUID().uuidString], flags + ["-UITestBrowserDownloadedPDF"],
                        ["-UITestMode", "-UITestNamespace", "bad", "-UITestBrowserDownloadedPDF"],
                        flags + ["-LiveModelUITest"], flags + ["-LiveMCPUITest"], flags + ["-UITestBrowserUpload"],
                        flags + ["-UITestBrowserLogin"], flags + ["-UITestBrowserNetwork"], flags + ["-UITestSkillExecution"],
                        flags + ["-UITestResetStorage", "-UITestResetStorage"]]
        for invalid in invalidCases {
            try c.check(BrowserDownloadedPDFFixture(arguments: invalid) == nil, "strict fixture gate rejects ambiguous or other mode")
        }
        try c.check(BrowserDownloadedPDFFixture(arguments: flags) != nil, "exact gate admits fixture")
        guard let server = BrowserDownloadedPDFFixture.enabled else { throw Failure(check: "isolated process fixture") }
        let alias = URL(string: "http://127.0.0.1:1/download-pdf/file.pdf")!
        try c.check(!server.allowsNavigation(alias) && !server.allowsDownload(alias), "no allowance before listener starts")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-pdf-ui-app-" + UUID().uuidString)
        defer { server.stop(); try? FileManager.default.removeItem(at: root) }
        let vault = EncryptedLearningFile(url: root.appendingPathComponent("library.vault"), keys: Keys())
        let workspace = BrowserWorkspace(dataStore: .nonPersistent(), vault: vault, downloadDirectory: root.appendingPathComponent("Downloads"))
        try c.check(workspace.available && workspace.downloads.items.isEmpty, "isolated real workspace starts empty")
        let view = workspace.selected.webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view; defer { view.stopLoading(); window.orderOut(nil) }
        workspace.activateSelected() // Same hook as the actual browser screen; opens only a page.
        try await wait("actual fixture page finishes", { workspace.selected.loadedURL != nil })
        let page = try await server.start()
        try c.check(workspace.selected.loadedURL == page && workspace.downloads.items.isEmpty, "opening page seeds no download")
        let file = page.deletingLastPathComponent().appendingPathComponent("file.pdf")
        try c.check(server.allowsNavigation(page) && !server.allowsDownload(page) && server.allowsDownload(file), "page cannot be downloaded via exception")
        let rejectedURLs: [String] = [file.absoluteString + "?x=1", file.absoluteString + "#x", file.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
                    file.absoluteString.replacingOccurrences(of: "http://", with: "http://u:p@"),
                    file.absoluteString.replacingOccurrences(of: "/file.pdf", with: "/%66ile.pdf"),
                    file.absoluteString.replacingOccurrences(of: server.namespace.uuidString.lowercased(), with: UUID().uuidString.lowercased()),
                    "http://127.0.0.1:1" + file.path, file.absoluteString.replacingOccurrences(of: "http://", with: "https://")]
        for raw in rejectedURLs {
            let bad = URL(string: raw)!
            try c.check(!server.allowsNavigation(bad) && !server.allowsDownload(bad), "URL identity aliases rejected")
            var intent = BrowserNavigationIntent(); intent.beginManual(bad)
            try c.check(!intent.authorizeDownload(bad, source: .action(NSObject())), "navigation intent does not admit alias")
        }
        let client = URLSession(configuration: .ephemeral); defer { client.invalidateAndCancel() }
        for (suffix, method, code) in [("?unexpected=1", "GET", 404), ("", "POST", 405)] {
            var request = URLRequest(url: URL(string: file.absoluteString + suffix)!); request.httpMethod = method; request.timeoutInterval = 10
            let (_, response) = try await client.data(for: request)
            try c.check((response as? HTTPURLResponse)?.statusCode == code && server.transferCount == 0, "actual fixture HTTP rejects wrong route/method before any PDF transfer")
        }
        var intent = BrowserNavigationIntent(); intent.beginManual(file)
        let issuer = NSObject(), stale = NSObject()
        try c.check(intent.authorizeDownload(file, source: .action(issuer)), "exact fixture navigation can request a permit")
        try c.check(!intent.consumeDownload(file, source: .action(stale)), "stale issuer cannot consume fixture permit")
        try c.check(intent.consumeDownload(file, source: .action(issuer)) && !intent.consumeDownload(file, source: .action(issuer)), "real-issuer identity and one-use fence retained")
        _ = try await view.evaluateJavaScript("document.querySelector('a[download]').click(); true")
        try await wait("actual BrowserSession WKDownload completion", { workspace.downloads.items.contains { $0.status == .completed } })
        try c.check(server.transferCount == 1 && workspace.downloads.items.count == 1, "one real HTTP transfer through production browser callbacks")
        let item = workspace.downloads.items[0]
        try c.check(item.fileName == server.filename, "actual response supplies isolated filename")
        let selection = try BrowserDownloadedPDFSelection(manager: workspace.downloads, userSelectedID: item.id)
        let model = SkillExecutionViewModel(downloadedPDF: selection); defer { model.clear() }
        try c.check(model.downloadUIAudit?.reads == 0 && model.uiTestFixture == nil && model.uiTestAudit == nil, "download audit is not picker audit")
        model.prepareDownload(pages: "", password: "", metadataOnly: false, worker: nil)
        guard let plan = model.plan else { throw Failure(check: "actual downloaded plan") }
        try c.check(model.result == nil && model.downloadUIAudit?.reads == 0, "plan grants no read")
        model.execute(stepID: plan.steps[0].id)
        if let task = model.executingTask { await task.value }
        try c.check(model.downloadUIAudit?.reads == 1 && model.downloadUIAudit?.extractions == 0 && model.result == nil, "first explicit approval only reads")
        model.execute(stepID: plan.steps[1].id)
        if let task = model.executingTask { await task.value }
        guard let result = model.result else { throw Failure(check: "actual PDFKit result") }
        let digest = SHA256.hash(data: BrowserDownloadedPDFFixture.payload).map { String(format: "%02x", $0) }.joined()
        try c.check(result.inputSHA256 == digest && result.engine == "Apple PDFKit", "extraction matches real HTTP payload")
        try c.check(result.text == "--- page 1 ---\nWOOW_DOWNLOADED_PDF_ALPHA\n\n--- page 2 ---\nWOOW_DOWNLOADED_PDF_BETA\n", "exact PDFKit text and page order")
        try c.check(model.downloadUIAudit?.reads == 1 && model.downloadUIAudit?.extractions == 1 && model.downloadUIAudit?.results == 1, "readonly audit counts actual caller dispatches")
        try workspace.downloads.delete(id: item.id, confirmed: true)
        try c.check(model.plan == nil && model.result == nil && !selection.isValid, "real manager deletion revokes caller")
        // Even a legitimate fixture route cannot become an automated/research
        // URL. Exercise the real App admission guard, not just a policy label.
        do { _ = try await workspace.selected.inspect(); throw Failure(check: "research admitted loopback") }
        catch WebResearchError.noPage { c.count += 1 }
        server.stop()
        try c.check(!server.allowsNavigation(page) && !server.allowsDownload(file), "stopped fixture revokes exact URLs")
        return c.count
        #else
        try c.check(BrowserDownloadedPDFFixture.enabled == nil && BrowserDownloadedPDFFixture(arguments: flags) == nil, "Release fixture remains unavailable")
        let local = URL(string: "http://127.0.0.1:1/download-pdf/file.pdf")!
        var intent = BrowserNavigationIntent(); intent.beginManual(local)
        try c.check(!intent.authorizeDownload(local, source: .action(NSObject())), "Release never adds loopback permission")
        return c.count
        #endif
    }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let groups: [String: Int] = ["actualBrowserFixture": try await fixtureFlow(),
                    "realDownloadAndApprovals": try await BrowserDownloadedPDFAppChecks.realDownloadAndApprovals(),
                    "invalidSourcesAndLimits": try await BrowserDownloadedPDFAppChecks.invalidSourcesAndLimits(),
                    "deletionAndHeldRead": try await BrowserDownloadedPDFAppChecks.deletionAndHeldRead(),
                    "lateWorkerAndDisclosure": try await BrowserDownloadedPDFAppChecks.lateWorkerAndDisclosure()]
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["groups": groups,"passed":groups.values.reduce(0,+),"failed":0,"native_ui":false,"external_or_model_requests":0],options:.sortedKeys),as:UTF8.self));exit(0)
            } catch { print("FAIL " + ((error as? Failure)?.check ?? (error as? BrowserDownloadedPDFAppChecks.Failure)?.check ?? "fixture flow"));exit(1) }
        }
        app.run()
    }
}
#endif
