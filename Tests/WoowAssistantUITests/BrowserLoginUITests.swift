#if BROWSER_LOGIN_HTTP_SMOKE
import Foundation
import Network

/// Real HTTP checks; these do not stand in for native typing or iOS relaunch.
/// swiftc -D DEBUG -D BROWSER_LOGIN_HTTP_SMOKE -parse-as-library \
/// Sources/App/BrowserLoginFixture.swift Tests/WoowAssistantUITests/BrowserLoginUITests.swift -o /tmp/login-http
@main enum BrowserLoginHTTPChecks {
    struct Failure: Error { let message: String }
    static func main() async throws {
        var assertions = 0
        func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
            assertions += 1; if !value() { throw Failure(message: message) }
        }
        let namespace = UUID().uuidString
        let flags = ["-UITestMode", "-UITestBrowserLogin", "-UITestNamespace", namespace]
        for arguments in [[], ["-UITestMode"], ["-UITestBrowserLogin"], flags + ["-UITestMode"],
                          ["-UITestMode", "-UITestBrowserLogin", "-UITestNamespace", "bad"],
                          flags + ["-UITestBrowserUpload"], flags + ["-LiveModelUITest"]] {
            try expect(BrowserLoginFixture(arguments: arguments) == nil, "Strict isolated fixture gating")
        }
        let server = BrowserLoginFixture(arguments: flags)!
        defer { server.stop() }
        let url = try await server.start()
        let repeated = try await server.start()
        try expect(url == repeated && server.allows(url), "Idempotent exact-origin start")
        let prefix = url.deletingLastPathComponent().path
        let origin = "http://127.0.0.1:\(url.port!)"
        for raw in [url.absoluteString + "?q=x", url.absoluteString + "#x", origin + "/status",
                    url.absoluteString.replacingOccurrences(of: "127.0.0.1", with: "localhost"),
                    url.absoluteString.replacingOccurrences(of: "http://", with: "https://"),
                    url.absoluteString.replacingOccurrences(of: "http://", with: "http://u:p@"),
                    url.absoluteString.replacingOccurrences(of: "/status", with: "/%73tatus")] {
            try expect(!server.allows(URL(string: raw)!), "No URL-policy aliases")
        }
        func send(_ method: String, _ endpoint: String, body: String = "", cookie: String? = nil,
                  extra: [String] = [], originHeader: String? = nil, fragmented: Bool = false,
                  port: Int? = nil, path: String? = nil) async throws -> LoginHTTPProbe.Response {
            let port = port ?? url.port!
            var headers = ["\(method) \(path ?? prefix + "/" + endpoint) HTTP/1.1", "Host: 127.0.0.1:\(port)", "Content-Length: \(body.utf8.count)", "Connection: close"]
            if method == "POST" { headers += ["Origin: \(originHeader ?? "http://127.0.0.1:\(port)")", "Content-Type: application/x-www-form-urlencoded"] }
            if let cookie { headers.append("Cookie: " + cookie) }
            headers += extra
            return try await LoginHTTPProbe(port: UInt16(port)).exchange(Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + body).utf8), fragmented: fragmented)
        }
        let initial = try await send("GET", "status", fragmented: true)
        try expect(initial.status == 200 && initial.body.contains("LOGIN_ANONYMOUS") && initial.body.contains("LOGIN_SERVER_LOGINS_0"), "Initial status comes from server Cookie validation")
        try expect(initial.body.contains("type=\"password\"") && initial.body.contains("method=\"post\""), "Actual form and password control")
        try expect(!initial.body.contains("document.cookie") && !initial.body.contains("<script"), "No script sets cookie")
        let denied = try await send("GET", "protected")
        try expect(denied.status == 401 && denied.body.contains("LOGIN_PROTECTED_DENIED"), "Protected endpoint rejects missing cookie")
        let credentials = "username=fixture-user&password=fixture-password-v1"
        let wrong = try await send("POST", "login", body: "username=fixture-user&password=wrong")
        try expect(wrong.status == 401 && wrong.header("set-cookie") == nil, "Wrong credentials cannot issue cookie")
        let crossOrigin = try await send("POST", "login", body: credentials, originHeader: "https://example.invalid")
        try expect(crossOrigin.status == 403 && crossOrigin.header("set-cookie") == nil, "Cross-origin form rejected")
        let login = try await send("POST", "login", body: credentials, fragmented: true)
        guard let issued = login.header("set-cookie"), let cookie = issued.split(separator: ";").first.map(String.init) else {
            throw Failure(message: "No Set-Cookie received from actual HTTP login")
        }
        try expect(login.status == 303 && login.header("location") == prefix + "/protected", "Successful POST redirects to protected endpoint")
        try expect(issued.contains("HttpOnly") && issued.contains("Max-Age=600") && issued.contains("Expires=")
                   && issued.contains("Path=" + prefix + "/") && !issued.contains("Domain=") && !issued.contains(":\(url.port!)"), "Persistent host-only cookie is namespace scoped and port independent")
        let protectedPage = try await send("GET", "protected", cookie: cookie)
        try expect(protectedPage.status == 200 && protectedPage.body.contains("LOGIN_PROTECTED_AUTHENTICATED") && protectedPage.body.contains("LOGIN_SERVER_LOGINS_1"), "Actual Cookie header grants protected access")
        let absent = try await send("GET", "status")
        try expect(absent.body.contains("LOGIN_ANONYMOUS"), "Global login count never substitutes for request Cookie")
        let forged = try await send("GET", "protected", cookie: cookie + "invalid")
        try expect(forged.status == 401, "Altered token rejected")
        let duplicated = try await send("GET", "protected", cookie: cookie + "; " + cookie)
        try expect(duplicated.status == 401, "Ambiguous duplicate cookie rejected")

