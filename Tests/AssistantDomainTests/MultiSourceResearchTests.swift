@testable import AssistantBrowser
import AssistantModels
import Foundation
import Network
#if !MULTI_SOURCE_RESEARCH_SMOKE
import XCTest

final class MultiSourceResearchTests: XCTestCase {
    func testConfirmedRootsAndActualCitationReceipts() async throws {
        let count = try await MultiSourceChecks.rootsAndReceipts()
        XCTAssertGreaterThan(count, 20)
    }
    func testUnsupportedCommandsStaleIDsAndInventedCitationsFailClosed() async throws {
        let count = try await MultiSourceChecks.rejections()
        XCTAssertGreaterThan(count, 10)
    }
    func testPartialResultsGlobalBudgetAndCancellation() async throws {
        let count = try await MultiSourceChecks.bounds()
        XCTAssertGreaterThan(count, 10)
    }
    func testActualHTTPModelRequestCarriesBothSourcesAndReturnsCheckedCitations() async throws {
        let count = try await MultiSourceChecks.http()
        XCTAssertGreaterThan(count, 3)
    }
    func testByteExactUnicodeAndSingleBoundedFormatCorrection() async throws {
        let count = try await MultiSourceChecks.formatAndUnicode()
        XCTAssertGreaterThan(count, 10)
    }
}
#endif

private enum MultiSourceChecks {
    struct Failure: Error { let message: String }
    struct Check {
        var count = 0
        mutating func expect(_ value: Bool, _ message: String) throws {
            count += 1
            if !value { throw Failure(message: message) }
        }
    }
    static let roots = ["https://research.example.invalid/start", "https://comparison.example.invalid/start"]
    static let configuration = ModelConfiguration(baseURL: URL(string: "https://model.example.invalid/v1")!, model: "synthetic")
    static func plan(_ urls: [String] = roots) throws -> MultiSourceResearchPlan { try MultiSourceResearchPlan(goal: "比較兩個來源；不猜測發布日期", rootAddresses: urls) }
    static let finish = #"{"action":"finish","findings":[{"kind":"finding","text":"兩個來源均提到相同規格，但未確認發布者獨立性。","citations":[{"observationID":"page-1","quote":"ALPHA_ACTUAL_TEXT"},{"observationID":"page-2","quote":"BETA_ACTUAL_TEXT"}]}],"limitations":[]}"#
    static let single = #"{"action":"finish","findings":[{"kind":"inference","text":"僅讀到來源甲，無法交叉核對。","citations":[{"observationID":"page-1","quote":"ALPHA_ACTUAL_TEXT"}]}],"limitations":[]}"#

