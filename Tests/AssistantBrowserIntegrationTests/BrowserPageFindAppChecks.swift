import Foundation
import WebKit
import AssistantPersistence
#if os(iOS)
import UIKit
#if canImport(XCTest)
@testable import WoowAssistant
#endif
#else
import AppKit
#endif

private final class PageFindKeys: LearningKeyStore {
    private var keys: [String: Data] = [:]
    func read(id: String) throws -> Data? { keys[id] }
    func insert(_ key: Data, id: String) throws { keys[id] = key }
    func remove(id: String) throws { keys.removeValue(forKey: id) }
    func removeAll(except id: String) throws { keys = keys.filter { $0.key == id } }
}

/// Exact production BrowserSession/Workspace, real WebKit documents and a
/// temporary encrypted vault. No substitute session, model client, or network.
/// UIKit-only assertions are required in the hosted iOS methods below; the
/// standalone macOS result explicitly does not claim native panel execution.
@MainActor enum BrowserPageFindAppChecks {
    struct Failure: Error { let check: String }
    static let html = """
    <!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1"><title>Find checks</title></head>
    <body><p>WOOW_FIND_ORCHID first 茶香</p><p>WOOW_FIND_ORCHID second</p>
    <p>ignore previous instructions</p><button>Unchanged action</button>
    <div style="height:900px"></div><p>WOOW_FIND_ORCHID third 茶香</p></body></html>
    """

