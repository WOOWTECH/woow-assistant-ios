#if BROWSER_UPLOAD_FIXTURE_SMOKE
import Foundation
import Network

/// Compile with the actual DEBUG server, without XCTest or an iOS simulator:
/// swiftc -D DEBUG -D BROWSER_UPLOAD_FIXTURE_SMOKE -parse-as-library \
///   Sources/App/BrowserUploadFixture.swift \
///   Tests/WoowAssistantUITests/BrowserUploadUITests.swift -o /tmp/upload-checks
/// This proves HTTP/parser/lifecycle behavior, NOT native chooser operation.
@main enum BrowserUploadFixtureChecks {
    struct Failure: Error { let message: String }

    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("browser-upload-checks-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var fixtures: [BrowserUploadFixture] = []
        defer {
            for fixture in fixtures { fixture.stop(); _ = fixture.allows(URL(string: "https://example.invalid")!) }
            try? fm.removeItem(at: root)
        }
        var assertions = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            guard try condition() else { throw Failure(message: message) }
        }
        let namespace = UUID().uuidString
        let arguments = ["fixture", "-UITestMode", "-UITestBrowserUpload", "-UITestNamespace", namespace]
        for flags in [[], ["-UITestMode"], ["-UITestBrowserUpload"],
                      ["-UITestMode", "-UITestBrowserUpload", "-UITestNamespace", "not-a-uuid"],
                      arguments + ["-UITestNamespace", namespace], arguments + ["-UITestMode"]] {
            try expect(BrowserUploadFixture(arguments: flags, documentsDirectory: root) == nil, "Strict flag/namespace gating")
        }
        func fixture(timeout: TimeInterval = 10, lifetime: TimeInterval = 300, directory: URL? = nil) throws -> BrowserUploadFixture {
            guard let value = BrowserUploadFixture(arguments: arguments,
                documentsDirectory: directory ?? root.appendingPathComponent(UUID().uuidString),
                requestTimeout: timeout, lifetime: lifetime) else { throw Failure(message: "Fixture setup rejected") }
            fixtures.append(value)
            return value
        }
        let documents = root.appendingPathComponent("Documents")
        let server = try fixture(directory: documents)
        let formURL = try await server.start()
        let sameURL = try await server.start()
        try expect(formURL == sameURL, "Repeated start shares listener")
        try expect(server.allows(formURL), "Running fixture allows its own form")
        let origin = "http://127.0.0.1:\(formURL.port!)"
        let prefix = formURL.deletingLastPathComponent().path
        for suffix in ["/form", "/upload", "/status"] {
            try expect(server.allows(URL(string: origin + prefix + suffix)!), "Allow exact fixture paths")
        }
        for raw in [formURL.absoluteString + "?x=1", formURL.absoluteString + "#fragment", origin + "/other",
                    formURL.absoluteString.replacingOccurrences(of: "/form", with: "/%66orm"),
                    formURL.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
                    formURL.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "127.0.0.2"),
                    formURL.absoluteString.replacingOccurrences(of: "http://", with: "https://"),
                    formURL.absoluteString.replacingOccurrences(of: "http://", with: "http://user:pass@"),
                    "http://127.0.0.1:1" + prefix + "/form"] {
            try expect(!server.allows(URL(string: raw)!), "Reject altered origin, URL authority, or path")
        }
        let seed = documents.appendingPathComponent(BrowserUploadFixture.filename)
        try expect(try Data(contentsOf: seed) == BrowserUploadFixture.payload && BrowserUploadFixture.payload.count == 31,
                   "Documents contains exactly the synthetic 31-byte file")

        func request(_ method: String, _ path: String, body: Data = Data(),
                     extra: [String] = [], host: String? = nil, contentLength: String? = nil) -> Data {
            let headers = ["\(method) \(path) HTTP/1.1", "Host: \(host ?? "127.0.0.1:\(formURL.port!)")",
                           "Content-Length: \(contentLength ?? String(body.count))", "Connection: close"] + extra
            return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
        }
        func exchange(_ bytes: Data, fragment: Int? = nil) async throws -> UploadHTTPProbe.Response {
            try await UploadHTTPProbe(port: UInt16(formURL.port!)).exchange(bytes, fragment: fragment)
        }
        let initial = try await exchange(request("GET", prefix + "/form"), fragment: 7)
        try expect(initial.status == 200 && initial.body.contains("UPLOAD_FORM_READY"), "Actual fragmented GET serves form")
        try expect(initial.body.contains("multipart/form-data") && initial.body.contains("type=\"file\""), "Real file input and multipart form")
        try expect(initial.headers.contains("Cache-Control: no-store") && initial.headers.contains("Content-Security-Policy:"), "No cached receipt and constrained HTML")
        let empty = try await exchange(request("GET", prefix + "/status"))
        try expect(empty.body.contains("UPLOAD_SERVER_RECEIPTS_0"), "Selection-free server count is zero")
        let boundary = "----WebKitFormBoundarySyntheticFixture"
        func multipart(name: String = BrowserUploadFixture.filename, payload: Data = BrowserUploadFixture.payload,
                       partName: String = "file", ending: Bool = true) -> Data {
            Data(("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(partName)\"; filename=\"\(name)\"\r\nContent-Type: text/plain\r\n\r\n").utf8)
                + payload + Data(("\r\n--\(boundary)--" + (ending ? "\r\n" : "")).utf8)
        }
        let headers = ["Origin: " + origin, "Content-Type: multipart/form-data; boundary=" + boundary]
        let valid = try await exchange(request("POST", prefix + "/upload", body: multipart(), extra: headers), fragment: 5)
        try expect(valid.status == 200, "Fragmented real HTTP multipart succeeds")
        try expect(valid.body.contains("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1")
                   && valid.body.contains("UPLOAD_SERVER_RECEIPTS_1") && valid.body.contains("UPLOAD_FILE_BYTES_31"),
                   "Only exact bytes yield actual receipt")
        let one = try await exchange(request("GET", prefix + "/status"))
        try expect(one.body.contains("UPLOAD_SERVER_RECEIPTS_1"), "Independent HTTP query confirms receipt")

        let extraPart = multipart(payload: BrowserUploadFixture.payload + Data(("\r\n--\(boundary)\r\nContent-Disposition: form-data; name=\"other\"\r\n\r\nextra").utf8))
        let cases: [(Data, Int)] = [
            (request("POST", prefix + "/upload", body: multipart(name: "../BrowserUploadFixture.txt"), extra: headers), 422),
            (request("POST", prefix + "/upload", body: multipart(payload: Data("wrong bytes".utf8)), extra: headers), 422),
            (request("POST", prefix + "/upload", body: multipart(partName: "other"), extra: headers), 422),
            (request("POST", prefix + "/upload", body: extraPart, extra: headers), 422),
            (request("POST", prefix + "/upload", body: Data(multipart().dropLast(7)), extra: headers), 400),
            (request("POST", prefix + "/upload", body: multipart(), extra: ["Origin: https://example.invalid", headers[1]]), 403),
            (request("POST", prefix + "/upload", body: multipart(), extra: [headers[1]]), 403),
            (request("POST", prefix + "/upload", body: multipart(), extra: [headers[0], "Content-Type: text/plain"]), 415),
            (request("POST", prefix + "/upload", body: multipart(), extra: headers + ["Transfer-Encoding: chunked"]), 400),
            (request("POST", prefix + "/upload", body: multipart(), extra: headers + ["Content-Length: 1"]), 400),
            (request("GET", prefix + "/status", extra: ["Host: 127.0.0.1"]), 400),
            (request("GET", prefix + "/status", host: "example.invalid"), 403),
            (request("GET", prefix + "/status?x=1"), 403),
            (request("GET", prefix + "/../status"), 403),
            (request("POST", prefix + "/upload", contentLength: "16385"), 413),
            (request("POST", prefix + "/upload", contentLength: "-1"), 411),
            (request("GET", prefix + "/status", extra: ["X-Large: " + String(repeating: "a", count: 9_000)]), 431)
        ]
        for (bytes, expectedStatus) in cases {
            let response = try await exchange(bytes)
            try expect(response.status == expectedStatus && !response.body.contains("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1"),
                       "Malformed HTTP/multipart cannot claim receipt")
        }
        let afterBad = try await exchange(request("GET", prefix + "/status"))
        try expect(afterBad.body.contains("UPLOAD_SERVER_RECEIPTS_1"), "Rejected requests do not increment server receipt count")
        let quoted = try await exchange(request("POST", prefix + "/upload", body: multipart(ending: false),
            extra: [headers[0], "Content-Type: multipart/form-data; boundary=\"" + boundary + "\""]))
        try expect(quoted.status == 200 && quoted.body.contains("UPLOAD_SERVER_RECEIPTS_2"), "Quoted boundary and legal terminal delimiter")
        for _ in 0..<14 { _ = try await exchange(request("POST", prefix + "/upload", body: multipart(), extra: headers)) }
        let receiptLimit = try await exchange(request("POST", prefix + "/upload", body: multipart(), extra: headers))
        try expect(receiptLimit.status == 429, "Receipt count is bounded")

        let slow = try fixture(timeout: 0.2)
        let slowURL = try await slow.start()
        do {
            _ = try await UploadHTTPProbe(port: UInt16(slowURL.port!)).exchange(Data("GET ".utf8))
            throw Failure(message: "Slow incomplete request should close")
        } catch UploadHTTPProbe.Failure.closed { assertions += 1 }
        let concurrent = try fixture(timeout: 1)
        let concurrentURL = try await concurrent.start()
        let held = (0..<4).map { _ in
            Task { try await UploadHTTPProbe(port: UInt16(concurrentURL.port!)).exchange(Data("GET ".utf8)) }
        }
        let admissionDeadline = ProcessInfo.processInfo.systemUptime + 0.8
        while concurrent.smokeActiveConnections < 4, ProcessInfo.processInfo.systemUptime < admissionDeadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try expect(concurrent.smokeActiveConnections == 4, "Four active connections admitted")
        do {
            _ = try await UploadHTTPProbe(port: UInt16(concurrentURL.port!)).exchange(Data("GET ".utf8))
            throw Failure(message: "Fifth connection should be refused")
        } catch UploadHTTPProbe.Failure.closed { assertions += 1 }
        for task in held {
            do { _ = try await task.value; throw Failure(message: "Incomplete held request should expire") }
            catch UploadHTTPProbe.Failure.closed { assertions += 1 }
        }
        try expect(concurrent.smokeActiveConnections == 0, "Timed-out connections release all slots")
        let bounded = try fixture()
        let boundedURL = try await bounded.start()
        let boundedRequest = Data("GET \(boundedURL.path) HTTP/1.1\r\nHost: 127.0.0.1:\(boundedURL.port!)\r\n\r\n".utf8)
        for _ in 0..<64 {
            let response = try await UploadHTTPProbe(port: UInt16(boundedURL.port!)).exchange(boundedRequest)
            try expect(response.status == 200, "Within bounded request budget")
        }
        do {
            _ = try await UploadHTTPProbe(port: UInt16(boundedURL.port!)).exchange(boundedRequest)
            throw Failure(message: "Request budget exceeded")
        } catch UploadHTTPProbe.Failure.closed { assertions += 1 }
        let expiring = try fixture(lifetime: 0.15)
        let expiringURL = try await expiring.start()
        try await Task.sleep(nanoseconds: 250_000_000)
        try expect(!expiring.allows(expiringURL), "Lifetime expiry revokes manual exception")
        do { _ = try await expiring.start(); throw Failure(message: "Expired fixture restarted") }
        catch BrowserUploadFixture.Failure.stopped { assertions += 1 }

        let existingDirectory = root.appendingPathComponent("Existing")
        try fm.createDirectory(at: existingDirectory, withIntermediateDirectories: true)
        let existing = existingDirectory.appendingPathComponent(BrowserUploadFixture.filename)
        try Data("preserve unrelated file".utf8).write(to: existing)
        let collision = try fixture(directory: existingDirectory)
        do { _ = try await collision.start(); throw Failure(message: "Unrelated file overwritten") }
        catch BrowserUploadFixture.Failure.unsafeFile { assertions += 1 }
        try expect(try String(contentsOf: existing) == "preserve unrelated file", "Seed collision never overwrites user data")
        let linkedDirectory = root.appendingPathComponent("Linked")
        try fm.createDirectory(at: linkedDirectory, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: linkedDirectory.appendingPathComponent(BrowserUploadFixture.filename), withDestinationURL: existing)
        let linked = try fixture(directory: linkedDirectory)
        do { _ = try await linked.start(); throw Failure(message: "Symlink seed accepted") }
        catch BrowserUploadFixture.Failure.unsafeFile { assertions += 1 }
        try expect(try String(contentsOf: existing) == "preserve unrelated file", "Seed symlink cannot overwrite target")

        server.stop()
        try expect(!server.allows(formURL), "Stop immediately revokes exact-origin exception")
        try expect(!fm.fileExists(atPath: seed.path), "Stop removes its unchanged synthetic file")
        print("Browser upload fixture: \(assertions) real HTTP/filesystem/lifecycle assertions passed; native Files UI not exercised")
    }
}

