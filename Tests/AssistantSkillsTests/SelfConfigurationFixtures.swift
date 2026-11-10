#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE
import AssistantModels
import Foundation
import Network

actor SelfConfigurationSequenceModel: ChatModelClient {
    private var replies: [String]
    private(set) var inputs: [[ModelMessage]] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        inputs.append(messages)
        guard !replies.isEmpty else { throw HTTPChatModelError.invalidResponse }
        return replies.removeFirst()
    }
}

/// Deliberately ignores cancellation until released, to exercise the *write*
/// guard rather than relying on a friendly transport to suppress late replies.
actor SelfConfigurationLateModel: ChatModelClient {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var calls = 0
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        calls += 1
        if calls == 1 { return "{\"action\":\"tool\",\"name\":\"settings_list\",\"arguments\":{}}" }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ text: String) { continuation?.resume(returning: text); continuation = nil }
    var pending: Bool { continuation != nil }
}

/// A real bounded HTTP/1.1 server, bound only to IPv4 loopback. Request bodies
/// come from HTTPChatModelClient through the test-only bridge below, not from
/// direct calls to the fixture. No server/listener code is compiled into App.
final class SelfConfigurationSocketFixture: @unchecked Sendable {
    enum Failure: Error { case unavailable, invalidRequest }
    static let key = "self-configuration-synthetic-not-live"
    private let queue = DispatchQueue(label: "self-configuration-socket-fixture")
    private let listener: NWListener
    private let replies: [String]
    private let holdSecond: Bool
    private let status: Int
    private var startup: CheckedContinuation<URL, Error>?
    private var stopped = false
    private var clients: [ObjectIdentifier: Client] = [:]
    private var bodies: [Data] = []
    private var held: Client?
    var requestBodies: [Data] { queue.sync { bodies } }

    private final class Client {
        let connection: NWConnection
        var data = Data()
        var replied = false
        var response: Data?
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(_ replies: [String], holdSecond: Bool = false, status: Int = 200) throws {
        self.replies = Array(replies.prefix(4)); self.holdSecond = holdSecond; self.status = status
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
    }

