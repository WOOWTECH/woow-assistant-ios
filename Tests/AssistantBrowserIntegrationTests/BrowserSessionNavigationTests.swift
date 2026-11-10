#if os(iOS) && canImport(XCTest)
import XCTest
import UIKit
import WebKit
import AssistantBrowser
import AssistantSkills
@testable import WoowAssistant

/// Real, locally rendered WebKit documents. Failure/late delegate callbacks
/// below are explicitly synthetic; no external request or model is involved.
final class BrowserSessionNavigationTests: XCTestCase {
    @MainActor func testTranscriptReadsBeyondResearchExcerptWithoutCapturingFormFields() async throws {
        let host = try Host(); defer { host.close() }
        _ = try await host.load(marker: "TRANSCRIPT START")
        _ = try await host.browser.webView.evaluateJavaScript("document.body.innerHTML='<p>'+('A'.repeat(9000))+'</p><p>COMPLETE_TAIL</p><textarea>PRIVATE_TEXTAREA</textarea><input value=PRIVATE_INPUT><p contenteditable>PRIVATE_EDITOR</p><p style=\"display:none\">PRIVATE_HIDDEN</p>'; true")
        let excerpt = try await host.browser.inspect()
        XCTAssertFalse(excerpt.text.contains("COMPLETE_TAIL"))
        let page = try await host.browser.textForTranscript()
        XCTAssertEqual(page.url, host.url)
        XCTAssertEqual(page.text, String(repeating: "A", count: 9000) + "\nCOMPLETE_TAIL")
        XCTAssertFalse(page.text.contains("PRIVATE_"))
        XCTAssertEqual(host.browser.current?.text, excerpt.text, "Full capture must not replace the research excerpt or navigation state")
    }

    @MainActor func testTranscriptRejectsOversizedUTF8AndUnloadedPagesInsteadOfTruncating() async throws {
        let host = try Host(); defer { host.close() }
        do { _ = try await host.browser.textForTranscript(); XCTFail("No page has been loaded") }
        catch let error as WebResearchError { XCTAssertEqual(error, .noPage) }
        _ = try await host.load(marker: "LARGE SOURCE")
        _ = try await host.browser.webView.evaluateJavaScript("document.body.innerHTML='<p>'+('字'.repeat(30000))+'</p>'; true")
        do { _ = try await host.browser.textForTranscript(); XCTFail("90,000 UTF-8 bytes cannot become a truncated success") }
        catch let error as TranscriptError { XCTAssertEqual(error, .tooLarge) }
        XCTAssertNotNil(host.browser.current)
    }

    @MainActor func testMalformedAddressDoesNotStartANormalizedNavigation() {
        let browser = BrowserSession(dataStore: .nonPersistent())
        for address in ["https://example.com:/", "https://example.com:999999999999999999999999/"] {
            browser.address = address
            browser.openAddress()
            XCTAssertNotNil(browser.error)
            XCTAssertNil(browser.current)
            XCTAssertNil(browser.webView.url)
            XCTAssertFalse(browser.webView.isLoading)
            XCTAssertEqual(browser.address, address)
        }
    }

    @MainActor func testSearchBeyondExcerptDoesNotClaimAbsenceFromWholePage() async throws {
        let host = try Host()
        defer { host.close() }
        _ = try await host.load(marker: "EXCERPT START")
        let sourceContainsMarker = try await host.browser.webView.evaluateJavaScript(
            "document.body.innerHTML='<p>'+('A'.repeat(9000))+'</p><p>ACTUAL_TAIL_MARKER</p>'; document.body.textContent.includes('ACTUAL_TAIL_MARKER')")
        XCTAssertEqual(sourceContainsMarker as? Bool, true)
        let observed = try await host.browser.inspect()
        XCTAssertEqual(observed.text.count, 8000)
        XCTAssertFalse(observed.text.contains("ACTUAL_TAIL_MARKER"))
        let found = try await host.browser.find(text: "ACTUAL_TAIL_MARKER")
        XCTAssertEqual(found.text, "目前可讀取的頁面摘錄中未找到指定文字；未檢查完整頁面。")
    }

    @MainActor func testLocalDocumentBecomesReadyAndMatchingFailuresStayTerminal() async throws {
        let host = try Host()
        defer { host.close() }
        let browser = host.browser
        for provisional in [false, true] {
            let navigation = try await host.load(marker: provisional ? "PROVISIONAL" : "COMMITTED")
            let snapshot = try await browser.snapshotControls()
            XCTAssertEqual(snapshot.url, host.url)
            XCTAssertTrue(snapshot.controls.contains { $0.label == "Local action" })

            // Synthetic failure for the exact navigation WebKit returned.
            let failure = URLError(provisional ? .timedOut : .cannotConnectToHost)
            if provisional {
                browser.webView(browser.webView, didFailProvisionalNavigation: navigation, withError: failure)
            } else {
                browser.webView(browser.webView, didFail: navigation, withError: failure)
            }
            assertNotReady(browser)
            browser.webView(browser.webView, didFinish: navigation)
            try await drainCallbacks(browser)
            assertNotReady(browser)
            do {
                _ = try await browser.snapshotControls()
                XCTFail("A failed document must not offer DOM interaction readiness")
            } catch let error as BrowserInteractionError {
                XCTAssertEqual(error, .noSnapshot)
            }
        }
    }