private final class UploadHTTPProbe {
    enum Failure: Error { case closed, timeout, malformed }
    struct Response { let status: Int; let headers: String; let body: String }
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "upload-http-probe")
    private var continuation: CheckedContinuation<Response, Error>?
    private var received = Data()
    private var timeout: DispatchWorkItem?

    init(port: UInt16) { connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }

    func exchange(_ request: Data, fragment: Int? = nil) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                let timer = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.timeout)) }
                timeout = timer; queue.asyncAfter(deadline: .now() + 3, execute: timer)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.receive(); self.send(request, offset: 0, fragment: fragment ?? request.count)
                    case .failed: self.finish(.failure(Failure.closed))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }

    private func send(_ data: Data, offset: Int, fragment: Int) {
        guard continuation != nil, offset < data.count else { return }
        let end = min(data.count, offset + max(1, fragment))
        connection.send(content: data.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error == nil { self.send(data, offset: end, fragment: fragment) }
            // The fixture can reject oversized headers before the client has
            // finished writing; receive its bounded rejection response first.
        })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, done, error in
            guard let self, self.continuation != nil else { return }
            self.received.append(data ?? Data())
            guard self.received.count <= 65_536 else { self.finish(.failure(Failure.malformed)); return }
            if let separator = self.received.range(of: Data("\r\n\r\n".utf8)),
               let headers = String(data: self.received[..<separator.lowerBound], encoding: .utf8) {
                let lines = headers.components(separatedBy: "\r\n")
                if let lengthLine = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let length = Int(lengthLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
                   self.received.count >= separator.upperBound + length,
                   let status = lines.first?.split(separator: " ").dropFirst().first.flatMap({ Int($0) }) {
                    self.finish(.success(Response(status: status, headers: headers,
                        body: String(decoding: self.received[separator.upperBound..<(separator.upperBound + length)], as: UTF8.self))))
                    return
                }
            }
            if done || error != nil { self.finish(.failure(Failure.closed)) }
            else { self.receive() }
        }
    }

    private func finish(_ result: Result<Response, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; timeout?.cancel(); timeout = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        pending.resume(with: result)
    }
}
#elseif BROWSER_UPLOAD_WEBKIT_SMOKE && os(macOS)
import AppKit
import Foundation
import WebKit

