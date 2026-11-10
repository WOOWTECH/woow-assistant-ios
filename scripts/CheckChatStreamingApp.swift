#if CHAT_STREAM_APP_STANDALONE || canImport(WoowAssistant)
import AssistantModels
import AssistantMemory
import AssistantMCP
import AssistantPersistence
import AssistantDomain
import Combine
import Foundation
#if !CHAT_STREAM_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private final class StreamKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private final class StreamCredentials: ModelCredentialStoring {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}
private final class StreamClient: StreamingChatModelClient, @unchecked Sendable {
    private let lock = NSLock()
    private let replies: [String]
    private var completions = 0
    private var streams: [AsyncThrowingStream<String, Error>.Continuation] = []
    init(_ replies: [String] = []) { self.replies = replies }
    private func nextReply() throws -> String {
        lock.lock(); defer { lock.unlock() }
        let index = completions; completions += 1
        guard index < replies.count else { throw ChatStreamingChecks.Failure(name: "unexpected complete/extraction request") }
        return replies[index]
    }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String { try nextReply() }
    func stream(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(8)) { c in
            lock.lock(); streams.append(c); lock.unlock()
        }
    }
    var counts: (complete: Int, stream: Int) { lock.lock(); defer { lock.unlock() }; return (completions, streams.count) }
    private func continuation(_ index: Int) -> AsyncThrowingStream<String, Error>.Continuation {
        lock.lock(); defer { lock.unlock() }; return streams[index]
    }
    @discardableResult func emit(_ text: String, at index: Int = 0) -> Bool {
        if case .enqueued = continuation(index).yield(text) { return true }; return false
    }
    func finish(_ error: Error? = nil, at index: Int = 0) { continuation(index).finish(throwing: error) }
}
private struct CompleteOnlyClient: ChatModelClient {
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String { "Complete-only adapter reply" }
}
@MainActor private final class StreamNotifications: TaskNotificationClient {
    var operations = 0, adds = 0
    var kinds: [TaskNotificationKind] = []
    func settings() async -> TaskNotificationSettings { operations += 1; return .init(authorization: .authorized, sound: .enabled, alert: .enabled) }
    func requestAuthorization() async throws { operations += 1 }
    func add(_ payload: TaskNotificationPayload, sound: Bool) async throws { operations += 1; adds += 1; kinds.append(payload.kind) }
    func remove(identifiers: [String]) async { operations += 1 }
    func removeAllOwned() async { operations += 1 }
}
@MainActor private final class StreamEnvironment {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-stream-" + UUID().uuidString)
    let suite = "woow.stream.check." + UUID().uuidString
    let keys = StreamKeys(), learningKeys = StreamKeys()
    let defaults: UserDefaults
    let repository: ModelSettingsRepository
    let learning: LearningStore
    let archive: ConversationArchiveStore
    var archiveFile: URL { root.appendingPathComponent("archive.vault") }
    var learningFile: URL { root.appendingPathComponent("learning.vault") }
    init(baseURL: URL = URL(string: "https://stream.example.invalid/v1")!) throws {
        defaults = UserDefaults(suiteName: suite)!
        repository = ModelSettingsRepository(defaults: defaults, credentials: StreamCredentials())
        _ = try repository.save(baseURL: baseURL.absoluteString, model: "fixture", newKey: "synthetic-not-a-key")
        learning = LearningStore(vault: EncryptedLearningFile(url: root.appendingPathComponent("learning.vault"), keys: learningKeys))
        guard learning.updatePreferences({ $0.useMemory = false; $0.autoRemember = true }) else { throw ChatStreamingChecks.Failure(name: "isolated learning creation") }
        archive = ConversationArchiveStore(vault: EncryptedLearningFile(url: root.appendingPathComponent("archive.vault"), keys: keys))
    }
    func session(_ client: any ChatModelClient) -> ChatSession { ChatSession(learning: learning, repository: repository, client: client, archive: archive) }
    func reopen() -> ConversationArchiveStore { ConversationArchiveStore(vault: EncryptedLearningFile(url: archiveFile, keys: keys)) }
    func close() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}
