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
        XCTAssertEqual(page.omittedRegions, 0)
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

    @MainActor func testTranscriptAcceptsExactUTF8LimitIncludingOnlyActualSeparators() async throws {
        let host = try Host(); defer { host.close() }
        _ = try await host.load(marker: "BYTE BOUNDARY")
        for (script, expected) in [
            ("document.body.innerHTML='<p>'+('A'.repeat(65536))+'</p>'; true", String(repeating: "A", count: 65536)),
            ("document.body.innerHTML='<p>'+('字'.repeat(21845))+'</p><p></p>'; true", String(repeating: "字", count: 21845)),
            ("document.body.innerHTML='<p>'+('字'.repeat(21845))+'A</p>'; true", String(repeating: "字", count: 21845) + "A"),
            ("document.body.innerHTML='<p>'+('A'.repeat(65534))+'</p><p>B</p>'; true", String(repeating: "A", count: 65534) + "\nB")
        ] {
            _ = try await host.browser.webView.evaluateJavaScript(script)
            let page = try await host.browser.textForTranscript()
            XCTAssertEqual(page.text, expected)
            XCTAssertLessThanOrEqual(page.text.utf8.count, 65536)
        }
        for script in [
            "document.body.innerHTML='<p>'+('A'.repeat(65537))+'</p>'; true",
            "document.body.innerHTML='<p>'+('字'.repeat(21846))+'</p>'; true"
        ] {
            _ = try await host.browser.webView.evaluateJavaScript(script)
            do { _ = try await host.browser.textForTranscript(); XCTFail("An over-limit source must not be truncated") }
            catch let error as TranscriptError { XCTAssertEqual(error, .tooLarge) }
        }
    }

    @MainActor func testTranscriptExcludesHiddenAncestorsAndSensitiveRolesButReadsDisplayContents() async throws {
        let host = try Host(); defer { host.close() }
        _ = try await host.load(marker: "VISIBLE SOURCE")
        _ = try await host.browser.webView.evaluateJavaScript(#"""
        document.body.innerHTML='<p>PUBLIC</p><div style="display:contents">VISIBLE_CONTENTS</div>'+
          '<p style="opacity:0">PRIVATE_OPACITY</p><div style="opacity:0"><p>PRIVATE_ANCESTOR</p></div>'+
          '<div style="visibility:hidden"><p>PRIVATE_VISIBILITY</p></div><div hidden>PRIVATE_HIDDEN</div>'+
          '<div aria-hidden="true">PRIVATE_ARIA</div><div role="textbox"><span>PRIVATE_TEXTBOX</span></div>'+
          '<div role="searchbox">PRIVATE_SEARCHBOX</div><div contenteditable="true">PRIVATE_EDITABLE</div>'+
          '<input type="hidden" value="PRIVATE_INPUT"><textarea>PRIVATE_TEXTAREA</textarea>'+
          '<select><option selected>PRIVATE_SELECTION</option></select>'; true
        """#)
        let page = try await host.browser.textForTranscript()
        XCTAssertEqual(page.text, "PUBLIC\nVISIBLE_CONTENTS")
        XCTAssertFalse(page.text.contains("PRIVATE_"))
        _ = try await host.browser.webView.evaluateJavaScript("document.documentElement.style.opacity='0'; true")
        defer { host.browser.webView.evaluateJavaScript("document.documentElement.style.opacity=''", completionHandler: nil) }
        do { _ = try await host.browser.textForTranscript(); XCTFail("A hidden document ancestor must exclude its descendants") }
        catch let error as TranscriptError { XCTAssertEqual(error, .emptySource) }
    }

    @MainActor func testTranscriptFlattensOpenShadowRootsAndAssignedSlotsWithoutLightDOMDuplicates() async throws {
        let host = try Host(); defer { host.close() }
        _ = try await host.load(marker: "SHADOW SOURCE")
        _ = try await host.browser.webView.evaluateJavaScript(#"""
        document.body.innerHTML='<p>PUBLIC</p><div id="shadow-host"><span slot="chosen">SLOTTED</span>'+
          '<span>PRIVATE_UNASSIGNED</span><span slot="secret">PRIVATE_HIDDEN_SLOT</span></div>';
        const root=document.getElementById('shadow-host').attachShadow({mode:'open'});
        root.innerHTML='<p>BEFORE</p><slot name="chosen">PRIVATE_UNUSED_FALLBACK</slot>'+
          '<slot name="missing">FALLBACK</slot><slot name="outer"><slot name="inner" style="opacity:0">PRIVATE_NESTED_SLOT</slot></slot><div id="nested"></div>'+
          '<div style="opacity:0"><slot name="secret"></slot></div><p>AFTER</p>';
        root.getElementById('nested').attachShadow({mode:'open'}).innerHTML='<p>NESTED_SHADOW</p>';
        true
        """#)
        let page = try await host.browser.textForTranscript()
        XCTAssertEqual(page.text, "PUBLIC\nBEFORE\nSLOTTED\nFALLBACK\nNESTED_SHADOW\nAFTER")
        XCTAssertFalse(page.text.contains("PRIVATE_"))
        XCTAssertEqual(page.omittedRegions, 0)
    }

    @MainActor func testTranscriptReportsOmittedRegionsAndPreservesReadableLightDOMWithoutPlaceholders() async throws {
        let host = try Host(); defer { host.close() }
        _ = try await host.load(marker: "READABLE SNAPSHOT")
        // A same-origin initial frame and sandbox srcdoc use no external request.
        // Both same-origin and
        // opaque-origin documents remain outside this snapshot, with counts.
        let frameBody = try await host.browser.webView.evaluateJavaScript(#"""
        document.body.innerHTML=`<p>PUBLIC</p><iframe id="local-frame"></iframe>
          <iframe sandbox srcdoc="<p>PRIVATE_SANDBOX</p>"></iframe>
          <closed-example></closed-example><light-example>READABLE_LIGHT</light-example>
          <contents-example style="display:contents">READABLE_CONTENTS</contents-example>
          <div hidden><iframe srcdoc="PRIVATE_HIDDEN_FRAME"></iframe><hidden-example>PRIVATE_HIDDEN_CUSTOM</hidden-example></div>`;
        document.querySelector('closed-example').attachShadow({mode:'closed'}).innerHTML='<p>PRIVATE_CLOSED_TEXT</p>';
        document.getElementById('local-frame').contentDocument.body.textContent='PRIVATE_FRAME';
        document.getElementById('local-frame').contentDocument.body.textContent
        """#)
        XCTAssertEqual(frameBody as? String, "PRIVATE_FRAME", "An actual populated frame must exist before checking its exclusion")
        let page = try await host.browser.textForTranscript()
        XCTAssertEqual(page.text, "PUBLIC\nREADABLE_LIGHT\nREADABLE_CONTENTS")
        XCTAssertEqual(page.omittedRegions, 5, "Two embedded documents and three possibly opaque custom elements")
        XCTAssertFalse(page.text.contains("PRIVATE_"))
        // Omissions are metadata only; the approved source text remains exactly
        // what was accessible, without model-facing placeholder instructions.
        _ = try await host.browser.webView.evaluateJavaScript("document.body.innerHTML='<p>PUBLIC</p><div hidden><iframe srcdoc=HIDDEN></iframe></div><iframe style=\"width:0;height:0;border:0\" srcdoc=ZERO></iframe>'; true")
        let hidden = try await host.browser.textForTranscript()
        XCTAssertEqual(hidden.text, "PUBLIC")
        XCTAssertEqual(hidden.omittedRegions, 0)
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