/// Actual WebKit form/CSP/status-request validation on the CLT host. This never
/// supplies an input file or claims to test the iOS native Files chooser.
@main enum BrowserUploadWebKitChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { try await run(); print("Browser upload WebKit: 7 actual form/status assertions passed; native Files UI not exercised"); exit(0) }
            catch { print("FAIL: real WebKit upload form/status fixture"); exit(1) }
        }
        app.run()
    }

    private struct Failure: Error {}
    @MainActor private static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("browser-upload-webkit-" + UUID().uuidString)
        let flags = ["-UITestMode", "-UITestBrowserUpload", "-UITestNamespace", UUID().uuidString]
        guard let fixture = BrowserUploadFixture(arguments: flags, documentsDirectory: root) else { throw Failure() }
        defer { fixture.stop(); _ = fixture.allows(URL(string: "https://example.invalid")!); try? FileManager.default.removeItem(at: root) }
        let url = try await fixture.start()
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: config)
        let navigation = Navigation(); view.navigationDelegate = navigation
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        defer { view.stopLoading(); view.navigationDelegate = nil; window.orderOut(nil) }
        view.load(URLRequest(url: url))
        try await wait { navigation.finishes == 1 }
        func check(_ condition: Bool) throws { if !condition { throw Failure() } }
        let initial = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        try check(initial.contains("UPLOAD_FORM_READY") && initial.contains("UPLOAD_SELECTED_NONE"))
        let form = try await view.evaluateJavaScript("document.querySelector('form').method + '|' + document.querySelector('form').enctype + '|' + document.getElementById('file').type") as? String
        try check(form == "post|multipart/form-data|file")
        let count = try await view.evaluateJavaScript("document.getElementById('file').files.length") as? Int
        try check(count == 0)
        let valid = try await view.evaluateJavaScript("document.querySelector('form').checkValidity()") as? Bool
        try check(valid == false)
        // Execute the page's real nonce-protected click handler, which navigates
        // to the server. Merely reading a hard-coded DOM receipt is insufficient.
        _ = try await view.evaluateJavaScript("document.getElementById('status').click(); true")
        try await wait { navigation.finishes == 2 }
        try check(view.url?.path == url.deletingLastPathComponent().appendingPathComponent("status").path)
        let status = try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        try check(status.contains("UPLOAD_SERVER_RECEIPTS_0"))
        try check(!status.contains("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1"))
    }

    @MainActor private static func wait(_ condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !condition(), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
        if !condition() { throw Failure() }
    }
    @MainActor private final class Navigation: NSObject, WKNavigationDelegate {
        var finishes = 0
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishes += 1 }
    }
}
#else
import XCTest