        // Keep the first listener alive so the replacement definitely has a
        // different port. Its counters start at zero; the issued cookie survives.
        let replacement = BrowserLoginFixture(arguments: flags)!
        defer { replacement.stop() }
        let replacementURL = try await replacement.start()
        try expect(replacementURL.port != url.port, "Replacement server has a different ephemeral port")
        let restored = try await send("GET", "status", cookie: cookie, port: replacementURL.port)
        try expect(restored.body.contains("LOGIN_AUTHENTICATED") && restored.body.contains("LOGIN_SERVER_LOGINS_0"), "Replacement server validates the previously issued cookie")
        let other = BrowserLoginFixture(arguments: ["-UITestMode", "-UITestBrowserLogin", "-UITestNamespace", UUID().uuidString])!
        defer { other.stop() }
        let otherURL = try await other.start()
        let otherStatus = try await send("GET", "status", cookie: cookie, port: otherURL.port, path: otherURL.path)
        try expect(otherStatus.body.contains("LOGIN_ANONYMOUS"), "Cookie cannot authenticate another namespace")
        let invalidLogout = try await send("POST", "logout", cookie: cookie, originHeader: "https://example.invalid")
        try expect(invalidLogout.status == 403 && invalidLogout.header("set-cookie") == nil, "Logout also requires same-origin POST")
        let logout = try await send("POST", "logout", cookie: cookie)
        try expect(logout.status == 303 && logout.header("set-cookie")?.contains("Max-Age=0") == true
                   && logout.header("set-cookie")?.contains("Path=" + prefix + "/") == true, "Logout expires same cookie path through HTTP")
        let afterLogout = try await send("GET", "protected")
        try expect(afterLogout.status == 401 && afterLogout.body.contains("LOGIN_SERVER_LOGOUTS_1"), "Fresh HTTP check without expired cookie denies access")
        for (body, status) in [("username=x&username=y", 400), (credentials + "&extra=x", 400), ("username=%ZZ&password=x", 400), (String(repeating: "a", count: 1_025), 413)] {
            let response = try await send("POST", "login", body: body)
            try expect(response.status == status && response.header("set-cookie") == nil, "Malformed/bounded form rejected without cookie")
        }
        let duplicateLength = try await send("GET", "status", extra: ["Content-Length: 0"])
        try expect(duplicateLength.status == 400, "Ambiguous framing rejected")
        let chunked = try await send("POST", "login", body: credentials, extra: ["Transfer-Encoding: chunked"])
        try expect(chunked.status == 400, "Unsupported transfer framing rejected")
        let timeoutServer = BrowserLoginFixture(arguments: flags, requestTimeout: 0.1)!
        defer { timeoutServer.stop() }
        let timeoutURL = try await timeoutServer.start()
        do {
            _ = try await LoginHTTPProbe(port: UInt16(timeoutURL.port!)).exchange(Data("GET ".utf8))
            throw Failure(message: "Incomplete request did not close")
        } catch LoginHTTPProbe.Failure.closed { assertions += 1 }
        let short = BrowserLoginFixture(arguments: flags, lifetime: 0.1)!
        let shortURL = try await short.start()
        try await Task.sleep(nanoseconds: 200_000_000)
        try expect(!short.allows(shortURL), "Expired server revokes URL allowance")
        server.stop()
        try expect(!server.allows(url), "Stopped fixture permits nothing")
        print("Browser login fixture: \(assertions) real HTTP assertions passed; no native UI/OAuth/MFA claim")
    }
}

