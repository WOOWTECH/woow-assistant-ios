import AssistantMemory
import AssistantModels
import AssistantPersistence
import Foundation

// Compile beside the unchanged App sources. This is actual model/App-logic
// coverage on macOS, not iOS UI or human-review acceptance. Only this executable
// approves its fixed synthetic proposals; the product still requires its UI.
private struct SmokeFailure: Error {}
private final class SmokeLearningKeys: LearningKeyStore {
    var keys: [String: Data] = [:]
    func read(id: String) throws -> Data? { keys[id] }
    func insert(_ key: Data, id: String) throws { keys[id] = key }
    func remove(id: String) throws { keys.removeValue(forKey: id) }
    func removeAll(except id: String) throws { keys = keys.filter { $0.key == id } }
}
private final class SmokeCredentials: ModelCredentialStoring {
    var keys: [String: String] = [:]
    func read(account: String) throws -> String? { keys[account] }
    func insert(_ key: String, account: String) throws { keys[account] = key }
    func remove(account: String) throws { keys.removeValue(forKey: account) }
    func removeAll() throws { keys = [:] }
}
private actor SmokeModel: ChatModelClient {
    private(set) var calls = 0
    private(set) var lastMessageCount = 0
    private(set) var lastContentBytes = 0
    private(set) var failure = "none"
    private(set) var actions: [String] = []
    let client = HTTPChatModelClient()
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        calls += 1; lastMessageCount = messages.count
        lastContentBytes = messages.reduce(0) { $0 + $1.content.utf8.count }
        do {
            let response = try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
            let object = try? JSONSerialization.jsonObject(with: Data(response.utf8)) as? [String: Any]
            let action = object?["action"] as? String ?? "unknown"
            actions.append(["finish", "profile_edit", "memory_search", "memory_save", "memory_edit"].contains(action) ? action : "unknown")
            return response
        }
        catch {
            if let error = error as? HTTPChatModelError {
                // Closed enum: it contains no response body, endpoint or key.
                failure = String(describing: error)
            } else { failure = "unknown" }
            throw error
        }
    }
}

