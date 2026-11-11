#if DEBUG && canImport(Network)
import Foundation
import Network

/// DEBUG-only real HTTP fixture, never a downloaded-file seeder or result stub.
/// Only one exact namespace and ephemeral loopback origin may cross manual
/// navigation/download policies. No model/research policy consults this fixture.
public final class BrowserDownloadedPDFFixture: @unchecked Sendable {
    public static let enabled = BrowserDownloadedPDFFixture(arguments: ProcessInfo.processInfo.arguments)
    public let namespace: UUID
    public var filename: String { "BrowserDownloadedPDF-" + namespace.uuidString + ".pdf" }
    public enum Failure: Error { case unavailable, stopped, timedOut }
    private let queue = DispatchQueue(label: "io.woowtech.download-pdf-fixture")
    private var listener: NWListener?
    private var origin: String?
    private var stopped = false
    private var waiters: [CheckedContinuation<URL, Error>] = []
    private var clients: [ObjectIdentifier: Client] = [:]
    private var startup: DispatchWorkItem?, expiry: DispatchWorkItem?
    private var requests = 0, downloads = 0
    private var prefix: String { "/download-pdf/" + namespace.uuidString.lowercased() }
    public var transferCount: Int { queue.sync { downloads } }

    public static func validatedNamespace(_ arguments: [String]) -> UUID? {
        let allowed = Set(["-UITestMode", "-UITestNamespace", "-UITestResetStorage", "-UITestBrowserDownloadedPDF"])
        guard ["-UITestMode", "-UITestNamespace", "-UITestBrowserDownloadedPDF"].allSatisfy({ flag in arguments.filter { $0 == flag }.count == 1 }),
              arguments.filter({ $0 == "-UITestResetStorage" }).count <= 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") || ($0.hasPrefix("-UITest") && !allowed.contains($0)) }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              arguments[index + 1].utf8.count == 36 else { return nil }
        return UUID(uuidString: arguments[index + 1])
    }
    public init?(arguments: [String]) {
        guard let namespace = Self.validatedNamespace(arguments) else { return nil }
        self.namespace = namespace
    }
    public func start() async throws -> URL {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in queue.async { self.begin(continuation) } }
        } onCancel: { [weak self] in self?.stop() }
    }
    public func allowsNavigation(_ url: URL) -> Bool {
        queue.sync { !stopped && origin.map { url.absoluteString == $0 + prefix + "/page" || url.absoluteString == $0 + prefix + "/file.pdf" } == true }
    }
    public func allowsDownload(_ url: URL) -> Bool {
        queue.sync { !stopped && origin.map { url.absoluteString == $0 + prefix + "/file.pdf" } == true }
    }
    public func stop() { queue.async { self.stopOnQueue(.stopped) } }
    deinit {
        startup?.cancel(); expiry?.cancel(); listener?.cancel()
        clients.values.forEach { $0.deadline?.cancel(); $0.connection.cancel() }
        waiters.forEach { $0.resume(throwing: Failure.stopped) }
    }
    private func begin(_ continuation: CheckedContinuation<URL, Error>) {
        guard !stopped else { continuation.resume(throwing: Failure.stopped); return }
        if let origin { continuation.resume(returning: URL(string: origin + prefix + "/page")!); return }
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
                    self.startup?.cancel(); self.startup = nil
                    self.origin = "http://127.0.0.1:\(port.rawValue)"
                    let page = URL(string: self.origin! + self.prefix + "/page")!
                    let pending = self.waiters; self.waiters.removeAll(); pending.forEach { $0.resume(returning: page) }
                    let expiry = DispatchWorkItem { [weak self] in self?.stopOnQueue(.timedOut) }
                    self.expiry = expiry; self.queue.asyncAfter(deadline: .now() + 300, execute: expiry)
                case .failed, .cancelled: self.stopOnQueue(.unavailable)
                default: break
                }
            }
            let deadline = DispatchWorkItem { [weak self] in self?.stopOnQueue(.timedOut) }
            startup = deadline; queue.asyncAfter(deadline: .now() + 5, execute: deadline); server.start(queue: queue)
        } catch { stopOnQueue(.unavailable) }
    }
    private func stopOnQueue(_ failure: Failure) {
        guard !stopped else { return }; stopped = true; origin = nil
        startup?.cancel(); expiry?.cancel(); startup = nil; expiry = nil
        listener?.stateUpdateHandler = nil; listener?.newConnectionHandler = nil; listener?.cancel(); listener = nil
        clients.values.forEach { $0.deadline?.cancel(); $0.connection.cancel() }; clients.removeAll()
        let pending = waiters; waiters.removeAll(); pending.forEach { $0.resume(throwing: failure) }
    }
    private final class Client {
        let connection: NWConnection
        var data = Data(), replied = false
        var deadline: DispatchWorkItem?
        init(_ connection: NWConnection) { self.connection = connection }
    }
    private func accept(_ connection: NWConnection) {
        guard !stopped, origin != nil, clients.count < 4, requests < 32 else { connection.cancel(); return }
        requests += 1
        let client = Client(connection); clients[ObjectIdentifier(connection)] = client
        let timeout = DispatchWorkItem { [weak self, weak client] in if let client { self?.close(client) } }
        client.deadline = timeout; queue.asyncAfter(deadline: .now() + 10, execute: timeout)
        connection.start(queue: queue); receive(client)
    }
    private func close(_ client: Client) {
        clients.removeValue(forKey: ObjectIdentifier(client.connection)); client.deadline?.cancel(); client.connection.cancel()
    }
    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self, weak client] data, _, complete, error in
            guard let self, let client, !self.stopped, !client.replied else { return }
            guard error == nil else { self.close(client); return }
            client.data.append(data ?? Data())
            guard client.data.count <= 8192 else { self.reply(client, status: 400, data: Data()); return }
            guard let end = client.data.range(of: Data("\r\n\r\n".utf8)) else {
                if complete { self.close(client) } else { self.receive(client) }; return
            }
            guard end.upperBound == client.data.count,
                  let raw = String(data: client.data[..<end.lowerBound], encoding: .utf8) else {
                self.reply(client, status: 400, data: Data()); return
            }
            let lines = raw.components(separatedBy: "\r\n"), first = raw.components(separatedBy: "\r\n")[0].split(separator: " ")
            guard first.count == 3, first[0] == "GET", first[2] == "HTTP/1.1" else {
                self.reply(client, status: 405, data: Data()); return
            }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { self.reply(client, status: 400, data: Data()); return }
                let name = line[..<colon].lowercased(), value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                guard headers[name] == nil else { self.reply(client, status: 400, data: Data()); return }; headers[name] = value
            }
            guard let origin = self.origin, headers["host"] == String(origin.dropFirst("http://".count)),
                  headers["transfer-encoding"] == nil, headers["content-length"].map({ $0 == "0" }) ?? true else {
                self.reply(client, status: 403, data: Data()); return
            }
            if first[1] == self.prefix + "/page" {
                let html = """
                <!doctype html><html lang="zh-Hant"><meta name="viewport" content="width=device-width,initial-scale=1"><title>PDF download fixture</title>
                <body style="font:20px sans-serif;padding:20px"><p>DLPDF_NAMESPACE_\(self.namespace.uuidString)</p>
                <p>DLPDF_REQUESTS_\(self.downloads)</p><p><a href="\(self.prefix)/file.pdf" download="\(self.filename)">下載測試 PDF</a></p>
                <p><a href="\(self.prefix)/page">檢查下載傳送次數</a></p></body></html>
                """
                self.reply(client, status: 200, data: Data(html.utf8), type: "text/html; charset=utf-8")
            } else if first[1] == self.prefix + "/file.pdf" {
                self.downloads += 1
                self.reply(client, status: 200, data: Self.payload, type: "application/pdf", attachment: self.filename)
            } else { self.reply(client, status: 404, data: Data()) }
        }
    }
    private func reply(_ client: Client, status: Int, data: Data, type: String = "text/plain", attachment: String? = nil) {
        guard !client.replied else { return }; client.replied = true
        var headers = "HTTP/1.1 \(status) Fixture\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'\r\n"
        if let attachment { headers += "Content-Disposition: attachment; filename=\"\(attachment)\"\r\n" }
        client.connection.send(content: Data((headers + "\r\n").utf8) + data, completion: .contentProcessed { [weak self, weak client] _ in
            if let client { self?.close(client) }
        })
    }
    /// Public synthetic fixture, identical bytes for every namespace. Names and
    /// routes are isolated; no files are preseeded in Documents/download storage.
    public static var payload: Data {
        let streams = ["BT /F1 18 Tf 40 700 Td (WOOW_DOWNLOADED_PDF_ALPHA) Tj ET", "BT /F1 18 Tf 40 700 Td (WOOW_DOWNLOADED_PDF_BETA) Tj ET"]
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 5 0 R] /Count 2 >>"]
        for (index, stream) in streams.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 7 0 R >> >> /Contents \(4 + index * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var text = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() { offsets.append(text.utf8.count); text += "\(index + 1) 0 obj\n\(object)\nendobj\n" }
        let start = text.utf8.count
        text += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { text += String(format: "%010d 00000 n \n", offset) }
        text += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(text.utf8)
    }
}
#elseif canImport(Network)
import Foundation

/// Inert API for CLT checkers that intentionally link a Debug App against a
/// Release browser module. No server, payload, gate or URL exception is compiled.
public final class BrowserDownloadedPDFFixture {
    public static let enabled: BrowserDownloadedPDFFixture? = nil
    public var namespace: UUID { UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)) }
    public var filename: String { "" }
    public var transferCount: Int { 0 }
    public static var payload: Data { Data() }
    public static func validatedNamespace(_ arguments: [String]) -> UUID? { nil }
    public init?(arguments: [String]) { return nil }
    public func start() async throws -> URL { throw CocoaError(.featureUnsupported) }
    public func allowsNavigation(_ url: URL) -> Bool { false }
    public func allowsDownload(_ url: URL) -> Bool { false }
    public func stop() {}
}
#endif