private final class LoginHTTPProbe {
    enum Failure: Error { case closed, timeout, malformed }
    struct Response {
        let status: Int; let headers: String; let body: String
        func header(_ name: String) -> String? {
            headers.components(separatedBy: "\r\n").first { $0.lowercased().hasPrefix(name.lowercased() + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
    }
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "login-http-probe")
    private var continuation: CheckedContinuation<Response, Error>?
    private var received = Data()
    private var timer: DispatchWorkItem?
    init(port: UInt16) { connection = NWConnection(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port)!, using: .tcp) }
    func exchange(_ request: Data, fragmented: Bool = false) async throws -> Response {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                self.continuation = continuation
                let timeout = DispatchWorkItem { [weak self] in self?.finish(.failure(Failure.timeout)) }
                timer = timeout; queue.asyncAfter(deadline: .now() + 3, execute: timeout)
                connection.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.receive(); self.send(request, offset: 0, size: fragmented ? 7 : request.count)
                    case .failed: self.finish(.failure(Failure.closed))
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        }
    }
    private func send(_ bytes: Data, offset: Int, size: Int) {
        guard continuation != nil, offset < bytes.count else { return }
        let end = min(bytes.count, offset + max(1, size))
        connection.send(content: bytes.subdata(in: offset..<end), completion: .contentProcessed { [weak self] error in
            if error == nil { self?.send(bytes, offset: end, size: size) }
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
                if let raw = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }),
                   let length = Int(raw.dropFirst(15).trimmingCharacters(in: .whitespaces)),
                   self.received.count >= separator.upperBound + length,
                   let status = lines[0].split(separator: " ").dropFirst().first.flatMap({ Int($0) }) {
                    self.finish(.success(Response(status: status, headers: headers,
                        body: String(decoding: self.received[separator.upperBound..<(separator.upperBound + length)], as: UTF8.self)))); return
                }
            }
            if done || error != nil { self.finish(.failure(Failure.closed)) } else { self.receive() }
        }
    }
    private func finish(_ result: Result<Response, Error>) {
        guard let pending = continuation else { return }
        continuation = nil; timer?.cancel(); timer = nil; connection.stateUpdateHandler = nil; connection.cancel()
        pending.resume(with: result)
    }
}
#elseif BROWSER_LOGIN_WEBKIT_SMOKE && os(macOS)
import AppKit
import Foundation
import WebKit