/// Simulator-only manual browser upload, through WebKit's iOS 17 native Files
/// chooser. No model actions, JavaScript file injection, pasteboard, or real files.
///
/// DEBUG host contract (-UITestMode -UITestBrowserUpload):
/// * Opening the browser mounts a loopback-only HTTP form, UPLOAD_FORM_READY.
/// * Documents/BrowserUploadFixture.txt contains exactly these 31 UTF-8 bytes:
///       WOOW_BROWSER_UPLOAD_FIXTURE_V1\n
/// * input[type=file] has aria-label="選擇測試檔案" and a visible selection
///   marker UPLOAD_SELECTED_NONE / UPLOAD_SELECTED_1_BrowserUploadFixture.txt.
/// * "送出測試檔案" submits multipart/form-data to the fixture HTTP server.
/// * Only an actual multipart receipt matching filename AND all 31 bytes returns
///   UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1 and UPLOAD_SERVER_RECEIPTS_1.
/// * "查詢伺服器收件狀態" makes a fresh server request and renders its actual
///   count, e.g. UPLOAD_SERVER_RECEIPTS_0. It must not be a client-side counter.
/// * The exact fixture origin is exempted from manual navigation/POST policy
///   only under the debug flag; model/research controls remain restricted.
/// * UIFileSharingEnabled exposes this synthetic file through "On My iPhone".
///
/// Chooser cancellation and actual HTTP upload are intentionally separate tests.
/// Missing picker/file/receipt fails the relevant test; selection is never
/// reported as an upload. Do not use runOpenPanel (iOS 18.4+) on iOS 17.
final class BrowserUploadUITests: XCTestCase {
    private let app = XCUIApplication()
    private let filename = "BrowserUploadFixture.txt"

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Files chooser tests run only on an isolated iOS simulator.")
        #endif
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        // Avoid attaching a Files-provider accessibility tree or screenshot:
        // only exact synthetic marker assertions belong in the test evidence.
        app.terminate()
    }

    func testNativeFileChooserCancellationDoesNotUpload() {
        launchFixture()
        openNativeDocumentPicker()
        let cancel = nativeCancel
        requireHittable(cancel, message: "Native Files picker must expose Cancel.")
        cancel.tap()
        XCTAssertTrue(webText("UPLOAD_SELECTED_NONE").waitForExistence(timeout: 15),
                      "Cancelling Files must leave the real DOM file input empty.")
        XCTAssertFalse(webText("UPLOAD_SELECTED_1_" + filename).exists)
        XCTAssertFalse(webText("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1").exists)
        XCTAssertFalse(webText("UPLOAD_SERVER_RECEIPTS_0").exists,
                       "The form cannot pre-render a successful server query result.")
        let query = app.webViews.buttons["查詢伺服器收件狀態"].firstMatch
        requireHittable(query, message: "Fixture must query the HTTP server's current receipt count.")
        query.tap()
        XCTAssertTrue(webText("UPLOAD_SERVER_RECEIPTS_0").waitForExistence(timeout: 20),
                      "Only a fresh server response with zero receipts proves cancellation did not upload.")
    }

    func testNativeFilesSelectionSubmitsExactSyntheticBytesToHTTPServer() {
        launchFixture()
        openNativeDocumentPicker()
        selectSyntheticFile()
        let selected = webText("UPLOAD_SELECTED_1_" + filename)
        XCTAssertTrue(selected.waitForExistence(timeout: 20),
                      "The real DOM input must receive the file selected in native Files.")
        XCTAssertFalse(webText("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1").exists,
                       "Selecting a file alone is not evidence of upload.")
        let submit = app.webViews.buttons["送出測試檔案"].firstMatch
        requireHittable(submit, message: "The fixture form must expose its real submit button.")
        submit.tap()
        XCTAssertTrue(webText("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1").waitForExistence(timeout: 30),
                      "Server must receive and verify the filename plus all 31 synthetic bytes in multipart/form-data.")
        XCTAssertTrue(webText("UPLOAD_SERVER_RECEIPTS_1").waitForExistence(timeout: 5),
                      "An exact server receipt, not chooser visibility or DOM selection, is required.")
        XCTAssertTrue(webText("UPLOAD_FILE_BYTES_31").waitForExistence(timeout: 5),
                      "The server must verify the complete 31-byte synthetic file.")
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
    }

    private func launchFixture() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", UUID().uuidString,
                               "-UITestResetStorage", "-UITestBrowserUpload"]
        app.launch()
        let browser = app.buttons["navigation.browser"]
        requireHittable(browser, timeout: 30, message: "Browser navigation must be available.")
        browser.tap()
        XCTAssertTrue(webText("UPLOAD_FORM_READY").waitForExistence(timeout: 75),
                      "Parent DEBUG hook must seed the synthetic file and serve the real loopback HTTP form.")
        XCTAssertTrue(webText("UPLOAD_SELECTED_NONE").exists)
        XCTAssertFalse(webText("UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1").exists)
    }

    private func openNativeDocumentPicker() {
        let input = app.webViews.buttons.matching(NSPredicate(format: "label CONTAINS %@", "選擇測試檔案")).firstMatch
        requireHittable(input, message: "The actual input[type=file] must be accessible in WKWebView.")
        input.tap()
        let chooserReady = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
            guard let self else { return false }
            return (self.nativeCancel.exists && self.nativeCancel.isHittable) || self.chooseFilesAction?.isHittable == true
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [chooserReady], timeout: 15), .completed,
                       "WebKit must present the native file-source menu or Files picker.")
        if let files = chooseFilesAction, files.isHittable { files.tap() }
        requireHittable(nativeCancel, message: "The native Files document picker must actually open.")
    }

    private var nativeCancel: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
    }

    private var chooseFilesAction: XCUIElement? {
        let names = ["選擇檔案", "選擇檔案⋯", "選擇檔案…", "Choose File", "Choose Files", "Choose File…", "Browse…"]
        let predicate = NSPredicate(format: "label IN %@", names)
        // Menus/popovers vary by simulator OS; inspect only known action labels.
        let candidates = app.sheets.buttons.matching(predicate).allElementsBoundByIndex
            + app.popovers.buttons.matching(predicate).allElementsBoundByIndex
            + app.buttons.matching(predicate).allElementsBoundByIndex
        return candidates.first(where: { $0.exists && $0.isHittable })
    }

    private func selectSyntheticFile() {
        // Files can reopen in Recents, Locations, or the previously used folder.
        // Navigate only known local locations and this app's synthetic document.
        for _ in 0..<8 {
            if let file = nativeItem(containing: "BrowserUploadFixture") {
                file.tap()
                let selected = webText("UPLOAD_SELECTED_1_" + filename)
                if selected.waitForExistence(timeout: 3) { return }
                // Some system versions require an explicit Open/Done action.
                if let open = knownButton(["開啟", "Open", "完成", "Done"]) { open.tap() }
                XCTAssertTrue(selected.waitForExistence(timeout: 15), "Native selection must reach WKWebView.")
                return
            }
            if let applicationFolder = nativeItem(exact: ["渥屋助理", "WoowAssistant"]) {
                applicationFolder.tap()
            } else if let local = nativeItem(exact: ["我的 iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]) {
                local.tap()
            } else if let browse = knownButton(["瀏覽", "Browse", "位置", "Locations"]) {
                browse.tap()
            } else {
                XCTFail("Native Files must expose the local app folder containing BrowserUploadFixture.txt; no cloud or real file fallback is allowed.")
                return
            }
            // Wait for the next native location's content instead of fixed sleeps.
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.nativeItem(containing: "BrowserUploadFixture") != nil
                    || self.nativeItem(exact: ["渥屋助理", "WoowAssistant", "我的 iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]) != nil
                    || self.knownButton(["瀏覽", "Browse", "位置", "Locations"]) != nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        }
        XCTFail("Synthetic file was not found within the bounded local Files navigation.")
    }

    private func nativeItem(exact labels: [String]) -> XCUIElement? {
        nativeItem(predicate: NSPredicate(format: "label IN %@", labels))
    }

    private func nativeItem(containing label: String) -> XCUIElement? {
        nativeItem(predicate: NSPredicate(format: "label CONTAINS %@", label))
    }

    private func nativeItem(predicate: NSPredicate) -> XCUIElement? {
        let candidates = app.cells.matching(predicate).allElementsBoundByIndex
            + app.buttons.matching(predicate).allElementsBoundByIndex
            + app.staticTexts.matching(predicate).allElementsBoundByIndex
        return candidates.first(where: { $0.exists && $0.isHittable })
    }

    private func knownButton(_ labels: [String]) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex
            .first(where: { $0.exists && $0.isHittable })
    }

    private func webText(_ value: String) -> XCUIElement {
        app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", value)).firstMatch
    }

    private func requireHittable(_ element: XCUIElement, timeout: TimeInterval = 15, message: String,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, message, file: file, line: line)
    }
}
#endif