private struct StreamEndpoint: MCPEndpointStoring {
    func load() throws -> URL? { URL(string: "https://mcp-stream.example.invalid/fixture") }
    func save(endpoint: String) throws { throw MCPSettingsError.invalidEndpoint }
    func remove() throws {}
}
private actor StreamMCP: MCPDiscovering {
    private(set) var calls = 0
    func initialize() async throws -> MCPServerInfo { .init(protocolVersion: "2025-03-26", capabilities: ["tools"]) }
    func listTools() async throws -> [MCPTool] { [.init(name: "synthetic_read", inputSchema: .object(["type": .string("object")]))] }
    func listResources() async throws -> [MCPResource] { [] }
    func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        guard name == "synthetic_read" else { throw MCPError.invalidRequest }
        calls += 1
        return .object(["isError": .bool(false), "content": .array([.object(["type": .string("text"), "text": .string("Read value")])])])
    }
    func readResource(uri: String) async throws -> JSONValue { throw MCPError.invalidRequest }
    func cancel() async {}
}

@MainActor enum ChatStreamingChecks {
    struct Failure: Error { let name: String }
    struct Assertions {
        var count = 0
        mutating func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(name: name) }; count += 1
        }
    }
    private static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw Failure(name: label) }
            await Task.yield()
        }
    }
    private static func start(_ session: ChatSession, _ prompt: String, mcp: MCPSession? = nil) throws -> Task<Void, Never> {
        session.draft = prompt; session.send(mcp: mcp)
        guard let task = session.capturedArchiveRequest else { throw Failure(name: "actual request missing") }
        return task
    }
    private static func interceptedBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        // URLSession may move the request body into a stream before URLProtocol.
        guard let stream = request.httpBodyStream else { throw Failure(name: "intercepted request body absent") }
        stream.open(); defer { stream.close() }
        var body = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw Failure(name: "intercepted request body unreadable") }
            if count == 0 { return body }
            guard body.count + count <= 64 * 1024 else { throw Failure(name: "unexpected fixture request size") }
            body.append(contentsOf: buffer.prefix(count))
        }
    }
    static func incrementalCompletion() async throws -> Int {
        var a = Assertions(); let e = try StreamEnvironment(); defer { e.close() }
        let client = StreamClient(); let session = e.session(client)
        let notifications = StreamNotifications(); let service = TaskNotificationService(client: notifications, enabled: true)
        await service.refresh(); let baseline = notifications.operations
        let bridge = TaskNotificationChatBridge(session: session, service: service); defer { bridge.invalidate() }
        let learningBytes = try Data(contentsOf: e.learningFile)
        let task = try start(session, "A complete streaming question")
        try await wait("stream requested") { client.counts.stream == 1 }
        client.emit("Hello "); try await wait("first real partial") { session.replyPreview?.text == "Hello " }
        let id = session.replyPreview!.id
        try a.check(session.isSubmitting && session.replyPreview?.phase == .receiving, "partial explicitly unfinished")
        try a.check(session.entries.isEmpty && e.archive.conversations.isEmpty && !FileManager.default.fileExists(atPath: e.archiveFile.path), "partial not complete or durable")
        try a.check(session.draft == "A complete streaming question", "draft not consumed by partial")
        await service.waitUntilIdle()
        try a.check(notifications.operations == baseline && notifications.adds == 0, "actual notification bridge ignores partial")
        try a.check(try Data(contentsOf: e.learningFile) == learningBytes && !e.learning.isLearning, "partial never extracts learning")
        client.emit("世界 🏡"); try await wait("second real partial") { session.replyPreview?.text == "Hello 世界 🏡" }
        try a.check(session.replyPreview?.id == id && session.entries.isEmpty, "one preview identity across Unicode deltas")
        client.finish(); await task.value; await service.waitUntilIdle()
        try a.check(!session.isSubmitting && session.replyPreview == nil && session.entries.count == 2, "only completed stream publishes pair")
        try a.check(session.entries[1].content == "Hello 世界 🏡" && session.draft.isEmpty, "exact completed text and draft clearing")
        try a.check(e.archive.conversations.count == 1 && e.reopen().conversations[0].turns[0].assistantText == session.entries[1].content, "actual encrypted completion relaunch")
        try a.check(notifications.adds == 1 && notifications.kinds == [.completed] && service.trackedCount == 1, "one completed notification retained by existing service until expiry")
        try a.check(client.counts.complete == 0 && client.counts.stream == 1, "single request no hidden fallback or extraction")
        try a.check(try Data(contentsOf: e.learningFile) == learningBytes, "master-off learning stays unchanged")
        return a.count
    }
    static func cancellationFailureAndGeneration() async throws -> Int {
        var a = Assertions(); let e = try StreamEnvironment(); defer { e.close() }
        let client = StreamClient(); let session = e.session(client)
        let notifications = StreamNotifications(); let service = TaskNotificationService(client: notifications, enabled: true)
        await service.refresh(); let bridge = TaskNotificationChatBridge(session: session, service: service); defer { bridge.invalidate() }
        let beforeStart = try start(session, "Cancel before request starts")
        session.cancel(); await beforeStart.value; await service.waitUntilIdle()
        try a.check(client.counts.stream == 0 && client.counts.complete == 0, "cancel before execution does not create a request")
        try a.check(session.replyPreview == nil && session.entries.isEmpty && notifications.adds == 0, "pre-start cancel has no partial or completion")
        let task = try start(session, "Cancelled question")
        try await wait("cancel stream requested") { client.counts.stream == 1 }
        client.emit("Old partial"); try await wait("cancel partial") { session.replyPreview != nil }
        session.cancel(); await task.value; await service.waitUntilIdle()
        try a.check(session.replyPreview?.text == "Old partial" && session.replyPreview?.phase == .cancelled, "cancel retains labelled partial")
        try a.check(session.draft == "Cancelled question" && session.entries.isEmpty && e.archive.conversations.isEmpty, "cancel retains draft without saving pair")
        try a.check(notifications.adds == 0 && service.trackedCount == 0, "cancel cannot become notification completion")
        let newer = try start(session, "New question")
        try a.check(session.replyPreview == nil, "new submitted generation clears old partial")
        try await wait("new stream requested") { client.counts.stream == 2 }
        client.emit("New partial", at: 1); try await wait("new partial") { session.replyPreview?.text == "New partial" }
        try a.check(!client.emit("Late poison", at: 0), "cancelled stream rejects actual late producer yield")
        client.finish(at: 0)
        try a.check(session.replyPreview?.text == "New partial" && session.entries.isEmpty, "old generation cannot replace newer preview")
        client.finish(HTTPChatModelError.transportFailure, at: 1); await newer.value; await service.waitUntilIdle()
        try a.check(session.replyPreview?.text == "New partial" && session.replyPreview?.phase == .failed, "failure retains labelled partial")
        try a.check(session.draft == "New question" && session.chatError != nil && session.entries.isEmpty, "failure retains draft without completed entry")
        try a.check(e.archive.conversations.isEmpty && notifications.adds == 0 && client.counts.complete == 0, "error does not persist notify or retry")
        session.newConversation(); try a.check(session.replyPreview == nil, "new conversation discards unfinished display")
        let changed = try start(session, "Change destination")
        try await wait("third stream") { client.counts.stream == 3 }
        client.emit("Old destination", at: 2); try await wait("third partial") { session.replyPreview != nil }
        session.cancel(); await changed.value
        session.modelDraft = "new-model"; session.saveSettings()
        try a.check(session.replyPreview == nil && session.entries.isEmpty, "destination changes do not transfer unfinished text")
        try a.check(!client.emit("Late after settings", at: 2), "old stream remains closed after settings change")
        return a.count
    }
    static func boundsFallbackAndSaveFailure() async throws -> Int {
        var a = Assertions(); let e = try StreamEnvironment(); defer { e.close() }
        let client = StreamClient(); let session = e.session(client)
        let task = try start(session, "Bounded text")
        try await wait("bound stream") { client.counts.stream == 1 }
        client.emit("safe"); try await wait("safe prefix") { session.replyPreview != nil }
        client.emit(String(repeating: "界", count: ChatReplyPreview.maximumUTF8Bytes / 3 + 1)); await task.value
        try a.check(session.replyPreview?.text == "safe" && session.replyPreview?.phase == .failed, "UTF8 overflow does not publish oversized delta")
        try a.check(session.entries.isEmpty && e.archive.conversations.isEmpty && session.draft == "Bounded text", "overflow cannot persist or consume draft")
        let empty = try start(session, "Empty text")
        try await wait("empty stream") { client.counts.stream == 2 }; client.finish(at: 1); await empty.value
        try a.check(session.replyPreview == nil && session.entries.isEmpty && session.chatError != nil, "empty normal stream is not completed answer")
        try a.check(client.counts.complete == 0, "no automatic HTTP fallback after stream errors")
        let fallback = e.session(CompleteOnlyClient()); await (try start(fallback, "Non-stream adapter")).value
        try a.check(fallback.entries.count == 2 && fallback.replyPreview == nil, "non-stream capability keeps existing complete path")
        let broken = try StreamEnvironment(); defer { broken.close() }
        try FileManager.default.createDirectory(at: broken.archiveFile, withIntermediateDirectories: true)
        let deliveredClient = StreamClient(); let delivered = broken.session(deliveredClient)
        let delivery = try start(delivered, "Completed but disk failed")
        try await wait("delivery stream") { deliveredClient.counts.stream == 1 }
        deliveredClient.emit("Complete answer"); deliveredClient.finish(); await delivery.value
        try a.check(delivered.entries.count == 2 && delivered.replyPreview == nil && delivered.archiveNotice != nil, "disk failure preserves completed displayed answer")
        try a.check(broken.archive.conversations.isEmpty && delivered.canRetryArchiveSave, "failed save remains distinguishable")
        let ids = delivered.entries.map(\.id)
        try FileManager.default.removeItem(at: broken.archiveFile); delivered.retryArchiveSave()
        try a.check(delivered.archiveNotice == nil && broken.reopen().conversations.count == 1 && delivered.entries.map(\.id) == ids, "save retry retains completed pair IDs")
        try a.check(deliveredClient.counts.stream == 1 && deliveredClient.counts.complete == 0, "save retry cannot issue model request")
        return a.count
    }
    static func restoreCancelsPreview() async throws -> Int {
        var a = Assertions(); let e = try StreamEnvironment(); defer { e.close() }
        let seed = e.session(CompleteOnlyClient()); await (try start(seed, "Saved question")).value
        let row = e.archive.conversations[0]; let savedBytes = try Data(contentsOf: e.archiveFile)
        let client = StreamClient(); let session = e.session(client)
        let task = try start(session, "Unfinished unrelated question")
        try await wait("restore stream") { client.counts.stream == 1 }
        client.emit("Unfinished"); try await wait("restore partial") { session.replyPreview != nil }
        try a.check(session.openConversation(id: row.id), "explicit restore cancels active request")
        await task.value
        try a.check(session.replyPreview == nil && !session.isSubmitting && session.entries.map(\.id) == [row.turns[0].userID,row.turns[0].assistantID], "restore exposes only saved completed pair")
        try a.check(!client.emit("Late after restore"), "late stream cannot enter restored conversation")
        client.finish()
        try a.check(try Data(contentsOf: e.archiveFile) == savedBytes, "restore never saves partial or replay")
        try a.check(client.counts.complete == 0 && client.counts.stream == 1 && session.pendingProfileReview == nil && session.pendingMemoryReview == nil && session.pendingMCPApproval == nil, "restore creates no calls or approvals")
        return a.count
    }
    static func structuredFlowsRemainReviewed() async throws -> Int {
        var a = Assertions()
        #if DEBUG
        a.count += try await nativeStreamingFixture()
        #endif
        for approve in [false, true] {
            let e = try StreamEnvironment(); defer { e.close() }
            _ = e.learning.updatePreferences { $0.useMemory = true; $0.autoRemember = false }
            let proposal = #"{"action":"profile_edit","arguments":{"op":"add","text":"I prefer jasmine tea","quote":"Please remember that I prefer jasmine tea"}}"#
            let client = StreamClient([proposal, #"{"action":"finish","answer":"Saved profile."}"#]); let session = e.session(client)
            let task = try start(session, "Please remember that I prefer jasmine tea")
            try await wait("actual profile review") { session.pendingProfileReview != nil || !session.isSubmitting }
            guard let review = session.pendingProfileReview else { throw Failure(name: "missing actual profile review") }
            try a.check(client.counts.stream == 0 && session.replyPreview == nil && session.entries.isEmpty, "profile raw JSON is never streamed")
            try a.check(e.archive.conversations.isEmpty && e.learning.profile.snapshot().entries.isEmpty, "profile approval still required before effect")
            session.resolveProfileReview(id: review.id, approved: approve); await task.value
            try a.check((session.entries.count == 2) == approve && (e.archive.conversations.count == 1) == approve, "only approved final answer is complete")
            try a.check(session.replyPreview == nil && client.counts.stream == 0 && client.counts.complete == (approve ? 2 : 1), "structured flow uses unchanged bounded complete requests")
        }
        for approve in [false, true] {
            let e = try StreamEnvironment(); defer { e.close() }
            let server = StreamMCP(); let connection = MCPSession(repository: StreamEndpoint(), clientFactory: { _ in server })
            connection.connect(); try await wait("actual MCP discovery") { !connection.isBusy }
            connection.selectTool("synthetic_read", enabled: true)
            try a.check(connection.canUseInConversation, "real selected MCP catalog")
            let client = StreamClient([#"{"action":"call_tool","name":"synthetic_read","arguments":{}}"#, #"{"action":"finish","answer":"Verified tool result."}"#])
            let session = e.session(client); session.usesMCP = true
            let task = try start(session, "Read selected tool", mcp: connection)
            try await wait("actual MCP approval") { session.pendingMCPApproval != nil || !session.isSubmitting }
            guard let approval = session.pendingMCPApproval else { throw Failure(name: "missing actual MCP approval") }
            let before = await server.calls
            try a.check(before == 0 && session.replyPreview == nil && session.entries.isEmpty && client.counts.stream == 0, "MCP JSON hidden until explicit approval and execution")
            session.resolveMCPApproval(id: approval.id, approved: approve); await task.value
            let after = await server.calls
            try a.check(after == (approve ? 1 : 0), "MCP refusal and one approved effect retained")
            try a.check((session.entries.count == 2) == approve && session.replyPreview == nil && client.counts.stream == 0, "MCP finish validator still precedes delivered answer")
        }
        return a.count
    }
    #if DEBUG
    private static func nativeStreamingFixture() async throws -> Int {
        var a = Assertions()
        let namespace = UUID().uuidString
        let valid = ["-UITestMode", "-UITestNamespace", namespace, "-UITestChatStreaming"]
        guard let configuration = try UITestChatStreamingConfiguration.resolve(arguments: valid) else { throw Failure(name: "valid streaming gate") }
        try a.check(configuration.namespace.uuidString == namespace, "exact isolated namespace")
        try a.check(try UITestChatStreamingConfiguration.resolve(arguments: []) == nil, "production has no stream fixture")
        try a.check(try UITestChatStreamingConfiguration.resolve(arguments: Array(valid.dropLast())) == nil, "legacy UI fixture stays complete-only")
        var malformed: [[String]] = [
            ["-UITestChatStreaming"], ["-UITestMode", "-UITestChatStreaming"],
            ["-UITestMode", "-UITestNamespace", "bad", "-UITestChatStreaming"],
            ["-UITestMode", "-UITestChatStreaming", "-UITestNamespace"]
        ]
        for extra: [String] in [["-UITestChatStreaming"], ["-UITestMode"], ["-UITestNamespace", namespace],
                               ["-LiveModelUITest"], ["-LiveModelUITestNamespace", namespace], ["-LiveMCPUITest"],
                               ["-UITestMCPFixture"], ["-UITestResetStorage", "-UITestResetStorage"], ["-UITestChatStreaming=true"]] {
            var args = valid; args.append(contentsOf: extra); malformed.append(args)
        }
        var malformedFlag = Array(valid.dropLast()); malformedFlag.append("-UITestChatStreaming=true"); malformed.append(malformedFlag)
        for args in malformed {
            do { _ = try UITestChatStreamingConfiguration.resolve(arguments: args); throw Failure(name: "malformed streaming gate accepted") }
            catch is UITestChatStreamingConfiguration.Invalid { a.count += 1 }
        }
        let client = UITestStreamingChatModelClient(configuration: configuration)
        let e = try StreamEnvironment(); defer { e.close() }
        let session = e.session(client)
        let task = try start(session, "[fixture:stream-complete]")
        try await wait("actual native fixture first delta") { session.replyPreview?.text == "串流測試：第一段" }
        try a.check(session.replyPreview?.phase == .receiving && session.entries.isEmpty && e.archive.conversations.isEmpty, "fixture traverses actual unfinished App path")
        await task.value
        try a.check(session.replyPreview == nil && session.entries.last?.content == "串流測試：第一段；完整回覆。", "bounded fixture terminates as real complete pair")
        try a.check(e.reopen().conversations.count == 1, "fixture only saves on complete")
        session.newConversation()
        let cancelled = try start(session, "[fixture:stream-cancel]")
        try await wait("actual fixture cancellation partial") { session.replyPreview != nil }
        session.cancel(); await cancelled.value
        try a.check(session.replyPreview?.phase == .cancelled && session.entries.isEmpty && session.draft == "[fixture:stream-cancel]", "fixture cancellation preserves actual draft and preview")
        try a.check(e.reopen().conversations.count == 1, "cancelled fixture adds no archive record")
        for messages in [[ModelMessage(role: "user", content: "unknown prompt")],
                         [ModelMessage(role: "system", content: "structured tool instruction"), ModelMessage(role: "user", content: "[fixture:stream-complete]")]] {
            var deltas = 0
            do {
                for try await _ in client.stream(messages: messages, configuration: try session.modelAccess().configuration, apiKey: "synthetic") { deltas += 1 }
                throw Failure(name: "fixture accepted unknown/structured stream")
            } catch HTTPChatModelError.invalidConfiguration { try a.check(deltas == 0, "fixture cannot stream raw structured instructions") }
        }
        session.newConversation(); _ = e.learning.updatePreferences { $0.useMemory = true }
        let reviewed = try start(session, "Remember Prefer tea")
        try await wait("fixture still enters actual profile review") { session.pendingProfileReview != nil }
        try a.check(session.replyPreview == nil && session.entries.isEmpty, "stream flag cannot bypass enabled profile review")
        session.resolveProfileReview(id: session.pendingProfileReview!.id, approved: false); await reviewed.value
        try a.check(e.learning.profile.snapshot().entries.isEmpty && session.entries.isEmpty, "fixture decline remains without effect")
        return a.count
    }
    #endif
    static func actualHTTPStream() async throws -> Int {
        var a = Assertions()
        let event = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Actual SSE 🏡\"},\"finish_reason\":null}]}\n\n"
        let stop = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n"
        for mode in ["success", "truncated", "invalid", "cancel"] {
            let suffix = mode == "success" ? stop + "data: [DONE]\n\n" : mode == "invalid" ? "data: not-json\n\n" : ""
            let fixture = ModelProtocolFixture.Scenario(mime: "text/event-stream", chunks: [Data(event.utf8), Data(suffix.utf8)], holdAfterBody: mode == "cancel")
            let url = ModelProtocolFixture.register(fixture); defer { ModelProtocolFixture.remove(url) }
            let transport = ModelProtocolFixture.session(); defer { transport.invalidateAndCancel() }
            let e = try StreamEnvironment(baseURL: url); defer { e.close() }
            let client: any ChatModelClient = HTTPChatModelClient(session: transport); let session = e.session(client)
            var observed: [ChatReplyPreview] = []; var allWereUnfinished = true
            let subscription = session.$replyPreview.sink { value in
                if let value { observed.append(value); allWereUnfinished = allWereUnfinished && session.entries.isEmpty && e.archive.conversations.isEmpty }
            }; defer { subscription.cancel() }
            let task = try start(session, "Actual intercepted SSE request")
            if mode == "cancel" {
                try await wait("actual HTTP partial before cancel") { session.replyPreview?.text == "Actual SSE 🏡" }
                session.cancel()
            }
            await task.value
            try a.check(fixture.requestCount == 1 && fixture.bodyDelivered, "actual HTTP stream made one intercepted request")
            let request = fixture.lastRequest!
            let body = try JSONSerialization.jsonObject(with: interceptedBody(request)) as! [String: Any]
            try a.check(body["stream"] as? Bool == true && request.value(forHTTPHeaderField: "Accept") == "text/event-stream", "real HTTP client selected SSE transport")
            try a.check(observed.first?.text == "Actual SSE 🏡" && allWereUnfinished, "real parser delta displayed only as unfinished")
            if mode == "success" {
                try a.check(session.entries.count == 2 && session.replyPreview == nil && e.reopen().conversations[0].turns[0].assistantText == "Actual SSE 🏡", "verified DONE alone permits actual archive completion")
            } else {
                try a.check(session.entries.isEmpty && e.archive.conversations.isEmpty && session.draft == "Actual intercepted SSE request", "truncated invalid cancelled HTTP never saves or consumes draft")
                try a.check(session.replyPreview?.text == "Actual SSE 🏡" && session.replyPreview?.phase == (mode == "cancel" ? .cancelled : .failed), "actual HTTP failure preserves labelled partial")
            }
        }
        return a.count
    }
}
#if CHAT_STREAM_APP_STANDALONE
@main enum ChatStreamingMain {
    @MainActor static func main() async {
        do {
            let groups = try await [ChatStreamingChecks.incrementalCompletion(), ChatStreamingChecks.cancellationFailureAndGeneration(),
                ChatStreamingChecks.boundsFallbackAndSaveFailure(), ChatStreamingChecks.restoreCancelsPreview(),
                ChatStreamingChecks.structuredFlowsRemainReviewed(), ChatStreamingChecks.actualHTTPStream()]
            print("{\"groups\":6,\"assertions\":\(groups.reduce(0,+)),\"group_counts\":\(groups)}")
        } catch { print("STREAM_APP_FAILURE: \(error)"); exit(1) }
    }
}
#else
final class ChatStreamingAppTests: XCTestCase {
    @MainActor func testIncrementalCompletion() async throws { let n = try await ChatStreamingChecks.incrementalCompletion(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testCancellationFailureAndGeneration() async throws { let n = try await ChatStreamingChecks.cancellationFailureAndGeneration(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testBoundsFallbackAndSaveFailure() async throws { let n = try await ChatStreamingChecks.boundsFallbackAndSaveFailure(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testRestoreCancelsPreview() async throws { let n = try await ChatStreamingChecks.restoreCancelsPreview(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testStructuredFlowsRemainReviewed() async throws { let n = try await ChatStreamingChecks.structuredFlowsRemainReviewed(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testActualHTTPStream() async throws { let n = try await ChatStreamingChecks.actualHTTPStream(); XCTAssertGreaterThan(n, 0) }
}
#endif
#endif
