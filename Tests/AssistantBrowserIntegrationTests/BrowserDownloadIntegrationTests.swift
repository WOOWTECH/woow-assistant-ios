#if canImport(WebKit) && canImport(Network)
import Foundation
import Network
import WebKit
@testable import AssistantBrowser
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// Real HTTP bytes -> WebKit network process -> WKDownload -> sandbox file.
/// No URLProtocol stubs, copied cookies, external service, or trust override.
/// Loopback is admitted ONLY by the manager's internal @testable initializer;
/// the public manager still rejects all HTTP/private-address downloads.
@MainActor
enum BrowserDownloadIntegrationFixtures {
    struct Failure: Error { let message: String }

    static func run() async throws -> Int {
        let fixture = try DownloadHTTPFixture()
        try await fixture.start()
        defer { fixture.stop() }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wkdownload-test-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = BrowserDownloadManager(directory: directory, limits: .init(), allowsURL: fixture.allows)
        let host = try Host(manager: manager)
        defer { host.close() }
        var assertions = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            guard try value() else { throw Failure(message: message) }
        }
        let cookie = HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/",
                                            .name: "download_fixture", .value: "present"])!
        await host.webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie)

        // Both navigation delegate conversion callbacks are used by real WebKit.
        for useDownloadAttribute in [true, false] {
            trace(useDownloadAttribute ? "navigation-action-begin" : "navigation-response-begin")
            host.navigation.finishedPage = false
            host.webView.loadHTMLString("<html><body><a id='file' href='\(fixture.url("file").absoluteString)?marker=FIXTURE_ONLY' \(useDownloadAttribute ? "download" : "")>download</a></body></html>", baseURL: fixture.url("page"))
            try await wait { host.navigation.finishedPage }
            _ = try await host.webView.evaluateJavaScript("document.getElementById('file').click(); true")
            try await wait {
                host.navigation.identityFailure != nil
                    || manager.items.filter { $0.status == .completed }.count == (useDownloadAttribute ? 1 : 2)
            }
            try expect(host.navigation.identityFailure == nil,
                       host.navigation.identityFailure ?? "Policy object identity and permit consumption succeeded")
            trace(useDownloadAttribute ? "navigation-action-completed" : "navigation-response-completed")
        }
        try expect(host.navigation.actionDownloads == 1, "Real action didBecome callback")
        try expect(host.navigation.responseDownloads == 1, "Real response didBecome callback")
        try expect(host.navigation.actionIdentityMatches == 1, "Action callback returns the exact policy-delegate object")
        try expect(host.navigation.responseIdentityMatches == 1, "Response callback returns the exact policy-delegate object")
        try expect(host.navigation.staleActionRejected, "Prior action callback cannot consume a new response permit")
        try expect(fixture.authenticatedRequests == 2, "WebKit download uses its originating session cookie")
        let records = manager.items
        try expect(records.count == 2 && records.allSatisfy { $0.status == .completed }, "Real downloads completed")
        for item in records {
            try expect(try Data(contentsOf: manager.fileURL(id: item.id)) == fixture.payload, "Actual downloaded bytes match fixture")
            try expect(!item.fileName.contains("/") && !item.fileName.contains("\\"), "Server filename is sanitized")
        }
        try expect(try manager.fileURL(id: records[0].id) != manager.fileURL(id: records[1].id), "Duplicate server names cannot overwrite")
        let restored = BrowserDownloadManager(directory: directory)
        try expect(restored.items == manager.items, "Completed downloads survive manager restart")
        let manifest = try String(contentsOf: directory.appendingPathComponent("completed.json"))
        try expect(!manifest.contains("FIXTURE_ONLY") && !manifest.contains("127.0.0.1") && !manifest.contains("present"), "No signed URL/cookie metadata")

        trace("slow-begin")
        let slow = try await start(host.webView, manager: manager, url: fixture.url("slow"))
        try await wait {
            guard let item = manager.items.first(where: { $0.id == slow }) else { return false }
            return item.receivedBytes > 0 || !item.status.isActive
        }
        trace("slow-progress", manager: manager)
        try expect(manager.items.first { $0.id == slow }?.status == .downloading, "Progress is sampled while transfer is active")
        manager.cancel(id: slow)
        try await wait { manager.items.first { $0.id == slow }?.status == .cancelled }
        trace("slow-cancelled")
        try expect(try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Partial").path).isEmpty,
                   "Cancellation acknowledgement removes the partial file")
        do { _ = try manager.fileURL(id: slow); throw Failure(message: "Cancelled file was shareable") }
        catch is BrowserDownloadError { assertions += 1 }

        trace("redirect-begin")
        let redirected = try await start(host.webView, manager: manager, url: fixture.url("redirect"))
        try await wait { manager.items.first { $0.id == redirected }?.status == .completed }
        try expect(try Data(contentsOf: manager.fileURL(id: redirected)) == fixture.payload, "Allowed redirect stays inside WebKit session")
        trace("blocked-redirect-begin")
        let blocked = try await start(host.webView, manager: manager, url: fixture.url("blocked-redirect"))
        try await wait { manager.items.first { $0.id == blocked }?.status == .failed }
        try expect(manager.items.first { $0.id == blocked }?.failureMessage == BrowserDownloadError.unsafeURL.localizedDescription,
                   "Redirect destination is revalidated before allowing")

        // Defence-in-depth accept gate: native download objects received after
        // research cancellation must be cancelled without publishing any record.
        let before = manager.items.count
        trace("research-accept-begin")
        let rejected = try await receiveDownload(host.webView, manager: manager, url: fixture.url("slow"), allowsDownload: false)
        try expect(rejected == nil, "Research acceptance always rejects")
        try expect(manager.items.count == before, "Research never creates a download item")
        // The navigation policy blocks research before converting to WKDownload.
        host.navigation.research = true
        host.navigation.finishedPage = false
        host.webView.loadHTMLString("<a id='file' href='\(fixture.url("file"))' download>download</a>", baseURL: fixture.url("page"))
        try await wait { host.navigation.finishedPage }
        _ = try await host.webView.evaluateJavaScript("document.getElementById('file').click(); true")
        try await wait { host.navigation.blockedResearch > 0 }
        try expect(host.navigation.actionDownloads == 1 && manager.items.count == before, "Research download action cancelled at navigation policy")
        host.navigation.finishedPage = false
        host.webView.loadHTMLString("<a id='file' href='\(fixture.url("file"))'>download</a>", baseURL: fixture.url("page"))
        try await wait { host.navigation.finishedPage }
        _ = try await host.webView.evaluateJavaScript("document.getElementById('file').click(); true")
        try await wait { host.navigation.blockedResearch == 2 }
        try expect(host.navigation.responseDownloads == 1 && manager.items.count == before, "Research attachment response cancelled at navigation policy")
        host.navigation.research = false

        // Known oversized Content-Length and an unknown-length stream are both bounded.
        for endpoint in ["oversize", "unknown"] {
            trace("limit-" + endpoint + "-begin")
            let limitedRoot = directory.appendingPathComponent("limited-" + endpoint)
            let limited = BrowserDownloadManager(directory: limitedRoot,
                limits: .init(maximumFileBytes: 1_024), allowsURL: fixture.allows)
            let id = try await start(host.webView, manager: limited, url: fixture.url(endpoint))
            try await wait { limited.items.first { $0.id == id }?.status == .failed }
            try expect(limited.items.first?.failureMessage == BrowserDownloadError.tooLarge.localizedDescription, "Byte limit enforces \(endpoint)")
            try expect(try FileManager.default.contentsOfDirectory(atPath: limitedRoot.appendingPathComponent("Partial").path).isEmpty,
                       "Oversized partial is removed")
        }
        let originalFile = try manager.fileURL(id: records[0].id)
        do { try manager.delete(id: records[0].id, confirmed: false); throw Failure(message: "Unconfirmed deletion succeeded") }
        catch BrowserDownloadError.confirmationRequired { assertions += 1 }
        try expect(FileManager.default.fileExists(atPath: originalFile.path), "Unconfirmed deletion preserves real download")
        try manager.delete(id: records[0].id, confirmed: true)
        try expect(!FileManager.default.fileExists(atPath: originalFile.path), "Confirmed deletion removes real download")
        trace("all-checks-completed")
        return assertions
    }

    private static func start(_ webView: WKWebView, manager: BrowserDownloadManager, url: URL) async throws -> UUID {
        guard let id = try await receiveDownload(webView, manager: manager, url: url, allowsDownload: true) else {
            throw Failure(message: "Fixture download rejected")
        }
        return id
    }

    private static func receiveDownload(_ webView: WKWebView, manager: BrowserDownloadManager,
                                        url: URL, allowsDownload: Bool) async throws -> UUID? {
        var delivered = false
        var expired = false
        var id: UUID?
        // Install WKDownloadDelegate synchronously in WebKit's native callback,
        // just as the production didBecome integration does. The async overlay
        // introduces a suspension before accept; do not rely on that timing.
        webView.startDownload(using: URLRequest(url: url)) { download in
            guard !expired else { download.cancel(nil); return }
            id = manager.accept(download, sourceURL: url, allowsDownload: allowsDownload)
            delivered = true
            trace("native-download-delivered", manager: manager)
        }
        do { try await wait { delivered } }
        catch { expired = true; trace("native-download-delivery-timeout", manager: manager); throw error }
        return id
    }

    private static func trace(_ step: String, manager: BrowserDownloadManager? = nil) {
        // Fixed stages and status counts only: no URLs, headers, filenames,
        // cookie values, native descriptions or underlying network errors.
        guard let manager else { print("WKDOWNLOAD_STEP \(step)"); return }
        let items = manager.items
        print("WKDOWNLOAD_STEP \(step) active=\(items.filter { $0.status.isActive }.count) completed=\(items.filter { $0.status == .completed }.count) failed=\(items.filter { $0.status == .failed }.count)")
    }

    private static func wait(line: Int = #line, _ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        guard condition() else {
            trace("wait-timeout-line-\(line)")
            throw Failure(message: "Real WebKit fixture timed out at fixture line \(line)")
        }
    }

    @MainActor private final class Navigation: NSObject, WKNavigationDelegate {
        let manager: BrowserDownloadManager
        var finishedPage = false
        var research = false
        var blockedResearch = 0
        var actionDownloads = 0
        var responseDownloads = 0
        var actionIdentityMatches = 0
        var responseIdentityMatches = 0
        var staleActionRejected = false
        var identityFailure: String?
        private var issuedAction: WKNavigationAction?
        private var issuedResponse: WKNavigationResponse?
        private var intent = BrowserNavigationIntent()
        // Only a policy-provenance alias: network traffic still uses the exact
        // loopback fixture. This tests real WK wrapper identity through the core
        // permit; it does not exercise BrowserSession or relax production policy.
        private let provenanceURL = URL(string: "https://download.example.invalid/fixture")!
        init(manager: BrowserDownloadManager) { self.manager = manager }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishedPage = true }
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if navigationAction.shouldPerformDownload {
                if research { blockedResearch += 1 }
                else {
                    issuedAction = navigationAction
                    intent.beginManual(provenanceURL)
                    guard intent.authorizeDownload(provenanceURL, source: .action(navigationAction)) else {
                        identityFailure = "Action permit was not issued"; decisionHandler(.cancel); return
                    }
                }
                decisionHandler(research ? .cancel : .download)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                     decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
            if BrowserDownloadPolicy.isAttachment(navigationResponse.response) || !navigationResponse.canShowMIMEType {
                if research { blockedResearch += 1 }
                else {
                    issuedResponse = navigationResponse
                    intent.beginManual(provenanceURL)
                    guard intent.authorizeDownload(provenanceURL, source: .response(navigationResponse)) else {
                        identityFailure = "Response permit was not issued"; decisionHandler(.cancel); return
                    }
                    if let old = issuedAction {
                        staleActionRejected = !intent.consumeDownload(provenanceURL, source: .action(old))
                        if !staleActionRejected { identityFailure = "Old action consumed the response permit" }
                    }
                }
                decisionHandler(research ? .cancel : .download)
            } else { decisionHandler(.allow) }
        }
        func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
            actionDownloads += 1
            let sameObject = issuedAction === navigationAction
            if sameObject { actionIdentityMatches += 1 }
            let approved = intent.consumeDownload(provenanceURL, source: .action(navigationAction)) && !research
            if !sameObject || !approved { identityFailure = "Action didBecome identity or permit did not match" }
            manager.accept(download, sourceURL: navigationAction.request.url, allowsDownload: sameObject && approved)
        }
        func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
            responseDownloads += 1
            let sameObject = issuedResponse === navigationResponse
            if sameObject { responseIdentityMatches += 1 }
            let approved = intent.consumeDownload(provenanceURL, source: .response(navigationResponse)) && !research
            if !sameObject || !approved { identityFailure = "Response didBecome identity or permit did not match" }
            manager.accept(download, sourceURL: navigationResponse.response.url, allowsDownload: sameObject && approved)
        }
    }

    @MainActor private final class Host {
        let webView: WKWebView
        let navigation: Navigation
        #if os(iOS)
        let window: UIWindow
        let previous: UIWindow?
        #else
        let window: NSWindow
        #endif

        init(manager: BrowserDownloadManager) throws {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            webView = WKWebView(frame: .zero, configuration: configuration)
            navigation = Navigation(manager: manager)
            webView.navigationDelegate = navigation
            #if os(iOS)
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
                throw Failure(message: "Hosted WebKit tests require an app scene")
            }
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            let controller = UIViewController(); controller.view = webView
            window.rootViewController = controller; window.makeKeyAndVisible()
            #else
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
                              styleMask: [.borderless], backing: .buffered, defer: false)
            window.contentView = webView
            #endif
        }

        func close() {
            webView.stopLoading(); webView.navigationDelegate = nil
            for item in navigation.manager.items where item.status.isActive { navigation.manager.cancel(id: item.id) }
            #if os(iOS)
            window.isHidden = true; previous?.makeKey()
            #else
            window.orderOut(nil)
            #endif
        }
    }
}

