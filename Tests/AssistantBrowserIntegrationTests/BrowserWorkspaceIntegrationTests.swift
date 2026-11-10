#if os(iOS) && canImport(XCTest)
import XCTest
import Combine
import UIKit
import WebKit
import AssistantBrowser
@testable import WoowAssistant

/// Hosted WebKit, real cookie-store APIs and real DOM state. HTML is loaded
/// locally with HTTPS identity URLs; no server, TLS override or model is used.
/// Installing a synthetic cookie does NOT cover form login, OAuth, MFA, or an
/// authenticated HTTP request. Reopening a store is not an App-relaunch test.
final class BrowserWorkspaceIntegrationTests: XCTestCase {
    @MainActor func testRetiredUnmaterializedSessionRejectsManualNavigation() async throws {
        let session = BrowserSession(dataStore: .nonPersistent())
        let target = try XCTUnwrap(URL(string: "https://research.example.invalid/retirement"))
        var calls = 0
        session.manualNavigation(to: target) { calls += 1; return nil }
        XCTAssertEqual(calls, 1, "The same public-HTTPS manual operation is accepted before retirement")
        let first = await session.discardPageForDataRemoval()
        XCTAssertTrue(first)
        session.manualNavigation(to: target) { calls += 1; return nil }
        XCTAssertEqual(calls, 1, "Retirement must apply even before a WKWebView was materialized")
        let second = await session.discardPageForDataRemoval()
        XCTAssertTrue(second)
        session.manualNavigation(to: target) { calls += 1; return nil }
        XCTAssertEqual(calls, 1, "A repeated discard cannot revive the session")
    }

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
        // Observe this one production fetch separately from its domain predicate.
        // A missing record is not evidence that WebKit never called back.
        let enumeration = WebsiteRecordObservation()
        let recordObservation = workspace.$websiteRecords.dropFirst().sink { records in
            enumeration.publicationCount += 1
            enumeration.records = records
        }
        defer { recordObservation.cancel() }
        host.store.httpCookieStore.getAllCookies { cookies in
            // This isolated random store has only these synthetic cookies.
            // Never attach values, arbitrary domains, or unrelated cookie names.
            enumeration.nativeCookieNames = cookies.map(\.name).filter {
                ["workspace_cookie", "other_site_cookie"].contains($0)
            }.sorted()
        }
        workspace.refreshWebsiteRecords()
        do {
            try await waitUntil("Website-record callback did not publish within 15 seconds") { enumeration.records != nil }
            let returned = try XCTUnwrap(enumeration.records)
            guard returned.contains(where: {
                $0.displayName.contains("example.invalid") && $0.dataTypes.contains(WKWebsiteDataTypeCookies)
            }) else {
                XCTFail("Website-record callback returned without the expected synthetic cookie record")
                throw FixtureFailure.unexpectedWebsiteRecords
            }
            XCTAssertEqual(enumeration.publicationCount, 1, "One refresh must publish one actual WebKit result")
        } catch {
            let allowedNames = ["example.invalid", "research.example.invalid", "invalid", "example.org"]
            func recordMetadata(_ records: [WKWebsiteDataRecord]) -> [[String: Any]] {
                records.prefix(8).map { record in
                    ["name": allowedNames.contains(record.displayName) ? record.displayName :
                        (record.displayName.isEmpty ? "empty" : "other"),
                     "types": record.dataTypes.intersection(WKWebsiteDataStore.allWebsiteDataTypes()).sorted()]
                }
            }
            let metadata: [String: Any] = [
                "phase": "cookie_record_enumeration",
                "isRefreshingObserved": enumeration.records == nil,
                "callbackPublications": enumeration.publicationCount,
                "workspaceHasError": workspace.error != nil,
                "returnedCount": enumeration.records?.count ?? 0,
                "returnedRecords": recordMetadata(enumeration.records ?? []),
                "currentCount": workspace.websiteRecords.count,
                "currentRecords": recordMetadata(workspace.websiteRecords),
                "nativeCookieCallbackReturned": enumeration.nativeCookieNames != nil,
                "syntheticCookieNames": enumeration.nativeCookieNames ?? [],
                "reopenedProfileContainedSharedCookie": reopenedCookies.contains { $0.name == shared.name && $0.value == shared.value }
            ]
            let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
            let text = String(decoding: data, as: UTF8.self)
            let attachment = XCTAttachment(string: text)
            attachment.name = "synthetic-cookie-record-enumeration"
            attachment.lifetime = .keepAlways
            add(attachment)
            print("SYNTHETIC_COOKIE_RECORD_ENUMERATION " + text)
            throw error
        }
        let records = workspace.websiteRecords.filter { $0.displayName.contains("example.invalid") }
        XCTAssertFalse(records.isEmpty)
        XCTAssertTrue(records.allSatisfy { !$0.displayName.contains("example.org") })
        // BrowserView requests/mounts the new WKWebView as soon as selected
        // changes. Waiting until after removal to attach it missed the real
        // UI's overlap between new-process startup and data-store deletion.
        var replacementCount = 0
        let selection = workspace.$selected.dropFirst().sink { session in
            replacementCount += 1
            XCTAssertFalse(workspace.isClearingWebsiteData,
                           "Do not create a replacement WebKit view while website-data removal is pending")
            host.attach(session)
        }
        defer { selection.cancel() }
        // A new storage type written after the confirmation snapshot must
        // still be included by the post-quiescence enumeration.
        _ = try await javascript("localStorage.setItem('workspace_late_record', 'FIXTURE_LATE'); 'written'", in: secondWebView)
        let publicationsBeforeClear = enumeration.publicationCount
        workspace.refreshWebsiteRecords() // Its callback must be invalidated by the clear below.
        workspace.removeWebsiteData(records)
        XCTAssertTrue(workspace.isClearingWebsiteData)
        // A refresh initiated while deleting must not race the final verified list.
        workspace.refreshWebsiteRecords()
        do {
            // 1747c20 Large: both documents were blank by 35 ms, while WebKit's
            // persistent removeData callback arrived at 23.066 s. Bound only
            // this asynchronous deletion phase to the UI's 30-second budget.
            try await waitUntil("Website-record removal did not complete", timeout: 30) { !workspace.isClearingWebsiteData }
        } catch {
            // Preserve the state before teardown can interrupt a pending blank
            // navigation. Fixed fixture categories only, no cookie contents.
            let states = [firstWebView, secondWebView].enumerated().map { index, view in
                "tab=\(index);blank=\(view.url?.absoluteString == "about:blank");loading=\(view.isLoading);attached=\(view.window != nil);delegate=\(view.navigationDelegate != nil)"
            }.joined(separator: "\n")
            let attachment = XCTAttachment(string: "clearing=\(workspace.isClearingWebsiteData);error=\(workspace.error != nil)\n" + states)
            attachment.lifetime = .keepAlways
            add(attachment)
            throw error
        }
        XCTAssertNil(workspace.error, "Quiescence failure must not be mistaken for completed record removal")
        XCTAssertEqual(enumeration.publicationCount, publicationsBeforeClear + 1,
                       "Only the verified final records may publish after clearing starts")
        XCTAssertEqual(replacementCount, 1, "Mount exactly one replacement after the actual removeData callback")
        XCTAssertNil(second.interactionProposal)
        XCTAssertNil(second.controlSnapshot)
        // Keep the old views alive: removing Swift session references alone
        // does not stop an existing document from writing into its shared store.
        for oldView in [firstWebView, secondWebView] {
            XCTAssertEqual(oldView.url?.absoluteString, "about:blank")
            let oldDocument = try await javascript("document.getElementById('note') === null ? 'cleared' : 'still-live'", in: oldView)
            XCTAssertEqual(oldDocument, "cleared")
        }
        // A retained old session cannot reopen the site after its navigation
        // delegates have been detached, even through the shared manual seam.
        for oldSession in [first, second] {
            var navigationInvoked = false
            oldSession.manualNavigation(to: URL(string: "https://research.example.invalid/revive")!) {
                navigationInvoked = true
                return nil
            }
            XCTAssertFalse(navigationInvoked, "A retired session must not execute another navigation")
            XCTAssertNil(oldSession.current)
            XCTAssertNil(oldSession.loadedURL)
            XCTAssertFalse(oldSession.canGoBack)
            XCTAssertFalse(oldSession.canGoForward)
            XCTAssertEqual(oldSession.webView.url?.absoluteString, "about:blank")
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
        let lateStorage = try await javascript("localStorage.getItem('workspace_late_record') === null ? 'absent' : 'retained'", in: replacement.webView)
        XCTAssertEqual(lateStorage, "absent", "Clear must include storage types added after the original record snapshot")
        XCTAssertFalse(workspace.websiteRecords.contains { $0.displayName.contains("example.invalid") },
                       "Published completion must reflect verified removal, not a stale enumeration")
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

    @MainActor func testDeferredApprovedInputStaysRestrictedUntilExplicitManualDocumentCommits() async throws {
        let host = try Host()
        addTeardownBlock { await host.close() }
        let browser = host.attachSelected()
        let callback = URL(string: "https://research.example.invalid/oauth/callback?code=FIXTURE_LATE")!
        XCTAssertTrue(BrowserManualNavigationPolicy.allows(callback))
        XCTAssertThrowsError(try WebsiteOrigin(url: callback))

        for cancelAfterCompletion in [false, true] {
            try await host.load(browser, path: "/deferred-navigation-\(cancelAfterCompletion)", marker: "延遲導覽測試")
            // A real approved input event queues page work. The test releases
            // that work after completion/cancellation instead of racing timers.
            _ = try await javascript("""
                window.releaseDeferredNavigation = null;
                document.getElementById('note').addEventListener('input', function() {
                    window.releaseDeferredNavigation = function() { location.href = '\(callback.absoluteString)'; };
                }, {once: true});
                'armed'
                """, in: browser.webView)
            let proposal = try await proposeTyping(in: browser, text: "已核准的輸入")
            browser.approveInteraction(id: proposal.id)
            try await waitUntil("Approved DOM input did not finish") { !browser.isInteracting }
            XCTAssertNil(browser.interactionError)
            let queued = try await javascript("typeof window.releaseDeferredNavigation", in: browser.webView)
            XCTAssertEqual(queued, "function", "The actual approved input must have queued the callback")
            guard queued == "function" else { throw FixtureFailure.unexpectedJavaScriptValue }
            if cancelAfterCompletion { browser.cancel() }
            XCTAssertTrue(browser.automationOwnsDocument, "Completion and cancellation must preserve document restrictions")

            let probe = DeferredNavigationProbe(browser: browser, target: callback)
            browser.webView.navigationDelegate = probe
            defer { browser.webView.navigationDelegate = browser }
            _ = try await javascript("window.releaseDeferredNavigation(); 'released'", in: browser.webView)
            try await waitUntil("WebKit did not deliver the deferred navigation action") { probe.decision != nil }
            XCTAssertEqual(probe.navigationType, .other)
            let decision = try XCTUnwrap(probe.decision)
            let evidence = XCTAttachment(string: "afterCancel=\(cancelAfterCompletion); real WK action policy=\(decision.rawValue); external request cancelled by probe")
            evidence.lifetime = .keepAlways
            add(evidence)
            XCTAssertEqual(decision, .cancel)
            XCTAssertTrue(browser.automationOwnsDocument)

            browser.webView.navigationDelegate = browser
            let manual = URL(string: "https://research.example.invalid/oauth/callback?code=FIXTURE_MANUAL_\(cancelAfterCompletion)")!
            try await host.load(browser, url: manual, marker: "已返回手動瀏覽", manualOnly: true, explicitManual: true)
            XCTAssertFalse(browser.automationOwnsDocument, "Only the explicit navigation's real commit releases ownership")
            let oldWork = try await javascript("typeof window.releaseDeferredNavigation", in: browser.webView)
            XCTAssertEqual(oldWork, "undefined", "Returning to manual browsing must replace the old document")
            let manualProbe = DeferredNavigationProbe(browser: browser, target: callback)
            browser.webView.navigationDelegate = manualProbe
            _ = try await javascript("location.href = '\(callback.absoluteString)'; 'released'", in: browser.webView)
            try await waitUntil("Manual document did not deliver its navigation") { manualProbe.decision != nil }
            XCTAssertEqual(manualProbe.decision, .allow, "The new manual document can navigate to ordinary HTTPS login callbacks")
            browser.webView.navigationDelegate = browser
        }
    }

    @MainActor private final class DeferredNavigationProbe: NSObject, WKNavigationDelegate {
        let browser: BrowserSession
        let target: URL
        private(set) var decision: WKNavigationActionPolicy?
        private(set) var navigationType: WKNavigationType?
        init(browser: BrowserSession, target: URL) { self.browser = browser; self.target = target }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.request.url == target, action.targetFrame?.isMainFrame == true else {
                decisionHandler(.cancel); return
            }
            navigationType = action.navigationType
            // Use the actual WebKit-created action and production Session
            // decision. Always stop here, so the fixture sends no external HTTP.
            browser.webView(webView, decidePolicyFor: action) { [weak self] policy in
                self?.decision = policy
                decisionHandler(.cancel)
            }
        }
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

    @MainActor private func waitUntil(_ message: String, timeout: TimeInterval = 15, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard condition() else { XCTFail(message); throw FixtureFailure.deadline }
    }

    @MainActor private final class WebsiteRecordObservation {
        var records: [WKWebsiteDataRecord]?
        var publicationCount = 0
        var nativeCookieNames: [String]?
    }

    private enum FixtureFailure: Error { case unavailableStorage, deadline, unexpectedJavaScriptValue, unexpectedWebsiteRecords }

    @MainActor private final class Host {
        let namespace = UUID()
        let storeID = UUID()
        private var storedStore: WKWebsiteDataStore?
        var store: WKWebsiteDataStore { storedStore! }
        private(set) var workspace: BrowserWorkspace?
        private var sessions: [BrowserSession] = []
        private let window: UIWindow
        private let controller = UIViewController()
        private let previousKeyWindow: UIWindow?
        private var loadedFirstDocument = false

        init() throws {
            // Never use/reset the personal vault or WKWebsiteDataStore.default().
            let dataStore = WKWebsiteDataStore(forIdentifier: storeID)
            storedStore = dataStore
            workspace = BrowserWorkspace(dataStore: dataStore,
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
            attach(workspace!.selected)
        }

        @discardableResult func attach(_ session: BrowserSession) -> BrowserSession {
            if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
            controller.view = session.webView
            return session
        }

        func load(_ browser: BrowserSession, path: String, marker: String) async throws {
            try await load(browser, url: URL(string: "https://research.example.invalid" + path)!, marker: marker)
        }

        func load(_ browser: BrowserSession, url: URL, marker: String, manualOnly: Bool = false, explicitManual: Bool = false) async throws {
            let html = """
            <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>\(marker)</title></head>
            <body><p>\(marker)</p><label for="note">測試欄位</label><input id="note" type="text" value="原始值">
            <a href="https://research.example.invalid/oauth/callback?code=FIXTURE_ONLY#session=FIXTURE_ONLY">手動登入返回頁面</a></body></html>
            """
            if explicitManual {
                let wasOwned = browser.automationOwnsDocument
                var navigation: WKNavigation?
                browser.manualNavigation(to: url) {
                    navigation = browser.webView.loadHTMLString(html, baseURL: url)
                    return navigation
                }
                _ = try XCTUnwrap(navigation)
                if wasOwned { XCTAssertTrue(browser.automationOwnsDocument, "Issuing a request must not release the old document") }
            } else {
                _ = try XCTUnwrap(browser.webView.loadHTMLString(html, baseURL: url))
            }
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
            // A failed 15s assertion can leave the production removal Task in
            // its second per-tab 10s discard. Do not remove its delegate or
            // profile while that Task still owns the sessions/store. This is
            // failure cleanup only; it cannot turn the original failure green.
            if workspace?.isClearingWebsiteData == true {
                let deadline = ProcessInfo.processInfo.systemUptime + Double(max(1, sessions.count) * 10)
                while workspace?.isClearingWebsiteData == true, ProcessInfo.processInfo.systemUptime < deadline {
                    try? await Task.sleep(nanoseconds: 20_000_000)
                }
                XCTAssertFalse(workspace?.isClearingWebsiteData == true, "Website removal remained active during fixture cleanup")
            }
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
            storedStore = nil
            // Release the profile and all views before asking WebKit to remove
            // its NetworkProcess-backed profile; do not retry or extend waits.
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async { continuation.resume() }
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