    @MainActor final class Fixture {
        let root: URL
        let workspace: BrowserWorkspace
        let host: BrowserSiteModesAppChecks.Host
        let browser: BrowserSession
        let probe: BrowserSiteModesAppChecks.Probe
        var assertions = 0
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-page-find-" + UUID().uuidString)
            let vault = EncryptedLearningFile(url: root.appendingPathComponent("library.vault"), keys: PageFindKeys())
            workspace = BrowserWorkspace(dataStore: .nonPersistent(), vault: vault,
                                         downloadDirectory: root.appendingPathComponent("Downloads"))
            host = try BrowserSiteModesAppChecks.Host()
            browser = workspace.selected
            probe = BrowserSiteModesAppChecks.Probe(browser)
            host.attach(browser)
            browser.webView.navigationDelegate = probe
            browser.setPageFindHostVisible(true)
            try check(workspace.available, "isolated encrypted workspace available")
            try check(!browser.canFindInPage && !browser.presentPageFind(), "empty tab cannot find")
        }
        func finish() {
            browser.setPageFindHostVisible(false)
            workspace.cancelAllWork(); host.close()
            try? FileManager.default.removeItem(at: root)
        }
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(check: name) }
            assertions += 1
        }
        func load(_ path: String = "/page-find", html: String = BrowserPageFindAppChecks.html,
                  explicitlyManual: Bool = true) async throws {
            let url = URL(string: "https://research.example.invalid" + path)!
            let before = probe.finishes
            probe.localHTMLURL = url
            var invalidatedBeforeLoad = false
            if explicitlyManual {
                browser.manualNavigation(to: url) {
                    invalidatedBeforeLoad = !browser.pageFindDocumentReady && !browser.canFindInPage
                    #if os(iOS)
                    invalidatedBeforeLoad = invalidatedBeforeLoad && !browser.webView.isFindInteractionEnabled
                    #endif
                    return browser.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
                }
                try check(invalidatedBeforeLoad, "find revoked synchronously before actual manual navigation")
            } else {
                browser.webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
            }
            try await BrowserSiteModesAppChecks.wait("real document finish", {
                self.probe.finishes == before + 1 && self.browser.loadedURL == url && !self.browser.webView.isLoading
            })
            if url.query == nil {
                try await BrowserSiteModesAppChecks.wait("actual observation complete", { self.browser.current?.url == url })
            }
            try check(browser.canFindInPage, "loaded manual document eligible")
            #if os(iOS)
            try check(browser.webView.isFindInteractionEnabled && browser.webView.findInteraction?.searchText == "",
                      "new document also starts hardware-keyboard Find with an empty query")
            #endif
        }
        func engineFind(_ text: String, backwards: Bool = false, wraps: Bool = true) async throws -> Bool {
            try check(browser.canFindInPage, "engine check only on manual document")
            let config = WKFindConfiguration(); config.backwards = backwards; config.wraps = wraps
            return try await browser.webView.find(text, configuration: config).matchFound
        }
        #if os(iOS)
        func panel() async throws -> UIFindInteraction {
            try check(browser.presentPageFind(), "actual native panel requested")
            try await BrowserSiteModesAppChecks.wait("native panel session", {
                self.browser.webView.findInteraction?.isFindNavigatorVisible == true
                && self.browser.webView.findInteraction?.activeFindSession != nil
            })
            guard let interaction = browser.webView.findInteraction else { throw Failure(check: "missing native interaction") }
            try check(browser.webView.isFindInteractionEnabled, "native interaction enabled")
            return interaction
        }
        func search(_ text: String, count: Int, interaction: UIFindInteraction) async throws {
            guard let session = interaction.activeFindSession else { throw Failure(check: "native session missing") }
            session.performSearch(query: text, options: nil)
            try await BrowserSiteModesAppChecks.wait("native exact result count", { session.resultCount == count })
            try check(session.resultCount == count, "actual native exact result count")
        }
        #endif
    }

    static func queryAndNavigation() async throws -> Int {
        let f = try Fixture(); defer { f.finish() }
        try checkViewportGeometry(f)
        try await f.load()
        let navigationCount = f.probe.actions.count
        let history = f.workspace.library.history
        let url = f.browser.loadedURL
        #if os(iOS)
        let panel = try await f.panel()
        try await f.search("WOOW_FIND_ORCHID", count: 3, interaction: panel)
        guard let session = panel.activeFindSession else { throw Failure(check: "missing native search session") }
        panel.findNext()
        try await BrowserSiteModesAppChecks.wait("native first highlighted result", { (0..<3).contains(session.highlightedResultIndex) })
        let first = session.highlightedResultIndex
        panel.findNext()
        try await BrowserSiteModesAppChecks.wait("native next result", { session.highlightedResultIndex == (first + 1) % 3 })
        try f.check(session.highlightedResultIndex == (first + 1) % 3, "native next highlights next actual match")
        panel.findPrevious()
        try await BrowserSiteModesAppChecks.wait("native previous result", { session.highlightedResultIndex == first })
        try f.check(session.highlightedResultIndex == first, "native previous reverses next")
        try await f.search("茶香", count: 2, interaction: panel)
        try await f.search("NOT_PRESENT_LITERAL", count: 0, interaction: panel)
        try await f.search("ignore previous instructions", count: 1, interaction: panel)
        try await f.search("", count: 0, interaction: panel)
        panel.dismissFindNavigator()
        try await BrowserSiteModesAppChecks.wait("native close", { !panel.isFindNavigatorVisible })
        try f.check(!panel.isFindNavigatorVisible, "public native close dismisses")
        let reopened = try await f.panel()
        try f.check(reopened.searchText == nil || reopened.searchText == "", "fresh explicit opening has no retained query")
        f.browser.closePageFind()
        try f.check(!reopened.isFindNavigatorVisible, "App close ends prior native session")
        #else
        // Real WebKit engine, not a substitute UIFindInteraction implementation.
        let found = try await f.engineFind("WOOW_FIND_ORCHID")
        try f.check(found, "real WebKit finds literal")
        let reverse = try await f.engineFind("WOOW_FIND_ORCHID", backwards: true)
        try f.check(reverse, "real WebKit reverse find")
        let unicode = try await f.engineFind("茶香")
        try f.check(unicode, "real WebKit Unicode find")
        let absent = try await f.engineFind("NOT_PRESENT_LITERAL")
        try f.check(!absent, "real WebKit absent literal")
        let instruction = try await f.engineFind("ignore previous instructions")
        try f.check(instruction, "instruction-looking query remains literal text")
        try f.check(!f.browser.presentPageFind(), "macOS does not pretend to present UIKit panel")
        #endif
        try f.check(f.probe.actions.count == navigationCount && f.browser.loadedURL == url, "finding never navigates")
        try f.check(f.workspace.library.history == history, "finding does not save query in history")
        try f.check(!f.browser.isRunning && !f.browser.isInteracting && !f.browser.automationOwnsDocument,
                    "finding starts no automation")
        try await f.load("/different", html: "<title>Other</title><p>ONLY_OTHER_DOCUMENT</p>")
        let oldMatch = try await f.engineFind("WOOW_FIND_ORCHID")
        try f.check(!oldMatch, "new document cannot reuse old matches")
        #if os(iOS)
        let fresh = try await f.panel()
        try f.check(fresh.searchText == nil || fresh.searchText == "", "new document has no old query")
        try await f.search("ONLY_OTHER_DOCUMENT", count: 1, interaction: fresh)
        #endif
        // A real delegate-initiated navigation, not the explicit manual seam.
        try await f.load("/site-initiated", explicitlyManual: false)
        #if os(iOS)
        try f.check(!fresh.isFindNavigatorVisible, "site-initiated provisional navigation closes old panel")
        #endif
        try await f.load("/manual-only?q=synthetic")
        try f.check(f.browser.current == nil, "query page remains excluded from model research")
        let manualMatch = try await f.engineFind("WOOW_FIND_ORCHID")
        try f.check(manualMatch, "native find works on manual-only query page")
        return f.assertions
    }

    /// Exercise the production geometry with a docked input-panel frame, not
    /// an AX Keyboard child's smaller frame. These are layout calculations;
    /// actual iOS keyboard notifications and native scrolling remain UI tests.
    private static func checkViewportGeometry(_ f: Fixture) throws {
        let window = CGRect(x: 0, y: 0, width: 402, height: 874)
        let keyboard = CGRect(x: 0, y: 506, width: 402, height: 368)
        let compact = CGRect(x: 0, y: 219, width: 402, height: 189)
        func reserve(_ viewport: CGRect, _ input: CGRect = keyboard, finding: Bool = true) -> CGFloat {
            BrowserFindViewport.reservedHeight(viewport: viewport, keyboard: input, window: window, finding: finding)
        }
        try f.check(reserve(compact) == 368, "already avoided keyboard is reserved exactly once for native find")
        let expandedHeight = compact.height + reserve(compact)
        try f.check(expandedHeight - keyboard.height == compact.height,
                    "WebKit full input-panel subtraction leaves exactly the clipped viewport")
        let textHeight: CGFloat = 20
        let originalMatchTop = (compact.height - keyboard.height - textHeight) / 2
        let repairedMatchTop = (expandedHeight - keyboard.height - textHeight) / 2
        try f.check(originalMatchTop < 0, "original double subtraction moves a centered match above a short viewport")
        try f.check(repairedMatchTop >= 0 && repairedMatchTop + textHeight <= compact.height,
                    "native centering fits the complete match without changing scroll position or query")
        let partiallyCovered = CGRect(x: 0, y: 219, width: 402, height: 500)
        try f.check(reserve(partiallyCovered) == 155, "reserve excludes keyboard overlap already inside the web canvas")
        try f.check(partiallyCovered.height + reserve(partiallyCovered) - keyboard.height == 287,
                    "partly covered layout retains only its true visible height")
        let shorterWindow = CGRect(x: 0, y: 0, width: 402, height: 700)
        try f.check(BrowserFindViewport.reservedHeight(viewport: compact, keyboard: keyboard,
                    window: shorterWindow, finding: true) == keyboard.height,
                    "window intersection does not truncate the full input height WebKit subtracts")
        let full = CGRect(x: 0, y: 0, width: 402, height: 874)
        try f.check(reserve(full) == 0, "UIKit full-height host does not double-reserve keyboard")
        try f.check(reserve(compact, finding: false) == 0, "ordinary manual forms keep their original layout")
        try f.check(reserve(compact, .zero) == 0, "closed keyboard restores original canvas")
        try f.check(reserve(compact, CGRect(x: 0, y: 874, width: 402, height: 368)) == 0,
                    "offscreen hide notification restores original canvas")
        try f.check(reserve(compact, CGRect(x: 40, y: 400, width: 300, height: 200)) == 0,
                    "floating input is not treated as a docked keyboard")
        try f.check(reserve(.zero) == 0 && reserve(.null) == 0 && reserve(.infinite) == 0,
                    "unmounted or invalid viewport never expands")
        try f.check(reserve(compact, CGRect(x: 0, y: 506, width: CGFloat.nan, height: 368)) == 0,
                    "nonfinite keyboard geometry is rejected")
    }

    static func ownershipAndRetirement() async throws -> Int {
        let f = try Fixture(); defer { f.finish() }
        try await f.load()
        #if os(iOS)
        let panel = try await f.panel()
        try await f.search("WOOW_FIND_ORCHID", count: 3, interaction: panel)
        #endif
        f.browser.refreshControls()
        try f.check(!f.browser.canFindInPage && !f.browser.presentPageFind(), "automation claims document before asynchronous work")
        #if os(iOS)
        try f.check(!f.browser.webView.isFindInteractionEnabled && !panel.isFindNavigatorVisible,
                    "automation removes keyboard entry and dismisses panel")
        #endif
        try await BrowserSiteModesAppChecks.wait("actual control snapshot completion", { !f.browser.isInteracting })
        try f.check(f.browser.controlSnapshot != nil && f.browser.automationOwnsDocument, "actual control enumeration finished with ownership")
        f.browser.cancelInteraction()
        f.browser.setPageFindHostVisible(false); f.browser.setPageFindHostVisible(true)
        try f.check(!f.browser.canFindInPage && !f.browser.presentPageFind(), "cancel and remount do not release ownership")
        try await f.load("/manual-again")
        try f.check(!f.browser.automationOwnsDocument && f.browser.canFindInPage, "fresh manual commit restores eligibility")
        #if os(iOS)
        _ = try await f.panel()
        #endif
        // The generic navigation probe intentionally blocks all unscheduled
        // loads; the production delegate must handle its own about:blank wipe.
        f.browser.webView.navigationDelegate = f.browser
        let discarded = await f.browser.discardPageForDataRemoval()
        try f.check(discarded, "actual blank document discard completes")
        f.browser.setPageFindHostVisible(true)
        var attemptedLoad = false
        f.browser.manualNavigation(to: URL(string: "https://research.example.invalid/retired")!) { attemptedLoad = true; return nil }
        try f.check(!attemptedLoad && !f.browser.canFindInPage && !f.browser.presentPageFind(), "retired session never reopens find or navigation")
        #if os(iOS)
        try f.check(!f.browser.webView.isFindInteractionEnabled, "retired keyboard find remains disabled")
        #endif
        return f.assertions
    }

    static func tabsAndVisibility() async throws -> Int {
        let f = try Fixture(); defer { f.finish() }
        try await f.load()
        let firstID = f.workspace.library.selectedID
        #if os(iOS)
        let firstPanel = try await f.panel()
        try await f.search("WOOW_FIND_ORCHID", count: 3, interaction: firstPanel)
        #endif
        f.workspace.newTab()
        try f.check(f.workspace.selected !== f.browser && !f.browser.canFindInPage, "actual workspace selection rejects old tab")
        try f.check(!f.browser.presentPageFind() && !f.workspace.selected.canFindInPage, "neither hidden tab nor blank tab can open find")
        #if os(iOS)
        try f.check(!firstPanel.isFindNavigatorVisible && !f.browser.webView.isFindInteractionEnabled, "workspace suspension ends old native find")
        #endif
        f.workspace.selectTab(firstID)
        f.host.attach(f.browser); f.browser.setPageFindHostVisible(true)
        try f.check(f.workspace.selected === f.browser && f.browser.canFindInPage, "selecting retained manual page restores eligibility")
        #if os(iOS)
        let secondPanel = try await f.panel()
        try f.check(secondPanel.searchText == nil || secondPanel.searchText == "", "tab restore does not revive query")
        #endif
        f.browser.setPageFindHostVisible(false)
        try f.check(!f.browser.presentPageFind(), "background, covered or detached host cannot open find")
        #if os(iOS)
        try f.check(!f.browser.webView.isFindInteractionEnabled && !secondPanel.isFindNavigatorVisible, "hidden host disables native keyboard interaction")
        #endif
        f.browser.setPageFindHostVisible(true)
        try f.check(f.browser.canFindInPage, "foreground retains eligible document")
        f.workspace.closeTab(firstID)
        f.browser.setPageFindHostVisible(true)
        try f.check(!f.browser.canFindInPage && !f.browser.presentPageFind(), "closed tab cannot revive native find")
        return f.assertions
    }
    #if DEBUG
    static func actualHTTPHistory() async throws -> [String: Any] {
        guard let fixture = BrowserLoginFixture.enabled else { throw Failure(check: "HTTP fixture flags required") }
        let firstURL = try await fixture.start()
        defer { fixture.stop() }
        let f = try Fixture(); defer { f.finish() }
        f.probe.allowsNetworkFixture = fixture.allows
        let secondURL = firstURL.deletingLastPathComponent().appendingPathComponent("protected")
        func completion(_ url: URL, after finishes: Int) async throws {
            try await BrowserSiteModesAppChecks.wait("actual HTTP history document", {
                f.probe.finishes == finishes + 1 && f.browser.loadedURL == url && !f.browser.webView.isLoading
            })
            try f.check(f.browser.canFindInPage, "actual HTTP manual document eligible")
        }
        func open(_ url: URL) async throws {
            let count = f.probe.finishes
            f.browser.address = url.absoluteString; f.browser.openAddress()
            try f.check(!f.browser.pageFindDocumentReady, "HTTP navigation synchronously clears find document")
            try await completion(url, after: count)
        }
        try await open(firstURL)
        let first = try await f.engineFind("LOGIN_STATUS_READY")
        try f.check(first, "actual HTTP first-page text found")
        try await open(secondURL)
        let stale = try await f.engineFind("LOGIN_STATUS_READY")
        try f.check(!stale, "second HTTP page cannot find first-page text")
        try f.check(f.browser.canGoBack, "actual history has previous document")
        let beforeBack = f.probe.finishes
        f.browser.goBack()
        try f.check(!f.browser.pageFindDocumentReady, "Back clears find before WebKit side effect")
        try await completion(firstURL, after: beforeBack)
        let back = try await f.engineFind("LOGIN_STATUS_READY")
        try f.check(back && f.browser.canGoForward, "Back restores actual first document")
        let beforeForward = f.probe.finishes
        f.browser.goForward()
        try f.check(!f.browser.pageFindDocumentReady, "Forward clears find before WebKit side effect")
        try await completion(secondURL, after: beforeForward)
        let forward = try await f.engineFind("LOGIN_PROTECTED_DENIED")
        try f.check(forward, "Forward restores actual second document")
        let beforeReload = f.probe.finishes
        f.browser.reloadPage()
        try f.check(!f.browser.pageFindDocumentReady, "Reload clears find before WebKit side effect")
        try await completion(secondURL, after: beforeReload)
        let reloaded = try await f.engineFind("LOGIN_PROTECTED_DENIED")
        try f.check(reloaded, "Reload completes with actual current document text")
        try f.check(f.probe.actions.filter { $0.type == .backForward }.count == 2, "exactly two native history actions")
        try f.check(f.probe.actions.filter { $0.type == .reload }.count == 1, "exactly one native reload action")
        try f.check(f.probe.actions.allSatisfy { $0.method == "GET" }, "no query submission or form POST")
        return ["assertions": f.assertions, "actual_loopback_http": true,
                "back_forward_actions": 2, "reload_actions": 1, "external_network_or_model_calls": 0]
    }
    #endif

}

#if BROWSER_PAGE_FIND_APP_STANDALONE
@main struct BrowserPageFindMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                #if DEBUG
                if BrowserLoginFixture.enabled != nil {
                    let result = try await BrowserPageFindAppChecks.actualHTTPHistory()
                    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                    exit(0)
                }
                #endif
                let results = [
                    "query_and_navigation": try await BrowserPageFindAppChecks.queryAndNavigation(),
                    "ownership_and_retirement": try await BrowserPageFindAppChecks.ownershipAndRetirement(),
                    "tabs_and_visibility": try await BrowserPageFindAppChecks.tabsAndVisibility()
                ]
                let report: [String: Any] = [
                    "groups": results, "assertions": results.values.reduce(0, +),
                    "actual_webkit": true, "actual_encrypted_workspace": true,
                    "native_uikit_panel_executed": false, "external_network_or_model_calls": 0
                ]
                print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]), as: UTF8.self))
                exit(0)
            } catch { print("FAIL \(error)"); exit(1) }
        }
        app.run()
    }
}
#endif
