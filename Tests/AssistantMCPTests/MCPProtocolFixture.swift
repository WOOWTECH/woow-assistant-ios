import Foundation
#if !MCP_SMOKE
@testable import AssistantMCP
#endif

/// Intercepts every URL. An unregistered request fails locally, never on the network.
final class MCPProtocolFixture: URLProtocol {
    struct Reply {
        var status = 200
        var headers = ["Content-Type": "application/json"]
        var chunks: [Data] = []
        var holdBeforeHeaders = false
        var holdAfterBody = false
        var delay: TimeInterval = 0
        var failure: URLError?

        static func result(_ result: JSONValue, request: JSONValue, sse: Bool = false) throws -> Reply {
            let data = try JSONEncoder().encode(JSONValue.object([
                "jsonrpc": .string("2.0"), "id": request["id"] ?? .null, "result": result
            ]))
            if !sse { return Reply(chunks: [data]) }
            var frame = Data(": keepalive\r\nevent: message\r\ndata: ".utf8)
            frame.append(data)
            frame.append(Data("\r\n\r\n".utf8))
            return Reply(headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                         chunks: stride(from: 0, to: frame.count, by: 257).map {
                             frame.subdata(in: $0..<min($0 + 257, frame.count))
                         })
        }
    }

    final class Scenario: @unchecked Sendable {
        let handler: (URLRequest, JSONValue, Int) throws -> Reply
        private let lock = NSLock()
        private var recorded: [(URLRequest, JSONValue)] = []
        private var stopped = 0

        init(_ handler: @escaping (URLRequest, JSONValue, Int) throws -> Reply) { self.handler = handler }
        func record(_ request: URLRequest, _ body: JSONValue) -> Int {
            lock.lock(); defer { lock.unlock() }
            recorded.append((request, body)); return recorded.count
        }
        var records: [(URLRequest, JSONValue)] { lock.lock(); defer { lock.unlock() }; return recorded }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopped }
        func stop() { lock.lock(); defer { lock.unlock() }; stopped += 1 }
    }

    private static let lock = NSLock()
    private static var scenarios: [String: Scenario] = [:]
    private var scenario: Scenario?
    private let stateLock = NSLock()
    private var stopped = false

    static func register(_ scenario: Scenario) -> URL {
        let host = "mcp-\(UUID().uuidString.lowercased()).invalid"
        lock.lock(); scenarios[host] = scenario; lock.unlock()
        return URL(string: "https://\(host)/webhook/fixture-secret?key=fixture-query")!
    }

    static func remove(_ endpoint: URL) {
        lock.lock(); scenarios.removeValue(forKey: endpoint.host ?? ""); lock.unlock()
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MCPProtocolFixture.self]
        return configuration
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock(); scenario = Self.scenarios[request.url?.host ?? ""]; Self.lock.unlock()
        guard let scenario = scenario else { fail(); return }
        do {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count == 0 { break }
                    guard count > 0 else { fail(); return }
                    data.append(contentsOf: buffer.prefix(count))
                    guard data.count <= MCPHTTPTransport.maximumResponseBytes else { fail(); return }
                }
            }
            let body = try JSONDecoder().decode(JSONValue.self, from: data)
            let index = scenario.record(request, body)
            let reply = try scenario.handler(request, body, index)
            if reply.delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay) { self.deliver(reply) }
            } else { deliver(reply) }
        } catch { fail() }
    }

    private func deliver(_ reply: Reply) {
        stateLock.lock(); let alreadyStopped = stopped; stateLock.unlock()
        guard !alreadyStopped else { return }
        if let failure = reply.failure { client?.urlProtocol(self, didFailWithError: failure); return }
        if reply.holdBeforeHeaders { return }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            fail(); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        if !reply.holdAfterBody { client?.urlProtocolDidFinishLoading(self) }
    }

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)) }
    override func stopLoading() {
        stateLock.lock(); stopped = true; stateLock.unlock()
        scenario?.stop()
    }
}