    func start() async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                startup = continuation
                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        guard let port = self.listener.port else { self.stopOnQueue(); return }
                        let callback = self.startup; self.startup = nil
                        callback?.resume(returning: URL(string: "http://127.0.0.1:\(port.rawValue)/v1/chat/completions")!)
                    case .failed, .cancelled: self.stopOnQueue()
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self, !self.stopped, self.clients.count < 4, self.bodies.count < 4 else {
                        connection.cancel(); return
                    }
                    let client = Client(connection)
                    self.clients[ObjectIdentifier(connection)] = client
                    connection.start(queue: self.queue); self.receive(client)
                    self.queue.asyncAfter(deadline: .now() + 10) { [weak self, weak client] in
                        if let client { self?.close(client) }
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                    if self?.startup != nil { self?.stopOnQueue() }
                }
                queue.asyncAfter(deadline: .now() + 20) { [weak self] in self?.stopOnQueue() }
            }
        }
    }

    func release() { queue.async { [self] in if let held { self.held = nil; send(held) } } }
    func stop() { queue.sync { stopOnQueue() } }
    deinit { listener.cancel(); for client in clients.values { client.connection.cancel() } }

    private func stopOnQueue() {
        guard !stopped else { return }; stopped = true
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil; listener.cancel()
        for client in clients.values { client.connection.cancel() }
        clients.removeAll(); held = nil
        let callback = startup; startup = nil; callback?.resume(throwing: Failure.unavailable)
    }
    private func close(_ client: Client) {
        client.connection.cancel(); clients.removeValue(forKey: ObjectIdentifier(client.connection))
        if held === client { held = nil }
    }
    private func receive(_ client: Client) {
        client.connection.receive(minimumIncompleteLength: 1, maximumLength: 2048) { [weak self, weak client] data, _, done, error in
            guard let self, let client, !self.stopped, !client.replied else { return }
            client.data.append(data ?? Data())
            guard error == nil, client.data.count <= 32768 else { self.close(client); return }
            do {
                if let separator = client.data.range(of: Data("\r\n\r\n".utf8)) {
                    guard separator.lowerBound <= 8192 else { throw Failure.invalidRequest }
                    let header = String(decoding: client.data[..<separator.lowerBound], as: UTF8.self)
                    let lines = header.components(separatedBy: "\r\n")
                    guard lines.first == "POST /v1/chat/completions HTTP/1.1" else { throw Failure.invalidRequest }
                    var fields: [String: String] = [:]
                    for line in lines.dropFirst() {
                        let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                        guard pair.count == 2, fields[pair[0].lowercased()] == nil else { throw Failure.invalidRequest }
                        fields[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
                    }
                    guard fields["authorization"] == "Bearer " + Self.key,
                          fields["content-type"] == "application/json", fields["transfer-encoding"] == nil,
                          let length = Int(fields["content-length"] ?? ""), (1...16384).contains(length),
                          client.data.count <= separator.upperBound + length else { throw Failure.invalidRequest }
                    if client.data.count == separator.upperBound + length {
                        guard self.bodies.count < self.replies.count else { throw Failure.invalidRequest }
                        let index = self.bodies.count
                        self.bodies.append(Data(client.data[separator.upperBound...]))
                        let choice: [String: Any] = ["message": ["role": "assistant", "content": self.replies[index]], "finish_reason": "stop"]
                        let object: [String: Any] = ["choices": [choice]]
                        client.response = try JSONSerialization.data(withJSONObject: object)
                        client.replied = true
                        if self.holdSecond && index == 1 { self.held = client } else { self.send(client) }
                        return
                    }
                } else if client.data.count > 8192 { throw Failure.invalidRequest }
                if done { self.close(client) } else { self.receive(client) }
            } catch { self.close(client) }
        }
    }
    private func send(_ client: Client) {
        guard let body = client.response, !stopped else { return }
        var response = Data("HTTP/1.1 \(status) Fixture\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        response.append(body)
        client.connection.send(content: response, completion: .contentProcessed { [weak self, weak client] _ in
            if let client { self?.close(client) }
        })
    }
}

/// Test-only transport adapter: the production client still constructs and
/// validates HTTPS requests. ONLY a registered synthetic host + synthetic key
/// is forwarded to this fixture's exact loopback URL. The inner URLSession
/// performs real HTTP socket I/O. This is NOT a TLS/trust-validation test.
final class SelfConfigurationHTTPBridge: URLProtocol {
    private static let lock = NSLock()
    private static var routes: [String: URL] = [:]
    private var forwardedTask: URLSessionDataTask?
    private var transport: URLSession?

    static func register(_ endpoint: URL) -> URL {
        precondition(endpoint.scheme == "http" && endpoint.host == "127.0.0.1" && endpoint.port != nil && endpoint.path == "/v1/chat/completions")
        let host = "self-config-" + UUID().uuidString.lowercased() + ".invalid"
        lock.lock(); routes[host] = endpoint; lock.unlock()
        return URL(string: "https://" + host + "/v1")!
    }
    static func remove(_ url: URL) { lock.lock(); routes.removeValue(forKey: url.host!); lock.unlock() }
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [Self.self]; config.httpCookieStorage = nil
        config.urlCredentialStorage = nil; config.urlCache = nil
        return URLSession(configuration: config)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let endpoint = Self.routes[request.url?.host ?? ""]; Self.lock.unlock()
        guard let endpoint, request.url?.scheme == "https", request.url?.path == "/v1/chat/completions",
              request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer " + SelfConfigurationSocketFixture.key else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 2048)
            while body.count <= 16384 {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }; body.append(contentsOf: buffer.prefix(count))
            }
        }
        guard (1...16384).contains(body.count) else { client?.urlProtocol(self, didFailWithError: URLError(.dataLengthExceedsMaximum)); return }
        var forwarded = URLRequest(url: endpoint, timeoutInterval: 5)
        forwarded.httpMethod = "POST"; forwarded.httpBody = body
        forwarded.setValue("application/json", forHTTPHeaderField: "Content-Type")
        forwarded.setValue("Bearer " + SelfConfigurationSocketFixture.key, forHTTPHeaderField: "Authorization")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = []; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 5; config.timeoutIntervalForResource = 5
        let transport = URLSession(configuration: config); self.transport = transport
        forwardedTask = transport.dataTask(with: forwarded) { [weak self] data, response, error in
            guard let self else { return }
            defer { transport.finishTasksAndInvalidate() }
            guard error == nil, let response = response as? HTTPURLResponse, let data, data.count <= 16384,
                  let mapped = HTTPURLResponse(url: self.request.url!, statusCode: response.statusCode, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]) else {
                self.client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
            }
            self.client?.urlProtocol(self, didReceive: mapped, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        forwardedTask?.resume()
    }
    override func stopLoading() { forwardedTask?.cancel(); transport?.invalidateAndCancel() }
}
#endif
