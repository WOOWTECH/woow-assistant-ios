#if !SKILLS_CORE_SMOKE && !SKILL_EXECUTION_SMOKE && !SKILL_AUTHORING_SMOKE
import AssistantModels
import Foundation
@testable import AssistantSkills

/// Real NSFileCoordinator interaction: saves, refusal, post-save growth and a
/// held provider callback exercise the production reader without an injected IO.
final class TranscriptPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
    let presentedItemURL: URL?
    let presentedItemOperationQueue: OperationQueue = {
        let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
    }()
    private let replacement: Data?
    private let hold: Bool
    private let lock = NSLock()
    private var pending: ((Error?) -> Void)?
    private var saves = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return saves }
    init(url: URL, replacement: Data?, hold: Bool = false) {
        presentedItemURL = url; self.replacement = replacement; self.hold = hold
    }
    func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
        lock.lock(); saves += 1
        if hold { pending = completionHandler; lock.unlock(); return }
        lock.unlock()
        do {
            guard let replacement, let url = presentedItemURL else { throw CocoaError(.fileWriteNoPermission) }
            try replacement.write(to: url, options: .atomic); completionHandler(nil)
        } catch { completionHandler(error) }
    }
    func release() { lock.lock(); let callback = pending; pending = nil; lock.unlock(); callback?(nil) }
}

/// Exercises HTTPChatModelClient request/response encoding. Every URL is
/// intercepted; unknown scenarios fail closed and cannot touch the network.
final class TranscriptHTTPFixture: URLProtocol {
    final class Scenario: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var inputs: [URLRequest] = []
        private var bodies: [Data] = []
        private var stopped = 0
        private var delivery: ((String) -> Void)?
        let hold: Bool
        let status: Int
        init(_ replies: [String], hold: Bool = false, status: Int = 200) {
            self.replies = replies; self.hold = hold; self.status = status
        }
        func next(_ request: URLRequest, body: Data) -> String? {
            lock.lock(); defer { lock.unlock() }
            inputs.append(request); bodies.append(body)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        func stop() { lock.lock(); stopped += 1; lock.unlock() }
        func holdDelivery(_ action: @escaping (String) -> Void) { lock.lock(); delivery = action; lock.unlock() }
        func release(_ reply: String) { lock.lock(); let action = delivery; delivery = nil; lock.unlock(); action?(reply) }
        var count: Int { lock.lock(); defer { lock.unlock() }; return inputs.count }
        var ready: Bool { lock.lock(); defer { lock.unlock() }; return !inputs.isEmpty && (!hold || delivery != nil) }
        var stops: Int { lock.lock(); defer { lock.unlock() }; return stopped }
        var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return inputs }
        var requestBodies: [Data] { lock.lock(); defer { lock.unlock() }; return bodies }
    }
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: Scenario] = [:]
    }
    private static let registry = Registry()
    private var scenario: Scenario?
    static func register(_ scenario: Scenario) -> URL {
        let host = "transcript-" + UUID().uuidString.lowercased() + ".invalid"
        registry.lock.lock(); registry.items[host] = scenario; registry.lock.unlock()
        return URL(string: "https://" + host + "/v1")!
    }
    static func remove(_ url: URL) {
        registry.lock.lock(); registry.items.removeValue(forKey: url.host!); registry.lock.unlock()
    }
    static func session() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.protocolClasses = [Self.self]; c.urlCache = nil; c.httpCookieStorage = nil; c.urlCredentialStorage = nil
        return URLSession(configuration: c)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.registry.lock.lock(); scenario = Self.registry.items[request.url?.host ?? ""]; Self.registry.lock.unlock()
        guard let scenario, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable)); return
        }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&bytes, maxLength: bytes.count)
                if count <= 0 { break }
                body.append(contentsOf: bytes.prefix(count))
            }
        }
        let reply = scenario.next(request, body: body)
        if scenario.hold {
            let status = scenario.status
            scenario.holdDelivery { [weak self] reply in self?.deliver(reply, url: url, status: status) }
            return
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        deliver(reply, url: url, status: scenario.status)
    }
    private func deliver(_ reply: String, url: URL, status: Int) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        let choice: [String: Any] = ["message": ["role": "assistant", "content": reply], "finish_reason": "stop"]
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { scenario?.stop() }
}

#endif
