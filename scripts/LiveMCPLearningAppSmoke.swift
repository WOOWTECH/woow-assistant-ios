import AssistantMCP
import AssistantMemory
import AssistantModels
import AssistantPersistence
import Foundation

// Real HTTP + unchanged App transactions on macOS; NOT native iOS/UI acceptance.
// The executable approves only the two synthetic local reviews below. No keys,
// endpoints, catalogs, arguments, server results or model replies are printed.
private enum Check: String, Error {
    case missingConfiguration, setup, discovery, selection, budget, deadline
    case unexpectedReview, remoteProposal, remoteFence, remoteResult, memoryReview
    case memoryCommit, memoryReopen, undo, profileReview, profileCommit
    case refusal, draftPreservation, receiptPreservation, encryptedFile, unknown
}

private final class RAMLearningKeys: LearningKeyStore {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

private final class RAMModelKeys: ModelCredentialStoring {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}

private struct RAMEndpoint: MCPEndpointStoring {
    let url: URL
    func load() throws -> URL? { url }
    func save(endpoint: String) throws { throw Check.setup }
    func remove() throws { throw Check.setup }
}

private let allowedName = "ha_eval_template"
private let allowedArguments: JSONValue = .object(["template": .string("{{7*6}}")])

/// Defense in depth around the actual transport, not a fake server. A single
/// permit is armed only after the real App proposes the exact approved call.
private actor BoundedMCP: MCPDiscovering {
    private let client: MCPClient
    private var permit = false
    private var sealed = false
    private(set) var attempts = 0
    private(set) var results = 0
    private(set) var blocked = 0
    private(set) var toolErrors = 0
    private(set) var failure = "none"
    private(set) var lastResult: JSONValue?

    init(endpoint: URL) { client = MCPClient(endpoint: endpoint) }
    func initialize() async throws -> MCPServerInfo {
        do { return try await client.initialize() }
        catch { failure = Self.category(error); throw error }
    }
    func listTools() async throws -> [MCPTool] {
        do { return try await client.listTools() }
        catch { failure = Self.category(error); throw error }
    }
    func listResources() async throws -> [MCPResource] {
        do { return try await client.listResources() }
        catch { failure = Self.category(error); throw error }
    }
    func armOnce() throws {
        guard !sealed, !permit, attempts == 0 else { throw Check.remoteFence }
        permit = true
    }
    func seal() { permit = false; sealed = true }
    func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard !sealed, permit, attempts == 0, name == allowedName, arguments == allowedArguments else {
            blocked += 1; failure = "remoteFence"; throw Check.remoteFence
        }
        permit = false; attempts += 1 // Consumed before suspension; never retried.
        do {
            let value = try await client.callAuthorizedTool(name: name, arguments: arguments)
            results += 1; lastResult = value
            if value["isError"] == .bool(true) { toolErrors += 1 }
            return value // Exact actual server result; no substitution.
        } catch { failure = Self.category(error); throw error }
    }
    func readResource(uri: String) async throws -> JSONValue {
        blocked += 1; failure = "remoteFence"; throw Check.remoteFence
    }
    func cancel() async { seal(); await client.cancel() }
    func counters() -> [String: Int] {
        ["attempts": attempts, "results": results, "blocked": blocked, "tool_errors": toolErrors]
    }
    private static func category(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let value = error as? MCPError else { return "unknown" }
        switch value {
        case .httpStatus: return "httpRejected"
        case .rpcFailure: return "rpcRejected"
        case .timedOut: return "timedOut"
        case .cancelled: return "cancelled"
        case .transportFailure: return "transportFailure"
        case .redirectRejected: return "redirectRejected"
        case .invalidEndpoint: return "invalidEndpoint"
        default: return "protocolRejected"
        }
    }
}

