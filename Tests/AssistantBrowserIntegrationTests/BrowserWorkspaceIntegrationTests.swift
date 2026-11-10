#if os(iOS) && canImport(XCTest)
import XCTest
import UIKit
import WebKit
import AssistantBrowser
@testable import WoowAssistant

/// Hosted WebKit, real cookie-store APIs and real DOM state. HTML is loaded
/// locally with HTTPS identity URLs; no server, TLS override or model is used.
/// Installing a synthetic cookie does NOT cover form login, OAuth, MFA, or an
/// authenticated HTTP request. Reopening a store is not an App-relaunch test.
final class BrowserWorkspaceIntegrationTests: XCTestCase {
    @MainActor func testPersistentCookiesAreSharedAndRemovingOneRecordPreservesOtherSites() async throws {
        let host = try Host()
        addTeardownBlock { await host.close() }
        let workspace = try XCTUnwrap(host.workspace)
        let first = host.attachSelected()
        let firstWebView = first.webView
        XCTAssertTrue(workspace.websiteDataStore === host.store, "Injected store must override the test-argument store")
        XCTAssertTrue(host.store.isPersistent)
        XCTAssertEqual(firstWebView.configuration.websiteDataStore.identifier, host.storeID)
        XCTAssertNotEqual(host.storeID, host.namespace)

        let shared = try cookie(name: "workspace_cookie", domain: "research.example.invalid", value: "FIXTURE_SHARED")
        let unrelated = try cookie(name: "other_site_cookie", domain: "example.org", value: "FIXTURE_OTHER")
        await setCookie(shared, in: firstWebView.configuration.websiteDataStore)
        await setCookie(unrelated, in: host.store)
        try await host.load(first, path: "/workspace-one", marker: "第一個分頁")
        let firstCookie = try await javascript("document.cookie", in: firstWebView)
        XCTAssertTrue(firstCookie.contains("workspace_cookie=FIXTURE_SHARED"))

        workspace.newTab()
        let second = host.attachSelected()
        let secondWebView = second.webView
        XCTAssertFalse(first === second)
        XCTAssertFalse(firstWebView === secondWebView)
        XCTAssertEqual(secondWebView.configuration.websiteDataStore.identifier, host.storeID)
        try await host.load(second, path: "/workspace-two", marker: "第二個分頁")
        let secondCookie = try await javascript("document.cookie", in: secondWebView)
        XCTAssertTrue(secondCookie.contains("workspace_cookie=FIXTURE_SHARED"))

        // Reacquire the same persistent profile, without copying cookies.
        let reopened = WKWebsiteDataStore(forIdentifier: host.storeID)
        let reopenedCookies = await cookies(in: reopened)
        XCTAssertTrue(reopenedCookies.contains { $0.name == shared.name && $0.value == shared.value })
        let isolated = WKWebsiteDataStore.nonPersistent()
        let isolatedCookies = await cookies(in: isolated)
        XCTAssertFalse(isolatedCookies.contains { $0.name == shared.name })

        let pending = try await proposeTyping(in: second, text: "不得在清除後寫入")
        workspace.refreshWebsiteRecords()
        try await waitUntil("Cookie records were not returned") {
            workspace.websiteRecords.contains { $0.displayName.contains("example.invalid") && $0.dataTypes.contains(WKWebsiteDataTypeCookies) }
        }
        let records = workspace.websiteRecords.filter { $0.displayName.contains("example.invalid") }
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { !$0.displayName.contains("example.org") })
        workspace.removeWebsiteData(records)
        XCTAssertTrue(workspace.isClearingWebsiteData)
        try await waitUntil("Website-record removal did not complete") { !workspace.isClearingWebsiteData }
        XCTAssertNil(workspace.error, "Quiescence failure must not be mistaken for completed record removal")
        XCTAssertNil(second.interactionProposal)
        XCTAssertNil(second.controlSnapshot)
        // Keep the old views alive: removing Swift session references alone
        // does not stop an existing document from writing into its shared store.
        for oldView in [firstWebView, secondWebView] {
            XCTAssertEqual(oldView.url?.absoluteString, "about:blank")
            let oldDocument = try await javascript("document.getElementById('note') === null ? 'cleared' : 'still-live'", in: oldView)
            XCTAssertEqual(oldDocument, "cleared")
        }
        let remaining = await cookies(in: host.store)
        XCTAssertFalse(remaining.contains { $0.name == shared.name }, "The selected site's cookie must actually be removed")
        XCTAssertTrue(remaining.contains { $0.name == unrelated.name && $0.value == unrelated.value }, "Record deletion must not clear every site")