/// Actual WebKit networking/cookie/website-data checks on macOS 13. The real
/// HTML form is filled/submitted by script with synthetic credentials only.
/// The native typing and full App-relaunch assertions remain in the iOS suite.
/// No cookie is injected by JavaScript or WKHTTPCookieStore.
/// swiftc -D DEBUG -D BROWSER_LOGIN_WEBKIT_SMOKE -parse-as-library \
/// Sources/App/BrowserLoginFixture.swift Tests/WoowAssistantUITests/BrowserLoginUITests.swift -o /tmp/login-webkit
@main enum BrowserLoginWebKitChecks {
    private struct Failure: Error { let message: String }
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do { print("Browser login WebKit: \(try await run()) actual cookie/HTTP/website-clear assertions passed; iOS typing/relaunch not exercised"); exit(0) }
            catch {
                print("FAIL: " + ((error as? Failure)?.message ?? "synthetic WebKit login check")); exit(1)
            }
        }
        app.run()
    }

    @MainActor private static func run() async throws -> Int {
        let flags = ["-UITestMode", "-UITestBrowserLogin", "-UITestNamespace", UUID().uuidString]
        let server = BrowserLoginFixture(arguments: flags)!
        let replacement = BrowserLoginFixture(arguments: flags)!
        defer { server.stop(); replacement.stop() }
        let statusURL = try await server.start()
        let prefix = statusURL.deletingLastPathComponent()
        let protectedURL = prefix.appendingPathComponent("protected")
        let store = WKWebsiteDataStore.nonPersistent() // Isolated from the user's real browser data.
        let first = Host(store: store), second = Host(store: store)
        defer { first.close(); second.close() }
        var assertions = 0
        func expect(_ value: Bool, _ message: String) throws {
            assertions += 1; if !value { throw Failure(message: message) }
        }
        let initial = try await first.load(URLRequest(url: statusURL))
        try expect(initial.contains("LOGIN_ANONYMOUS"), "Fresh WebKit session is anonymous")
        let loggedIn = try await first.submitForm(credentials: true)
        try expect(loggedIn.contains("LOGIN_PROTECTED_AUTHENTICATED") && loggedIn.contains("LOGIN_SERVER_LOGINS_1"), "Actual WebKit POST follows Set-Cookie redirect")
        try expect(first.view.url == protectedURL, "HTTP 303 reaches protected resource")
        let cookies = await allCookies(store)
        let cookie = cookies.first { $0.name == BrowserLoginFixture.cookieName }
        try expect(cookie?.isHTTPOnly == true && cookie?.expiresDate != nil, "WebKit stores persistent HttpOnly response cookie")
        try expect(cookie?.path == prefix.path + "/" && cookie?.domain == "127.0.0.1", "Cookie has exact host/path scope")
        let visible = try await first.view.evaluateJavaScript("document.cookie") as? String ?? ""
        try expect(!visible.contains(BrowserLoginFixture.cookieName), "HttpOnly cookie is inaccessible to page JavaScript")
        let newTab = try await second.load(URLRequest(url: protectedURL))
        try expect(newTab.contains("LOGIN_PROTECTED_AUTHENTICATED") && newTab.contains("LOGIN_PROTECTED_CHECKS_2"), "Second WKWebView sends shared session cookie over HTTP")

        let replacementURL = try await replacement.start()
        try expect(replacementURL.port != statusURL.port, "Replacement listener uses a new port")
        let portChanged = try await second.load(URLRequest(url: replacementURL))
        try expect(portChanged.contains("LOGIN_AUTHENTICATED") && portChanged.contains("LOGIN_SERVER_LOGINS_0"), "Browser cookie authenticates new-port server without another login")
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { continuation in
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { continuation.resume(returning: $0) }
        }
        let matching = records.filter { $0.displayName == "127.0.0.1" }
        try expect(matching.count == 1, "Website record is named 127.0.0.1 for the native clear UI")
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), for: matching) { continuation.resume() }
        }
        let cleared = try await second.load(URLRequest(url: protectedURL))
        try expect(cleared.contains("LOGIN_PROTECTED_DENIED") && cleared.contains("LOGIN_SERVER_LOGINS_1"), "Real website-record deletion removes Cookie on next HTTP request")
        let loginPage = try await first.load(URLRequest(url: statusURL))
        try expect(loginPage.contains("LOGIN_ANONYMOUS"), "Cleared session receives the actual login form")
        let relogged = try await first.submitForm(credentials: true)
        try expect(relogged.contains("LOGIN_PROTECTED_AUTHENTICATED") && relogged.contains("LOGIN_SERVER_LOGINS_2"), "Login works again only after another verified POST")
        let loggedOut = try await first.submitForm(credentials: false)
        try expect(loggedOut.contains("LOGIN_ANONYMOUS") && loggedOut.contains("LOGIN_SERVER_LOGOUTS_1"), "WebKit honors server cookie expiry on logout")
        let denied = try await second.load(URLRequest(url: protectedURL))
        try expect(denied.contains("LOGIN_PROTECTED_DENIED"), "Another tab is denied after logout")
        let remaining = await allCookies(store)
        try expect(!remaining.contains { $0.name == BrowserLoginFixture.cookieName }, "Logout removes stored fixture cookie")
        return assertions
    }

    @MainActor private static func allCookies(_ store: WKWebsiteDataStore) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
    @MainActor private final class Host: NSObject, WKNavigationDelegate {
        let view: WKWebView
        let window: NSWindow
        var finishes = 0
        init(store: WKWebsiteDataStore) {
            let config = WKWebViewConfiguration(); config.websiteDataStore = store
            view = WKWebView(frame: .zero, configuration: config)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
            super.init(); view.navigationDelegate = self; window.contentView = view
        }
        func load(_ request: URLRequest) async throws -> String {
            let previous = finishes; view.load(request)
            return try await finished(after: previous)
        }
        func submitForm(credentials: Bool) async throws -> String {
            let previous = finishes
            let fill = credentials ? "document.getElementById('username').value = 'fixture-user'; document.getElementById('password').value = 'fixture-password-v1'; " : ""
            // Only this macOS harness scripts form controls; the iOS suite types
            // natively. WebKit itself supplies Origin, body framing and cookies.
            _ = try await view.evaluateJavaScript(fill + "document.querySelector('form').requestSubmit(); true")
            return try await finished(after: previous)
        }
        private func finished(after previous: Int) async throws -> String {
            let deadline = ProcessInfo.processInfo.systemUptime + 30
            while finishes == previous, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 25_000_000) }
            guard finishes > previous else { throw Failure(message: "WebKit navigation timed out") }
            return try await view.evaluateJavaScript("document.body.innerText") as? String ?? ""
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finishes += 1 }
        func close() { view.stopLoading(); view.navigationDelegate = nil; window.orderOut(nil) }
    }
}
#else
import XCTest
import CoreGraphics