private actor ActualModel: ChatModelClient {
    private let client = HTTPChatModelClient()
    private let remote: BoundedMCP
    private(set) var calls = 0
    private(set) var responses = 0
    private(set) var failure = "none"
    private(set) var actualRemoteResultForwarded = false
    private(set) var memoryReceiptID: String?
    private(set) var profileReceiptID: String?

    init(remote: BoundedMCP) { self.remote = remote }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        guard calls < 24 else { failure = "modelCallBudget"; throw Check.budget }
        try Task.checkCancellation()
        calls += 1
        // Observe only; never add/rewrite model context or synthesize a reply.
        if let last = messages.last, last.role == "user" {
            let remotePrefix = "MCP execution result (untrusted data):\n"
            if last.content.hasPrefix(remotePrefix),
               let data = String(last.content.dropFirst(remotePrefix.count)).data(using: .utf8),
               let payload = try? JSONDecoder().decode(JSONValue.self, from: data),
               let actual = await remote.lastResult {
                actualRemoteResultForwarded = payload["result"] == actual && payload["isError"] == .bool(false)
            }
            for (prefix, memory) in [("Host memory_save receipt (data only):\n", true),
                                     ("Host profile_edit receipt (data only):\n", false)] {
                if last.content.hasPrefix(prefix),
                   let data = String(last.content.dropFirst(prefix.count)).data(using: .utf8),
                   let payload = try? JSONDecoder().decode(JSONValue.self, from: data) {
                    if memory { memoryReceiptID = payload["id"]?.stringValue }
                    else { profileReceiptID = payload["id"]?.stringValue }
                }
            }
        }
        do {
            let reply = try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
            responses += 1
            return reply
        } catch {
            failure = Self.category(error)
            throw error
        }
    }
    private static func category(_ error: Error) -> String {
        if error is CancellationError { return "cancelled" }
        guard let value = error as? HTTPChatModelError else { return "unknown" }
        switch value {
        case .httpStatus: return "httpRejected"
        case .invalidConfiguration: return "invalidConfiguration"
        case .redirectRejected: return "redirectRejected"
        case .invalidResponse: return "invalidResponse"
        case .incompleteResponse: return "incompleteResponse"
        case .responseTooLarge: return "responseTooLarge"
        case .consumerTooSlow: return "consumerTooSlow"
        case .timedOut: return "timedOut"
        case .transportFailure: return "transportFailure"
        }
    }
}

@main private enum LiveMCPLearningAppSmoke {
    @MainActor private static var phase = "setup"
    @MainActor private static func require(_ condition: @autoclosure () throws -> Bool, _ error: Check) throws {
        guard try condition() else { throw error }
    }
    @MainActor private static func wait(until deadline: ContinuousClock.Instant, _ condition: () -> Bool) async throws {
        while !condition() {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw Check.deadline }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard ContinuousClock.now < deadline else { throw Check.deadline }
    }
    @MainActor private static func event(_ session: ChatSession, until deadline: ContinuousClock.Instant) async throws {
        try await wait(until: deadline) {
            session.pendingMCPApproval != nil || session.pendingMemoryReview != nil
                || session.pendingProfileReview != nil || !session.isSubmitting
        }
    }
    @MainActor private static func start(_ session: ChatSession, connection: MCPSession, prompt: String) throws {
        session.usesMCP = true; session.draft = prompt
        try require(session.canSend && connection.canUseInConversation, .setup)
        session.send(mcp: connection)
    }

