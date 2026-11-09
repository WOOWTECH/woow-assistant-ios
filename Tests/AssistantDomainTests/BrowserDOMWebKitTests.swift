#if canImport(WebKit)
import Foundation
import WebKit
import AssistantBrowser
#if os(macOS)
import AppKit
#endif

@MainActor
enum BrowserDOMFixtures {
    struct Failure: Error { let message: String }
    static func run() async throws -> Int {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600), configuration: configuration)
        #if os(macOS)
        let window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        defer { window.orderOut(nil) }
        #endif
        let executor = BrowserDOMExecutor(webView: web)
        var assertions = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1
            if !condition() { throw Failure(message: message) }
        }
        func js(_ script: String) async throws -> String {
            let result = try await web.evaluateJavaScript(script)
            return result as? String ?? String(describing: result)
        }
        func load() async throws {
            web.loadHTMLString(html, baseURL: URL(string: "https://example.com/form")!)
            let deadline = Date().addingTimeInterval(75)
            while web.isLoading && Date() < deadline { try await Task.sleep(nanoseconds: 100_000_000) }
            try expect(!web.isLoading, "Local real WebKit load finished")
            let ready = try await js("document.title")
            try expect(ready == "DOM fixture", "Real HTML document loaded")
        }
        func proposal(_ kind: BrowserInteractionKind, label: String? = nil, text: String? = nil,
                      option: Int? = nil, direction: BrowserScrollDirection? = nil) async throws -> BrowserInteractionProposal {
            let snapshot = try await executor.snapshot()
            let control = snapshot.controls.first(where: { $0.label == label })
            var gate = BrowserInteractionGate()
            let pending = try gate.propose(.init(documentID: snapshot.documentID, snapshotID: snapshot.snapshotID,
                kind: kind, controlID: control?.id, text: text, optionIndex: option, direction: direction), snapshot: snapshot)
            return try gate.consumeApproval(id: pending.id)
        }
        try await load()
        let initial = try await executor.snapshot()
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
        let before = try await js("document.getElementById('note').value")
        try expect(before == "initial-value", "Preparing/consuming grant alone does not execute")
        try await executor.performApproved(typing)
        let typed = try await js("document.getElementById('note').value")
        try expect(typed == literal, "Arguments are literal data, not executable JS")
        let event = try await js("document.getElementById('events').textContent")
        try expect(event == "input:false change:false", "Actual DOM listeners fired, explicitly synthetic not trusted")
        do { try await executor.performApproved(typing); throw Failure(message: "Snapshot replay executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Executed snapshot cannot replay") }
        try await executor.performApproved(proposal(.select, label: "Mode", option: 1))
        let selected = try await js("document.getElementById('choice').value")
        try expect(selected == "advanced", "Actual select value changed")
        try await executor.performApproved(proposal(.click, label: "Save locally"))
        let saved = try await js("document.getElementById('result').textContent")
        try expect(saved == "SAVED " + literal + " advanced", "Actual form submit handler ran")

        let stale = try await proposal(.type, label: "Public note", text: "must not write")
        _ = try await js("document.getElementById('note').replaceWith(document.getElementById('note').cloneNode(true)); 'replaced'")
        do { try await executor.performApproved(stale); throw Failure(message: "Replaced node executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Identical replacement node invalidates identity") }
        let unchanged = try await js("document.getElementById('note').value")
        try expect(unchanged == literal, "Stale action changed nothing")
        let mutated = try await proposal(.type, label: "Public note", text: "must not write")
        _ = try await js("document.getElementById('note').value='human edit'; 'changed'")
        do { try await executor.performApproved(mutated); throw Failure(message: "Changed input executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Value changes during review invalidate approval") }

        let cancelledProposal = try await proposal(.type, label: "Public note", text: "cancelled")
        let cancelled = Task { @MainActor in try await executor.performApproved(cancelledProposal) }
        cancelled.cancel()
        do { try await cancelled.value; throw Failure(message: "Cancelled task executed") }
        catch is CancellationError { try expect(true, "Cancellation honored before dispatch") }
        let afterCancel = try await js("document.getElementById('note').value")
        try expect(afterCancel == "human edit", "Cancelled action changed nothing")
        try await executor.performApproved(proposal(.scroll, direction: .down))
        let scroll = try await js("String(window.scrollY > 0)")
        try expect(scroll == "true", "Actual viewport scrolled")
        let oldDocument = try await proposal(.click, label: "Save locally")
        try await load()
        do { try await executor.performApproved(oldDocument); throw Failure(message: "Same-URL new document executed") }
        catch let error as BrowserInteractionError { try expect(error == .staleSnapshot, "Same URL reload has new document identity") }
        let unsubmitted = try await js("document.getElementById('result').textContent")
        try expect(unsubmitted == "NOT SAVED", "Reload refused old submit without effects")
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
        let count = try await BrowserDOMFixtures.run()
        XCTAssertGreaterThan(count, 25)
    }
}
#endif
#endif