/// Synthetic credentials only. Native typing -> form HTTP POST -> Set-Cookie ->
/// protected HTTP response. No JS login, cookie injection, external accounts,
/// or claim of OAuth/MFA support. Parent mounts .start() on browser activation.
final class BrowserLoginUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic login tests run only on an isolated iOS simulator.")
        #endif
        continueAfterFailure = false
        executionTimeAllowance = 420
    }
    override func tearDownWithError() throws {
        // No full accessibility/password/keyboard dumps or cookie artifacts.
        app.terminate()
    }

    func testNativeFormLoginSharesCookieAcrossTabsAndRelaunchThenLogout() {
        launch(reset: true)
        XCTAssertTrue(text("LOGIN_ANONYMOUS").exists)
        let firstInstance = serverInstance
        loginByTyping()
        XCTAssertTrue(text("LOGIN_PROTECTED_CHECKS_1").exists)
        let protectedURL = currentProtectedURL()
        openInNewTab(protectedURL)
        XCTAssertTrue(text("LOGIN_PROTECTED_AUTHENTICATED").waitForExistence(timeout: 30))
        XCTAssertTrue(text("LOGIN_PROTECTED_CHECKS_2").exists,
                      "A new tab must make another authenticated HTTP request.")
        XCTAssertTrue(text("LOGIN_SERVER_LOGINS_1").exists)

        // Keep the namespace and persistent WKWebsiteDataStore; no reset flag.
        // New process/server can have a different port, while cookie Path stays stable.
        launch(reset: false)
        XCTAssertTrue(text("LOGIN_AUTHENTICATED").exists,
                      "The new server must receive WebKit's persistent cookie after App termination.")
        XCTAssertTrue(text("LOGIN_SERVER_LOGINS_0").exists,
                      "Relaunch must not secretly submit the login form again.")
        XCTAssertNotEqual(serverInstance, firstInstance, "The receipt must come from a new server process.")
        guard let statusURL = URL(string: app.textFields["browser.address"].value as? String ?? ""),
              statusURL.host == "127.0.0.1" else { XCTFail("Expected synthetic status URL after relaunch."); return }
        let currentURL = statusURL.deletingLastPathComponent().appendingPathComponent("protected")
        tap(app.webViews.buttons["登出測試帳號"].firstMatch)
        XCTAssertTrue(text("LOGIN_ANONYMOUS").waitForExistence(timeout: 30))
        XCTAssertTrue(text("LOGIN_SERVER_LOGOUTS_1").exists)
        openInNewTab(currentURL)
        XCTAssertTrue(text("LOGIN_PROTECTED_DENIED").waitForExistence(timeout: 30),
                      "A fresh protected HTTP request must fail after server-driven cookie expiry.")
        XCTAssertFalse(text("LOGIN_PROTECTED_AUTHENTICATED").exists)
    }

    func testWebsiteRecordClearRevokesCookieAndRemainsClearedAfterRelaunch() {
        launch(reset: true)
        loginByTyping()
        let protectedURL = currentProtectedURL()
        library()
        tap(app.segmentedControls["browser.library.sections"].buttons["網站"])
        let clear = app.buttons["browser.sites.clear.127.0.0.1"]
        tap(clear, timeout: 30)
        // 6d480d8 iOS 17 exposes this titled confirmation as Other; iOS 26
        // exposes Sheet and nested duplicate Buttons. Scope to the exact
        // dialog title and action, without assuming a single AX container type.
        let confirmation = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND label == %@",
            XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.other.rawValue,
            "清除此網站的資料？可能需要重新登入，所有分頁與下載將停止。")).firstMatch
        let confirm = confirmation.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@",
            "browser.sites.confirmClear", "清除網站資料")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 15))
        XCTAssertEqual(confirm.label, "清除網站資料")
        tap(confirm)
        // 1747c20 SE/Large: removeData completed after 18.8/19.9 s and the
        // synthetic cookie count was zero, while fetchDataRecords was still
        // pending at the old combined 30 s deadline. 0df511b SE then recorded
        // removeCompleted at 30.719 s with zero synthetic cookies. Share the
        // existing 60 s total across both callbacks instead of imposing a
        // separate 30 s cutoff on each. Do not retry deletion or infer success
        // from an enabled button; the empty list and real HTTP checks remain.
        let removalDeadline = ProcessInfo.processInfo.systemUptime + 60
        let empty = app.staticTexts["browser.sites.empty"]
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            empty.exists || (clear.exists && clear.isEnabled)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: max(0, removalDeadline - ProcessInfo.processInfo.systemUptime)), .completed,
                       "Wait for the selected-site removeData callback.")
        XCTAssertFalse(app.staticTexts["browser.library.error"].exists,
                       "Stopping-page failure must not be mistaken for successful deletion.")
        XCTAssertTrue(empty.waitForExistence(timeout: max(0, removalDeadline - ProcessInfo.processInfo.systemUptime)),
                      "Wait for the post-deletion WebKit website-record refresh to show an empty list.")
        tap(app.buttons["browser.library.close"])
        // The cleared store was empty in d938 SE, but its first post-clear
        // protected navigation stayed in the provisional loading state. Visit
        // the same live server's ordinary status document through a fresh
        // WebView first. Its server-rendered anonymous/login counters prove the
        // cleared cookie header independently; the protected 401 below remains
        // a separate, required native navigation and denial assertion.
        let statusURL = protectedURL.deletingLastPathComponent().appendingPathComponent("status")
        openInNewTab(statusURL)
        XCTAssertTrue(text("LOGIN_ANONYMOUS").waitForExistence(timeout: 30),
                      "The same HTTP server must receive a fresh WebKit request without the cleared cookie.")
        XCTAssertTrue(text("LOGIN_SERVER_LOGINS_1").exists,
                      "The anonymous response must come from the original live server, not a reset fixture.")
        openInNewTab(protectedURL)
        XCTAssertTrue(text("LOGIN_PROTECTED_DENIED").waitForExistence(timeout: 30),
                      "Website clearing must change the Cookie header observed by the same HTTP server.")
        XCTAssertTrue(text("LOGIN_SERVER_LOGINS_1").exists,
                      "The server must remain alive; resetting its counters is not cookie deletion.")
        launch(reset: false)
        XCTAssertTrue(text("LOGIN_ANONYMOUS").exists,
                      "Cleared cookies must not reappear from the persistent store after relaunch.")
        XCTAssertTrue(text("LOGIN_SERVER_LOGINS_0").exists)
    }

    private func launch(reset: Bool) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestBrowserLogin", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        tap(app.buttons["navigation.browser"], timeout: 30)
        XCTAssertTrue(text("LOGIN_STATUS_READY").waitForExistence(timeout: 75),
                      "Parent must mount BrowserLoginFixture.start() and allow its exact manual origin.")
    }

    private func loginByTyping() {
        let username = app.webViews.textFields["測試帳號"].firstMatch
        let password = app.webViews.secureTextFields["測試密碼"].firstMatch
        tap(username)
        dismissKeyboardIntroductionIfPresented()
        guard selectLatinKeyboardForSyntheticAccount() else { return }
        username.typeText("fixture-user")
        // 68c49a6 current: typeText returned successfully with the Zhuyin
        // keyboard, but the video and every username AX snapshot stayed empty.
        // Submission returned focus to the required empty username without a
        // protected HTTP receipt. Verify input before moving focus; never retry.
        let accountEntered = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "fixture-user"), object: username)
        guard XCTWaiter.wait(for: [accountEntered], timeout: 10) == .completed else {
            XCTFail("Native keyboard input must populate the exact synthetic username before entering the password.")
            return
        }
        guard let passwordOffset = revealPasswordByNativeScrolling(password) else { return }
        // faf7536 iOS 26: after the native scroll, the video shows the entire
        // enabled password field, but XCTest throws when resolving its activation
        // point. Tap the verified field center through the visible WebView. This
        // remains a real touch; the actual form POST must still validate input.
        app.webViews.firstMatch.coordinate(withNormalizedOffset: .zero)
            .withOffset(passwordOffset).tap()
        password.typeText("fixture-password-v1")
        // Only a boolean for the fixed synthetic account; no password values or
        // arbitrary keyboard/AX dumps. Keep submission separate from typing so
        // an input failure cannot be reported as a cookie/network timeout.
        guard (username.value as? String) == "fixture-user" else {
            XCTFail("The synthetic username must remain unchanged when the password receives focus.")
            return
        }
        print("LOGIN_NATIVE_ACCOUNT_VERIFIED")
        password.typeText("\n")
        // Native keyboard Go submits the real form. No evaluateJavaScript,
        // setCookie, URLRequest body injection, or pre-authenticated fixtures.
        XCTAssertTrue(text("LOGIN_PROTECTED_AUTHENTICATED").waitForExistence(timeout: 30))
        XCTAssertTrue(text("LOGIN_SERVER_LOGINS_1").exists)
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
    }

    private func selectLatinKeyboardForSyntheticAccount() -> Bool {
        let keyboard = app.keyboards.firstMatch
        func hasLatinKeys() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q", "a", "A"])).count >= 2
        }
        if hasLatinKeys() { return true }

        // Native AX varies by runtime: SE places the switch in the keyboard
        // with identifier "emoji"; iOS 17 places it just outside that AX node
        // without an identifier. Both expose a dedicated keyboard-switch label.
        let switchLabels = ["Next keyboard", "下一個鍵盤"]
        let globe = app.buttons.matching(NSPredicate(format: "label IN %@", switchLabels)).firstMatch
        let globeReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: globe)
        guard XCTWaiter.wait(for: [globeReady], timeout: 10) == .completed else {
            XCTFail("The native keyboard switch must be available for the synthetic ASCII account.")
            return false
        }
        guard switchLabels.contains(globe.label), app.frame.intersects(globe.frame),
              keyboard.frame.intersects(globe.frame) else {
            XCTFail("The native keyboard switch must be visible at the active keyboard edge.")
            return false
        }
        // Select English (US) from the real native language menu once; do not
        // cycle unknown layouts or change simulator preferences.
        globe.press(forDuration: 1)
        let english = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "English (US)")).firstMatch
        let englishReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: english)
        guard XCTWaiter.wait(for: [englishReady], timeout: 10) == .completed else {
            XCTFail("The native language menu must offer the known English (US) keyboard.")
            return false
        }
        english.tap()
        // First English activation may present the real QuickPath tutorial.
        dismissKeyboardIntroductionIfPresented()
        let latinReady = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in hasLatinKeys() }, object: nil)
        guard XCTWaiter.wait(for: [latinReady], timeout: 10) == .completed else {
            XCTFail("The selected native keyboard must expose Latin letter keys before typing the synthetic account.")
            return false
        }
        print("LOGIN_NATIVE_LATIN_KEYBOARD_SELECTED")
        return true
    }

    private func dismissKeyboardIntroductionIfPresented() {
        // e1024aa SE records this exact first-use QuickPath explanation.
        // 1747c20 current records the keyboard still animating when Continue
        // first exists; its frame is not yet a reliable containment boundary.
        // Use the full App viewport, not the moving keyboard, as the boundary.
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10))
        let button = app.buttons["Continue"].firstMatch
        guard button.waitForExistence(timeout: 3) else { return }
        let explanationLabel = "Speed up your typing by sliding your finger across the letters to compose a word."
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            // 74f7b71 SE: the exact explanation exists query took 7.641s,
            // then another Continue query was interrupted by this 10s waiter.
            // The recording shows both controls throughout. Bind their exact
            // roles, labels and geometry in ONE public snapshot; reading its
            // children/attributes locally does not issue separate AX queries.
            let snapshot: XCUIElementSnapshot
            do { snapshot = try self.app.snapshot() }
            catch {
                XCTFail("Unable to snapshot the exact native QuickPath tutorial; no touch was sent.")
                return false
            }
            var pending = [snapshot]
            var explanations: [XCUIElementSnapshot] = []
            var buttons: [XCUIElementSnapshot] = []
            while let node = pending.popLast() {
                if node.elementType == .staticText && node.label == explanationLabel { explanations.append(node) }
                if node.elementType == .button && node.label == "Continue" { buttons.append(node) }
                pending.append(contentsOf: node.children)
            }
            guard explanations.count == 1, buttons.count == 1, buttons[0].isEnabled else { return false }
            let viewport = snapshot.frame, explanation = explanations[0].frame, target = buttons[0].frame
            let frames = [viewport, explanation, target]
            guard frames.allSatisfy({ frame in
                !frame.isEmpty && [frame.minX, frame.minY, frame.width, frame.height].allSatisfy { $0.isFinite }
            }), viewport.contains(explanation), viewport.contains(target), target.minY >= explanation.maxY else { return false }
            return true
        }, object: nil)
        guard XCTWaiter.wait(for: [ready], timeout: 10) == .completed else {
            XCTFail("The exact native QuickPath tutorial must become visible before Continue is tapped.")
            return
        }
        print("LOGIN_KEYBOARD_INTRO_PRESENTED")
        // Native button tap still resolves its actionable target. Do not repeat
        // the helper's exists/enabled/hittable queries or substitute a screen tap.
        button.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed,
                       "The native keyboard tutorial must dismiss before typing synthetic credentials.")
    }

    private func revealPasswordByNativeScrolling(_ password: XCUIElement) -> CGVector? {
        // d160a24: iOS 17/18/26 reach native username entry, then the password
        // is below the keyboard's remaining viewport. e1024aa's fast upward
        // drag overshot it (relative Y 169 -> -121 in a 123-point viewport).
        // Use ordinary page scrolling, never JS focus/value or cookie injection.
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.waitForExistence(timeout: 10))
        XCTAssertTrue(password.waitForExistence(timeout: 10))

        func visibleFrame(in frame: CGRect) -> CGRect {
            var visible = frame.intersection(app.frame)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                let overlap = visible.intersection(keyboard.frame)
                if !overlap.isNull && !overlap.isEmpty {
                    visible.size.height = max(0, min(visible.maxY, keyboard.frame.minY) - visible.minY)
                }
            }
            return visible
        }
        var verifiedOffset: CGVector?
        func passwordIsReady() -> Bool {
            verifiedOffset = nil
            guard password.exists else { return false }
            let snapshot: XCUIElementSnapshot
            do { snapshot = try password.snapshot() }
            catch {
                XCTFail("Unable to snapshot the exact synthetic password field; no touch was sent.")
                return false
            }
            guard snapshot.elementType == .secureTextField, snapshot.label == "測試密碼",
                  snapshot.isEnabled else { return false }
            let frame = web.frame
            let visible = visibleFrame(in: frame)
            let field = snapshot.frame
            // Do not ask this synthetic secure field for an activation point:
            // faf7536 fails there even after the full frame becomes visible.
            // One snapshot binds its exact role/label/enabled state and frame.
            guard !visible.isNull, visible.width >= 64, visible.height >= 64,
                  [field.minX, field.minY, field.width, field.height,
                   visible.minX, visible.minY, visible.width, visible.height].allSatisfy({ $0.isFinite }),
                  !field.isEmpty, visible.insetBy(dx: 1, dy: 1).contains(field) else { return false }
            verifiedOffset = CGVector(dx: field.midX - frame.minX, dy: field.midY - frame.minY)
            print("LOGIN_PASSWORD_TARGET_VERIFIED width=\(Int(field.width)) height=\(Int(field.height)) inside=1")
            return true
        }
        for attempt in 0...3 {
            if passwordIsReady() { return verifiedOffset }
            let frame = web.frame
            let visible = visibleFrame(in: frame)
            let field = password.frame
            let fieldY = Int(field.minY - frame.minY)
            // Only fixed synthetic field geometry; no values, labels, URLs,
            // accessibility tree or keyboard contents are attached.
            print("LOGIN_FORM_GEOMETRY attempt=\(attempt) webHeight=\(Int(frame.height)) visibleHeight=\(Int(visible.height)) passwordY=\(fieldY) keyboard=\(app.keyboards.firstMatch.exists)")
            guard !visible.isNull, visible.width >= 64, visible.height >= 64 else {
                XCTFail("Browser WebView has insufficient visible space above the keyboard for native form scrolling.")
                return nil
            }
            guard attempt < 3 else {
                XCTFail("Synthetic password field stayed inaccessible after three native page scrolls.")
                return nil
            }
            let origin = web.coordinate(withNormalizedOffset: .zero)
            let x = visible.minX - frame.minX + visible.width * 0.88
            let limit = visible.height * 0.6
            let delta = max(-limit, min(limit, visible.midY - field.midY))
            let middle = visible.midY - frame.minY
            // Move toward the viewport center in either direction; hold at the
            // end to stop momentum before remeasuring the native field frame.
            if abs(delta) >= 1 {
                let start = origin.withOffset(CGVector(dx: x, dy: middle - delta / 2))
                let end = origin.withOffset(CGVector(dx: x, dy: middle + delta / 2))
                start.press(forDuration: 0.1, thenDragTo: end,
                            withVelocity: .slow, thenHoldForDuration: 0.3)
            }
            // bb5c9eb SE: this short predicate waiter interrupted snapshot()
            // while the field was still partly covered, aborting the next
            // bounded scroll. The next loop iteration checks geometry once,
            // synchronously, after the native gesture's existing hold/idle.
            // No polling, extra delay, or per-scroll wait budget is added.
        }
        return nil
    }

    private func currentProtectedURL() -> URL {
        let raw = app.textFields["browser.address"].value as? String ?? ""
        guard let url = URL(string: raw), url.host == "127.0.0.1",
              url.path == "/login-fixture/\(namespace.lowercased())/protected" else {
            XCTFail("Expected the synthetic protected HTTP page.")
            return URL(string: "http://127.0.0.1:1/invalid")!
        }
        return url
    }

    private var serverInstance: String {
        let marker = app.webViews.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "LOGIN_SERVER_INSTANCE_")).firstMatch
        XCTAssertTrue(marker.waitForExistence(timeout: 10))
        return marker.label
    }
    private func openInNewTab(_ url: URL) {
        library(); tap(app.buttons["browser.tabs.new"])
        let field = app.textFields["browser.address"]
        tap(field)
        XCTAssertFalse((field.value as? String ?? "").hasPrefix("http://"), "New tab must start empty.")
        field.typeText(url.absoluteString + "\n")
    }
    private func library() { tap(app.buttons["browser.library"]); XCTAssertTrue(app.buttons["browser.library.close"].waitForExistence(timeout: 10)) }
    private func text(_ marker: String) -> XCUIElement { app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", marker)).firstMatch }
    private func tap(_ element: XCUIElement, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed, file: file, line: line)
        element.tap()
    }
}
#endif
