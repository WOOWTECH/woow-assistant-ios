import AppKit
import CryptoKit
import Foundation
import WebKit
@testable import AssistantBrowser

/// Standalone executable, sharing the exact core XCTest bodies. The local HTML
/// cases exercise real WebKit but are explicitly not live-provider evidence.
@main enum CheckResearchSourceDiscovery {
    typealias Checks = ResearchSourceDiscoveryChecks
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            let local = CommandLine.arguments[2]
            var report: [String: Any] = ["status": "INCOMPLETE", "groups": [String: Int](),
                "actual_webkit": true, "native_ios_execution": false, "live": ["status": "NOT_REQUESTED"]]
            var groups: [String: Int] = [:]
            do {
                for (name, body) in [("queriesAndNavigation", Checks.queriesAndNavigation),
                                     ("candidatePolicy", Checks.candidatePolicy),
                                     ("selectionBinding", Checks.selectionBinding),
                                     ("hostileSnapshots", Checks.hostileSnapshots)] {
                    let before = Checks.checks.count; try body(); groups[name] = Checks.checks.count - before
                }
                var before = Checks.checks.count
                try await lifecycle()
                groups["adapterMountAndCancellation"] = Checks.checks.count - before
                before = Checks.checks.count
                try await localWebKit(local: local)
                groups["actualWebKitDOMAndPrivacy"] = Checks.checks.count - before
                if CommandLine.arguments.contains("--live") {
                    before = Checks.checks.count
                    report["live"] = try await live(output: output)
                    groups["actualProviderSearch"] = Checks.checks.count - before
                }
                report["status"] = "PASS"
            } catch {
                report["status"] = "FAIL"
                report["failure"] = (error as? ResearchSourceDiscoveryError)?.rawValue
                    ?? (error as? Checks.Failure)?.message ?? "harness_operation_failed"
            }
            report["groups"] = groups; report["passed_assertions"] = Checks.checks.count
            if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
                try? bytes.write(to: output.appendingPathComponent("result.json"), options: .atomic)
            }
            print("RESEARCH_SOURCE_DISCOVERY_\(report["status"]!) checks=\(Checks.checks.count) groups=\(groups.count)")
            fflush(stdout); exit(report["status"] as? String == "PASS" ? 0 : 1)
        }
        app.run()
    }

    @MainActor static func rejected(_ expected: ResearchSourceDiscoveryError,
                                    _ work: () async throws -> Void) async throws {
        do { try await work(); throw Checks.Failure(message: "missing async rejection") }
        catch let error as ResearchSourceDiscoveryError { try Checks.expect(error == expected, "exact async rejection: \(expected.rawValue)") }
    }
    @MainActor static func mount(_ view: WKWebView) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = view; window.orderFront(nil)
        return window
    }
    @MainActor static func lifecycle() async throws {
        let unmounted = ResearchSourceDiscoveryWebKit()
        try Checks.expect(unmounted.requestsStarted == 0 && !unmounted.webView.configuration.websiteDataStore.isPersistent, "init is ephemeral and sends no request")
        try Checks.expect(!unmounted.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript &&
                          !unmounted.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically, "page scripting and new windows disabled")
        try await rejected(.invalidQuery) { _ = try await unmounted.search(query: "") }
        let start = ContinuousClock.now
        try await rejected(.notMounted) { _ = try await unmounted.search(query: "synthetic local mount test") }
        try Checks.expect(start.duration(to: .now) < .seconds(3) && unmounted.requestsStarted == 0, "bounded mount wait never loads provider")
        try await rejected(.alreadyUsed) { _ = try await unmounted.search(query: "synthetic") }
        unmounted.cancel()
        try await rejected(.cancelled) { _ = try await unmounted.search(query: "synthetic") }

        let cancelled = ResearchSourceDiscoveryWebKit()
        let task = Task { @MainActor in try await cancelled.search(query: "synthetic cancellation") }
        try await Task.sleep(nanoseconds: 40_000_000)
        task.cancel()
        try await rejected(.cancelled) { _ = try await task.value }
        try Checks.expect(cancelled.requestsStarted == 0 && cancelled.lastDOMSnapshot == nil, "cancel drains mount without publishing/network")
        cancelled.cancel(); cancelled.cancel()
        try await rejected(.cancelled) { _ = try await cancelled.search(query: "synthetic") }

        let beforeStart = ResearchSourceDiscoveryWebKit()
        beforeStart.cancel()
        try await rejected(.cancelled) { _ = try await beforeStart.search(query: "synthetic") }
        try Checks.expect(beforeStart.requestsStarted == 0, "retired view never sends a request")
    }

    @MainActor static func rules() async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "woow-discovery-local-acceptance",
                encodedContentRuleList: ResearchSourceDiscoveryWebKit.contentRules) { value, _ in
                if let value { continuation.resume(returning: value) }
                else { continuation.resume(throwing: Checks.Failure(message: "real content-rule compilation failed")) }
            }
        }
    }
    @MainActor static func evaluate(_ web: WKWebView, _ fixed: String) async throws -> Any {
        try await withCheckedThrowingContinuation { continuation in
            web.evaluateJavaScript(fixed, in: nil, in: .defaultClient) { result in continuation.resume(with: result) }
        }
    }
    @MainActor private static func fixture(_ html: String, rules: WKContentRuleList?) async throws -> (WKWebView, NSWindow, FixtureNavigation) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent(); config.defaultWebpagePreferences.allowsContentJavaScript = false
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        if let rules { config.userContentController.add(rules) }
        let web = WKWebView(frame: .zero, configuration: config), delegate = FixtureNavigation()
        web.navigationDelegate = delegate
        let window = mount(web)
        web.loadHTMLString(html, baseURL: nil)
        let until = ContinuousClock.now.advanced(by: .seconds(10))
        while !delegate.finished && !delegate.failed && ContinuousClock.now < until { try await Task.sleep(nanoseconds: 20_000_000) }
        try Checks.expect(delegate.finished && !delegate.failed, "actual local HTML finished inside bound")
        return (web, window, delegate)
    }
    @MainActor static func localWebKit(local: String) async throws {
        let compiled = try await rules()
        // Loopback server exists solely in the checker, not in any public adapter API.
        for protected in [false, true] {
            let mode = protected ? "blocked" : "control"
            let (web, window, delegate) = try await fixture("""
            <html><head><link rel="stylesheet" href="\(local)/\(mode).css"></head><body>
            <div id="links"><a class="result__a" href="https://docs.swift.org/documentation/">Actual visible anchor</a>
            <a class="result__a" hidden href="https://example.com/hidden">Hidden</a>
            <span style="opacity:0"><a class="result__a" href="https://example.com/transparent">Invisible</a></span>
            <a class="result__a" download href="https://example.com/file">Download</a>
            <a class="result__a" href="https://example.com/login">Login data</a></div>
            <img id="probe" src="\(local)/\(mode).png">
            <script>document.querySelector('.result__a').href='https://example.com/forged';window.forged=true;</script>
            </body></html>
            """, rules: protected ? compiled : nil)
            defer { withExtendedLifetime(delegate) {}; web.stopLoading(); window.orderOut(nil) }
            let snapshot = try await evaluate(web, ResearchSourceDiscoveryWebKit.observationScript) as? String
            let page = try JSONDecoder().decode(ResearchSourceDiscoveryDOM.self, from: Data((snapshot ?? "").utf8))
            try Checks.expect(page.resultsPresent && !page.challenge && !page.oversized && page.links.count == 2, "fixed DOM observer excludes hidden/download anchors")
            try Checks.expect(page.links.first?.href == "https://docs.swift.org/documentation/", "page script cannot forge DOM candidate")
            let scriptDisabled = try await evaluate(web, "typeof window.forged === 'undefined'") as? Bool
            try Checks.expect(scriptDisabled == true, "inline page JavaScript never executed")
            let pixels = try await evaluate(web, "document.getElementById('probe').naturalWidth") as? Int
            let color = try await evaluate(web, "getComputedStyle(document.body).color") as? String
            try Checks.expect(protected ? pixels == 0 : pixels == 1, "real resource image block/control")
            try Checks.expect(protected ? color != "rgb(1, 2, 3)" : color == "rgb(1, 2, 3)", "real foreign stylesheet block/control")
        }
        for (html, oversized, challenge) in [
            ("<html><body><form id='challenge-form'>Synthetic captcha</form></body></html>", false, true),
            ("<html><body>" + String(repeating: "臺", count: 360_000) + "</body></html>", true, false)
        ] {
            let (web, window, delegate) = try await fixture(html, rules: compiled)
            defer { withExtendedLifetime(delegate) {}; web.stopLoading(); window.orderOut(nil) }
            let raw = try await evaluate(web, ResearchSourceDiscoveryWebKit.observationScript) as? String
            let page = try JSONDecoder().decode(ResearchSourceDiscoveryDOM.self, from: Data((raw ?? "").utf8))
            try Checks.expect(page.oversized == oversized && page.challenge == challenge, "actual DOM UTF8 size/challenge detection")
        }
    }

    @MainActor static func live(output: URL) async throws -> [String: Any] {
        let adapter = ResearchSourceDiscoveryWebKit(), query = "Swift concurrency documentation"
        let start = Date()
        // Start first, mount on the next render turn: exercises the actual local mount wait.
        let task = Task { @MainActor in try await adapter.search(query: query) }
        await Task.yield()
        let window = mount(adapter.webView)
        defer { adapter.cancel(); window.orderOut(nil) }
        do {
            let result = try await task.value
            guard let bytes = adapter.lastDOMSnapshot else { throw Checks.Failure(message: "missing actual DOM") }
            try bytes.write(to: output.appendingPathComponent("live-dom.json"), options: .atomic)
            let page = try JSONDecoder().decode(ResearchSourceDiscoveryDOM.self, from: bytes)
            try Checks.expect(adapter.requestsStarted == 1 && adapter.httpStatus == 200, "one exact native page request")
            try Checks.expect(!result.grantsResearchAuthorization && !result.candidates.isEmpty, "real candidates do not authorize research")
            try Checks.expect(Set(result.candidates.compactMap { $0.url.host }).count >= 2, "actual public response offers distinct origins for review")
            for candidate in result.candidates {
                try Checks.expect(page.links.contains { $0.index == candidate.domIndex && $0.href == candidate.url.absoluteString && $0.title == candidate.title }, "each candidate matches exact observed DOM anchor")
            }
            try await rejected(.alreadyUsed) { _ = try await adapter.search(query: query) }
            let record: [String: Any] = ["status": "PASS", "provider": result.provider.rawValue,
                "query": result.query, "page_url": result.pageURL.absoluteString,
                "observed_at": ISO8601DateFormatter().string(from: result.observedAt),
                "seconds": Date().timeIntervalSince(start), "http_status": adapter.httpStatus ?? 0,
                "main_load_requests": adapter.requestsStarted, "html_bytes": result.htmlByteCount,
                "dom_sha256": result.observationSHA256, "truncated": result.truncated,
                "rejected_links": result.rejectedLinkCount,
                "candidates": result.candidates.map { ["title": $0.title, "url": $0.url.absoluteString, "dom_index": $0.domIndex] as [String: Any] }]
            let report = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try report.write(to: output.appendingPathComponent("live-result.json"), options: .atomic)
            return record
        } catch {
            let record: [String: Any] = ["status": "FAIL", "provider": adapter.provider.rawValue,
                "query": query, "page_url": try adapter.provider.searchURL(query: query).absoluteString,
                "seconds": Date().timeIntervalSince(start), "http_status": adapter.httpStatus ?? 0,
                "main_load_requests": adapter.requestsStarted,
                "failure": (error as? ResearchSourceDiscoveryError)?.rawValue ?? "acceptance_failed"]
            let bytes = try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys])
            try bytes.write(to: output.appendingPathComponent("live-result.json"), options: .atomic)
            if let dom = adapter.lastDOMSnapshot { try dom.write(to: output.appendingPathComponent("live-dom.json")) }
            throw error
        }
    }
}

private final class FixtureNavigation: NSObject, WKNavigationDelegate {
    private let lock = NSLock()
    private var didFinish = false, didFail = false
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return didFinish }
    var failed: Bool { lock.lock(); defer { lock.unlock() }; return didFail }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { lock.lock(); didFinish = true; lock.unlock() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { lock.lock(); didFail = true; lock.unlock() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { lock.lock(); didFail = true; lock.unlock() }
}