    @MainActor func testSyntheticProcessTerminationFencesQueuedAndLateFinish() async throws {
        let host = try Host()
        defer { host.close() }
        let browser = host.browser
        let old = try await host.load(marker: "BEFORE TERMINATION")
        // Queue a real inspect, then invalidate it before its MainActor task
        // runs. Also inject the old finish after invalidation.
        browser.webView(browser.webView, didFinish: old)
        browser.webViewWebContentProcessDidTerminate(browser.webView)
        assertNotReady(browser)
        browser.webView(browser.webView, didFinish: old)
        try await drainCallbacks(browser)
        assertNotReady(browser)

        // Explicit fresh load, not an automatic retry; identical URL is
        // intentional, so URL equality alone cannot protect the new page.
        _ = try await host.load(marker: "AFTER TERMINATION")
        browser.webView(browser.webView, didFinish: old)
        browser.webView(browser.webView, didFail: old, withError: URLError(.timedOut))
        try await drainCallbacks(browser)
        XCTAssertEqual(browser.current?.text, "AFTER TERMINATION\nLocal action")
        XCTAssertEqual(browser.status, "頁面已載入")
        XCTAssertNil(browser.error)
    }

    @MainActor func testActualUnreadableDOMEndsLoadingAndCannotRestoreOldPage() async throws {
        let host = try Host()
        defer { host.close() }
        let browser = host.browser
        let old = try await host.load(marker: "BODY WILL BE REMOVED")
        // Actual local DOM mutation makes the production observation script
        // fail. Only the finish callback triggering the re-read is synthetic.
        _ = try await browser.webView.evaluateJavaScript("document.body.remove(); true")
        browser.webView(browser.webView, didFinish: old)
        try await waitUntil { browser.status == "載入未完成" }
        assertNotReady(browser)
        XCTAssertEqual(browser.error, "頁面載入後的內容讀取未完成；沒有自動重試。")
        browser.webView(browser.webView, didFinish: old)
        try await drainCallbacks(browser)
        assertNotReady(browser)
    }

    @MainActor private func assertNotReady(_ browser: BrowserSession,
                                         file: StaticString = #filePath, line: UInt = #line) {
        // BrowserView uses current != nil to enable research/interaction.
        XCTAssertNil(browser.current, file: file, line: line)
        XCTAssertEqual(browser.status, "載入未完成", file: file, line: line)
        XCTAssertNotNil(browser.error, file: file, line: line)
        XCTAssertFalse(browser.isRunning, file: file, line: line)
    }

    @MainActor private func drainCallbacks(_ browser: BrowserSession) async throws {
        for _ in 0..<10 { await Task.yield() }
        // Flush an actual evaluation in the production observation's content
        // world, not just the Swift scheduler, before checking late callbacks.
        _ = try await browser.webView.evaluateJavaScript("true", in: nil, in: .defaultClient)
        for _ in 0..<10 { await Task.yield() }
    }

    @MainActor private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), "Local observation must reach its expected terminal state")
        guard condition() else { throw FixtureFailure.didNotFinish }
    }

    private enum FixtureFailure: Error { case missingScene, didNotFinish }

    @MainActor private final class Host {
        let browser = BrowserSession()
        let url = URL(string: "https://research.example.invalid/navigation-test")!
        let window: UIWindow
        let previousKeyWindow: UIWindow?

        init() throws {
            XCTAssertNotEqual(UIApplication.shared.applicationState, .background,
                              "Navigation tests require a foreground App host")
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                throw FixtureFailure.missingScene
            }
            previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            controller.view = browser.webView
            window.rootViewController = controller
            window.makeKeyAndVisible()
        }

        func close() {
            browser.cancel()
            browser.webView.navigationDelegate = nil
            window.isHidden = true
            previousKeyWindow?.makeKey()
        }

        func load(marker: String) async throws -> WKNavigation {
            // No subresources/scripts/links: the HTTPS base is identity only,
            // never fetched. No test hook or delegate replacement is used.
            let html = "<!doctype html><html><head><title>Local navigation</title></head><body><p>\(marker)</p><button>Local action</button></body></html>"
            let navigation = try XCTUnwrap(browser.webView.loadHTMLString(html, baseURL: url))
            let deadline = ProcessInfo.processInfo.systemUptime + 75
            while (browser.current?.text != marker + "\nLocal action" || browser.status != "頁面已載入"),
                  ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            XCTAssertEqual(browser.current?.url, url)
            XCTAssertEqual(browser.current?.title, "Local navigation")
            XCTAssertEqual(browser.current?.text, marker + "\nLocal action")
            XCTAssertEqual(browser.status, "頁面已載入")
            XCTAssertNil(browser.error)
            guard browser.current?.text == marker + "\nLocal action", browser.status == "頁面已載入" else {
                throw FixtureFailure.didNotFinish
            }
            return navigation
        }
    }
}
#endif
