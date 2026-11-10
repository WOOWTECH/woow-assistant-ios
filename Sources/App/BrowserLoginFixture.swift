#if DEBUG
import Foundation
import Network

/// Real, synthetic HTTP form login only; not OAuth, MFA, production account
/// security, or a JavaScript/HTTPCookieStore cookie injection. Release has no
/// fixture symbol. Parent permits `allows` only for manual browser navigation.
/// The existing Debug-only 127.0.0.1 ATS exception is sufficient.
final class BrowserLoginFixture: @unchecked Sendable {
    static let enabled = BrowserLoginFixture(arguments: ProcessInfo.processInfo.arguments)
    static let username = "fixture-user"
    static let password = "fixture-password-v1"
    static let cookieName = "woow_login_fixture"
    enum Failure: Error { case unavailable, stopped, timedOut }

    private let queue = DispatchQueue(label: "io.woowtech.browser-login-fixture")
    private let namespace: UUID
    private let requestTimeout: TimeInterval
    private let lifetime: TimeInterval
    private var listener: NWListener?
    private var origin: String?
    private var stopped = false
    private var waiters: [CheckedContinuation<URL, Error>] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var startupDeadline: DispatchWorkItem?
    private var lifetimeDeadline: DispatchWorkItem?
    private var requests = 0
    private var logins = 0
    private var logouts = 0
    private var protectedChecks = 0
    private let instance = UUID().uuidString.lowercased()
    private var prefix: String { "/login-fixture/" + namespace.uuidString.lowercased() }
    private var paths: Set<String> { [prefix + "/status", prefix + "/login", prefix + "/protected", prefix + "/logout"] }
    // Deliberately deterministic SYNTHETIC token: a replacement fixture process
    // can validate the browser's previously issued cookie without a real account
    // database or persisted secret. Never reuse this as production authentication.
    private var token: String { "synthetic-" + namespace.uuidString.lowercased() }

    init?(arguments: [String], requestTimeout: TimeInterval = 10, lifetime: TimeInterval = 300) {
        guard arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestBrowserLogin" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              !arguments.contains("-UITestBrowserUpload"), !arguments.contains(where: { $0.hasPrefix("-Live") }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              arguments[index + 1].utf8.count == 36,
              let id = UUID(uuidString: arguments[index + 1]) else { return nil }
        namespace = id
        self.requestTimeout = max(0.1, min(10, requestTimeout))
        self.lifetime = max(0.1, min(300, lifetime))
    }

