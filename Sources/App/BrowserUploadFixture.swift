#if DEBUG
import Foundation
import Network

/// DEBUG-only real HTTP fixture. There is no release symbol, local-network
/// exception, TLS override, model action, or file-input injection in this file.
/// Parent mounts `try await enabled?.start()` and permits only `allows(url)` for
/// manual navigation. Research keeps its normal WebsiteOrigin policy.
/// iOS 17's test host needs a Debug-only ATS exception for 127.0.0.1 HTTP.
final class BrowserUploadFixture: @unchecked Sendable {
    static let enabled = BrowserUploadFixture(arguments: ProcessInfo.processInfo.arguments)
    static let filename = "BrowserUploadFixture.txt"
    static let payload = Data("WOOW_BROWSER_UPLOAD_FIXTURE_V1\n".utf8)

    enum Failure: Error { case unavailable, stopped, unsafeFile, timedOut }
    private static let maximumHeaders = 8_192
    private static let maximumBody = 16_384
    private static let maximumConnections = 4
    private static let maximumRequests = 64
    private static let maximumReceipts = 16

    private let queue = DispatchQueue(label: "io.woowtech.browser-upload-fixture")
    private let namespace: UUID
    private let documents: URL
    private let requestTimeout: TimeInterval
    private let lifetime: TimeInterval
    private var listener: NWListener?
    private var origin: String?
    private var stopped = false
    private var waiters: [CheckedContinuation<URL, Error>] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var requestCount = 0
    private var receiptCount = 0
    private var ownsSeed = false
    private var startupDeadline: DispatchWorkItem?
    private var lifetimeDeadline: DispatchWorkItem?

    private var prefix: String { "/upload-fixture/" + namespace.uuidString.lowercased() }
    private var file: URL { documents.appendingPathComponent(Self.filename) }
    private var paths: Set<String> { [prefix + "/form", prefix + "/upload", prefix + "/status"] }

    /// An injectable Documents directory is for the command-line fixture tests.
    /// Even those callers must supply both flags and exactly one valid UUID.
    init?(arguments: [String], documentsDirectory: URL? = nil,
          requestTimeout: TimeInterval = 10, lifetime: TimeInterval = 300) {
        guard arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestBrowserUpload" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              arguments[index + 1].utf8.count == 36, let id = UUID(uuidString: arguments[index + 1]),
              let root = documentsDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first,
              root.isFileURL else { return nil }
        namespace = id; documents = root.standardizedFileURL
        self.requestTimeout = max(0.1, min(10, requestTimeout))
        self.lifetime = max(0.1, min(300, lifetime))
    }