    static func rootsAndReceipts() async throws -> Int {
        var c = Check()
        for invalid in [[], [roots[0]], roots + ["https://three.example.org", "https://four.example.org"],
            [roots[0], roots[0]], [roots[0], "https://RESEARCH.example.invalid:443/other"],
            [roots[0], "http://other.example.org/"], [roots[0], "https://127.0.0.1/"],
            [roots[0], "https://[::1]/"], [roots[0], "https://localhost/"],
            [roots[0], "https://user:secret@other.example.org/"], [roots[0], "https://other.example.org/login"],
            [roots[0], "https://other.example.org/?token=synthetic"], [roots[0], "https://other.example.org/#part"],
            [roots[0], "https://other.example.org:/"], [roots[0], "https://other.example.org:999999999999/"]] {
            do { _ = try plan(invalid); throw Failure(message: "invalid root accepted") }
            catch let error as MultiSourceResearchError { try c.expect(error == .invalidPlan, "roots fail before navigation") }
        }
        let approved = try plan()
        try c.expect(approved.sources.count == 2, "two explicit sources")
        try c.expect(!approved.sources[0].allows(approved.sources[1].rootURL), "approved second source cannot redirect first source")
        let browser = MultiSourceTestBrowser(), model = MultiSourceTestModel([finish])
        let result = try await MultiSourceResearchRunner(client: model).run(plan: approved, browser: browser, configuration: configuration, apiKey: "synthetic")
        try c.expect(!result.partial && result.citedSourceCount == 2, "two actual cited origins")
        try c.expect(result.receipts.count == 2 && result.findings.count == 1, "actual reads preserved")
        try c.expect(result.findings[0].citations.map { $0.quote } == ["ALPHA_ACTUAL_TEXT", "BETA_ACTUAL_TEXT"], "quotes exact")
        let observed = await browser.observed
        for (receipt, original) in zip(result.receipts, observed) {
            try c.expect(receipt.observation.url == original.url, "URL comes from actual browser result")
            try c.expect(receipt.observation.capturedAt == original.capturedAt, "actual observation timestamp preserved")
        }
        let inputs = await model.inputs
        try c.expect(inputs.count == 1 && inputs[0].contains { $0.content.contains("ALPHA_ACTUAL_TEXT") && $0.content.contains("BETA_ACTUAL_TEXT") }, "model receives both real receipts")
        let three = try await MultiSourceResearchRunner(client: MultiSourceTestModel([finish])).run(
            plan: plan(roots + ["https://third.example.org/start"]), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic")
        try c.expect(three.receipts.count == 3, "third user seed actually read")
        return c.count
    }

    static func rejections() async throws -> Int {
        var c = Check()
        let invalid: [(String, MultiSourceResearchError)] = [
            (#"{"action":"navigate","url":"https://unapproved.example.org"}"#, .invalidCommand),
            (#"{"action":"open","sourceID":"source-1","observationID":"page-1","linkID":0,"url":"https://unapproved.example.org"}"#, .invalidCommand),
            (#"{"action":"open","sourceID":"source-2","observationID":"page-1","linkID":0}"#, .staleObservation),
            (#"{"action":"open","sourceID":"source-4","observationID":"page-1","linkID":0}"#, .staleObservation),
            (#"{"action":"open","sourceID":"source-1","observationID":"page-1","linkID":99}"#, .staleObservation),
            (finish.replacingOccurrences(of: "ALPHA_ACTUAL_TEXT", with: "INVENTED_QUOTE"), .invalidCitation),
            (finish.replacingOccurrences(of: "page-2", with: "page-99"), .invalidCitation),
            (finish.replacingOccurrences(of: "\"quote\":\"BETA_ACTUAL_TEXT\"", with: "\"quote\":\"BETA_ACTUAL_TEXT\",\"url\":\"https://fake.example.org\""), .invalidCommand)
        ]
        for (reply, expected) in invalid {
            let browser = MultiSourceTestBrowser()
            do {
                _ = try await MultiSourceResearchRunner(client: MultiSourceTestModel([reply])).run(plan: plan(), browser: browser, configuration: configuration, apiKey: "synthetic")
                throw Failure(message: "invalid command accepted")
            } catch let error as MultiSourceResearchError { try c.expect(error == expected, "exact rejection category") }
            try c.expect(await browser.opens == 0, "invalid command never navigates")
        }
        do {
            _ = try await MultiSourceResearchRunner(client: MultiSourceTestModel([finish])).run(plan: plan(), browser: MultiSourceTestBrowser(wrongOrigin: true), configuration: configuration, apiKey: "synthetic")
            throw Failure(message: "wrong-origin executor receipt accepted")
        } catch let error as MultiSourceResearchError { try c.expect(error == .unsafeObservation, "executor receipt origin rechecked") }
        let open = #"{"action":"open","sourceID":"source-1","observationID":"page-1","linkID":0}"#
        let stale = #"{"action":"find","sourceID":"source-1","observationID":"page-1","text":"alpha"}"#
        let browser = MultiSourceTestBrowser()
        do {
            _ = try await MultiSourceResearchRunner(client: MultiSourceTestModel([open, stale])).run(plan: plan(), browser: browser, configuration: configuration, apiKey: "synthetic")
            throw Failure(message: "superseded observation accepted")
        } catch let error as MultiSourceResearchError { try c.expect(error == .staleObservation, "old page ID rejected after real open") }
        try c.expect(await browser.opens == 1, "one valid navigation actually happened")
        return c.count
    }

    static func bounds() async throws -> Int {
        var c = Check()
        let partial = try await MultiSourceResearchRunner(client: MultiSourceTestModel([single])).run(plan: plan(), browser: MultiSourceTestBrowser(failSecond: true), configuration: configuration, apiKey: "synthetic")
        try c.expect(partial.partial && partial.citedSourceCount == 1, "one offline source is partial")
        try c.expect(partial.receipts.count == 1 && partial.limitations.count >= 2, "no fabricated offline receipt")
        let search = #"{"action":"find","sourceID":"source-1","observationID":"page-1","text":"absent"}"#
        let model = MultiSourceTestModel([search, finish])
        let capped = try await MultiSourceResearchRunner(client: model, maximumCalls: 1).run(plan: plan(), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic")
        try c.expect(capped.partial && capped.findings.isEmpty, "call budget cannot deliver unrequested finish")
        try c.expect(capped.receipts.count == 2, "find does not invent receipt")
        try c.expect(await model.inputs.count == 1, "global budget remains one across both sources")
        let early = MultiSourceTestModel([finish])
        do {
            _ = try await MultiSourceResearchRunner(client: early, timeoutNanoseconds: 20_000_000).run(plan: plan(), browser: MultiSourceTestBrowser(delay: true), configuration: configuration, apiKey: "synthetic")
            throw Failure(message: "root reading escaped global timeout")
        } catch let error as MultiSourceResearchError { try c.expect(error == .deadline, "deadline includes root load") }
        try c.expect(await early.inputs.isEmpty, "no model request after seed timeout")
        let late = MultiSourceLateModel()
        let browser = MultiSourceTestBrowser()
        let task = Task { try await MultiSourceResearchRunner(client: late).run(plan: plan(), browser: browser, configuration: configuration, apiKey: "synthetic") }
        for _ in 0..<1000 {
            if await late.pending { break }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try c.expect(await late.pending, "late fixture reached actual model suspension")
        task.cancel()
        await late.release(#"{"action":"open","sourceID":"source-1","observationID":"page-1","linkID":0}"#)
        do { _ = try await task.value; throw Failure(message: "late reply escaped cancellation") }
        catch is CancellationError { try c.expect(true, "cancelled operation throws") }
        try c.expect(await browser.opens == 0, "late model reply cannot navigate")
        try c.expect(await browser.observed.count == 2, "completed seeds remain real evidence only")
        return c.count
    }

    static func http() async throws -> Int {
        var c = Check()
        let server = try MultiSourceSocketFixture([finish]); defer { server.stop() }
        let endpoint = try await server.start()
        let mapped = MultiSourceHTTPBridge.register(endpoint); defer { MultiSourceHTTPBridge.remove(mapped) }
        let session = MultiSourceHTTPBridge.session(); defer { session.invalidateAndCancel() }
        let result = try await MultiSourceResearchRunner(client: HTTPChatModelClient(session: session)).run(plan: plan(), browser: MultiSourceTestBrowser(), configuration: ModelConfiguration(baseURL: mapped, model: "synthetic"), apiKey: MultiSourceSocketFixture.key)
        try c.expect(!result.partial && result.citedSourceCount == 2, "HTTP model reply passes actual citation validation")
        let bodies = server.requestBodies
        try c.expect(bodies.count == 1, "actual server received exactly one model request")
        let body = String(decoding: bodies[0], as: UTF8.self)
        try c.expect(body.contains("ALPHA_ACTUAL_TEXT") && body.contains("BETA_ACTUAL_TEXT"), "real HTTP request includes both source receipts")
        try c.expect(!body.contains(MultiSourceSocketFixture.key), "synthetic authorization not copied into model message")
        return c.count
    }

    static func formatAndUnicode() async throws -> Int {
        var c = Check()
        let composed = "caf\u{e9}", decomposed = "cafe\u{301}"
        try c.expect(composed.contains(decomposed), "Unicode canonical equivalence would pass String.contains")
        let exact = try await MultiSourceResearchRunner(client: MultiSourceTestModel([finish.replacingOccurrences(of: "ALPHA_ACTUAL_TEXT", with: composed)])).run(plan: plan(), browser: MultiSourceTestBrowser(unicode: true), configuration: configuration, apiKey: "synthetic")
        try c.expect(!exact.partial, "actual composed quote accepted")
        do {
            _ = try await MultiSourceResearchRunner(client: MultiSourceTestModel([finish.replacingOccurrences(of: "ALPHA_ACTUAL_TEXT", with: decomposed)])).run(plan: plan(), browser: MultiSourceTestBrowser(unicode: true), configuration: configuration, apiKey: "synthetic")
            throw Failure(message: "non-byte-exact canonical quote accepted")
        } catch let error as MultiSourceResearchError { try c.expect(error == .invalidCitation, "different UTF-8 quote rejected") }
        let malformed = "synthetic-malformed-private-output"
        let repair = MultiSourceTestModel([malformed, finish])
        let result = try await MultiSourceResearchRunner(client: repair).run(plan: plan(), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic")
        try c.expect(!result.partial && result.receipts.count == 2, "repair preserves only real observations")
        let inputs = await repair.inputs
        try c.expect(inputs.count == 2, "one correction is an actual second call")
        try c.expect(!inputs[1].contains(where: { $0.content.contains(malformed) }), "malformed output is never echoed")
        let twice = MultiSourceTestModel([malformed, malformed, finish])
        do {
            _ = try await MultiSourceResearchRunner(client: twice).run(plan: plan(), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic")
            throw Failure(message: "second malformed response retried")
        } catch let error as MultiSourceResearchError { try c.expect(error == .invalidModelJSON, "second format failure stops") }
        try c.expect(await twice.inputs.count == 2, "no third call to repair")
        let cappedModel = MultiSourceTestModel([malformed, finish])
        let capped = try await MultiSourceResearchRunner(client: cappedModel, maximumCalls: 1).run(plan: plan(), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic")
        try c.expect(capped.partial && capped.findings.isEmpty, "repair never expands original call budget")
        try c.expect(await cappedModel.inputs.count == 1, "one-call budget never sends correction")
        let late = MultiSourceLateModel(firstReply: malformed)
        let task = Task { try await MultiSourceResearchRunner(client: late).run(plan: plan(), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic") }
        for _ in 0..<1000 { if await late.pending { break }; try await Task.sleep(nanoseconds: 1_000_000) }
        try c.expect(await late.pending, "actual corrective call reached suspension")
        task.cancel(); await late.release(finish)
        do { _ = try await task.value; throw Failure(message: "cancelled repair published result") }
        catch is CancellationError { try c.expect(true, "cancelled correction remains cancelled") }
        // This test observes the corrective call before expiring the original
        // deadline. A 30ms wall-clock timer cannot guarantee that two root reads,
        // JSON encoding and the first model reply have already been scheduled.
        // bounds() separately exercises the real timer while reading roots.
        let deadline = MultiSourceRepairDeadline()
        let delayed = MultiSourceSlowRepairModel(deadline: deadline)
        do {
            _ = try await MultiSourceResearchRunner(client: delayed, timeoutNanoseconds: 30_000_000,
                deadlineWait: { try await deadline.wait(nanoseconds: $0) }).run(
                    plan: plan(), browser: MultiSourceTestBrowser(), configuration: configuration, apiKey: "synthetic")
            throw Failure(message: "corrective call reset deadline")
        } catch let error as MultiSourceResearchError { try c.expect(error == .deadline, "correction shares original deadline") }
        try c.expect(await delayed.calls == 2, "deadline occurred inside corrective call")
        try c.expect(await deadline.durations == [30_000_000], "one original deadline, no correction timer reset")
        try c.expect(await delayed.cancelled, "deadline cancels the actual suspended corrective call")
        try c.expect(await delayed.returned == false, "timed-out correction did not deliver a late reply")
        return c.count
    }
}

private actor MultiSourceTestModel: ChatModelClient {
    private var replies: [String]
    private(set) var inputs: [[ModelMessage]] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        inputs.append(messages)
        guard !replies.isEmpty else { throw HTTPChatModelError.invalidResponse }
        return replies.removeFirst()
    }
}

private actor MultiSourceLateModel: ChatModelClient {
    private var continuation: CheckedContinuation<String, Never>?
    private var firstReply: String?
    init(firstReply: String? = nil) { self.firstReply = firstReply }
    var pending: Bool { continuation != nil }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        if let first = firstReply { firstReply = nil; return first }
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ reply: String) { continuation?.resume(returning: reply); continuation = nil }
}

/// Both orderings are valid: the timer task or the model task can run first.
/// Expiration is delivered only when both have reached the selected phase.
private actor MultiSourceRepairDeadline {
    private(set) var durations: [UInt64] = []
    private var continuation: CheckedContinuation<Void, Error>?
    private var correctiveCallEntered = false
    private var cancelled = false

    func wait(nanoseconds: UInt64) async throws {
        durations.append(nanoseconds)
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if cancelled { continuation.resume(throwing: CancellationError()) }
                else if correctiveCallEntered { continuation.resume() }
                else { self.continuation = continuation }
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func enterCorrectiveCall() {
        correctiveCallEntered = true
        continuation?.resume(); continuation = nil
    }
    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError()); continuation = nil
    }
}

private actor MultiSourceSlowRepairModel: ChatModelClient {
    let deadline: MultiSourceRepairDeadline
    private(set) var calls = 0
    private(set) var cancelled = false
    private(set) var returned = false
    init(deadline: MultiSourceRepairDeadline) { self.deadline = deadline }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        calls += 1
        if calls == 1 { return "not-json" }
        await deadline.enterCorrectiveCall()
        do { try await Task.sleep(nanoseconds: 5_000_000_000) }
        catch is CancellationError { cancelled = true; throw CancellationError() }
        returned = true
        return MultiSourceChecks.finish
    }
}

private actor MultiSourceTestBrowser: MultiSourceResearchExecuting {
    let failSecond: Bool
    let wrongOrigin: Bool
    let delay: Bool
    let unicode: Bool
    private(set) var opens = 0
    private(set) var observed: [WebObservation] = []
    private var sources: [String: MultiSourceResearchSource] = [:]
    init(failSecond: Bool = false, wrongOrigin: Bool = false, delay: Bool = false, unicode: Bool = false) {
        self.failSecond = failSecond; self.wrongOrigin = wrongOrigin; self.delay = delay; self.unicode = unicode
    }
    func loadRoot(source: MultiSourceResearchSource) async throws -> WebObservation {
        if delay { try await Task.sleep(nanoseconds: 5_000_000_000) }
        if failSecond && source.id == "source-2" { throw WebResearchError.navigationFailed }
        sources[source.id] = source
        return page(source: source, url: wrongOrigin ? URL(string: "https://unapproved.example.org/")! : source.rootURL)
    }
    func openLink(sourceID: String, id: Int) async throws -> WebObservation {
        guard let source = sources[sourceID], id == 0 else { throw WebResearchError.unknownLink }
        opens += 1
        return page(source: source, url: source.origin.url.appendingPathComponent("details"))
    }
    private func page(source: MultiSourceResearchSource, url: URL) -> WebObservation {
        let result = WebObservation(url: url, title: source.id,
            text: source.id == "source-1" ? (unicode ? "ALPHA_ACTUAL_TEXT caf\u{e9}" : "ALPHA_ACTUAL_TEXT") : "BETA_ACTUAL_TEXT",
            links: [WebResearchLink(id: 0, title: "Details", url: source.origin.url.appendingPathComponent("details"))])
        observed.append(result); return result
    }
}

#if MULTI_SOURCE_RESEARCH_SMOKE
@main struct MultiSourceResearchStandaloneChecks {
    static func main() async throws {
        let roots = try await MultiSourceChecks.rootsAndReceipts()
        let rejected = try await MultiSourceChecks.rejections()
        let bounds = try await MultiSourceChecks.bounds()
        let http = try await MultiSourceChecks.http()
        let format = try await MultiSourceChecks.formatAndUnicode()
        print("PASS multisource: \(roots + rejected + bounds + http + format) assertions; actual loopback model HTTP receipt; synthetic browser observations")
    }
}
#endif

// Same bounded loopback/HTTPS-test-adapter pattern as SelfConfigurationFixtures.
// Only synthetic host/key requests are forwarded; this does not test TLS.
private final class MultiSourceSocketFixture: @unchecked Sendable {
    enum Failure: Error { case unavailable, invalidRequest }
    static let key = "multi-source-research-synthetic-not-live"
    private let queue = DispatchQueue(label: "multi-source-research-socket-fixture")
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
private final class MultiSourceHTTPBridge: URLProtocol {
    private static let lock = NSLock()
    private static var routes: [String: URL] = [:]
    private var forwardedTask: URLSessionDataTask?
    private var transport: URLSession?

    static func register(_ endpoint: URL) -> URL {
        precondition(endpoint.scheme == "http" && endpoint.host == "127.0.0.1" && endpoint.port != nil && endpoint.path == "/v1/chat/completions")
        let host = "multi-source-" + UUID().uuidString.lowercased() + ".invalid"
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
              request.httpMethod == "POST", request.value(forHTTPHeaderField: "Authorization") == "Bearer " + MultiSourceSocketFixture.key else {
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
        forwarded.setValue("Bearer " + MultiSourceSocketFixture.key, forHTTPHeaderField: "Authorization")
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