    /// Validate an actual result value, not a substring of prose or a template.
    /// Accept the scalar or the result field in structuredContent/text JSON.
    private static func fortyTwo(_ result: JSONValue) -> Bool {
        func scalar(_ value: JSONValue?) -> Bool {
            value == .number(42) || value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) == "42"
        }
        func payload(_ value: JSONValue) -> Bool {
            if scalar(value) || scalar(value["result"]) { return true }
            if let text = value.stringValue, text.utf8.count <= 16 * 1024,
               let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
                return scalar(parsed) || scalar(parsed["result"])
            }
            return false
        }
        guard result["isError"] != .bool(true) else { return false }
        if let structured = result["structuredContent"], payload(structured) { return true }
        guard case .array(let content)? = result["content"] else { return false }
        return content.contains { part in
            part["type"] == .string("text") && part["text"].map(payload) == true
        }
    }
    private static func encryptedFile(_ file: URL, excluding text: String) throws -> Bool {
        let bytes = try Data(contentsOf: file)
        let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        guard object?["version"] as? Int == 1, let key = object?["keyID"] as? String,
              UUID(uuidString: key) != nil, let encoded = object?["sealed"] as? String,
              let sealed = Data(base64Encoded: encoded), sealed.count > 28 else { return false }
        return bytes.range(of: Data(text.utf8)) == nil
    }

    @MainActor static func main() async {
        let clock = ContinuousClock(), began = ContinuousClock.now
        let overall = began.advanced(by: .seconds(445)) // Outer runner owns 450s process limit.
        var remote: BoundedMCP?
        var model: ActualModel?
        var output: [String: Any] = ["native_ios_ui": false, "actual_http_model": true,
            "actual_mcp_http": true, "production_keychain_used": false,
            "approval_driver": "fixed synthetic executable", "passed": false]
        var completed: [String] = []
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let base = environment["WOOW_MODEL_TEST_BASE_URL"], !base.isEmpty,
                  let key = environment["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty,
                  let name = environment["WOOW_MODEL_TEST_MODEL"], !name.isEmpty,
                  let endpointText = environment["WOOW_HA_MCP_TEST_URL"], !endpointText.isEmpty else {
                throw Check.missingConfiguration
            }
            let endpoint = try MCPSettingsStore.validate(endpointText)
            let server = BoundedMCP(endpoint: endpoint), actualModel = ActualModel(remote: server)
            remote = server; model = actualModel
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-live-mcp-learning-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "io.woowtech.live-mcp-learning-smoke." + UUID().uuidString
            guard let defaults = UserDefaults(suiteName: suite) else { throw Check.setup }
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = RAMLearningKeys(), vault = root.appendingPathComponent("learning.vault")
            func reopen() -> LearningStore { LearningStore(vault: EncryptedLearningFile(url: vault, keys: keys)) }
            let learning = reopen()
            try require(learning.available && learning.updatePreferences { $0.useMemory = true; $0.autoRemember = false }, .setup)
            try require(learning.memory.memories.isEmpty && learning.profile.snapshot().entries.isEmpty, .setup)
            let repository = ModelSettingsRepository(defaults: defaults, credentials: RAMModelKeys())
            _ = try repository.save(baseURL: base, model: name, newKey: key)
            let session = ChatSession(learning: learning, repository: repository, client: actualModel)
            let connection = MCPSession(repository: RAMEndpoint(url: endpoint), clientFactory: { _ in server })
            connection.onConnectionChange = { [weak session] in session?.cancelMCP() }
            defer { session.cancel(); learning.cancelLearning(); connection.disconnect() }

            phase = "discovery"
            connection.connect()
            try await wait(until: min(overall, clock.now.advanced(by: .seconds(95)))) { !connection.isBusy }
            try require(connection.phase == .connected && connection.supportsTools, .discovery)
            connection.selectTool(allowedName, enabled: true)
            try require(connection.selectedToolNames == [allowedName] && connection.selectedResourceURIs.isEmpty, .selection)
            let (_, selected, resources) = try connection.conversationConnection()
            try require(selected.count == 1 && selected.first?.name == allowedName && resources.isEmpty, .selection)
            completed.append(phase)

            phase = "remote_then_memory"
            let firstDeadline = min(overall, clock.now.advanced(by: .seconds(185)))
            let firstPrompt = #"First call ha_eval_template exactly once with only {"template":"{{7*6}}"}. Wait for its actual successful result to equal 42. Then use local memory_save with kind preference, content and quote exactly "Prefer jasmine tea", and keywords ["jasmine","tea"]. I will review both the remote call and the local write separately. Only after the committed local receipt, finish with exactly MCP_MEMORY_OK_42. Do not search, edit my profile, read resources, or call any other tool."#
            try start(session, connection: connection, prompt: firstPrompt)
            try await event(session, until: firstDeadline)
            output["remote_review_received"] = session.pendingMCPApproval != nil
            output["first_turn_app_error"] = session.chatError != nil
            guard let request = session.pendingMCPApproval else { throw Check.unexpectedReview }
            try require(session.pendingMemoryReview == nil && session.pendingProfileReview == nil, .unexpectedReview)
            try require(request.name == allowedName && request.arguments == allowedArguments, .remoteProposal)
            let before = await server.attempts
            try require(before == 0 && learning.memory.memories.isEmpty && session.memoryReceipt == nil, .remoteFence)
            try await server.armOnce()
            session.resolveMCPApproval(id: request.id, approved: true)
            output["remote_approvals"] = 1

            phase = "memory_review"
            try await event(session, until: firstDeadline)
            output["memory_review_received"] = session.pendingMemoryReview != nil
            output["first_turn_app_error"] = session.chatError != nil
            guard let review = session.pendingMemoryReview else { throw Check.unexpectedReview }
            try require(session.pendingMCPApproval == nil && session.pendingProfileReview == nil, .unexpectedReview)
            let actual = await server.lastResult
            try require(session.mcpSteps.count == 1 && session.mcpSteps[0].result == actual
                        && !session.mcpSteps[0].isError && actual.map(fortyTwo) == true, .remoteResult)
            output["remote_result_matches_42"] = true
            output["memory_quote_matches"] = review.quote == "Prefer jasmine tea"
            output["memory_content_matches"] = review.after?.content == "Prefer jasmine tea"
            output["memory_keywords_match"] = review.keywords == ["jasmine", "tea"]
            try require(review.toolName == "memory_save" && review.op == .add && review.before == nil
                        && review.kind == .preference && review.after?.status == .active
                        && review.quote == "Prefer jasmine tea" && review.after?.content == "Prefer jasmine tea"
                        && review.keywords == ["jasmine", "tea"], .memoryReview)
            try require(learning.memory.memories.isEmpty && reopen().memory.memories.isEmpty && session.memoryReceipt == nil, .memoryCommit)
            session.resolveMemoryReview(id: review.id, approved: true)
            output["memory_reviews_approved"] = 1
            phase = "memory_finish"
            try await event(session, until: firstDeadline)
            output["first_turn_app_error"] = session.chatError != nil
            try require(!session.isSubmitting && session.pendingMemoryReview == nil && session.pendingMCPApproval == nil
                        && session.pendingProfileReview == nil && session.chatError == nil, .memoryCommit)
            guard let receipt = session.memoryReceipt, receipt.ok else { throw Check.memoryCommit }
            try require(session.entries.count == 2 && session.entries.last?.role == "assistant"
                        && session.entries.last?.content == "MCP_MEMORY_OK_42" && session.draft.isEmpty, .memoryCommit)
            let restored = reopen()
            try require(restored.available && restored.memory.memories.count == 1
                        && restored.memory.memories[0].id == receipt.id
                        && restored.memory.memories[0].kind == .preference
                        && restored.memory.memories[0].content == "Prefer jasmine tea"
                        && restored.memory.memories[0].keywords == ["jasmine", "tea"]
                        && restored.memory.memories[0].source.type == "user_said"
                        && restored.memory.memories[0].source.quote == "Prefer jasmine tea", .memoryReopen)
            try require(try encryptedFile(vault, excluding: "Prefer jasmine tea"), .encryptedFile)
            let forwardedResult = await actualModel.actualRemoteResultForwarded
            let forwardedMemory = await actualModel.memoryReceiptID
            try require(forwardedResult && forwardedMemory == receipt.id.uuidString, .memoryCommit)
            output["actual_remote_result_forwarded"] = forwardedResult
            output["memory_receipt_forwarded"] = true
            output["memory_encrypted_reopen"] = true
            learning.undo(receipt.note)
            let undone = reopen()
            try require(learning.error == nil && learning.memory.memories.isEmpty
                        && undone.available && undone.memory.memories.isEmpty, .undo)
            output["memory_undo_reopen_empty"] = true
            let firstCounters = await server.counters()
            try require(firstCounters == ["attempts": 1, "results": 1, "blocked": 0, "tool_errors": 0], .remoteResult)
            output["first_turn_remote"] = firstCounters
            completed.append("remote_then_memory")

            phase = "profile_then_remote_refusal"
            await server.seal() // The second turn cannot dispatch even on a regression.
            session.newConversation()
            try require(session.entries.isEmpty && session.profileReceipt == nil && session.memoryReceipt == nil, .setup)
            let secondDeadline = min(overall, clock.now.advanced(by: .seconds(185)))
            let secondPrompt = #"First use local profile_edit to add the preference with text and quote exactly "Prefer quiet walks". I will review that write. After its successful committed receipt, propose ha_eval_template with only {"template":"{{7*6}}"}. Wait for my separate remote approval; do not call any other tool, save ordinary memory, or read resources. I may refuse the remote call; the saved profile must remain saved."#
            try start(session, connection: connection, prompt: secondPrompt)
            try await event(session, until: secondDeadline)
            output["profile_review_received"] = session.pendingProfileReview != nil
            output["second_turn_app_error"] = session.chatError != nil
            guard let profile = session.pendingProfileReview else { throw Check.unexpectedReview }
            output["profile_quote_matches"] = profile.quote == "Prefer quiet walks"
            output["profile_content_matches"] = profile.after == "Prefer quiet walks"
            try require(session.pendingMCPApproval == nil && session.pendingMemoryReview == nil
                        && profile.op == .add && profile.before == nil
                        && profile.after == "Prefer quiet walks" && profile.quote == "Prefer quiet walks", .profileReview)
            try require(learning.profile.snapshot().entries.isEmpty && session.profileReceipt == nil, .profileCommit)
            session.resolveProfileReview(id: profile.id, approved: true)
            output["profile_reviews_approved"] = 1
            phase = "remote_refusal"
            try await event(session, until: secondDeadline)
            output["second_remote_review_received"] = session.pendingMCPApproval != nil
            output["second_turn_app_error"] = session.chatError != nil
            guard let denied = session.pendingMCPApproval else { throw Check.unexpectedReview }
            try require(denied.name == allowedName && denied.arguments == allowedArguments
                        && session.pendingProfileReview == nil && session.pendingMemoryReview == nil, .remoteProposal)
            guard let profileReceipt = session.profileReceipt, profileReceipt.applied,
                  let profileID = profileReceipt.id else { throw Check.profileCommit }
            let committed = reopen()
            try require(committed.available && committed.profile.snapshot().entries.count == 1
                        && committed.profile.snapshot().entries[0].id == profileID
                        && committed.profile.snapshot().entries[0].text == "Prefer quiet walks", .profileCommit)
            let beforeRefusal = await server.counters()
            let modelCallsBeforeRefusal = await actualModel.calls
            try require(beforeRefusal == firstCounters && session.mcpSteps.isEmpty, .remoteFence)
            session.resolveMCPApproval(id: denied.id, approved: false)
            output["remote_denials"] = 1
            try await event(session, until: secondDeadline)
            try require(!session.isSubmitting && session.pendingMCPApproval == nil
                        && session.pendingProfileReview == nil && session.pendingMemoryReview == nil, .refusal)
            // After a local commit the actual App replaces the stop message
            // with its saved-state warning; it does not retain the denial text.
            try require(session.chatError == "個人檔案已儲存，但後續模型回覆未完成；請先查看已保存內容，避免重複修改。草稿保留。", .refusal)
            try require(session.draft == secondPrompt && session.entries.isEmpty, .draftPreservation)
            try require(session.profileReceipt?.applied == true && session.profileReceipt?.id == profileID
                        && session.memoryReceipt == nil, .receiptPreservation)
            let retained = reopen()
            try require(retained.available && retained.profile.snapshot().entries.count == 1
                        && retained.profile.snapshot().entries[0].id == profileID
                        && retained.profile.snapshot().entries[0].text == "Prefer quiet walks"
                        && retained.memory.memories.isEmpty, .receiptPreservation)
            try require(try encryptedFile(vault, excluding: "Prefer quiet walks"), .encryptedFile)
            let afterRefusal = await server.counters(), forwardedProfile = await actualModel.profileReceiptID
            let modelCallsAfterRefusal = await actualModel.calls
            try require(afterRefusal == firstCounters && session.mcpSteps.isEmpty
                        && forwardedProfile == profileID.uuidString
                        && modelCallsAfterRefusal == modelCallsBeforeRefusal, .remoteFence)
            output["second_turn_remote_attempts"] = afterRefusal["attempts", default: 0] - beforeRefusal["attempts", default: 0]
            output["profile_receipt_forwarded"] = true
            output["profile_receipt_preserved"] = true
            output["profile_encrypted_reopen"] = true
            output["refused_remote_draft_preserved"] = true
            output["second_turn_app_error"] = true // Expected saved-state warning after refusal.
            completed.append("profile_then_remote_refusal")
            try require(clock.now < overall, .deadline)
            output["passed"] = true
            output["error"] = "none"
        } catch {
            output["error"] = (error as? Check)?.rawValue ?? (error is CancellationError ? "cancelled" : "unknown")
        }
        output["phase"] = phase; output["completed"] = completed
        output["model_calls"] = await model?.calls ?? 0
        output["model_responses"] = await model?.responses ?? 0
        output["model_error"] = await model?.failure ?? "none"
        output["remote_error"] = await remote?.failure ?? "none"
        output["remote"] = await remote?.counters() ?? [:]
        let elapsed = began.duration(to: clock.now).components
        output["seconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        // One bounded JSON record. Never serialize errors, URLs or private data.
        if let bytes = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            print(String(decoding: bytes, as: UTF8.self))
        } else { print("{\"passed\":false,\"error\":\"reportEncoding\"}") }
    }
}
