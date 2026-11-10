#if canImport(WebKit)
import Foundation
import WebKit
import AssistantBrowser
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

@MainActor
enum BrowserDOMFixtures {
    struct Failure: Error { let message: String }
    private enum Stage: String {
        case setup, navigation, documentTitle, initialSnapshot, repeatedSnapshot, proposal
        case beforeTyping, typing, typedValue, inputEvents, consumedApproval
        case selecting, selectedValue, submitting, submittedValue
        case replaceNode, replacedApproval, unchangedValue, mutateValue, mutatedApproval
        case cancellation, cancelledValue, scrolling, scrollPosition, reloadedApproval, reloadedValue
    }

    /// Keep the delegate alive for both loads, and accept only the navigation
    /// returned by that particular loadHTMLString call. isLoading is not a
    /// substitute for a committed, finished document on a cold WebKit process.
    @MainActor private final class NavigationWaiter: NSObject, WKNavigationDelegate {
        private var expected: WKNavigation?
        private var outcome: Result<Void, Error>?

        func load(_ web: WKWebView, html: String, baseURL: URL) async throws {
            outcome = nil
            expected = nil
            guard let navigation = web.loadHTMLString(html, baseURL: baseURL) else {
                throw Failure(message: "Local fixture navigation was not created")
            }
            expected = navigation
            let deadline = ProcessInfo.processInfo.systemUptime + 75
            while outcome == nil && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            guard let outcome else { throw Failure(message: "Local fixture didFinish deadline exceeded") }
            try outcome.get()
        }

        private func finish(_ navigation: WKNavigation?, result: Result<Void, Error>) {
            guard let expected, navigation === expected, outcome == nil else { return }
            outcome = result
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(navigation, result: .success(()))
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(navigation, result: .failure(Failure(message: "Local fixture navigation failed")))
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(navigation, result: .failure(Failure(message: "Local fixture provisional navigation failed")))
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard outcome == nil else { return }
            outcome = .failure(Failure(message: "Local fixture WebContent process terminated"))
        }
    }