    /// Idempotent while running. Cancellation, explicit stop and the five-minute
    /// lifetime close the listener, pending connections and only our own seed.
    func start() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in begin(continuation) }
            }
        } onCancel: { [weak self] in self?.stop() }
    }

    /// No localhost aliases, credential authority, query, fragment, escaped path,
    /// alternate port or arbitrary path. An expired fixture permits nothing.
    func allows(_ url: URL) -> Bool {
        queue.sync {
            guard !stopped, let origin else { return false }
            return paths.contains { url.absoluteString == origin + $0 }
        }
    }

    func stop() { queue.async { [weak self] in self?.stopOnQueue(.stopped) } }

    #if BROWSER_UPLOAD_FIXTURE_SMOKE
    // Observation only, compiled exclusively into the standalone HTTP tests.
    var smokeActiveConnections: Int { queue.sync { clients.count } }
    #endif

    deinit {
        startupDeadline?.cancel(); lifetimeDeadline?.cancel()
        listener?.cancel()
        for client in clients.values { client.deadline?.cancel(); client.connection.cancel() }
        for waiter in waiters { waiter.resume(throwing: Failure.stopped) }
        removeSeedIfOwned()
    }

    private func begin(_ continuation: CheckedContinuation<URL, Error>) {
        guard !stopped else { continuation.resume(throwing: Failure.stopped); return }
        if let origin, let url = URL(string: origin + prefix + "/form") { continuation.resume(returning: url); return }
        waiters.append(continuation)
        guard listener == nil else { return }
        do {
            try seedFile()
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let server = try NWListener(using: parameters)
            listener = server
            server.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            server.stateUpdateHandler = { [weak self, weak server] state in
                guard let self, let server, self.listener === server, !self.stopped else { return }
                switch state {
                case .ready:
                    guard let port = server.port else { self.stopOnQueue(.unavailable); return }
                    self.startupDeadline?.cancel(); self.startupDeadline = nil
                    self.origin = "http://127.0.0.1:\(port.rawValue)"
                    guard let url = URL(string: self.origin! + self.prefix + "/form") else {
                        self.stopOnQueue(.unavailable); return
                    }
                    let pending = self.waiters; self.waiters.removeAll()
                    for waiter in pending { waiter.resume(returning: url) }
                    let expiry = DispatchWorkItem { [weak self] in self?.stopOnQueue(.timedOut) }
                    self.lifetimeDeadline = expiry
                    self.queue.asyncAfter(deadline: .now() + self.lifetime, execute: expiry)
                case .failed, .cancelled: self.stopOnQueue(.unavailable)
                default: break
                }
            }
            let startup = DispatchWorkItem { [weak self] in self?.stopOnQueue(.timedOut) }
            startupDeadline = startup
            queue.asyncAfter(deadline: .now() + 5, execute: startup)
            server.start(queue: queue)
        } catch { stopOnQueue(error as? Failure ?? .unavailable) }
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
        removeSeedIfOwned()
    }

    private func seedFile() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        guard try fm.attributesOfItem(atPath: documents.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw Failure.unsafeFile
        }
        if (try? fm.attributesOfItem(atPath: file.path)) != nil {
            // Preserve any unrelated or modified file, including symlinks. A
            // prior abruptly terminated fixture may leave the exact seed intact.
            guard seedMatches() else { throw Failure.unsafeFile }
            return
        }
        try Self.payload.write(to: file, options: .withoutOverwriting)
        ownsSeed = true
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #if os(iOS)
        try fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        #endif
    }

    private func seedMatches() -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
              attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1,
              (attributes[.size] as? NSNumber)?.intValue == Self.payload.count else { return false }
        return (try? Data(contentsOf: file)) == Self.payload
    }

    private func removeSeedIfOwned() {
        if ownsSeed, seedMatches() { try? FileManager.default.removeItem(at: file) }
        ownsSeed = false
    }

    private final class Client {
        let connection: NWConnection
        var buffer = Data()
        var request: Request?
        var headerEnd = 0
        var replied = false
        var deadline: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    private struct Request {
        let method: String
        let path: String
        let headers: [String: String]
        let length: Int
    }

    private struct Rejection: Error { let status: Int }

    private func accept(_ connection: NWConnection) {
        guard !stopped, origin != nil, clients.count < Self.maximumConnections,
              requestCount < Self.maximumRequests else { connection.cancel(); return }
        requestCount += 1
        let client = Client(connection), key = ObjectIdentifier(connection)
        clients[key] = client
        let timeout = DispatchWorkItem { [weak self, weak client] in
            guard let self, let client else { return }
            self.close(client)
        }
        client.deadline = timeout
        queue.asyncAfter(deadline: .now() + requestTimeout, execute: timeout)
        connection.start(queue: queue)
        receive(client)
    }

    private func close(_ client: Client) {
        client.deadline?.cancel(); client.deadline = nil
        client.connection.cancel()
        clients.removeValue(forKey: ObjectIdentifier(client.connection))
    }

    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { [weak self, weak client] data, _, done, error in
            guard let self, let client, !self.stopped, !client.replied,
                  self.clients[ObjectIdentifier(client.connection)] != nil else { return }
            if error != nil { self.close(client); return }
            if let data { client.buffer.append(data) }
            do {
                guard client.buffer.count <= Self.maximumHeaders + Self.maximumBody else { throw Rejection(status: 413) }
                if client.request == nil {
                    if let separator = client.buffer.range(of: Data("\r\n\r\n".utf8)) {
                        guard separator.lowerBound <= Self.maximumHeaders else { throw Rejection(status: 431) }
                        client.request = try self.parseRequest(Data(client.buffer[..<separator.lowerBound]))
                        client.headerEnd = separator.upperBound
                    } else {
                        guard client.buffer.count <= Self.maximumHeaders else { throw Rejection(status: 431) }
                    }
                }
                if let request = client.request {
                    let expected = client.headerEnd + request.length
                    guard client.buffer.count <= expected else { throw Rejection(status: 400) }
                    if client.buffer.count == expected {
                        try self.handle(request, body: Data(client.buffer[client.headerEnd...]), client: client)
                        return
                    }
                }
                if done { throw Rejection(status: 400) }
                self.receive(client)
            } catch {
                self.reply(client, status: (error as? Rejection)?.status ?? 400,
                           content: self.page("<p>UPLOAD_REJECTED</p><p>測試上傳未通過驗證。</p>"))
            }
        }
    }

    private func parseRequest(_ data: Data) throws -> Request {
        guard let text = String(data: data, encoding: .utf8), let origin else { throw Rejection(status: 400) }
        let lines = text.components(separatedBy: "\r\n")
        let first = (lines.first ?? "").split(separator: " ", omittingEmptySubsequences: false)
        guard first.count == 3, first[2] == "HTTP/1.1", ["GET", "POST"].contains(first[0]) else {
            throw Rejection(status: 405)
        }
        let headers = try Self.headers(Array(lines.dropFirst()))
        guard headers["host"] == String(origin.dropFirst("http://".count)),
              paths.contains(String(first[1])) else { throw Rejection(status: 403) }
        guard headers["transfer-encoding"] == nil, headers["expect"] == nil else { throw Rejection(status: 400) }
        let rawLength = headers["content-length"] ?? (first[0] == "GET" ? "0" : "")
        guard !rawLength.isEmpty, rawLength.utf8.allSatisfy({ (48...57).contains($0) }),
              let length = Int(rawLength) else { throw Rejection(status: 411) }
        guard length <= Self.maximumBody else { throw Rejection(status: 413) }
        if first[0] == "GET", length != 0 { throw Rejection(status: 400) }
        return Request(method: String(first[0]), path: String(first[1]), headers: headers, length: length)
    }

    private static func headers(_ lines: [String]) throws -> [String: String] {
        guard lines.count <= 32 else { throw Rejection(status: 431) }
        var result: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { throw Rejection(status: 400) }
            let key = String(line[..<colon]).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }),
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  result[key] == nil else { throw Rejection(status: 400) }
            result[key] = value
        }
        return result
    }

    private func handle(_ request: Request, body: Data, client: Client) throws {
        if request.method == "GET", request.path == prefix + "/form" {
            reply(client, status: 200, content: form)
        } else if request.method == "GET", request.path == prefix + "/status" {
            reply(client, status: 200, content: page("<h1>伺服器收件狀態</h1><p>UPLOAD_SERVER_RECEIPTS_\(receiptCount)</p>"))
        } else if request.method == "POST", request.path == prefix + "/upload" {
            guard request.headers["origin"] == origin else { throw Rejection(status: 403) }
            guard receiptCount < Self.maximumReceipts else { throw Rejection(status: 429) }
            try Self.verifyMultipart(body, contentType: request.headers["content-type"] ?? "")
            // Increment ONLY after actual complete network bytes pass validation.
            // Neither opening the chooser nor a DOM onchange can reach this code.
            receiptCount += 1
            reply(client, status: 200, content: page("""
                <h1>已收到測試檔案</h1><p>UPLOAD_RECEIVED_BROWSER_UPLOAD_FIXTURE_V1</p>
                <p>UPLOAD_SERVER_RECEIPTS_\(receiptCount)</p><p>UPLOAD_FILE_BYTES_\(Self.payload.count)</p>
                """))
        } else { throw Rejection(status: 405) }
    }

    private static func verifyMultipart(_ body: Data, contentType: String) throws {
        let components = contentType.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard components.count == 2, components[0].lowercased() == "multipart/form-data",
              components[1].lowercased().hasPrefix("boundary=") else { throw Rejection(status: 415) }
        var boundary = String(components[1].dropFirst("boundary=".count))
        if boundary.hasPrefix("\""), boundary.hasSuffix("\""), boundary.count >= 2 { boundary = String(boundary.dropFirst().dropLast()) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'()+_,-./:=?")
        guard (1...70).contains(boundary.utf8.count), boundary.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw Rejection(status: 400)
        }
        let opening = Data(("--" + boundary + "\r\n").utf8)
        let closing = Data(("\r\n--" + boundary + "--").utf8)
        let ending = body.suffix(closing.count + 2) == closing + Data("\r\n".utf8) ? closing.count + 2 : closing.count
        guard body.starts(with: opening), body.count >= opening.count + ending,
              body.suffix(ending) == (ending == closing.count ? closing : closing + Data("\r\n".utf8)) else {
            throw Rejection(status: 400)
        }
        let inner = Data(body.dropFirst(opening.count).dropLast(ending))
        guard let separator = inner.range(of: Data("\r\n\r\n".utf8)), separator.lowerBound <= 2_048,
              let text = String(data: inner[..<separator.lowerBound], encoding: .utf8) else { throw Rejection(status: 400) }
        let partHeaders = try headers(text.components(separatedBy: "\r\n"))
        guard Set(partHeaders.keys).isSubset(of: ["content-disposition", "content-type"]),
              let disposition = partHeaders["content-disposition"] else { throw Rejection(status: 400) }
        let fields = disposition.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count == 3, fields[0].lowercased() == "form-data" else { throw Rejection(status: 400) }
        var values: [String: String] = [:]
        for field in fields.dropFirst() {
            guard let equal = field.firstIndex(of: "=") else { throw Rejection(status: 400) }
            let name = String(field[..<equal]).lowercased()
            var value = String(field[field.index(after: equal)...])
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            guard values[name] == nil else { throw Rejection(status: 400) }
            values[name] = value
        }
        guard values == ["name": "file", "filename": filename], Data(inner[separator.upperBound...]) == payload else {
            throw Rejection(status: 422)
        }
    }

    private func reply(_ client: Client, status: Int, content: String) {
        guard !client.replied, clients[ObjectIdentifier(client.connection)] != nil else { return }
        client.replied = true
        let body = Data(content.utf8)
        let headers = [
            "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Rejected")",
            "Content-Type: text/html; charset=utf-8", "Content-Length: \(body.count)",
            "Cache-Control: no-store", "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; script-src 'nonce-\(namespace.uuidString)'; style-src 'nonce-\(namespace.uuidString)'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'",
            "Connection: close"
        ].joined(separator: "\r\n") + "\r\n\r\n"
        client.connection.send(content: Data(headers.utf8) + body, completion: .contentProcessed { [weak self, weak client] _ in
            guard let self, let client else { return }
            self.close(client)
        })
    }

    private func page(_ content: String) -> String {
        """
        <!doctype html><html lang="zh-Hant"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1"><title>檔案上傳測試</title>
        <style nonce="\(namespace.uuidString)">body{font:17px -apple-system;padding:20px}button,input{font:inherit;margin:12px 0;padding:12px;display:block}p{overflow-wrap:anywhere}</style>
        </head><body>\(content)</body></html>
        """
    }

    private var form: String {
        page("""
        <h1>手動選檔與上傳測試</h1><p>UPLOAD_FORM_READY</p>
        <form method="post" action="\(prefix)/upload" enctype="multipart/form-data">
        <label for="file">選擇測試檔案</label>
        <input id="file" type="file" name="file" accept=".txt,text/plain" aria-label="選擇測試檔案" required>
        <p id="selection">UPLOAD_SELECTED_NONE</p><button type="submit">送出測試檔案</button></form>
        <button id="status" type="button">查詢伺服器收件狀態</button>
        <script nonce="\(namespace.uuidString)">
        document.getElementById('file').addEventListener('change', function() {
          document.getElementById('selection').textContent = this.files.length === 1
            ? 'UPLOAD_SELECTED_1_' + this.files[0].name : 'UPLOAD_SELECTED_NONE';
        });
        document.getElementById('status').addEventListener('click', function() { location.href = '\(prefix)/status'; });
        </script>
        """)
    }
}
#endif
