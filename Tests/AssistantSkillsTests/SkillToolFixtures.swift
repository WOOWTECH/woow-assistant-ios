#if !SKILLS_CORE_SMOKE && !SKILL_EXECUTION_SMOKE && !SKILL_AUTHORING_SMOKE
import AssistantModels
import AssistantPersistence
import Foundation
@testable import AssistantSkills

final class SkillToolTestKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    var fail = false
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws {
        if fail { throw LearningFileError.unavailable }
        values[id] = key
    }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

/// Same generation/copy/encrypt/publish ordering as LearningStore; real AES-GCM
/// persistence, with synthetic keys kept in memory instead of the user's Keychain.
@MainActor final class SkillToolTestStore: SkillAuthoringStoring {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("skill-tool-" + UUID().uuidString)
    let keys = SkillToolTestKeys()
    var state = SkillsState()
    var generation = UUID()
    var tools: Set<String> = []
    var writes = 0
    var url: URL { directory.appendingPathComponent("skills.vault") }
    private lazy var vault = EncryptedLearningFile(url: url, keys: keys)
    init() throws { state = try vault.load(SkillsState.self) ?? .init() }
    func skillAuthoringSnapshot() -> SkillAuthoringSnapshot {
        SkillAuthoringSnapshot(state: state, generation: generation, availableToolNames: tools, available: true)
    }
    func commitSkillAuthoring(expectedGeneration: UUID, _ change: (inout SkillsState) throws -> Void) throws {
        guard expectedGeneration == generation else { throw SkillAuthoringError.storageChanged }
        generation = UUID()
        var next = state
        try change(&next)
        try vault.save(next)
        state = next; writes += 1
    }
    func reload() throws -> SkillsState { try EncryptedLearningFile(url: url, keys: keys).load(SkillsState.self) ?? .init() }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
}

/// Exercises HTTPChatModelClient request/response encoding. Every URL is
/// intercepted; unknown scenarios fail closed and cannot touch the network.
final class SkillToolHTTPFixture: URLProtocol {
    final class Scenario: @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [String]
        private var inputs: [URLRequest] = []
        private var bodies: [Data] = []
        private var stopped = 0
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
        var count: Int { lock.lock(); defer { lock.unlock() }; return inputs.count }
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
        let host = "skill-" + UUID().uuidString.lowercased() + ".invalid"
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
        if scenario.hold { return }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        let response = HTTPURLResponse(url: url, statusCode: scenario.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        let choice: [String: Any] = ["message": ["role": "assistant", "content": reply], "finish_reason": "stop"]
        let data = try! JSONSerialization.data(withJSONObject: ["choices": [choice]])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { scenario?.stop() }
}

actor SkillToolSequenceModel: ChatModelClient {
    var replies: [String]
    var inputs: [[ModelMessage]] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        inputs.append(messages)
        guard !replies.isEmpty else { throw HTTPChatModelError.invalidResponse }
        return replies.removeFirst()
    }
}

/// Intentionally delivers a late response after host state changes. No sleeps or
/// automatic retries: the test releases the exact outstanding request once.
actor SkillToolGatedModel: ChatModelClient {
    private var pending: CheckedContinuation<String, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    private var started = false
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        started = true; entered?.resume(); entered = nil
        return await withCheckedContinuation { pending = $0 }
    }
    func waitUntilEntered() async {
        if started { return }
        await withCheckedContinuation { entered = $0 }
    }
    func release(_ value: String) { pending?.resume(returning: value); pending = nil }
}
#endif
