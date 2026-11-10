#if PROFILE_CHAT_APP_STANDALONE || canImport(WoowAssistant)
import AssistantMemory
import AssistantModels
import AssistantMCP
import AssistantPersistence
import Combine
import Foundation
#if !PROFILE_CHAT_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

// Compile alongside unchanged App sources using check_profile_chat_app.py.
// Only external model replies and key stores are synthetic. No production
// defaults, Keychain, network, view automation, or private OS APIs are used.
private struct CheckFailure: Error { let check: String }

private final class SyntheticKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    var failReads = false
    func read(id: String) throws -> Data? {
        if failReads { throw LearningFileError.unavailable }
        return values[id]
    }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

private final class SyntheticCredentials: ModelCredentialStoring {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}

private actor ModelGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Intentionally lets a model response arrive AFTER cancellation. The actual
    // ChatSession must reject it; the test then joins that original App task.
    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiters.append(continuation) }
        }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor ScriptedModel: ChatModelClient {
    struct Response: Sendable {
        let text: String?
        let gate: ModelGate?
        init(_ text: String?, gate: ModelGate? = nil) { self.text = text; self.gate = gate }
    }
    private let responses: [Response]
    private(set) var requests: [[ModelMessage]] = []
    init(_ responses: [Response]) { self.responses = responses }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        let index = requests.count
        requests.append(messages)
        guard index < responses.count else { throw CheckFailure(check: "Unexpected extra model request") }
        let response = responses[index]
        if let gate = response.gate { await gate.wait() }
        guard let text = response.text else { throw URLError(.networkConnectionLost) }
        return text
    }
}

private struct SyntheticMCPEndpoint: MCPEndpointStoring {
    func load() throws -> URL? { URL(string: "https://mcp-learning.example.invalid/fixture") }
    func save(endpoint: String) throws { throw MCPSettingsError.invalidEndpoint }
    func remove() throws {}
}

/// Actual MCPSession discovery/selection and runner dispatch; only the external
/// transport is synthetic. It cannot edit learning data or approve proposals.
private actor LearningMCPServer: MCPDiscovering {
    private(set) var calls: [JSONValue] = []
    private let resultText: String
    init(resultText: String = "Actual synthetic server result") { self.resultText = resultText }
    func initialize() async throws -> MCPServerInfo {
        MCPServerInfo(protocolVersion: "2025-03-26", capabilities: ["tools"])
    }
    func listTools() async throws -> [MCPTool] {
        [MCPTool(name: "synthetic_read", inputSchema: .object(["type": .string("object")]))]
    }
    func listResources() async throws -> [MCPResource] { [] }
    func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        try Task.checkCancellation()
        guard name == "synthetic_read" else { throw MCPError.invalidRequest }
        calls.append(arguments)
        return .object(["isError": .bool(false), "content": .array([
            .object(["type": .string("text"), "text": .string(resultText)])])])
    }
    func readResource(uri: String) async throws -> JSONValue { throw MCPError.invalidRequest }
    func cancel() async {}
}

#if DEBUG
// Observation only: all responses still come from the actual App UI fixture.
private actor RecordingUIModel: ChatModelClient {
    private let client = UITestChatModelClient()
    private(set) var requests: [[ModelMessage]] = []
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        requests.append(messages)
        return try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
    }
}
#endif

@MainActor private final class Environment {
    let root: URL
    let file: URL
    let keys = SyntheticKeys()
    let defaultsName = "io.woowtech.profile-chat-check." + UUID().uuidString
    let defaults: UserDefaults
    let store: LearningStore
    let repository: ModelSettingsRepository

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-profile-chat-" + UUID().uuidString)
        file = root.appendingPathComponent("learning.vault")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: defaultsName)!
        repository = ModelSettingsRepository(defaults: defaults, credentials: SyntheticCredentials())
        _ = try repository.save(baseURL: "https://profile-check.example.invalid/v1", model: "synthetic", newKey: "synthetic-not-a-key")
        store = LearningStore(vault: EncryptedLearningFile(url: file, keys: keys))
        guard store.available, store.updatePreferences({ $0.useMemory = true; $0.autoRemember = false }) else {
            throw CheckFailure(check: "Create isolated real encrypted store")
        }
    }
    func close() throws {
        defaults.removePersistentDomain(forName: defaultsName)
        try FileManager.default.removeItem(at: root)
    }
    func reopen() -> LearningStore { LearningStore(vault: EncryptedLearningFile(url: file, keys: keys)) }
    func bytes() throws -> Data { try Data(contentsOf: file) }
    func session(_ client: any ChatModelClient) -> ChatSession {
        ChatSession(learning: store, repository: repository, client: client)
    }
    // Real atomic file replacement failure; never changes the production writer.
    func blockWrite() throws {
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("saved.vault"))
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    }
    func restoreWrite() throws {
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: root.appendingPathComponent("saved.vault"), to: file)
    }
}

