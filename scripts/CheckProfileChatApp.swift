#if PROFILE_CHAT_APP_STANDALONE || canImport(WoowAssistant)
import AssistantMemory
import AssistantModels
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
        try await body()
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

    #if DEBUG
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
            #if DEBUG
            try await group("actualUIFixtureEdits", actualUIFixtureEdits)
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
    #if DEBUG
    @MainActor func testActualUIFixtureEdits() async throws {
        try await CheckProfileChatApp.actualUIFixtureEdits()
    }
    #endif
}
#endif
#endif