@main private enum LiveLearningToolAppSmoke {
    @MainActor static var phase = "setup"
    @MainActor static var completed: [String] = []
    @MainActor static func require(_ condition: @autoclosure () throws -> Bool) throws {
        guard try condition() else { throw SmokeFailure() }
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let limit = ContinuousClock.now.advanced(by: .seconds(95))
        while !condition() {
            guard ContinuousClock.now < limit else { throw SmokeFailure() }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    @MainActor static func start(_ session: ChatSession, _ text: String) throws -> Task<Void, Never> {
        session.draft = text
        try require(session.canSend)
        session.send()
        guard let task = Mirror(reflecting: session).children.first(where: { $0.label == "request" })?.value as? Task<Void, Never> else {
            throw SmokeFailure()
        }
        return task
    }
    @MainActor static func memoryTurn(_ session: ChatSession, prompt: String,
                                     operation: MemoryToolOperation, content: String?) async throws {
        let task = try start(session, prompt)
        try await wait { session.pendingMemoryReview != nil || !session.isSubmitting }
        guard let review = session.pendingMemoryReview else { throw SmokeFailure() }
        try require(review.op == operation && review.after?.content == content)
        session.resolveMemoryReview(id: review.id, approved: true)
        await task.value
        try require(session.chatError == nil && session.memoryReceipt?.ok == true
                    && session.entries.last?.role == "assistant" && !session.entries.last!.content.isEmpty)
    }

    @MainActor static func main() async {
        let model = SmokeModel()
        var output: [String: Any] = ["native_ios_ui": false, "actual_http_model": true,
            "approval_driver": "fixed synthetic executable", "production_keychain_used": false]
        let started = Date()
        do {
            let environment = ProcessInfo.processInfo.environment
            guard let base = environment["WOOW_MODEL_TEST_BASE_URL"], let key = environment["WOOW_MODEL_TEST_API_KEY"],
                  let name = environment["WOOW_MODEL_TEST_MODEL"] else { throw SmokeFailure() }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-live-learning-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "io.woowtech.live-learning-smoke." + UUID().uuidString
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let keys = SmokeLearningKeys(), file = root.appendingPathComponent("learning.vault")
            func reopen() -> LearningStore { LearningStore(vault: EncryptedLearningFile(url: file, keys: keys)) }
            let learning = reopen()
            try require(learning.available && learning.updatePreferences { $0.autoRemember = false })
            let repository = ModelSettingsRepository(defaults: defaults, credentials: SmokeCredentials())
            _ = try repository.save(baseURL: base, model: name, newKey: key)
            let session = ChatSession(learning: learning, repository: repository, client: model)
            defer { session.cancel(); learning.cancelLearning() }

            phase = "profile_add"
            let task = try start(session, #"Add this exact lasting preference to my personal profile using profile_edit: Prefer quiet walks. Use text and quote exactly "Prefer quiet walks". I will review the proposed change before you save it."#)
            try await wait { session.pendingProfileReview != nil || !session.isSubmitting }
            output["profile_review_received"] = session.pendingProfileReview != nil
            output["profile_app_error"] = session.chatError != nil
            guard let profile = session.pendingProfileReview else { throw SmokeFailure() }
            output["profile_operation_matches"] = profile.op == .add
            output["profile_content_matches"] = profile.after == "Prefer quiet walks"
            output["profile_quote_matches"] = profile.quote == "Prefer quiet walks"
            output["profile_content_ignoring_outer_punctuation_matches"] = profile.after?.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) == "Prefer quiet walks"
            output["profile_quote_ignoring_outer_punctuation_matches"] = profile.quote.trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines)) == "Prefer quiet walks"
            try require(profile.op == .add && profile.after == "Prefer quiet walks" && profile.quote == "Prefer quiet walks")
            session.resolveProfileReview(id: profile.id, approved: true)
            await task.value
            try require(session.chatError == nil && session.profileReceipt?.applied == true)
            try require(reopen().profile.snapshot().entries.map(\.text) == ["Prefer quiet walks"])
            completed.append(phase)

            phase = "memory_save"
            try await memoryTurn(session, prompt: #"Use memory_save to save the ordinary preference with content and quote both exactly "Prefer jasmine tea", and keywords ["jasmine", "tea"]. I will review the write."#, operation: .add, content: "Prefer jasmine tea")
            try require(reopen().memory.memories.contains { $0.content == "Prefer jasmine tea" && $0.source.type == "user_said" })
            completed.append(phase)

            phase = "memory_search_delete_undo"
            try await memoryTurn(session, prompt: "Delete the ordinary memory Prefer jasmine tea. First use memory_search for jasmine tea, then memory_edit delete. Quote this whole request for the explicit deletion request.", operation: .delete, content: nil)
            try require(reopen().memory.memories.isEmpty)
            guard let deleted = session.memoryReceipt?.note else { throw SmokeFailure() }
            learning.undo(deleted)
            try require(reopen().memory.memories.map(\.content) == ["Prefer jasmine tea"])
            completed.append(phase)

            phase = "procedure_pending_then_approve"
            try await memoryTurn(session, prompt: #"Use memory_save to save an ordinary procedure with content and quote both exactly "Check invoices before paying", and keywords ["invoices"]. I will review the write."#, operation: .add, content: "Check invoices before paying")
            guard let pending = session.memoryReceipt?.note else { throw SmokeFailure() }
            try require(learning.canReviewMemory(pending))
            try require(reopen().memory.memories.contains { $0.id == pending.memoryID && $0.status == .pending })
            learning.approvePendingMemory(pending)
            try require(reopen().memory.memories.contains { $0.id == pending.memoryID && $0.status == .active })
            completed.append(phase)

            phase = "twenty_turns"
            session.newConversation()
            let before = await model.calls
            for index in 1...20 {
                let marker = "WOOW_LONG_" + String(index)
                let turn = try start(session, "Reply exactly " + marker + " and do not change any memory or profile.")
                await turn.value
                try require(session.chatError == nil && session.entries.count == index * 2
                    && session.entries.last?.content.trimmingCharacters(in: .whitespacesAndNewlines) == marker)
            }
            let after = await model.calls
            try require(after - before == 20 && session.chatNotice != nil)
            let lastCount = await model.lastMessageCount
            try require(lastCount <= 33 && session.entries.count == 40)
            output["long_chat_model_calls"] = after - before
            output["displayed_entries"] = session.entries.count
            output["last_messages_including_flow_system"] = lastCount
            output["last_content_bytes_including_flow_system"] = await model.lastContentBytes
            session.draft = String(repeating: "界", count: 21_846)
            session.send()
            let noExtra = await model.calls
            try require(noExtra == after && !session.isSubmitting && session.entries.count == 40
                && session.draft.utf8.count == 65_538 && session.chatError != nil)
            completed.append(phase)
            output["passed"] = true
        } catch { output["passed"] = false }
        output["phase"] = phase; output["completed"] = completed
        output["model_calls"] = await model.calls
        output["model_error"] = await model.failure
        output["model_actions"] = await model.actions
        output["seconds"] = Date().timeIntervalSince(started)
        let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