#if PROFILE_CHAT_APP_STANDALONE
@main
#endif
private enum CheckProfileChatApp {
    @MainActor static var assertions = 0
    @MainActor static var groups: [String: Int] = [:]
    @MainActor static var longChatObservation: [String: Int] = [:]
    static let text = "Prefer jasmine tea"
    static let utterance = "Please remember Prefer jasmine tea"
    static let proposal = #"{"action":"profile_edit","arguments":{"op":"add","text":"Prefer jasmine tea","quote":"Please remember Prefer jasmine tea"}}"#
    static let finished = #"{"action":"finish","answer":"Synthetic answer after commit"}"#

    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
        assertions += 1
        if try !condition() { throw CheckFailure(check: name) }
    }
    @MainActor static func until(_ name: String, _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw CheckFailure(check: name + " did not reach state") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    @MainActor static func task(_ session: ChatSession) throws -> Task<Void, Never> {
        // Read-only observation of the exact private App Task, so cancellation
        // checks wait for late completion rather than only isSubmitting=false.
        guard let task = Mirror(reflecting: session).children.first(where: { $0.label == "request" })?.value as? Task<Void, Never> else {
            throw CheckFailure(check: "Observe original ChatSession request task")
        }
        return task
    }
    @MainActor static func start(_ session: ChatSession, draft: String = utterance) throws -> Task<Void, Never> {
        session.draft = draft
        try check(session.canSend, "Synthetic settings load through real initializer")
        session.send()
        return try task(session)
    }
    @MainActor static func review(_ session: ChatSession) async throws -> UserProfileToolReview {
        try await until("Pending actual profile review") { session.pendingProfileReview != nil || !session.isSubmitting }
        guard let review = session.pendingProfileReview else { throw CheckFailure(check: "Profile proposal must reach actual review") }
        return review
    }
    @MainActor static func prepared(_ store: LearningStore) throws -> UserProfileToolReview {
        try UserProfileToolRequest.parse(#"{"op":"add","text":"Prefer jasmine tea","quote":"Please remember Prefer jasmine tea"}"#)
            .prepare(state: store.profile, utterances: [utterance])
    }
    @MainActor static func rejected(_ expected: UserProfileToolError, _ action: () throws -> Void) throws {
        do { try action(); throw CheckFailure(check: "Transaction should reject") }
        catch let error as UserProfileToolError { try check(error == expected, "Exact transaction rejection") }
    }
    @MainActor static func group(_ name: String, _ body: () async throws -> Void) async throws {
        let before = assertions
        do { try await body() }
        catch let error as CheckFailure { throw CheckFailure(check: name + ": " + error.check) }
        groups[name] = assertions - before
    }

    @MainActor static func transactionChecks() async throws {
        let env = try Environment(); defer { try? env.close() }
        let initial = env.store.profile, bytes = try env.bytes(), generation = env.store.generation
        let pending = try prepared(env.store)
        try check(env.store.profile == initial && (try env.bytes()) == bytes, "Preparing is not permission or a write")
        let receipt = try env.store.commitProfileTool(pending, expectedGeneration: generation)
        try check(receipt.applied && receipt.effective == "next_run", "Actual committed receipt semantics")
        try check(receipt.id == env.store.profile.snapshot().entries.first?.id, "Receipt references actual persisted entry")
        try check(env.reopen().profile == env.store.profile, "Authenticated reopen restores exact profile revision")
        try check(!String(decoding: env.bytes(), as: UTF8.self).contains(text), "Saved profile is ciphertext")
        let savedBytes = try env.bytes(), saved = env.store.profile
        try rejected(.staleRevision) { _ = try env.store.commitProfileTool(pending, expectedGeneration: generation) }
        try check((try env.bytes()) == savedBytes && env.store.profile == saved, "Replay changes neither disk nor publication")

        let fresh = try Environment(); defer { try? fresh.close() }
        let stale = try prepared(fresh.store), oldGeneration = fresh.store.generation
        try check(fresh.store.mutateProfile { try $0.add(text: "Prefer quiet hotels") }, "Concurrent real manual profile write")
        let current = fresh.store.profile, currentBytes = try fresh.bytes()
        try rejected(.staleRevision) { _ = try fresh.store.commitProfileTool(stale, expectedGeneration: oldGeneration) }
        try check(fresh.store.profile == current && (try fresh.bytes()) == currentBytes, "Stale revision cannot overwrite concurrent edit")
        fresh.store.cancelLearning()
        let validReview = try prepared(fresh.store)
        try rejected(.staleRevision) { _ = try fresh.store.commitProfileTool(validReview, expectedGeneration: oldGeneration) }
        try check(fresh.store.profile == current && (try fresh.bytes()) == currentBytes, "Stale generation cannot write")
        try check(fresh.store.updatePreferences { $0.useMemory = false }, "Persist master off")
        do {
            _ = try fresh.store.commitProfileTool(validReview, expectedGeneration: fresh.store.generation)
            throw CheckFailure(check: "Master off must reject even with current generation")
        } catch let error as MemoryError { try check(error == .disabled, "Independent master-switch commit gate") }
        try check(fresh.reopen().profile == current && !fresh.reopen().memory.preferences.useMemory, "Disabled commit remains unchanged after reopen")
    }

    @MainActor static func approveAndReceipt() async throws {
        let env = try Environment(); defer { try? env.close() }
        let gate = ModelGate()
        let model = ScriptedModel([.init(proposal), .init(finished, gate: gate), .init(finished)])
        let session = env.session(model)
        let initialBytes = try env.bytes()
        var receiptPublications = 0, receiptAlreadyDurable = false
        let subscription = session.$profileReceipt.compactMap { $0 }.sink { receipt in
            receiptPublications += 1
            receiptAlreadyDurable = env.reopen().profile.snapshot().entries.first?.id == receipt.id
        }
        defer { subscription.cancel() }
        let running = try start(session), pending = try await review(session)
        try check(pending.quote == utterance && pending.after == text, "Review is grounded in exact sent utterance")
        try check(session.profileReceipt == nil && (try env.bytes()) == initialBytes, "No receipt or encrypted write before approval")
        session.resolveProfileReview(id: UUID(), approved: true)
        try check(session.pendingProfileReview?.id == pending.id && (try env.bytes()) == initialBytes, "Wrong approval ID grants nothing")
        session.resolveProfileReview(id: pending.id, approved: true)
        try await until("Committed receipt before second model reply") { session.profileReceipt != nil }
        try check(receiptPublications == 1 && receiptAlreadyDurable, "Receipt observer sees already durable encrypted state")
        try check(session.entries.isEmpty && session.isSubmitting, "Model reply still pending after actual commit")
        try check(env.store.profile.snapshot().entries.map(\.text) == [text], "Exact approved text committed once")
        session.resolveProfileReview(id: pending.id, approved: true)
        try check(receiptPublications == 1, "Replayed UI approval cannot publish twice")
        await gate.release(); await running.value
        try check(session.entries.map(\.role) == ["user", "assistant"] && session.draft.isEmpty, "Actual success completes chat")
        try check(session.chatError == nil && session.pendingProfileReview == nil, "Completed review cleaned up")
        let requests = await model.requests
        try check(requests.count == 2 && requests[1].last?.content.hasPrefix("Host profile_edit receipt") == true, "Only actual committed receipt reaches continuation")
        try check(!requests[1].contains { $0.content.hasPrefix("User profile (for reference only;") }, "Current model request does not gain a changed profile snapshot")
        let id = session.profileReceipt?.id
        let next = try start(session, draft: "What do I prefer")
        try check(session.profileReceipt?.id == id, "Starting next turn retains prior receipt")
        await next.value
        let later = await model.requests
        try check(later.count == 3 && later[2].contains { $0.content.hasPrefix("User profile (for reference only;") && $0.content.contains(text) }, "Next turn uses saved profile")
        session.newConversation()
        try check(session.profileReceipt == nil && env.reopen().profile.snapshot().entries.map(\.text) == [text], "New conversation clears presentation only")
        for reset in ["changeSettings", "removeSettings"] {
            let fresh = try Environment(); defer { try? fresh.close() }
            let other = fresh.session(ScriptedModel([.init(proposal), .init(finished)]))
            let writing = try start(other), approval = try await review(other)
            other.resolveProfileReview(id: approval.id, approved: true)
            await writing.value
            let saved = try fresh.bytes(), priorID = other.profileReceipt?.id
            try check(priorID != nil, "Settings reset starts with an actual saved receipt")
            other.saveSettings()
            try check(other.profileReceipt?.id == priorID && other.entries.count == 2,
                      "Saving unchanged model settings retains the same conversation receipt")
            if reset == "changeSettings" {
                other.modelDraft = "different-synthetic"
                other.saveSettings()
            } else { other.removeSettings() }
            try check(other.settingsError == nil && other.profileReceipt == nil && other.entries.isEmpty,
                      "Settings reset clears old conversation receipt")
            try check((try fresh.bytes()) == saved && fresh.reopen().profile.snapshot().entries.map(\.text) == [text],
                      "Settings reset preserves the actual encrypted profile")
        }
    }

    @MainActor static func deniedOrCancelled() async throws {
        for action in ["decline", "cancel", "background", "masterOff", "generation", "revision"] {
            let env = try Environment(); defer { try? env.close() }
            let model = ScriptedModel([.init(proposal)])
            let session = env.session(model), bytes = try env.bytes()
            let running = try start(session), pending = try await review(session)
            switch action {
            case "decline": session.resolveProfileReview(id: pending.id, approved: false)
            case "cancel": session.cancel()
            case "background": session.invalidateProfileReview() // Exact ContentView background callback.
            case "masterOff":
                env.store.onUserChange = { [weak session] in session?.invalidateProfileReview() }
                try check(env.store.updatePreferences { $0.useMemory = false }, "UI master switch persisted")
            case "generation":
                env.store.cancelLearning()
                session.resolveProfileReview(id: pending.id, approved: true)
            default:
                try check(env.store.mutateProfile { try $0.add(text: "Prefer quiet hotels") }, "Manual edit during review")
                session.resolveProfileReview(id: pending.id, approved: true)
            }
            await running.value
            session.resolveProfileReview(id: pending.id, approved: true)
            try check(session.profileReceipt == nil && session.pendingProfileReview == nil && !session.isSubmitting, action + " blocks receipt and clears continuation")
            try check(!env.reopen().profile.snapshot().entries.contains { $0.text == text }, action + " cannot persist proposed text")
            try check(session.draft == utterance && session.entries.isEmpty, action + " retains draft and no false final answer")
            let requests = await model.requests
            try check(requests.count == 1, action + " sends no post-commit model call")
            if ["decline", "cancel", "background", "generation"].contains(action) {
                try check((try env.bytes()) == bytes, action + " preserves byte-identical ciphertext")
            }
        }
    }

    @MainActor static func lateProposals() async throws {
        for action in ["cancel", "generation", "masterOff", "revision"] {
            let env = try Environment(); defer { try? env.close() }
            let gate = ModelGate(), model = ScriptedModel([.init(proposal, gate: gate)])
            let session = env.session(model)
            let running = try start(session)
            try await until("First model call started") { await model.requests.count == 1 }
            switch action {
            case "cancel": session.cancel()
            case "generation": env.store.cancelLearning()
            case "masterOff": try check(env.store.updatePreferences { $0.useMemory = false }, "Master off before proposal")
            default: try check(env.store.mutateProfile { try $0.add(text: "Prefer quiet hotels") }, "Revision changes before proposal")
            }
            let before = env.store.profile, bytes = try env.bytes()
            await gate.release(); await running.value
            try check(session.profileReceipt == nil && session.pendingProfileReview == nil, action + " rejects late proposal before review")
            try check(env.store.profile == before && (try env.bytes()) == bytes, action + " late model cannot write")
        }
    }

    @MainActor static func failedWrites() async throws {
        for failure in ["filesystem", "keyRead"] {
            let env = try Environment(); defer { try? env.close() }
            let model = ScriptedModel([.init(proposal)])
            let session = env.session(model), original = env.store.profile, bytes = try env.bytes()
            var publications = 0
            let subscription = session.$profileReceipt.compactMap { $0 }.sink { _ in publications += 1 }
            defer { subscription.cancel() }
            let running = try start(session), pending = try await review(session)
            if failure == "filesystem" { try env.blockWrite() } else { env.keys.failReads = true }
            session.resolveProfileReview(id: pending.id, approved: true)
            await running.value
            try check(publications == 0 && session.profileReceipt == nil, failure + " cannot publish receipt")
            try check(env.store.profile == original && env.store.error != nil, failure + " leaves original published state")
            try check(session.chatError != nil && session.entries.isEmpty && session.draft == utterance, failure + " surfaces failure without false answer")
            if failure == "filesystem" { try env.restoreWrite() } else { env.keys.failReads = false }
            try check((try env.bytes()) == bytes && env.reopen().profile == original, failure + " preserves original ciphertext and relaunch state")
            let requests = await model.requests
            try check(requests.count == 1, failure + " emits no host receipt or follow-up call")
        }
    }

    @MainActor static func postCommitFailure() async throws {
        for action in ["disconnect", "cancel"] {
            let env = try Environment(); defer { try? env.close() }
            let gate = ModelGate()
            let model = ScriptedModel([.init(proposal), .init(nil, gate: gate)])
            let session = env.session(model)
            let running = try start(session), pending = try await review(session)
            session.resolveProfileReview(id: pending.id, approved: true)
            try await until("Second model call started") { await model.requests.count == 2 }
            let id = session.profileReceipt?.id, bytes = try env.bytes()
            try check(id != nil && env.reopen().profile.snapshot().entries.first?.id == id, "Commit durable before simulated post-commit failure")
            if action == "cancel" { session.cancel() }
            await gate.release(); await running.value
            try check(session.profileReceipt?.id == id && (try env.bytes()) == bytes, action + " preserves actual saved receipt and ciphertext")
            try check(session.entries.isEmpty && session.draft == utterance, action + " does not invent final response")
            if action == "disconnect" {
                try check(session.chatError?.contains("個人檔案已儲存") == true, "Post-commit disconnection explains durable side effect")
            }
            try check(env.reopen().profile.snapshot().entries.map(\.text) == [text], action + " preserves exactly one saved change")
        }
    }

    @MainActor static func groundingAndOrdinary() async throws {
        let env = try Environment(); defer { try? env.close() }
        let model = ScriptedModel([.init(proposal)])
        let session = env.session(model), bytes = try env.bytes()
        let running = try start(session, draft: "Explain how profile review works")
        await running.value
        try check(session.pendingProfileReview == nil && session.profileReceipt == nil && session.chatError != nil, "Model quote cannot stand in for actual submitted request")
        try check((try env.bytes()) == bytes, "Unrelated model proposal cannot write")

        let disabled = try Environment(); defer { try? disabled.close() }
        try check(disabled.store.updatePreferences { $0.useMemory = false }, "Master off before send")
        let plainModel = ScriptedModel([.init("Ordinary synthetic reply")])
        let plain = disabled.session(plainModel), plainTask = try start(plain, draft: "Hello")
        await plainTask.value
        let plainRequests = await plainModel.requests
        try check(plain.entries.last?.content == "Ordinary synthetic reply" && plain.profileReceipt == nil, "Master-off ordinary response remains ordinary")
        try check(plainRequests.count == 1 && !plainRequests[0].contains { $0.content.hasPrefix("Ordinary chat with an available profile_edit tool.") }, "Disabled tool is not offered")

        #if DEBUG
        let fixture = try Environment(); defer { try? fixture.close() }
        let ordinary = fixture.session(UITestChatModelClient())
        let ordinaryTask = try start(ordinary, draft: "合成普通問題")
        await ordinaryTask.value
        try check(ordinary.entries.last?.content == "測試回覆：合成普通問題" && ordinary.chatError == nil, "Actual DEBUG ordinary fixture wraps finish command correctly")
        try check(ordinary.pendingProfileReview == nil && ordinary.profileReceipt == nil, "Ordinary fixture never claims profile mutation")
        let failedTask = try start(ordinary, draft: "[fixture:error-once]")
        await failedTask.value
        try check(ordinary.chatError != nil && ordinary.draft == "[fixture:error-once]", "Actual DEBUG fixture error survives structured wrapper")
        let waitingTask = try start(ordinary, draft: "[fixture:wait]")
        ordinary.cancel(); await waitingTask.value
        try check(!ordinary.isSubmitting && ordinary.draft == "[fixture:wait]", "Actual DEBUG fixture remains cancellable")
        #endif
    }

    @MainActor static func priorReceiptAndFailedNewWrite() async throws {
        let env = try Environment(); defer { try? env.close() }
        let nextProposal = proposal.replacingOccurrences(of: "jasmine", with: "green")
        let model = ScriptedModel([.init(proposal), .init(finished), .init(nextProposal)])
        let session = env.session(model)
        var publications = 0
        let subscription = session.$profileReceipt.compactMap { $0 }.sink { _ in publications += 1 }
        defer { subscription.cancel() }
        let first = try start(session), approved = try await review(session)
        session.resolveProfileReview(id: approved.id, approved: true)
        await first.value
        let oldID = session.profileReceipt?.id, saved = env.store.profile, bytes = try env.bytes()
        try check(oldID != nil && publications == 1, "First run committed one actual receipt")
        let second = try start(session, draft: utterance.replacingOccurrences(of: "jasmine", with: "green"))
        let pending = try await review(session)
        try check(session.profileReceipt?.id == oldID, "Existing receipt survives unrelated new review")
        try env.blockWrite()
        session.resolveProfileReview(id: pending.id, approved: true)
        await second.value
        try env.restoreWrite()
        try check(publications == 1 && session.profileReceipt?.id == oldID, "Failed new write never republishes a receipt")
        try check(env.store.profile == saved && env.reopen().profile == saved && (try env.bytes()) == bytes,
                  "Failed new write preserves only the previous committed state")
        try check(session.chatError != nil && session.chatError?.contains("但後續模型回覆未完成") == false,
                  "Old receipt must not misclassify a new failed write as a completed write followed by model failure")
    }

    @MainActor static func twentyTurnContextWindow() async throws {
        let env = try Environment(); defer { try? env.close() }
        try check(env.store.memory.preferences.useMemory && !env.store.memory.preferences.autoRemember,
                  "Long chat uses profile flow with automatic memory extraction disabled")
        try check(env.store.mutateProfile { try $0.add(text: "Prefer quiet hotels") },
                  "Long chat includes one real persisted profile context")
        let context = env.store.contextMessages(for: "Synthetic context check")
        try check(context.count == 1, "One complete current reference message reserves a window slot")
        let prompts = (1...20).map { "  合成本輪 \($0)：保留完整原話。\n第二行與尾端空白 \($0)  " }
        let answers = (1...20).map { "合成回覆 \($0)" }
        let responses = try answers.map { answer in
            ScriptedModel.Response(String(decoding: try JSONSerialization.data(withJSONObject:
                ["action": "finish", "answer": answer]), as: UTF8.self))
        }
        let model = ScriptedModel(responses), session = env.session(model)
        for index in prompts.indices {
            let running = try start(session, draft: prompts[index])
            await running.value
            try check(session.chatError == nil && !session.isSubmitting && session.draft.isEmpty
                      && session.entries.last?.content == answers[index],
                      "Each of twenty actual App responses completes and clears only its sent draft")
        }
        let requests = await model.requests
        let expectedHistory = prompts.indices.flatMap { index in
            [ModelMessage(role: "user", content: prompts[index]), ModelMessage(role: "assistant", content: answers[index])]
        }
        try check(requests.count == 20 && session.entries.filter { $0.role == "assistant" }.count == 20,
                  "Twenty turns produce twenty real client calls and twenty responses")
        try check(session.entries.count == 40 && session.entries.map { ModelMessage(role: $0.role, content: $0.content) } == expectedHistory,
                  "Windowing never removes or rewrites any of forty displayed history entries")
        try check(requests.allSatisfy { $0.first == ModelMessage(role: "system", content: UserProfileChatFlow.instructions) },
                  "Every turn runs through actual profile flow with its separately prepended system message")
        let inputs = requests.map { Array($0.dropFirst()) }
        try check(inputs.allSatisfy { $0.count <= 32 && $0.reduce(0, { $0 + $1.content.utf8.count }) <= 64 * 1024 },
                  "Actual client input windows stay within thirty-two messages and sixty-four KiB before flow instructions")
        guard let last = inputs.last else { throw CheckFailure(check: "Long chat must reach twentieth model call") }
        let latestPairs = (4..<19).flatMap { index in
            [ModelMessage(role: "user", content: prompts[index]), ModelMessage(role: "assistant", content: answers[index])]
        }
        try check(last == latestPairs + context + [ModelMessage(role: "user", content: prompts[19])],
                  "Final client input contains exactly the latest fifteen complete pairs, unchanged context and complete current words")
        try check(last.count == 32 && requests[19].count == 33,
                  "Window and additional flow system message are counted independently")
        try check(session.chatNotice == "本次傳送最近 15 輪對話、本輪完整訊息及參考資料；較早 4 輪仍在畫面中，但未傳送。",
                  "Notice reports the actual fifteen retained and four omitted earlier turns")
        try check(session.pendingProfileReview == nil && session.profileReceipt == nil,
                  "Ordinary twenty-turn answers never invent a profile edit or receipt")

        let oldIDs = session.entries.map(\.id)
        let oversized = String(repeating: "字", count: (64 * 1024 / 3) + 1)
        session.draft = oversized
        try check(session.canSend, "Oversized draft reaches actual send validation rather than a disabled button")
        session.send()
        let originalTask = Mirror(reflecting: session).children.first(where: { $0.label == "request" })?.value as? Task<Void, Never>
        try check(!session.isSubmitting && originalTask == nil, "Oversized current input is rejected before creating an App request task")
        let callsAfterRejection = await model.requests.count
        try check(callsAfterRejection == 20, "Oversized current input never calls the model")
        try check(session.draft == oversized && session.chatError?.contains("超過傳送上限") == true,
                  "Oversized input remains byte-for-byte in the draft with an explicit bound error")
        try check(session.entries.map(\.id) == oldIDs
                  && session.entries.map { ModelMessage(role: $0.role, content: $0.content) } == expectedHistory,
                  "Rejected input leaves all existing history identities, roles and contents unchanged")
        longChatObservation = ["completed_responses": 20, "model_calls": requests.count,
            "displayed_entries": session.entries.count, "last_window_messages": last.count,
            "last_client_messages_including_flow_system": requests[19].count,
            "retained_history_pairs": latestPairs.count / 2, "omitted_history_pairs": 19 - latestPairs.count / 2,
            "oversized_prompt_utf8_bytes": oversized.utf8.count,
            "model_calls_after_oversized_rejection": callsAfterRejection]
    }

    // These commands are synthetic model output only. The actual App parses,
    // grounds, searches, reviews and persists them; no test writes a receipt.
    static func memoryCommand(_ action: String, _ arguments: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject:
            ["action": action, "arguments": arguments], options: [.sortedKeys]), as: UTF8.self)
    }
    static func memorySave(_ content: String = text, quote: String = utterance,
                           kind: String = "preference") throws -> String {
        try memoryCommand("memory_save", ["kind": kind, "content": content, "quote": quote])
    }
    static func memoryEdit(_ id: UUID, quote: String, content: String? = nil) throws -> String {
        var args: [String: Any] = ["op": content == nil ? "delete" : "update", "id": id.uuidString, "quote": quote]
        if let content { args["content"] = content }
        return try memoryCommand("memory_edit", args)
    }
    @MainActor static func memoryReview(_ session: ChatSession) async throws -> MemoryToolReview {
        try await until("Pending actual ordinary memory review") { session.pendingMemoryReview != nil || !session.isSubmitting }
        guard let value = session.pendingMemoryReview else { throw CheckFailure(check: "Memory command must reach actual review") }
        return value
    }
    @MainActor static func memoryReceipt(_ session: ChatSession) throws -> MemoryToolReceipt {
        guard let value = session.memoryReceipt else { throw CheckFailure(check: "Actual memory receipt required") }
        return value
    }

    @MainActor static func connectedMCP(_ server: LearningMCPServer) async throws -> MCPSession {
        let connection = MCPSession(repository: SyntheticMCPEndpoint(), clientFactory: { _ in server })
        connection.connect()
        try await until("Actual synthetic MCP discovery") { !connection.isBusy }
        try check(connection.phase == .connected, "Real MCPSession completes discovery")
        connection.selectTool("synthetic_read", enabled: true)
        try check(connection.canUseInConversation && connection.tools.map(\.name) == ["synthetic_read"],
                  "Local tools are not fabricated remote catalog entries")
        return connection
    }

    @MainActor static func startMCP(_ session: ChatSession, connection: MCPSession,
                                   draft: String = utterance) throws -> Task<Void, Never> {
        session.usesMCP = true; session.draft = draft
        connection.onConnectionChange = { [weak session] in session?.cancelMCP() }
        try check(session.canSend, "Actual settings allow mixed MCP turn")
        session.send(mcp: connection)
        return try task(session)
    }

    static let remoteRead = #"{"action":"call_tool","name":"synthetic_read","arguments":{}}"#

    @MainActor static func mcpMemoryAndRemoteApprovals() async throws {
        let env = try Environment(); defer { try? env.close() }
        let server = LearningMCPServer(), connection = try await connectedMCP(server)
        defer { connection.disconnect() }
        let model = ScriptedModel([.init(remoteRead), .init(try memorySave()), .init(finished)])
        let session = env.session(model), running = try startMCP(session, connection: connection)
        try await until("Remote native approval precedes dispatch") { session.pendingMCPApproval != nil || !session.isSubmitting }
        guard let remote = session.pendingMCPApproval else { throw CheckFailure(check: "Remote approval required") }
        let beforeCalls = await server.calls.count
        try check(beforeCalls == 0 && session.pendingMemoryReview == nil && env.store.memory.memories.isEmpty,
                  "Remote proposal cannot dispatch or save local memory without its own approvals")
        try check(remote.name == "synthetic_read" && remote.arguments == .object([:]), "Exact remote proposal retained")
        session.resolveMCPApproval(id: remote.id, approved: true)
        let pending = try await memoryReview(session)
        try check(session.mcpSteps.count == 1 && env.store.memory.memories.isEmpty && session.memoryReceipt == nil,
                  "Actual remote result precedes a separate uncommitted local review")
        try check(pending.quote == utterance && pending.after?.content == text, "Local authority is the current user draft")
        session.resolveMemoryReview(id: pending.id, approved: true)
        await running.value
        let receipt = try memoryReceipt(session), requests = await model.requests
        let calls = await server.calls.count
        try check(session.chatError == nil && session.entries.count == 2 && session.draft.isEmpty,
                  "Mixed remote/local turn delivers a final answer")
        try check(calls == 1 && requests.count == 3 && session.mcpSteps.count == 1,
                  "Local write is not sent to MCP or counted as a remote result")
        try check(env.reopen().memory.memories.first?.id == receipt.id && env.store.notes == [receipt.note],
                  "Local receipt follows durable encrypted memory and preserves undo note")
        try check(requests[1].contains { $0.content.contains("Actual synthetic server result") },
                  "The next model decision receives the actual remote output")
        try check(requests[2].last?.content.contains(receipt.id.uuidString) == true,
                  "The final model request receives the actual committed ID")
        env.store.undo(receipt.note)
        try check(env.reopen().memory.memories.isEmpty, "MCP conversation memory uses the actual durable undo path")
    }

    @MainActor static func mcpProfileReceiptSurvivesRemoteRefusal() async throws {
        let env = try Environment(); defer { try? env.close() }
        let server = LearningMCPServer(), connection = try await connectedMCP(server)
        defer { connection.disconnect() }
        let model = ScriptedModel([.init(proposal), .init(remoteRead)])
        let session = env.session(model), running = try startMCP(session, connection: connection)
        let pending = try await review(session)
        try check(env.store.profile.snapshot().entries.isEmpty && session.profileReceipt == nil,
                  "MCP profile proposal still needs the native profile review")
        session.resolveProfileReview(id: pending.id, approved: true)
        try await until("Remote approval after local commit") { session.pendingMCPApproval != nil || !session.isSubmitting }
        guard let remote = session.pendingMCPApproval else { throw CheckFailure(check: "Later remote approval required") }
        try check(env.reopen().profile.snapshot().entries.first?.text == text && session.profileReceipt != nil,
                  "Profile commit is durable before the later MCP decision")
        session.resolveMCPApproval(id: remote.id, approved: false)
        await running.value
        let calls = await server.calls.count
        try check(calls == 0 && session.mcpSteps.isEmpty, "Remote refusal never dispatches")
        try check(session.profileReceipt != nil && env.reopen().profile.snapshot().entries.first?.text == text,
                  "Later remote refusal cannot erase an already committed profile receipt")
        try check(session.chatError?.contains("已儲存") == true && session.draft == utterance && session.entries.isEmpty,
                  "Post-commit refusal explains saved state and retains the draft")
    }

    @MainActor static func mcpMemorySearchDeleteAndFences() async throws {
        do {
            let env = try Environment(); defer { try? env.close() }
            try check(env.store.mutateMemory { _ = try $0.add(kind: .preference, content: text, keywords: ["jasmine"]) },
                      "Seed through actual manual memory transaction")
            guard let id = env.store.memory.memories.first?.id else { throw CheckFailure(check: "Manual memory ID") }
            let server = LearningMCPServer(), connection = try await connectedMCP(server)
            defer { connection.disconnect() }
            let quote = "Delete Prefer jasmine tea"
            let model = ScriptedModel([.init(try memoryCommand("memory_search", ["query": "jasmine"])),
                                       .init(try memoryEdit(id, quote: quote)), .init(finished)])
            let session = env.session(model), running = try startMCP(session, connection: connection, draft: quote)
            let pending = try await memoryReview(session)
            let requests = await model.requests
            try check(requests.count == 2 && requests[1].last?.content.contains(id.uuidString) == true,
                      "MCP local search returns the actual stable ID before edit review")
            try check(pending.targetID == id && env.reopen().memory.memories.count == 1 && session.pendingMCPApproval == nil,
                      "Search has no remote approval and delete stays uncommitted until local review")
            session.resolveMemoryReview(id: pending.id, approved: true)
            await running.value
            let receipt = try memoryReceipt(session), calls = await server.calls.count
            try check(session.chatError == nil && env.reopen().memory.memories.isEmpty && calls == 0,
                      "Search/delete is local and durably removes the exact memory")
            env.store.undo(receipt.note)
            try check(env.reopen().memory.memories.first?.id == id, "Undo restores the same entry after MCP delete")
        }
        for action in ["decline", "cancel", "disconnect", "masterOff", "generation", "revision", "writeFailure"] {
            let env = try Environment(); defer { try? env.close() }
            let server = LearningMCPServer(), connection = try await connectedMCP(server)
            defer { connection.disconnect() }
            let model = ScriptedModel([.init(try memorySave())])
            let session = env.session(model), running = try startMCP(session, connection: connection)
            let pending = try await memoryReview(session)
            switch action {
            case "decline": session.resolveMemoryReview(id: pending.id, approved: false)
            case "cancel": session.cancel()
            case "disconnect": connection.disconnect()
            case "masterOff":
                try check(env.store.updatePreferences { $0.useMemory = false }, "Disable during MCP local review")
                session.resolveMemoryReview(id: pending.id, approved: true)
            case "generation":
                try check(env.store.clearAll(), "Clear real learning store during MCP review")
                session.resolveMemoryReview(id: pending.id, approved: true)
            case "revision":
                try check(env.store.mutateMemory { _ = try $0.add(kind: .fact, content: "Synthetic concurrent record") },
                          "Concurrent memory revision during MCP review")
                session.resolveMemoryReview(id: pending.id, approved: true)
            default:
                try env.blockWrite()
                session.resolveMemoryReview(id: pending.id, approved: true)
            }
            let before = env.store.memory
            await running.value
            if action == "writeFailure" { try env.restoreWrite() }
            session.resolveMemoryReview(id: pending.id, approved: true)
            let calls = await server.calls.count, requests = await model.requests.count
            try check(session.memoryReceipt == nil && session.pendingMemoryReview == nil && !session.isSubmitting,
                      action + " never publishes a local receipt or retains its continuation")
            try check(env.store.memory == before && env.reopen().memory == before,
                      action + " cannot change durable memory after invalidation")
            try check(calls == 0 && requests == 1 && session.entries.isEmpty && session.draft == utterance,
                      action + " neither dispatches a remote call nor invents a completed answer")
        }
    }

    @MainActor static func mcpLocalAuthorityAndLimits() async throws {
        for disabled in [true, false] {
            let env = try Environment(); defer { try? env.close() }
            if disabled { try check(env.store.updatePreferences { $0.useMemory = false }, "Disable before MCP turn") }
            let server = LearningMCPServer(), connection = try await connectedMCP(server)
            defer { connection.disconnect() }
            let duplicate = #"{"action":"memory_save","arguments":{"kind":"preference","content":"Prefer jasmine tea","content":"Prefer jasmine tea","quote":"Please remember Prefer jasmine tea"}}"#
            let model = ScriptedModel([.init(disabled ? try memorySave() : duplicate)])
            let session = env.session(model), running = try startMCP(session, connection: connection)
            await running.value
            let requests = await model.requests, calls = await server.calls.count
            try check(session.chatError != nil && session.pendingMemoryReview == nil && session.memoryReceipt == nil,
                      "Disabled or duplicate-key local command stops before review/receipt")
            try check(env.reopen().memory.memories.isEmpty && calls == 0 && requests.count == 1,
                      "Disabled/duplicate command never writes, dispatches or repairs permission")
            if disabled {
                try check(requests.first?.first?.content.contains("Separately, the host offers local") == false,
                          "Disabled memory does not advertise local tools")
            }
        }
        do {
            let env = try Environment(); defer { try? env.close() }
            let server = LearningMCPServer(resultText: utterance), connection = try await connectedMCP(server)
            defer { connection.disconnect() }
            let model = ScriptedModel([.init(remoteRead), .init(try memorySave())])
            let session = env.session(model), running = try startMCP(session, connection: connection, draft: "Read the selected service")
            try await until("Read untrusted result approval") { session.pendingMCPApproval != nil || !session.isSubmitting }
            guard let remote = session.pendingMCPApproval else { throw CheckFailure(check: "Read approval required") }
            session.resolveMCPApproval(id: remote.id, approved: true)
            await running.value
            try check(session.mcpSteps.count == 1 && session.chatError != nil && session.memoryReceipt == nil,
                      "Actual remote text cannot become the user's memory permission")
            try check(session.pendingMemoryReview == nil && env.reopen().memory.memories.isEmpty,
                      "Counterfeit quote is rejected before review and disk write")
        }
        do {
            let env = try Environment(); defer { try? env.close() }
            let server = LearningMCPServer(), connection = try await connectedMCP(server)
            defer { connection.disconnect() }
            let model = ScriptedModel([.init(proposal), .init(try memorySave())])
            let session = env.session(model), running = try startMCP(session, connection: connection)
            let pending = try await review(session)
            session.resolveProfileReview(id: pending.id, approved: true)
            await running.value
            try check(session.profileReceipt != nil && session.memoryReceipt == nil && session.pendingMemoryReview == nil,
                      "Profile and memory cannot each consume a separate mutation allowance")
            try check(env.reopen().profile.snapshot().entries.first?.text == text && env.reopen().memory.memories.isEmpty,
                      "Only the approved first mutation is durable when the second is blocked")
            try check(session.chatError?.contains("已儲存") == true && session.entries.isEmpty,
                      "Shared local mutation limit retains the prior committed receipt")
        }
    }
    @MainActor static func hostJSON(_ messages: [ModelMessage], prefix: String) throws -> [String: Any] {
        guard let body = messages.last?.content, body.hasPrefix(prefix + "\n"),
              let value = try JSONSerialization.jsonObject(with: Data(body.dropFirst(prefix.count + 1).utf8)) as? [String: Any]
        else { throw CheckFailure(check: "Actual host result has expected JSON envelope") }
        return value
    }
    @MainActor static func approveMemory(_ session: ChatSession, task running: Task<Void, Never>) async throws -> MemoryToolReceipt {
        let pending = try await memoryReview(session)
        session.resolveMemoryReview(id: pending.id, approved: true)
        await running.value
        try check(session.chatError == nil && session.pendingMemoryReview == nil && session.draft.isEmpty,
                  "Approved ordinary memory turn completes without an error")
        return try memoryReceipt(session)
    }

    @MainActor static func memorySaveSearchEditUndo() async throws {
        let env = try Environment(); defer { try? env.close() }
        try check(!env.store.memory.preferences.autoRemember && env.store.memory.preferences.useMemory,
                  "Explicit ordinary tools are exercised with automatic extraction off")
        let gate = ModelGate(), model = ScriptedModel([.init(try memorySave()), .init(finished, gate: gate)])
        let session = env.session(model), bytes = try env.bytes()
        var publications = 0, durable = false
        let subscription = session.$memoryReceipt.compactMap { $0 }.sink { receipt in
            publications += 1
            durable = env.reopen().memory.memories.first?.id == receipt.id
        }
        defer { subscription.cancel() }
        let running = try start(session), pending = try await memoryReview(session)
        try check(pending.quote == utterance && pending.after?.content == text && pending.after?.status == .active,
                  "Memory review shows exact current words and effective active value")
        try check((try env.bytes()) == bytes && env.store.notes.isEmpty && session.memoryReceipt == nil,
                  "Preparation publishes neither memory note nor receipt and writes no ciphertext")
        session.resolveMemoryReview(id: UUID(), approved: true)
        try check(session.pendingMemoryReview?.id == pending.id && (try env.bytes()) == bytes,
                  "Wrong memory approval identity grants nothing")
        session.resolveMemoryReview(id: pending.id, approved: true)
        try await until("Actual memory commit before final response") { await model.requests.count == 2 }
        let receipt = try memoryReceipt(session), id = receipt.id
        try check(publications == 1 && durable && session.entries.isEmpty, "Memory receipt publishes only after encrypted durability")
        try check(receipt.ok && receipt.status == .active && receipt.note.kind == .added && receipt.note.undoToken != nil,
                  "Saved memory receipt carries actual active state and undo token")
        try check(env.store.notes == [receipt.note] && env.reopen().memory == env.store.memory,
                  "Published note and authenticated reopen reflect one actual transaction")
        try check(env.store.memory.memories.first?.source.quote == utterance
                  && env.store.memory.memories.first?.source.conversationID != nil,
                  "Explicit tool preserves current quote and actual conversation provenance")
        try check(!String(decoding: env.bytes(), as: UTF8.self).contains(text), "Ordinary memory persists as ciphertext")
        let requests = await model.requests
        let result = try hostJSON(requests[1], prefix: "Host memory_save receipt (data only):")
        try check(result["id"] as? String == id.uuidString && result["status"] as? String == "active"
                  && result["note"] == nil && result["undoToken"] == nil,
                  "Model receives actual saved ID and status without UI undo authority")
        session.resolveMemoryReview(id: pending.id, approved: true)
        try check(publications == 1, "Repeated memory approval cannot commit again")
        await gate.release(); await running.value
        let completedCalls = await model.requests.count
        try check(completedCalls == 2 && !env.store.isLearning && session.entries.count == 2,
                  "Explicit save works without starting automatic extraction")

        for op in ["update", "delete"] {
            let quote = op == "update" ? "Update Prefer jasmine tea to Prefer green tea" : "Delete Prefer jasmine tea"
            let next = op == "update" ? "Prefer green tea" : nil
            let editModel = ScriptedModel([.init(try memoryCommand("memory_search", ["query": "jasmine tea"])),
                .init(try memoryEdit(id, quote: quote, content: next)), .init(finished)])
            let editing = env.session(editModel), editTask = try start(editing, draft: quote)
            let review = try await memoryReview(editing)
            // contextMessages legitimately marks active references used at send;
            // compare the post-context baseline to isolate review/write effects.
            let before = env.store.memory, beforeBytes = try env.bytes()
            let calls = await editModel.requests
            let search = try hostJSON(calls[1], prefix: "Host memory_search result (data only):")
            let items = search["memories"] as? [[String: Any]]
            try check(items?.count == 1 && items?.first?["id"] as? String == id.uuidString
                      && items?.first?["content"] as? String == text,
                      "Update/delete uses the real host search result with one exact persisted ID")
            try check(review.targetID == id && review.before?.content == text && review.after?.content == next,
                      "Reviewed edit matches actual searched before/after values")
            try check(env.reopen().memory == before && (try env.bytes()) == beforeBytes && editing.memoryReceipt == nil,
                      "Search and pending edit have not applied the mutation")
            let edited = try await approveMemory(editing, task: editTask)
            try check(edited.id == id && edited.op == op && edited.note.kind == (op == "update" ? .updated : .forgot),
                      "Edit receipt preserves stable target identity and exact operation")
            try check(env.reopen().memory.memories.first?.content == next && env.store.notes == [edited.note],
                      "Actual edited/deleted state and undo card follow encrypted transaction")
            let finalCalls = await editModel.requests
            let editReceipt = try hostJSON(finalCalls[2], prefix: "Host memory_edit receipt (data only):")
            try check(finalCalls.count == 3 && editReceipt["id"] as? String == id.uuidString
                      && editReceipt["op"] as? String == op, "Search/edit/final answer uses exactly three real calls")
            let undoNote: MemoryNote
            if op == "delete" {
                try check(editReceipt["deleted"] as? Bool == true, "Deletion has an actual deletion receipt")
                let previousPreference = env.store.memory.preferences.learnSkills
                try check(env.store.updatePreferences { $0.learnSkills = !previousPreference },
                          "Persist unrelated preference change after actual tool deletion")
                try check(env.reopen().memory.memories.isEmpty
                          && env.reopen().memory.preferences.learnSkills == !previousPreference,
                          "Preference transaction preserves deletion and persists the changed preference")
                try check(env.store.notes.contains(edited.note),
                          "Preference change must retain deleted memory undo card despite absent record ID")
                guard let visibleNote = env.store.notes.first(where: { $0.undoToken == edited.note.undoToken }) else {
                    throw CheckFailure(check: "Deletion undo must remain reachable from actual published notes")
                }
                undoNote = visibleNote
            } else { undoNote = edited.note }
            env.store.undo(undoNote)
            try check(env.store.error == nil && env.reopen().memory.memories.first?.content == text
                      && env.reopen().memory.memories.first?.id == id, "Actual App undo durably restores the exact original record")
            try check(env.store.notes.isEmpty, "Successful undo removes its presentation card")
            let undoneBytes = try env.bytes()
            env.store.undo(edited.note)
            try check((try env.bytes()) == undoneBytes && env.store.error != nil, "Replayed undo cannot change the restored record")
        }
        try check(env.reopen().profile.entries.isEmpty && env.reopen().skills == env.store.skills,
                  "Ordinary memory tools preserve sibling encrypted profile and skill state")
    }

    @MainActor static func memoryProcedureReview() async throws {
        for accept in [false, true] {
            let env = try Environment(); defer { try? env.close() }
            let content = "整理資料先列來源", quote = "以後整理資料先列來源"
            let session = env.session(ScriptedModel([.init(try memorySave(content, quote: quote, kind: "procedure")), .init(finished)]))
            let receipt = try await approveMemory(session, task: start(session, draft: quote))
            try check(receipt.status == .pending && receipt.note.pendingID == receipt.id && env.store.canReviewMemory(receipt.note),
                      "Approving a procedure write leaves a separately reviewable pending procedure")
            try check(env.reopen().memory.memories.first?.status == .pending
                      && env.store.memory.context(goal: content).usedIDs.isEmpty,
                      "Encrypted pending procedure is excluded from model context")
            if !accept {
                env.store.rejectPendingMemory(receipt.note)
                try check(env.store.error == nil && env.reopen().memory.memories.isEmpty && env.store.notes.isEmpty,
                          "Rejecting a newly written procedure durably removes it")
                continue
            }
            env.store.approvePendingMemory(receipt.note)
            try check(env.reopen().memory.memories.first?.status == .active && env.store.notes.isEmpty,
                      "Separate procedure approval activates and persists it")
            try check(env.store.memory.context(goal: content).usedIDs == [receipt.id], "Only approved procedure enters future context")
            for reapprove in [false, true] {
                let updated = "整理資料先核對來源", updateQuote = "更新為整理資料先核對來源"
                let model = ScriptedModel([.init(try memoryCommand("memory_search", ["query": "整理資料"])),
                    .init(try memoryEdit(receipt.id, quote: updateQuote, content: updated)), .init(finished)])
                let editing = env.session(model)
                let changed = try await approveMemory(editing, task: start(editing, draft: updateQuote))
                try check(changed.status == .pending && env.store.canReviewMemory(changed.note)
                          && env.reopen().memory.memories.first?.status == .pending,
                          "Tool update of an active procedure requires separate reapproval")
                try check(env.store.memory.context(goal: updated).usedIDs.isEmpty,
                          "Updated procedure cannot enter context while reapproval is pending")
                if reapprove { env.store.approvePendingMemory(changed.note) }
                else { env.store.rejectPendingMemory(changed.note) }
                try check(env.store.error == nil && env.reopen().memory.memories.first?.id == receipt.id
                          && env.reopen().memory.memories.first?.content == (reapprove ? updated : content)
                          && env.reopen().memory.memories.first?.status == .active,
                          "Reapproval persists new procedure; rejection restores the earlier approved procedure")
                try check(env.store.notes.isEmpty, "Resolved procedure review removes its pending card")
            }
        }
    }

    @MainActor static func memoryRefusalAndFences() async throws {
        for action in ["decline", "cancel", "background", "masterOff", "generation", "revision"] {
            let env = try Environment(); defer { try? env.close() }
            let model = ScriptedModel([.init(try memorySave())]), session = env.session(model)
            let running = try start(session), pending = try await memoryReview(session)
            switch action {
            case "decline": session.resolveMemoryReview(id: pending.id, approved: false)
            case "cancel": session.cancel()
            case "background": session.invalidateProfileReview()
            case "masterOff":
                env.store.onUserChange = { [weak session] in session?.invalidateProfileReview() }
                try check(env.store.updatePreferences { $0.useMemory = false }, "Memory master off persists during pending review")
            case "generation":
                env.store.cancelLearning(); session.resolveMemoryReview(id: pending.id, approved: true)
            default:
                // A second real transaction advances revision without changing
                // generation, so this specifically exercises the revision gate.
                let otherQuote = "Remember Prefer quiet hotels"
                let other = try MemoryToolRun(state: env.store.memory, utterances: [otherQuote]).prepare(
                    toolName: "memory_save", argumentsJSON: #"{"kind":"preference","content":"Prefer quiet hotels","quote":"Remember Prefer quiet hotels"}"#)
                _ = try env.store.commitMemoryTool(other, expectedGeneration: env.store.generation, conversationID: "synthetic-concurrent")
                session.resolveMemoryReview(id: pending.id, approved: true)
            }
            let before = env.store.memory, bytes = try env.bytes(), notes = env.store.notes
            await running.value
            session.resolveMemoryReview(id: pending.id, approved: true)
            try check(session.memoryReceipt == nil && session.pendingMemoryReview == nil && !session.isSubmitting,
                      action + " rejects ordinary memory commit and clears continuation")
            try check(env.store.memory == before && env.reopen().memory == before && (try env.bytes()) == bytes && env.store.notes == notes,
                      action + " cannot write or overwrite concurrent memory/notes")
            try check(session.entries.isEmpty && session.draft == utterance,
                      action + " keeps actual draft without inventing a final answer")
            let calls = await model.requests.count
            try check(calls == 1, action + " emits no fabricated host receipt or continuation call")
        }
        let env = try Environment(); defer { try? env.close() }
        let run = MemoryToolRun(state: env.store.memory, utterances: [utterance])
        let prepared = try run.prepare(toolName: "memory_save", argumentsJSON:
            #"{"kind":"preference","content":"Prefer jasmine tea","quote":"Please remember Prefer jasmine tea"}"#)
        let generation = env.store.generation
        _ = try env.store.commitMemoryTool(prepared, expectedGeneration: generation, conversationID: "synthetic")
        let saved = env.store.memory, bytes = try env.bytes()
        do {
            _ = try env.store.commitMemoryTool(prepared, expectedGeneration: generation, conversationID: "synthetic")
            throw CheckFailure(check: "Memory transaction replay must reject")
        } catch let error as MemoryToolError { try check(error == .staleRevision, "Actual transaction rejects replayed memory revision") }
        try check(env.reopen().memory == saved && (try env.bytes()) == bytes, "Replayed memory transaction leaves disk unchanged")
        try check(env.store.updatePreferences { $0.useMemory = false }, "Disable memory for independent commit gate")
        let disabled = try env.bytes()
        do {
            _ = try env.store.commitMemoryTool(prepared, expectedGeneration: env.store.generation, conversationID: "synthetic")
            throw CheckFailure(check: "Disabled memory transaction must reject")
        } catch let error as MemoryToolError { try check(error == .disabled, "Commit checks master switch even with current generation") }
        try check((try env.bytes()) == disabled, "Disabled direct transaction writes no ciphertext")
    }

    @MainActor static func memorySearchGrounding() async throws {
        for scenario in ["noSearch", "guessedID", "emptySearch", "negatedEdit", "foreignQuote"] {
            let env = try Environment(); defer { try? env.close() }
            try check(env.store.mutateMemory { _ = try $0.add(kind: .preference, content: text) }, "Seed one real encrypted search candidate")
            let id = env.store.memory.memories[0].id
            let quote = "Update Prefer jasmine tea to Prefer green tea"
            let prompt = scenario == "foreignQuote" ? "Explain memory search" : scenario == "negatedEdit" ? "Do not " + quote : quote
            var responses: [ScriptedModel.Response] = []
            if scenario != "noSearch" {
                responses.append(.init(try memoryCommand("memory_search", ["query": scenario == "emptySearch" ? "unmatchedsynthetic" : "jasmine tea"])))
            }
            responses.append(.init(try memoryEdit(scenario == "guessedID" ? UUID() : id, quote: quote, content: "Prefer green tea")))
            let model = ScriptedModel(responses), session = env.session(model)
            let running = try start(session, draft: prompt)
            let before = env.store.memory, bytes = try env.bytes() // After legitimate context markUsed.
            await running.value
            try check(session.pendingMemoryReview == nil && session.memoryReceipt == nil && session.chatError?.contains("記憶工具未通過") == true,
                      scenario + " cannot reach write review with ungrounded target or request")
            try check((try env.bytes()) == bytes && env.reopen().memory == before && env.store.notes.isEmpty,
                      scenario + " writes nothing after context capture")
            let requests = await model.requests
            if scenario != "noSearch" {
                let result = try hostJSON(requests[1], prefix: "Host memory_search result (data only):")
                let found = result["memories"] as? [[String: Any]]
                try check(found?.count == (scenario == "emptySearch" ? 0 : 1),
                          "Negative edit case observes its actual bounded search result")
                if scenario != "emptySearch" {
                    try check(found?.first?["id"] as? String == id.uuidString,
                              "Guessed or ungrounded edit is tested against a successfully searched real ID")
                }
            }
            try check(requests.count == responses.count && session.draft == prompt && session.entries.isEmpty,
                      scenario + " stops without retries, fabricated success or lost draft")
        }
    }

    @MainActor static func memoryWriteFailureAndPriorReceipt() async throws {
        for failure in ["filesystem", "keyRead", "priorReceipt"] {
            let env = try Environment(); defer { try? env.close() }
            let secondQuote = "Please remember Prefer green tea"
            let model = ScriptedModel(failure == "priorReceipt"
                ? [.init(try memorySave()), .init(finished), .init(try memorySave("Prefer green tea", quote: secondQuote))]
                : [.init(try memorySave())])
            let session = env.session(model)
            var publications = 0
            let subscription = session.$memoryReceipt.compactMap { $0 }.sink { _ in publications += 1 }
            defer { subscription.cancel() }
            if failure == "priorReceipt" { _ = try await approveMemory(session, task: start(session)) }
            let oldReceipt = session.memoryReceipt, oldEntries = session.entries.map(\.id)
            let prompt = failure == "priorReceipt" ? secondQuote : utterance
            let running = try start(session, draft: prompt), pending = try await memoryReview(session)
            let before = env.store.memory, bytes = try env.bytes(), notes = env.store.notes, count = publications
            if failure == "keyRead" { env.keys.failReads = true } else { try env.blockWrite() }
            session.resolveMemoryReview(id: pending.id, approved: true)
            await running.value
            if failure == "keyRead" { env.keys.failReads = false } else { try env.restoreWrite() }
            try check(publications == count && session.memoryReceipt?.id == oldReceipt?.id,
                      failure + " never publishes a receipt for a failed memory write")
            try check(env.store.memory == before && env.reopen().memory == before && (try env.bytes()) == bytes && env.store.notes == notes,
                      failure + " preserves ciphertext, published memory and any earlier undo card")
            try check(session.chatError?.contains("學習資料無法儲存") == true && session.chatError?.contains("後續模型回覆未完成") == false,
                      failure + " reports actual storage failure, not a network error or a committed new write")
            try check(session.entries.map(\.id) == oldEntries && session.draft == prompt && session.pendingMemoryReview == nil,
                      failure + " retains draft/history and cleans up review")
            let calls = await model.requests.count
            try check(calls == (failure == "priorReceipt" ? 3 : 1), failure + " emits no continuation receipt after failed persistence")
        }
    }

    @MainActor static func memoryPostCommitAndLateCancellation() async throws {
        for action in ["disconnect", "cancel"] {
            let env = try Environment(); defer { try? env.close() }
            let gate = ModelGate(), model = ScriptedModel([.init(try memorySave()), .init(nil, gate: gate)])
            let session = env.session(model), running = try start(session), pending = try await memoryReview(session)
            session.resolveMemoryReview(id: pending.id, approved: true)
            try await until("Memory receipt committed before disconnected final reply") { await model.requests.count == 2 }
            let receipt = try memoryReceipt(session), bytes = try env.bytes()
            if action == "cancel" { session.cancel() }
            await gate.release(); await running.value
            try check(session.memoryReceipt?.id == receipt.id && env.store.notes == [receipt.note] && (try env.bytes()) == bytes,
                      action + " after commit preserves real saved memory receipt and undo card")
            try check(env.reopen().memory.memories.map(\.content) == [text] && session.entries.isEmpty && session.draft == utterance,
                      action + " preserves one durable memory without fabricating a completed reply")
            if action == "disconnect" {
                try check(session.chatError?.contains("記憶修改已儲存") == true, "Post-commit memory error acknowledges actual saved side effect")
            }
            env.store.undo(receipt.note)
            try check(env.store.error == nil && env.reopen().memory.memories.isEmpty, "Post-commit disconnect/cancel still permits real durable undo")
        }
        for phase in ["beforeSearch", "afterSearch", "beforeSave"] {
            let env = try Environment(); defer { try? env.close() }
            try check(env.store.mutateMemory { _ = try $0.add(kind: .preference, content: text) }, "Seed late-response memory candidate")
            let gate = ModelGate(), id = env.store.memory.memories[0].id
            let quote = "Update Prefer jasmine tea to Prefer green tea"
            let search = try memoryCommand("memory_search", ["query": "jasmine tea"])
            let responses: [ScriptedModel.Response]
            if phase == "beforeSave" { responses = [.init(try memorySave("Prefer green tea", quote: quote), gate: gate)] }
            else if phase == "beforeSearch" { responses = [.init(search, gate: gate)] }
            else { responses = [.init(search), .init(try memoryEdit(id, quote: quote, content: "Prefer green tea"), gate: gate)] }
            let model = ScriptedModel(responses), session = env.session(model), running = try start(session, draft: quote)
            try await until("Delayed memory response reached actual client") { await model.requests.count == responses.count }
            let before = env.store.memory, bytes = try env.bytes()
            session.cancel()
            await gate.release(); await running.value // Join the original task, not just isSubmitting.
            try check(session.pendingMemoryReview == nil && session.memoryReceipt == nil && session.entries.isEmpty && session.draft == quote,
                      phase + " late response cannot resurrect a cancelled memory flow")
            try check(env.reopen().memory == before && (try env.bytes()) == bytes && env.store.notes.isEmpty,
                      phase + " late response cannot write or publish a note")
            let calls = await model.requests.count
            try check(calls == responses.count, phase + " cancellation prevents any following model call")
        }
    }

    @MainActor static func memoryNotesThroughExtraction() async throws {
        for outcome in ["newMemory", "empty", "failure", "cancel"] {
            let env = try Environment(); defer { try? env.close() }
            try check(env.store.updatePreferences { $0.autoRemember = true }, "Enable actual background extraction")
            let quote = "我喜歡喝茶，也喜歡散步", content = "我喜歡喝茶"
            let extracted = #"{"ops":[{"op":"add","kind":"preference","content":"我喜歡散步","quote":"喜歡散步"}]}"#
            let gate = ModelGate()
            let reply = outcome == "failure" ? nil : outcome == "empty" ? #"{"ops":[]}"# : extracted
            let model = ScriptedModel([.init(try memorySave(content, quote: quote)), .init(finished), .init(reply, gate: gate)])
            let session = env.session(model)
            let receipt = try await approveMemory(session, task: start(session, draft: quote))
            try await until("Actual background extractor started") { await model.requests.count == 3 }
            guard let extraction = Mirror(reflecting: env.store).children.first(where: { $0.label == "extraction" })?.value as? Task<Void, Never> else {
                throw CheckFailure(check: "Observe actual background extraction task")
            }
            let before = env.store.memory, bytes = try env.bytes()
            try check(env.store.isLearning && env.store.notes == [receipt.note], "Tool undo card exists while actual extraction is pending")
            if outcome == "cancel" { env.store.cancelLearning() }
            await gate.release(); await extraction.value
            try check(!env.store.isLearning && session.memoryReceipt?.id == receipt.id && session.entries.count == 2,
                      outcome + " extraction cannot erase actual chat receipt or delivered reply")
            try check(env.store.notes.contains(receipt.note), outcome + " background extraction preserves reviewed tool undo card")
            if outcome == "newMemory" {
                try check(env.reopen().memory.memories.map(\.content) == [content, "我喜歡散步"] && env.store.notes.count == 2,
                          "Actual extractor adds a different durable record without replacing the tool card")
            } else {
                try check(env.reopen().memory == before && (try env.bytes()) == bytes && env.store.notes == [receipt.note],
                          outcome + " extraction leaves committed memory and ciphertext unchanged")
            }
            let calls = await model.requests
            try check(calls.count == 3 && calls[2].count == 2 && calls[2][0].content.hasPrefix("Propose durable personal memories"),
                      "Third call is the actual separate MemoryExtractor, not a fabricated tool continuation")
            env.store.undo(receipt.note)
            try check(env.store.error == nil && env.reopen().memory.memories.map(\.content) == (outcome == "newMemory" ? ["我喜歡散步"] : []),
                      outcome + " original tool undo remains effective after background extraction")
        }
    }

    #if DEBUG
    @MainActor static func actualUIFixtureMCPLearning() async throws {
        let env = try Environment(); defer { try? env.close() }
        let client = RecordingUIModel()
        let connection = MCPSession(repository: SyntheticMCPEndpoint(), clientFactory: { _ in UITestMCPFixture() })
        connection.connect()
        try await until("Actual MCP UI fixture discovery") { !connection.isBusy }
        try check(connection.phase == .connected, "Actual fixture discovers its real selected catalog")
        connection.selectTool("fixture_echo", enabled: true)
        defer { connection.disconnect() }
        let prompt = "[fixture:mcp-memory] Remember preference Prefer jasmine tea"
        let session = env.session(client), running = try startMCP(session, connection: connection, draft: prompt)
        try await until("Actual fixture remote proposal") { session.pendingMCPApproval != nil || !session.isSubmitting }
        guard let remote = session.pendingMCPApproval else { throw CheckFailure(check: "Actual fixture remote review") }
        try check(remote.name == "fixture_echo" && remote.arguments == .object(["text": .string("hello")]),
                  "Actual fixture remote arguments are unchanged")
        session.resolveMCPApproval(id: remote.id, approved: true)
        let pending = try await memoryReview(session)
        try check(pending.quote == prompt && pending.after?.content == text && pending.keywords == ["jasmine", "tea"],
                  "Actual mixed fixture memory quote/content/keywords match UI contract")
        try check(env.reopen().memory.memories.isEmpty, "Actual fixture does not seed or save before review")
        session.resolveMemoryReview(id: pending.id, approved: true)
        await running.value
        let receipt = try memoryReceipt(session), requests = await client.requests
        try check(session.chatError == nil && session.entries.last?.content == "MCP 記憶流程已完成。",
                  "Actual fixture final answer requires a committed receipt")
        try check(requests.count == 3 && session.mcpSteps.count == 1 && env.reopen().memory.memories.first?.id == receipt.id,
                  "Actual mixed fixture passed real remote execution and encrypted local transaction")
        env.store.undo(receipt.note)
        try check(env.reopen().memory.memories.isEmpty, "Actual fixture memory undo persists")
    }

    @MainActor static func actualUIFixtureMemoryEdits() async throws {
        let env = try Environment(); defer { try? env.close() }
        let client = RecordingUIModel(), session = env.session(client)
        let cases: [(String, MemoryToolOperation, String, String?, Bool, [String])] = [
            ("Remember preference Prefer jasmine tea", .add, "Prefer jasmine tea", text, true, [text]),
            ("Remember preference Prefer quiet", .add, "Prefer quiet", "Prefer quiet", false, [text]),
            ("Update Prefer jasmine tea to Prefer coffee", .update, "Update Prefer jasmine tea to Prefer coffee", "Prefer coffee", true, ["Prefer coffee"]),
            ("Delete Prefer coffee", .delete, "Delete Prefer coffee", nil, true, []),
        ]
        var savedID: UUID?
        for (prompt, operation, quote, replacement, approved, expected) in cases {
            let callOffset = await client.requests.count
            let oldReceipt = session.memoryReceipt
            let running = try start(session, draft: prompt), pending = try await memoryReview(session)
            let before = env.store.memory, bytes = try env.bytes(), notes = env.store.notes
            try check(pending.op == operation && pending.quote == quote && pending.after?.content == replacement,
                      "Actual memory UI fixture supplies exact operation, quote and proposed content")
            try check(env.reopen().memory == before && (try env.bytes()) == bytes
                      && session.memoryReceipt?.id == oldReceipt?.id && env.store.notes == notes,
                      "Actual fixture proposal cannot write or publish before approval")
            if operation != .add {
                let requests = await client.requests
                let found = try hostJSON(requests[callOffset + 1], prefix: "Host memory_search result (data only):")
                let items = found["memories"] as? [[String: Any]]
                try check(items?.count == 1 && items?.first?["id"] as? String == savedID?.uuidString
                          && pending.targetID == savedID && pending.before?.content == before.memories.first?.content,
                          "Actual fixture edit ID comes from the sole real host search result")
            }
            session.resolveMemoryReview(id: pending.id, approved: approved)
            await running.value
            try check(env.reopen().memory.memories.map(\.content) == expected,
                      "Actual memory fixture operation survives authenticated encrypted reopen")
            let requests = await client.requests
            if approved {
                let receipt = try memoryReceipt(session)
                if operation == .add { savedID = receipt.id }
                try check(receipt.id == savedID && env.store.notes == [receipt.note]
                          && session.entries.last?.content == "記憶工具已完成。" && session.chatError == nil && session.draft.isEmpty,
                          "Actual fixture final answer follows one real durable receipt and undo card")
                let tool = operation == .add ? "memory_save" : "memory_edit"
                let result = try hostJSON(requests.last!, prefix: "Host " + tool + " receipt (data only):")
                try check(result["id"] as? String == savedID?.uuidString
                          && requests.count - callOffset == (operation == .add ? 2 : 3),
                          "Actual fixture continuation uses the committed ID with bounded search/write/final calls")
                if operation == .update {
                    try check(env.reopen().memory.memories.first?.keywords == ["coffee"],
                              "Actual update fixture persists its grounded replacement keywords")
                }
                if operation == .delete {
                    guard let card = env.store.notes.first(where: { $0.undoToken == receipt.note.undoToken }) else {
                        throw CheckFailure(check: "Actual fixture deletion has a user-reachable undo card")
                    }
                    env.store.undo(card)
                    try check(env.store.error == nil && env.reopen().memory.memories.first?.id == savedID
                              && env.reopen().memory.memories.first?.content == "Prefer coffee" && env.store.notes.isEmpty,
                              "Actual fixture deletion can be durably undone through its published card")
                }
            } else {
                try check((try env.bytes()) == bytes && env.store.notes == notes
                          && session.memoryReceipt?.id == oldReceipt?.id && session.chatError?.contains("拒絕") == true,
                          "Actual fixture refusal preserves existing encrypted data, receipt and undo card")
                try check(requests.count - callOffset == 1 && session.draft == prompt,
                          "Actual refusal emits no committed receipt or final model call")
            }
        }
        for approveProcedure in [false, true] {
            let fresh = try Environment(); defer { try? fresh.close() }
            let model = RecordingUIModel(), other = fresh.session(model)
            let prompt = "Remember procedure Check invoices before paying", content = "Check invoices before paying"
            let running = try start(other, draft: prompt), pending = try await memoryReview(other), bytes = try fresh.bytes()
            try check(pending.quote == content && pending.kind == .procedure && pending.after?.status == .pending
                      && fresh.store.notes.isEmpty && fresh.reopen().memory.memories.isEmpty,
                      "Actual procedure fixture proposes a separately pending procedure without implicit approval")
            try check((try fresh.bytes()) == bytes, "Actual procedure review does not write the vault")
            other.resolveMemoryReview(id: pending.id, approved: true)
            await running.value
            let receipt = try memoryReceipt(other)
            try check(receipt.status == .pending && fresh.reopen().memory.memories.first?.content == content
                      && fresh.store.canReviewMemory(receipt.note) && fresh.store.memory.context(goal: content).usedIDs.isEmpty,
                      "Actual fixture write approval persists pending procedure excluded from future context")
            try check(other.entries.last?.content == "記憶工具已完成。" && other.chatError == nil,
                      "Actual procedure fixture final answer follows durable write receipt")
            if approveProcedure { fresh.store.approvePendingMemory(receipt.note) }
            else { fresh.store.rejectPendingMemory(receipt.note) }
            try check(fresh.store.error == nil && fresh.store.notes.isEmpty,
                      "Actual procedure separate approval/refusal resolves its pending card")
            try check(fresh.reopen().memory.memories.map(\.content) == (approveProcedure ? [content] : [])
                      && fresh.store.memory.context(goal: content).usedIDs == (approveProcedure ? [receipt.id] : []),
                      "Actual fixture procedure becomes usable only after separate approval; rejection removes it")
            let requests = await model.requests
            try check(requests.count == 2, "Procedure approval/refusal adds no fabricated fixture model calls")
        }
    }

    @MainActor static func actualUIFixtureEdits() async throws {
        let env = try Environment(); defer { try? env.close() }
        let session = env.session(UITestChatModelClient())
        let cases: [(String, UserProfileToolOperation, Bool, [String])] = [
            ("Remember Prefer tea", .add, true, ["Prefer tea"]),
            ("Remember Prefer quiet", .add, false, ["Prefer tea"]),
            ("Replace Prefer tea with Prefer walks", .replace, true, ["Prefer walks"]),
            ("Delete Prefer walks", .delete, true, []),
        ]
        for (prompt, operation, approved, expected) in cases {
            let before = env.store.profile, bytes = try env.bytes()
            let running = try start(session, draft: prompt), pending = try await review(session)
            try check(pending.op == operation && pending.quote == prompt, "Exact real UI fixture proposal and current utterance")
            try check(env.store.profile == before && (try env.bytes()) == bytes, "UI fixture itself never writes before approval")
            session.resolveProfileReview(id: pending.id, approved: approved)
            await running.value
            try check(env.reopen().profile.snapshot().entries.map(\.text) == expected, "Actual fixture operation survives encrypted reopen")
            if approved {
                try check(session.profileReceipt?.applied == true && session.entries.last?.content == "個人檔案工具已完成。",
                          "Fixture resumes only after actual approved transaction")
            } else {
                try check((try env.bytes()) == bytes && session.chatError?.contains("拒絕") == true,
                          "Fixture refusal preserves data and is not confused by previous receipt")
            }
        }
        try check(env.store.profile.entries.count == 2 && env.store.profile.entries.allSatisfy { $0.status == .superseded },
                  "Fixture replace/delete retain the actual profile history")
        try check(session.profileReceipt != nil && session.profileReceipt?.id == nil,
                  "Delete still publishes successful receipt without a new entry ID")
    }
    #endif

    #if PROFILE_CHAT_APP_STANDALONE
    @MainActor static func main() async {
        do {
            try await group("encryptedTransaction", transactionChecks)
            try await group("approvalAndDurableReceipt", approveAndReceipt)
            try await group("refusalCancellationAndCommitFences", deniedOrCancelled)
            try await group("lateProposals", lateProposals)
            try await group("actualWriteFailure", failedWrites)
            try await group("postCommitFailure", postCommitFailure)
            try await group("groundingAndOrdinaryChat", groundingAndOrdinary)
            try await group("priorReceiptAndFailedNewWrite", priorReceiptAndFailedNewWrite)
            try await group("twentyTurnContextWindow", twentyTurnContextWindow)
            try await group("memorySaveSearchEditUndo", memorySaveSearchEditUndo)
            try await group("memoryProcedureReview", memoryProcedureReview)
            try await group("memoryRefusalAndFences", memoryRefusalAndFences)
            try await group("memorySearchGrounding", memorySearchGrounding)
            try await group("memoryWriteFailureAndPriorReceipt", memoryWriteFailureAndPriorReceipt)
            try await group("memoryPostCommitAndLateCancellation", memoryPostCommitAndLateCancellation)
            try await group("memoryNotesThroughExtraction", memoryNotesThroughExtraction)
            try await group("mcpMemoryAndRemoteApprovals", mcpMemoryAndRemoteApprovals)
            try await group("mcpProfileReceiptSurvivesRemoteRefusal", mcpProfileReceiptSurvivesRemoteRefusal)
            try await group("mcpMemorySearchDeleteAndFences", mcpMemorySearchDeleteAndFences)
            try await group("mcpLocalAuthorityAndLimits", mcpLocalAuthorityAndLimits)
            #if DEBUG
            try await group("actualUIFixtureEdits", actualUIFixtureEdits)
            try await group("actualUIFixtureMemoryEdits", actualUIFixtureMemoryEdits)
            try await group("actualUIFixtureMCPLearning", actualUIFixtureMCPLearning)
            #endif
            let data = try JSONSerialization.data(withJSONObject: ["passed": assertions, "failed": 0,
                "groups": groups, "long_chat": longChatObservation,
                "native_ui_executed": false, "real_encrypted_files": true], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            // Only bounded labels are printable; no arbitrary service errors,
            // credentials, messages, or filesystem paths enter the report.
            let label = (error as? CheckFailure)?.check ?? "Unexpected synthetic check error"
            fputs("FAIL: " + label + "\n", stderr)
            exit(1)
        }
    }
    #endif
}

#if !PROFILE_CHAT_APP_STANDALONE
final class ProfileChatAppIntegrationTests: XCTestCase {
    @MainActor func testEncryptedTransactionRevisionGenerationAndMasterSwitch() async throws {
        try await CheckProfileChatApp.transactionChecks()
    }
    @MainActor func testApprovalAndDurableReceipt() async throws {
        try await CheckProfileChatApp.approveAndReceipt()
    }
    @MainActor func testRefusalCancellationAndCommitFences() async throws {
        try await CheckProfileChatApp.deniedOrCancelled()
    }
    @MainActor func testLateProposalsCannotWrite() async throws {
        try await CheckProfileChatApp.lateProposals()
    }
    @MainActor func testActualWriteFailureDoesNotPublishReceipt() async throws {
        try await CheckProfileChatApp.failedWrites()
    }
    @MainActor func testPostCommitFailureRetainsReceipt() async throws {
        try await CheckProfileChatApp.postCommitFailure()
    }
    @MainActor func testGroundingAndOrdinaryChat() async throws {
        try await CheckProfileChatApp.groundingAndOrdinary()
    }
    @MainActor func testPriorReceiptAndFailedNewWrite() async throws {
        try await CheckProfileChatApp.priorReceiptAndFailedNewWrite()
    }
    @MainActor func testTwentyTurnContextWindowRejectsOversizedCurrentInput() async throws {
        try await CheckProfileChatApp.twentyTurnContextWindow()
    }
    @MainActor func testMemorySaveSearchEditAndDurableUndo() async throws {
        try await CheckProfileChatApp.memorySaveSearchEditUndo()
    }
    @MainActor func testMemoryProcedureApprovalRejectionAndReapproval() async throws {
        try await CheckProfileChatApp.memoryProcedureReview()
    }
    @MainActor func testMemoryRefusalCancellationRevisionAndMasterSwitch() async throws {
        try await CheckProfileChatApp.memoryRefusalAndFences()
    }
    @MainActor func testMemorySearchAndCurrentUtteranceGrounding() async throws {
        try await CheckProfileChatApp.memorySearchGrounding()
    }
    @MainActor func testMemoryWriteFailureNeverPublishesReceipt() async throws {
        try await CheckProfileChatApp.memoryWriteFailureAndPriorReceipt()
    }
    @MainActor func testMemoryPostCommitReceiptAndLateCancellation() async throws {
        try await CheckProfileChatApp.memoryPostCommitAndLateCancellation()
    }
    @MainActor func testMCPMemoryAndRemoteApprovalsAreSeparate() async throws {
        try await CheckProfileChatApp.mcpMemoryAndRemoteApprovals()
    }
    @MainActor func testMCPProfileReceiptSurvivesRemoteRefusal() async throws {
        try await CheckProfileChatApp.mcpProfileReceiptSurvivesRemoteRefusal()
    }
    @MainActor func testMCPLocalAuthorityAndSharedMutationLimit() async throws {
        try await CheckProfileChatApp.mcpLocalAuthorityAndLimits()
    }
    @MainActor func testMCPLocalSearchDeleteAndInvalidationFences() async throws {
        try await CheckProfileChatApp.mcpMemorySearchDeleteAndFences()
    }
    @MainActor func testMemoryToolNotesSurviveActualBackgroundExtraction() async throws {
        try await CheckProfileChatApp.memoryNotesThroughExtraction()
    }
    #if DEBUG
    @MainActor func testActualUIFixtureEdits() async throws {
        try await CheckProfileChatApp.actualUIFixtureEdits()
    }
    @MainActor func testActualUIFixtureMCPLearning() async throws {
        try await CheckProfileChatApp.actualUIFixtureMCPLearning()
    }
    @MainActor func testActualUIFixtureMemoryEdits() async throws {
        try await CheckProfileChatApp.actualUIFixtureMemoryEdits()
    }
    #endif
}
#endif
#endif