    static func run() async throws -> Int {
        var stage = Stage.setup
        var assertions = 0
        var loads = 0
        var completed = false
        defer {
            if !completed {
                // Fixed fixture phase/counts only: never print JS, DOM, or URLs.
                print("DOMFixture failed stage=\(stage.rawValue) loads=\(loads) assertions=\(assertions)")
            }
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: configuration)
        #if os(macOS)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        defer { window.orderOut(nil) }
        #elseif os(iOS)
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            throw Failure(message: "The integration fixture requires an App window scene")
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let controller = UIViewController()
        controller.view = web
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; previousKeyWindow?.makeKey() }
        #endif
        let navigationWaiter = NavigationWaiter()
        web.navigationDelegate = navigationWaiter
        defer { web.navigationDelegate = nil }
        let executor = BrowserDOMExecutor(webView: web)
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw Failure(message: message) }
        }
        func js(_ script: String, stage nextStage: Stage) async throws -> String {
            stage = nextStage
            // Use WebKit's callback API like the production executor; avoid
            // making fixture readiness depend on the SDK's async overlay.
            let result: Any? = try await withCheckedThrowingContinuation { continuation in
                web.evaluateJavaScript(script) { value, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: value) }
                }
            }
            return result as? String ?? String(describing: result)
        }
        func load() async throws {
            stage = .navigation
            loads += 1
            try await navigationWaiter.load(web, html: html, baseURL: URL(string: "https://example.com/form")!)
            try expect(!web.isLoading, "Local real WebKit load finished")
            let ready = try await js("document.title", stage: .documentTitle)
            try expect(ready == "DOM fixture", "Real HTML document loaded")
        }
        func proposal(_ kind: BrowserInteractionKind, label: String? = nil, text: String? = nil,
                      option: Int? = nil, direction: BrowserScrollDirection? = nil) async throws -> BrowserInteractionProposal {
            stage = .proposal
            let snapshot = try await executor.snapshot()
            let control = snapshot.controls.first(where: { $0.label == label })
            var gate = BrowserInteractionGate()
            let pending = try gate.propose(.init(documentID: snapshot.documentID, snapshotID: snapshot.snapshotID,
                kind: kind, controlID: control?.id, text: text, optionIndex: option, direction: direction), snapshot: snapshot)
            return try gate.consumeApproval(id: pending.id)
        }
        try await load()
        stage = .initialSnapshot
        let initial = try await executor.snapshot()
        stage = .repeatedSnapshot
        let repeated = try await executor.snapshot()
        try expect(initial.documentID == repeated.documentID, "Document identity stable")
        try expect(initial.snapshotID != repeated.snapshotID, "Each observation invalidates old snapshot")
        try expect(initial.controls.map(\.id) == repeated.controls.map(\.id), "Node IDs stable across observations")
        let json = String(decoding: try JSONEncoder().encode(initial), as: UTF8.self)
        for secret in ["fixture-secret", "initial-value", "Upload excluded", "Password", "Hidden action", "Invisible action", "New window"] {
            try expect(!json.contains(secret), "Sensitive/hidden/unsupported values excluded: \(secret)")
        }
        try expect(initial.controls.first(where: { $0.label == "Disabled action" })?.enabled == false, "Disabled control represented but not executable")
        let literal = "Quote '\"; alert(1); <script>safe</script> 世界"
        let typing = try await proposal(.type, label: "Public note", text: literal)
        let before = try await js("document.getElementById('note').value", stage: .beforeTyping)
        try expect(before == "initial-value", "Preparing/consuming grant alone does not execute")
        stage = .typing
        try await executor.performApproved(typing)
        let typed = try await js("document.getElementById('note').value", stage: .typedValue)
        try expect(typed == literal, "Arguments are literal data, not executable JS")
        let event = try await js("document.getElementById('events').textContent", stage: .inputEvents)
        try expect(event == "input:false change:false", "Actual DOM listeners fired, explicitly synthetic not trusted")
        stage = .consumedApproval
        do { try await executor.performApproved(typing); throw Failure(message: "Snapshot replay executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Executed snapshot cannot replay") }
        let selecting = try await proposal(.select, label: "Mode", option: 1)
        stage = .selecting
        try await executor.performApproved(selecting)
        let selected = try await js("document.getElementById('choice').value", stage: .selectedValue)
        try expect(selected == "advanced", "Actual select value changed")
        let submitting = try await proposal(.click, label: "Save locally")
        stage = .submitting
        try await executor.performApproved(submitting)
        let saved = try await js("document.getElementById('result').textContent", stage: .submittedValue)
        try expect(saved == "SAVED " + literal + " advanced", "Actual form submit handler ran")

        let stale = try await proposal(.type, label: "Public note", text: "must not write")
        _ = try await js("document.getElementById('note').replaceWith(document.getElementById('note').cloneNode(true)); 'replaced'", stage: .replaceNode)
        stage = .replacedApproval
        do { try await executor.performApproved(stale); throw Failure(message: "Replaced node executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Identical replacement node invalidates identity") }
        let unchanged = try await js("document.getElementById('note').value", stage: .unchangedValue)
        try expect(unchanged == literal, "Stale action changed nothing")
        let mutated = try await proposal(.type, label: "Public note", text: "must not write")
        _ = try await js("document.getElementById('note').value='human edit'; 'changed'", stage: .mutateValue)
        stage = .mutatedApproval
        do { try await executor.performApproved(mutated); throw Failure(message: "Changed input executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Value changes during review invalidate approval") }

        let cancelledProposal = try await proposal(.type, label: "Public note", text: "cancelled")
        stage = .cancellation
        let cancelled = Task { @MainActor in try await executor.performApproved(cancelledProposal) }
        cancelled.cancel()
        do { try await cancelled.value; throw Failure(message: "Cancelled task executed") }
        catch is CancellationError { try expect(true, "Cancellation honored before dispatch") }
        let afterCancel = try await js("document.getElementById('note').value", stage: .cancelledValue)
        try expect(afterCancel == "human edit", "Cancelled action changed nothing")
        let beforeScroll = try await js("String(window.scrollY)", stage: .scrollPosition)
        let initialScrollY = Double(beforeScroll) ?? .nan
        let scrolling = try await proposal(.scroll, direction: .down)
        stage = .scrolling
        try await executor.performApproved(scrolling)
        // performApproved reports dispatch, not presentation completion. iOS
        // returned the old offset on the very next JS callback. Observe the
        // actual offset across rendering turns; dispatch the action only once.
        let scrollDeadline = ProcessInfo.processInfo.systemUptime + 1
        var scrollY = initialScrollY
        repeat {
            let value = try await js("String(window.scrollY)", stage: .scrollPosition)
            scrollY = Double(value) ?? .nan
            if scrollY > initialScrollY { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        } while ProcessInfo.processInfo.systemUptime < scrollDeadline
        try expect(scrollY > initialScrollY, "Actual viewport scrolled: before=\(initialScrollY), after=\(scrollY)")
        let oldDocument = try await proposal(.click, label: "Save locally")
        try await load()
        stage = .reloadedApproval
        do { try await executor.performApproved(oldDocument); throw Failure(message: "Same-URL new document executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Same URL reload has new document identity") }
        let unsubmitted = try await js("document.getElementById('result').textContent", stage: .reloadedValue)
        try expect(unsubmitted == "NOT SAVED", "Reload refused old submit without effects")
        completed = true
        return assertions
    }
    static let html = #"""
    <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>DOM fixture</title></head><body>
    <form onsubmit="event.preventDefault();document.getElementById('result').textContent='SAVED '+document.getElementById('note').value+' '+document.getElementById('choice').value">
    <label>Public note <input id="note" value="initial-value" oninput="document.getElementById('events').textContent='input:'+event.isTrusted" onchange="document.getElementById('events').textContent+=' change:'+event.isTrusted"></label>
    <label>Mode <select id="choice"><option value="basic">Basic</option><option value="advanced">Advanced</option><option disabled>Disabled</option></select></label>
    <button>Save locally</button></form><p id="events"></p><p id="result">NOT SAVED</p>
    <label>Password <input type="password" value="fixture-secret"></label><input type="file" aria-label="Upload excluded">
    <button disabled>Disabled action</button><button hidden>Hidden action</button><button style="opacity:0">Invisible action</button>
    <a href="https://example.com/" target="_blank">New window</a><p style="height:2000px">Scroll area</p></body></html>
    """#
}

#if BROWSER_WEBKIT_SMOKE && os(macOS)
@main enum BrowserWebKitSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { print("Real local WebKit DOM: \(try await BrowserDOMFixtures.run()) assertions passed"); exit(0) }
            catch { print("Real local WebKit DOM FAILED: \(error)"); exit(1) }
        }
        app.run()
    }
}
#elseif canImport(XCTest) && os(iOS)
import XCTest
final class BrowserDOMWebKitTests: XCTestCase {
    @MainActor func testActualDOMAndStaleIdentity() async throws {
        XCTAssertTrue(UIApplication.shared.applicationState != .background,
                      "DOM integration must run in the foreground App host.")
        let count = try await BrowserDOMFixtures.run()
        XCTAssertGreaterThan(count, 25)
    }
}
#endif
#endif