    /// Idempotent for this process; returns /status, which authenticates only
    /// from the actual request Cookie header. Relaunch with the same namespace
    /// and without -UITestResetStorage to test WebKit's persistent cookie store.
    func start() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in begin(continuation) }
            }
        } onCancel: { [weak self] in self?.stop() }
    }

    func allows(_ url: URL) -> Bool {
        queue.sync {
            guard !stopped, let origin else { return false }
            return paths.contains { url.absoluteString == origin + $0 }
        }
    }
    func stop() { queue.async { [weak self] in self?.stopOnQueue(.stopped) } }

    deinit {
        startupDeadline?.cancel(); lifetimeDeadline?.cancel(); listener?.cancel()
        for client in clients.values { client.deadline?.cancel(); client.connection.cancel() }
        for waiter in waiters { waiter.resume(throwing: Failure.stopped) }
    }

    private func begin(_ continuation: CheckedContinuation<URL, Error>) {
        guard !stopped else { continuation.resume(throwing: Failure.stopped); return }
        if let origin, let url = URL(string: origin + prefix + "/status") { continuation.resume(returning: url); return }
        waiters.append(continuation)
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let server = try NWListener(using: parameters); listener = server
            server.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }; self.accept(connection)
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self, let server, self.listener === server, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = server.port else { self.stopOnQueue(.unavailable); return }
                    self.startupDeadline?.cancel(); self.startupDeadline = nil
                    self.origin = "http://127.0.0.1:\(port.rawValue)"
                    guard let url = URL(string: self.origin! + self.prefix + "/status") else { self.stopOnQueue(.unavailable); return }
                    let pending = self.waiters; self.waiters.removeAll()
                    for waiter in pending { waiter.resume(returning: url) }
                    let expiry = DispatchWorkItem { [weak self] in self?.stopOnQueue(.timedOut) }
                    self.lifetimeDeadline = expiry
                    self.queue.asyncAfter(deadline: .now() + self.lifetime, execute: expiry)
                case .failed, .cancelled: self.stopOnQueue(.unavailable)
                default: break
                }
            }
            let deadline = DispatchWorkItem { [weak self] in self?.stopOnQueue(.timedOut) }
            startupDeadline = deadline; queue.asyncAfter(deadline: .now() + 5, execute: deadline)
            server.start(queue: queue)
        } catch { stopOnQueue(.unavailable) }
    }

    private func stopOnQueue(_ failure: Failure) {
        guard !stopped else { return }
        stopped = true; origin = nil
        startupDeadline?.cancel(); lifetimeDeadline?.cancel()
        startupDeadline = nil; lifetimeDeadline = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil
        listener?.cancel(); listener = nil
        for client in clients.values { client.deadline?.cancel(); client.connection.cancel() }
        clients.removeAll()
        let pending = waiters; waiters.removeAll()
        for waiter in pending { waiter.resume(throwing: failure) }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let length: Int
    }
    private struct Rejection: Error { let status: Int }
    private final class Client {
        let connection: NWConnection
        var data = Data()
        var request: Request?
        var headerEnd = 0
        var replied = false
        var deadline: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, origin != nil, clients.count < 4, requests < 64 else { connection.cancel(); return }
        requests += 1
        let client = Client(connection); clients[ObjectIdentifier(connection)] = client
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }; self.close(client)
        }
        client.deadline = timeout; queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        connection.start(queue: queue); receive(client)
    }

    private func close(_ client: Client) {
        client.deadline?.cancel(); client.deadline = nil
        client.connection.cancel(); clients.removeValue(forKey: ObjectIdentifier(client.connection))
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 2_048) { [weak self, weak client] data, _, done, error in
            guard let self, let client, !self.stopped, !client.replied,
                  self.clients[ObjectIdentifier(client.connection)] != nil else { return }
            if error != nil { self.close(client); return }
            client.data.append(data ?? Data())
            do {
                guard client.data.count <= 8_192 + 1_024 else { throw Rejection(status: 413) }
                if client.request == nil {
                    if let separator = client.data.range(of: Data("\r\n\r\n".utf8)) {
                        guard separator.lowerBound <= 8_192 else { throw Rejection(status: 431) }
                        client.request = try self.parse(Data(client.data[..<separator.lowerBound]))
                        client.headerEnd = separator.upperBound
                    } else if client.data.count > 8_192 { throw Rejection(status: 431) }
                }
                if let request = client.request {
                    let length = client.headerEnd + request.length
                    guard client.data.count <= length else { throw Rejection(status: 400) }
                    if client.data.count == length {
                        try self.handle(request, body: Data(client.data[client.headerEnd...]), client: client); return
                    }
                }
                if done { throw Rejection(status: 400) }
                self.receive(client)
            } catch {
                self.reply(client, status: (error as? Rejection)?.status ?? 400,
                           body: self.page("<p>LOGIN_REQUEST_REJECTED</p><p>測試登入請求未通過驗證。</p>"))
            }
        }
    }

    private func parse(_ data: Data) throws -> Request {
        guard let text = String(data: data, encoding: .utf8), let origin else { throw Rejection(status: 400) }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, ["GET", "POST"].contains(first[0]), first[2] == "HTTP/1.1", lines.count <= 33 else { throw Rejection(status: 400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw Rejection(status: 400) }
            let name = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), headers[name] == nil else { throw Rejection(status: 400) }
            headers[name] = value
        }
        guard headers["host"] == String(origin.dropFirst(7)), paths.contains(String(first[1])) else { throw Rejection(status: 403) }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw Rejection(status: 400) }
        let rawLength = headers["content-length"] ?? (first[0] == "GET" ? "0" : "")
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }), let length = Int(rawLength) else { throw Rejection(status: 411) }
        guard length <= 1_024 else { throw Rejection(status: 413) }
        if first[0] == "GET", length != 0 { throw Rejection(status: 400) }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, length: length)
    }

    private func authenticated(_ request: Request) -> Bool {
        let matches = (request.headers["cookie"] ?? "").split(separator: ";").compactMap { raw -> String? in
            let value = raw.trimmingCharacters(in: .whitespaces)
            guard let equal = value.firstIndex(of: "="), String(value[..<equal]) == Self.cookieName else { return nil }
            return String(value[value.index(after: equal)...])
        }
        return matches.count == 1 && matches[0] == token
    }

    private func handle(_ request: Request, body: Data, client: Client) throws {
        let authorized = authenticated(request)
        if request.method == "GET", request.path == prefix + "/status" {
            reply(client, status: 200, body: statePage(authenticated: authorized))
        } else if request.method == "GET", request.path == prefix + "/protected" {
            protectedChecks += 1
            reply(client, status: authorized ? 200 : 401,
                  body: statePage(authenticated: authorized, protected: true))
        } else if request.method == "POST", request.path == prefix + "/login" {
            guard request.headers["origin"] == origin else { throw Rejection(status: 403) }
            guard request.headers["content-type"]?.split(separator: ";").first?.lowercased() == "application/x-www-form-urlencoded" else { throw Rejection(status: 415) }
            guard logins < 16 else { throw Rejection(status: 429) }
            let fields = try Self.formFields(body)
            guard fields == ["username": Self.username, "password": Self.password] else {
                reply(client, status: 401, body: page("<p>LOGIN_CREDENTIALS_REJECTED</p>" + stateContent(authenticated: false))); return
            }
            logins += 1
            reply(client, status: 303, body: page("<p>LOGIN_POST_RECEIVED</p>"),
                  extra: ["Location: " + prefix + "/protected", "Set-Cookie: " + cookie(deleting: false)])
        } else if request.method == "POST", request.path == prefix + "/logout" {
            guard body.isEmpty, request.headers["origin"] == origin else { throw Rejection(status: 403) }
            guard authorized else { throw Rejection(status: 401) }
            logouts += 1
            reply(client, status: 303, body: page("<p>LOGIN_LOGOUT_RECEIVED</p>"),
                  extra: ["Location: " + prefix + "/status", "Set-Cookie: " + cookie(deleting: true)])
        } else { throw Rejection(status: 405) }
    }

    private static func formFields(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw Rejection(status: 400) }
        let parts = text.split(separator: "&", omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw Rejection(status: 400) }
        var fields: [String: String] = [:]
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2,
                  let key = pair[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  let value = pair[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding,
                  fields[key] == nil else { throw Rejection(status: 400) }
            fields[key] = value
        }
        return fields
    }

    private func cookie(deleting: Bool) -> String {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let expiry = formatter.string(from: deleting ? Date(timeIntervalSince1970: 0) : Date().addingTimeInterval(600))
        // Host-only: intentionally no Domain and no port. HTTP is debug loopback
        // only, so this synthetic cookie cannot use the Secure attribute.
        return "\(Self.cookieName)=\(deleting ? "" : token); Path=\(prefix)/; Max-Age=\(deleting ? 0 : 600); Expires=\(expiry); HttpOnly; SameSite=Lax"
    }

    private func reply(_ client: Client, status: Int, body: String, extra: [String] = []) {
        guard !client.replied, clients[ObjectIdentifier(client.connection)] != nil else { return }
        client.replied = true
        let bytes = Data(body.utf8)
        let headers = ["HTTP/1.1 \(status) Fixture", "Content-Type: text/html; charset=utf-8", "Content-Length: \(bytes.count)",
                       "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
                       "Content-Security-Policy: default-src 'none'; style-src 'nonce-\(namespace.uuidString)'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
                       "Connection: close"] + extra
        client.connection.send(content: Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8) + bytes,
                               completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }; self.close(client)
        })
    }

    private func page(_ body: String) -> String {
        """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>合成帳密登入測試</title><style nonce="\(namespace.uuidString)">body{font:16px -apple-system;padding:16px}input,button{font:inherit;display:block;padding:10px;margin:8px 0}p{overflow-wrap:anywhere;margin:8px 0}</style>
        </head><body>\(body)</body></html>
        """
    }

    private func statePage(authenticated: Bool, protected: Bool = false) -> String {
        let marker = protected ? "<p>\(authenticated ? "LOGIN_PROTECTED_AUTHENTICATED" : "LOGIN_PROTECTED_DENIED")</p>" : "<p>LOGIN_STATUS_READY</p>"
        return page(marker + stateContent(authenticated: authenticated))
    }

    private func stateContent(authenticated: Bool) -> String {
        let controls: String
        if authenticated {
            controls = "<a href=\"\(prefix)/protected\">開啟受保護頁面</a><form method=\"post\" action=\"\(prefix)/logout\"><button type=\"submit\">登出測試帳號</button></form>"
        } else {
            controls = """
            <form method="post" action="\(prefix)/login" autocomplete="off">
            <label for="username">測試帳號</label><input id="username" name="username" aria-label="測試帳號" autocomplete="off" autocapitalize="none" spellcheck="false" required>
            <label for="password">測試密碼</label><input id="password" name="password" type="password" aria-label="測試密碼" autocomplete="off" enterkeyhint="go" required>
            <button type="submit">登入測試帳號</button></form>
            """
        }
        // Counters and auth marker are derived only from handled HTTP requests;
        // no script can fabricate a server receipt or read the HttpOnly token.
        return """
        <h1>合成帳密登入測試</h1><p>\(authenticated ? "LOGIN_AUTHENTICATED" : "LOGIN_ANONYMOUS")</p>
        \(controls)<p>LOGIN_SERVER_LOGINS_\(logins)</p><p>LOGIN_SERVER_LOGOUTS_\(logouts)</p>
        <p>LOGIN_PROTECTED_CHECKS_\(protectedChecks)</p><p>LOGIN_SERVER_INSTANCE_\(instance)</p>
        """
    }
}
#endif