        let replacement = host.attachSelected()
        XCTAssertFalse(replacement === first)
        XCTAssertFalse(replacement === second)
        XCTAssertFalse(replacement.webView === firstWebView)
        XCTAssertFalse(replacement.webView === secondWebView)
        XCTAssertEqual(replacement.webView.configuration.websiteDataStore.identifier, host.storeID)
        second.approveInteraction(id: pending.id)
        XCTAssertFalse(second.isInteracting)
        XCTAssertEqual(second.interactionError, BrowserInteractionError.approvalRequired.message)
        try await host.load(replacement, path: "/workspace-after-clear", marker: "網站資料已清除")
        let afterRemoval = try await javascript("document.cookie", in: replacement.webView)
        XCTAssertFalse(afterRemoval.contains("workspace_cookie="))
    }

    @MainActor func testTabsRetainDifferentDocumentsAndSwitchingOrClosingRevokesProposals() async throws {
        let host = try Host()
        addTeardownBlock { await host.close() }
        let workspace = try XCTUnwrap(host.workspace)
        let firstID = workspace.library.selectedID
        let first = host.attachSelected()
        let firstWebView = first.webView
        try await host.load(first, path: "/workspace-one", marker: "第一份文件")
        _ = try await javascript("window.workspaceMarker='FIRST'; document.getElementById('note').value='第一份手動編輯'; 'ok'", in: firstWebView)
        let firstProposal = try await proposeTyping(in: first, text: "不得跨分頁執行")
        let firstDocumentID = try XCTUnwrap(first.controlSnapshot?.documentID)

        workspace.newTab()
        XCTAssertNil(first.interactionProposal)
        XCTAssertNil(first.controlSnapshot)
        let secondID = workspace.library.selectedID
        let second = host.attachSelected()
        let secondWebView = second.webView
        XCTAssertNotEqual(firstID, secondID)
        XCTAssertFalse(first === second)
        XCTAssertFalse(firstWebView === secondWebView)
        try await host.load(second, path: "/workspace-two", marker: "第二份文件")
        _ = try await javascript("window.workspaceMarker='SECOND'; document.getElementById('note').value='第二份手動編輯'; 'ok'", in: secondWebView)
        let secondProposal = try await proposeTyping(in: second, text: "不得在切換後執行")
        let secondDocumentID = try XCTUnwrap(second.controlSnapshot?.documentID)
        XCTAssertNotEqual(firstDocumentID, secondDocumentID)

        workspace.selectTab(firstID)
        XCTAssertTrue(host.attachSelected() === first)
        XCTAssertTrue(workspace.selected.webView === firstWebView)
        XCTAssertNil(second.interactionProposal)
        XCTAssertNil(second.controlSnapshot)
        first.approveInteraction(id: firstProposal.id)
        XCTAssertFalse(first.isInteracting)
        XCTAssertEqual(first.interactionError, BrowserInteractionError.approvalRequired.message)
        let firstState = try await javascript("window.workspaceMarker+'|'+document.getElementById('note').value", in: firstWebView)
        XCTAssertEqual(firstState, "FIRST|第一份手動編輯", "Selecting a tab must not recreate or reload its document")
        let firstSnapshot = try await first.snapshotControls()
        XCTAssertEqual(firstSnapshot.documentID, firstDocumentID)

        workspace.selectTab(secondID)
        XCTAssertTrue(host.attachSelected() === second)
        XCTAssertTrue(workspace.selected.webView === secondWebView)
        second.approveInteraction(id: secondProposal.id)
        XCTAssertEqual(second.interactionError, BrowserInteractionError.approvalRequired.message)
        let secondState = try await javascript("window.workspaceMarker+'|'+document.getElementById('note').value", in: secondWebView)
        XCTAssertEqual(secondState, "SECOND|第二份手動編輯")
        let closingProposal = try await proposeTyping(in: second, text: "不得在關閉後執行")
        XCTAssertEqual(second.controlSnapshot?.documentID, secondDocumentID)

        workspace.closeTab(secondID)
        XCTAssertEqual(workspace.library.tabs.map(\.id), [firstID])
        XCTAssertTrue(host.attachSelected() === first)
        XCTAssertNil(second.interactionProposal)
        XCTAssertNil(second.controlSnapshot)
        XCTAssertFalse(second.isRunning)
        second.approveInteraction(id: closingProposal.id)
        XCTAssertFalse(second.isInteracting)
        XCTAssertEqual(second.interactionError, BrowserInteractionError.approvalRequired.message)
        // Retain the closed view deliberately: the revoked proposal must not
        // mutate even a still-live old document when its ID is replayed.
        let closedState = try await javascript("document.getElementById('note').value", in: secondWebView)
        XCTAssertEqual(closedState, "第二份手動編輯")
        let survivingState = try await javascript("document.getElementById('note').value", in: firstWebView)
        XCTAssertEqual(survivingState, "第一份手動編輯")
    }

    @MainActor func testManualCallbackPageLoadsButCannotBecomeAutomationEvidenceOrSavedURL() async throws {
        let host = try Host()
        addTeardownBlock { await host.close() }
        let workspace = try XCTUnwrap(host.workspace)
        let browser = host.attachSelected()
        let callback = URL(string: "https://research.example.invalid/oauth/callback?code=FIXTURE_ONLY#session=FIXTURE_ONLY")!
        XCTAssertTrue(BrowserManualNavigationPolicy.allows(callback))
        XCTAssertThrowsError(try WebsiteOrigin(url: callback))
        XCTAssertNil(BrowserManualNavigationPolicy.libraryURL(callback))
        for address in ["http://research.example.invalid/login", "https://127.0.0.1/login", "https://user:password@research.example.invalid/login"] {
            XCTAssertFalse(BrowserManualNavigationPolicy.allows(URL(string: address)!))
        }

        try await host.load(browser, path: "/workspace-public", marker: "公開文件")
        let publicObservation = try await browser.inspect()
        XCTAssertFalse(publicObservation.links.contains { $0.url == callback }, "Manual-only callback link must not reach the readonly runner")
        XCTAssertTrue(publicObservation.links.isEmpty, "The fixture has only the excluded callback link")
        do {
            _ = try await browser.openLink(id: 0)
            XCTFail("The readonly runner must reject a link that was never exposed")
        } catch let error as WebResearchError {
            XCTAssertEqual(error, .unsafeNavigation)
        }

        // A real local WebKit navigation through the production delegates, not
        // a fabricated WKNavigationAction or simulated successful login.
        try await host.load(browser, url: callback, marker: "僅供手動瀏覽", manualOnly: true)
        XCTAssertEqual(browser.loadedURL, callback)
        XCTAssertNil(browser.current)
        XCTAssertNil(browser.controlSnapshot)
        XCTAssertNil(browser.interactionProposal)
        do {
            _ = try await browser.inspect()
            XCTFail("Manual callback contents must not become model evidence")
        } catch let error as WebResearchError {
            XCTAssertEqual(error, .noPage)
        }
        do {
            _ = try await browser.snapshotControls()
            XCTFail("Manual-only pages must not offer automation proposals")
        } catch let error as BrowserInteractionError {
            XCTAssertEqual(error, .noSnapshot)
        }
        workspace.addBookmark()
        XCTAssertTrue(workspace.library.bookmarks.isEmpty)
        let tab = try XCTUnwrap(workspace.library.tabs.first { $0.id == workspace.library.selectedID })
        XCTAssertNil(tab.url)
        XCTAssertFalse(workspace.library.history.contains { $0.url == callback })
        let retained = String(decoding: try JSONEncoder().encode(workspace.library), as: UTF8.self)
        XCTAssertFalse(retained.contains("FIXTURE_ONLY"))

        try await host.load(browser, path: "/workspace-return", marker: "回到公開文件")
        XCTAssertNotNil(browser.current)
        let controls = try await browser.snapshotControls()
        XCTAssertTrue(controls.controls.contains { $0.label == "測試欄位" })
    }

    @MainActor private func proposeTyping(in browser: BrowserSession, text: String) async throws -> BrowserInteractionProposal {
        let snapshot = try await browser.snapshotControls()
        let control = try XCTUnwrap(snapshot.controls.first { $0.label == "測試欄位" && $0.kind == .text })
        return try browser.proposeInteraction(.init(documentID: snapshot.documentID, snapshotID: snapshot.snapshotID,
            kind: .type, controlID: control.id, text: text))
    }

    private func cookie(name: String, domain: String, value: String) throws -> HTTPCookie {
        try XCTUnwrap(HTTPCookie(properties: [.domain: domain, .path: "/", .name: name,
            .value: value, .secure: "TRUE", .expires: Date().addingTimeInterval(3600)]))
    }

    @MainActor private func setCookie(_ cookie: HTTPCookie, in store: WKWebsiteDataStore) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.httpCookieStore.setCookie(cookie) { continuation.resume() }
        }
    }

    @MainActor private func cookies(in store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    @MainActor private func javascript(_ script: String, in webView: WKWebView) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            webView.evaluateJavaScript(script) { value, error in
                if let error { continuation.resume(throwing: error) }
                else if let text = value as? String { continuation.resume(returning: text) }
                else { continuation.resume(throwing: FixtureFailure.unexpectedJavaScriptValue) }
            }
        }
    }

    @MainActor private func waitUntil(_ message: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard condition() else { XCTFail(message); throw FixtureFailure.deadline }
    }

    private enum FixtureFailure: Error { case unavailableStorage, deadline, unexpectedJavaScriptValue }

    @MainActor private final class Host {
        let namespace = UUID()
        let storeID = UUID()
        let store: WKWebsiteDataStore
        private(set) var workspace: BrowserWorkspace?
        private var sessions: [BrowserSession] = []
        private let window: UIWindow
        private let controller = UIViewController()
        private let previousKeyWindow: UIWindow?
        private var loadedFirstDocument = false

        init() throws {
            // Never use/reset the personal vault or WKWebsiteDataStore.default().
            store = WKWebsiteDataStore(forIdentifier: storeID)
            workspace = BrowserWorkspace(dataStore: store,
                arguments: ["-UITestMode", "-UITestNamespace", namespace.uuidString])
            XCTAssertTrue(workspace?.available == true, "The isolated test vault must be usable")
            guard workspace?.available == true else { throw FixtureFailure.unavailableStorage }
            XCTAssertNotEqual(UIApplication.shared.applicationState, .background)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }

        @discardableResult func attachSelected() -> BrowserSession {
            let session = workspace!.selected
            if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
            controller.view = session.webView
            return session
        }

        func load(_ browser: BrowserSession, path: String, marker: String) async throws {
            try await load(browser, url: URL(string: "https://research.example.invalid" + path)!, marker: marker)
        }

        func load(_ browser: BrowserSession, url: URL, marker: String, manualOnly: Bool = false) async throws {
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(marker)</title></head>
            <body><p>\(marker)</p><label for="note">測試欄位</label><input id="note" type="text" value="原始值">
            <a href="https://research.example.invalid/oauth/callback?code=FIXTURE_ONLY#session=FIXTURE_ONLY">手動登入返回頁面</a></body></html>
            """
            _ = try XCTUnwrap(browser.webView.loadHTMLString(html, baseURL: url))
            // Same first-document bound as the existing hosted WebKit fixtures;
            // warm transitions are 15s, no retries or fixed settling delays.
            let deadline = ProcessInfo.processInfo.systemUptime + (loadedFirstDocument ? 15 : 75)
            let expectedStatus = manualOnly ? "頁面已載入；此頁面僅供手動瀏覽" : "頁面已載入"
            while (browser.loadedURL != url || browser.pageTitle != marker || browser.status != expectedStatus),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            XCTAssertEqual(browser.loadedURL, url)
            XCTAssertEqual(browser.pageTitle, marker)
            XCTAssertEqual(browser.status, expectedStatus)
            XCTAssertNil(browser.error)
            guard browser.loadedURL == url, browser.pageTitle == marker, browser.status == expectedStatus else {
                throw FixtureFailure.deadline
            }
            loadedFirstDocument = true
        }

        func close() async {
            workspace?.cancelAllWork()
            for session in sessions {
                session.cancel()
                session.webView.navigationDelegate = nil
                session.webView.uiDelegate = nil
                session.webView.removeFromSuperview()
            }
            controller.view = UIView()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
            sessions.removeAll()
            workspace = nil
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {
                    continuation.resume()
                }
            }
            // Only this test's random profile IDs and encrypted-vault key service.
            for identifier in [storeID, namespace] {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    WKWebsiteDataStore.remove(forIdentifier: identifier) { error in
                        XCTAssertNil(error, "Isolated WebKit profile cleanup failed")
                        continuation.resume()
                    }
                }
            }
            do {
                let scope = "test-" + namespace.uuidString
                let root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                    appropriateFor: nil, create: false)
                for category in ["BrowserLibrary", "BrowserDownloads"] {
                    let directory = root.appendingPathComponent(category + "/" + scope, isDirectory: true)
                    if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
                }
                try LearningKeychainStore(service: "io.woowtech.assistant.browser.library." + scope).removeAll(except: "unused-fixture-key")
            } catch { XCTFail("Isolated browser-library cleanup failed") }
        }
    }
}
#endif