private final class DownloadHTTPFixture: @unchecked Sendable {
    let payload = Data("WKDOWNLOAD_FIXTURE_繁體中文\n".utf8)
    private let queue = DispatchQueue(label: "browser-download-http-fixture")
    private let listener: NWListener
    private var connections: [NWConnection] = []
    private let lock = NSLock()
    private var authenticated = 0
    var authenticatedRequests: Int { lock.lock(); defer { lock.unlock() }; return authenticated }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var resumed = false
            listener.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready: resumed = true; continuation.resume()
                case .failed(let error): resumed = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: self.queue)
                self.receive(connection, accumulated: Data())
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        queue.sync { for connection in connections { connection.cancel() }; connections.removeAll() }
    }

    func url(_ path: String) -> URL { URL(string: "http://127.0.0.1:\(listener.port!.rawValue)/\(path)")! }
    func allows(_ url: URL) -> Bool { url.scheme == "http" && url.host == "127.0.0.1" && url.port == Int(listener.port!.rawValue) }

    private func receive(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var bytes = accumulated; bytes.append(data ?? Data())
            guard bytes.count <= 16_384 else { connection.cancel(); return }
            let text = String(decoding: bytes, as: UTF8.self)
            if text.contains("\r\n\r\n") { self.reply(connection, request: text) }
            else if !done { self.receive(connection, accumulated: bytes) }
            else { connection.cancel() }
        }
    }

    private func reply(_ connection: NWConnection, request: String) {
        let target = request.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let path = target.split(separator: "?").first.map(String.init) ?? ""
        if path == "/redirect" || path == "/blocked-redirect" {
            let location = path == "/redirect" ? url("file").absoluteString : "http://127.0.0.2:\(listener.port!.rawValue)/file"
            send(connection, Data("HTTP/1.1 302 Found\r\nLocation: \(location)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
            return
        }
        if path == "/file" {
            guard request.lowercased().contains("download_fixture=present") else {
                send(connection, Data("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)); return
            }
            lock.lock(); authenticated += 1; lock.unlock()
        }
        let streaming = path == "/slow" || path == "/unknown"
        let body = streaming || path == "/oversize" ? Data(repeating: 65, count: 65_536) : payload
        let length = path == "/unknown" ? "" : "Content-Length: \(body.count)\r\n"
        let headers = Data("HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=\"../../fixture.txt\"\r\n\(length)Connection: close\r\n\r\n".utf8)
        if streaming {
            connection.send(content: headers, completion: .contentProcessed { [weak self] error in
                guard let self, error == nil else { connection.cancel(); return }
                self.stream(connection, data: body, offset: 0)
            })
        } else { send(connection, headers + body) }
    }

    private func send(_ connection: NWConnection, _ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func stream(_ connection: NWConnection, data: Data, offset: Int) {
        guard offset < data.count else { connection.cancel(); return }
        let end = min(data.count, offset + 512)
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else { connection.cancel(); return }
            self.queue.asyncAfter(deadline: .now() + 0.03) { self.stream(connection, data: data, offset: end) }
        })
    }
}

#if BROWSER_DOWNLOAD_WEBKIT_SMOKE && os(macOS)
@main enum BrowserDownloadWebKitSmoke {
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                let count = try await BrowserDownloadIntegrationFixtures.run()
                print("Real WKDownload: \(count) hosted assertions passed")
                exit(0)
            } catch {
                // Fixed fixture failures only; no production URLs/credentials.
                if let failure = error as? BrowserDownloadIntegrationFixtures.Failure { print("FAIL: " + failure.message) }
                else { print("FAIL: real WKDownload fixture could not run") }
                exit(1)
            }
        }
        application.run()
    }
}
#elseif canImport(XCTest)
import XCTest
final class BrowserDownloadIntegrationTests: XCTestCase {
    @MainActor func testRealWebKitSessionDownloadsRedirectsProgressAndCancellation() async throws {
        let assertions = try await BrowserDownloadIntegrationFixtures.run()
        XCTAssertGreaterThan(assertions, 25)
    }
}
#endif
#endif
