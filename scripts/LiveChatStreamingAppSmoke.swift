import AssistantModels
import AssistantPersistence
import AssistantDomain
import Combine
import Foundation

private enum StreamProbeFailure: String, Error {
    case configuration, budget, storage, completion, observation, cancellation, unknown
}
private final class ProbeDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    override func data(forKey key: String) -> Data? { values[key] as? Data }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
private final class ProbeCredentials: ModelCredentialStoring {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}
private final class ProbeArchiveKeys: LearningKeyStore {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private final class ProbeHTTP: StreamingChatModelClient, @unchecked Sendable {
    private let client = HTTPChatModelClient()
    private let lock = NSLock()
    private var starts = 0, completed = 0, deltas: [Int] = [], ended: [Bool] = []
    private var workers: [Task<Void, Never>] = []
    private var failure = "none"
    var counts: (attempts: Int, completed: Int, deltas: [Int], ended: [Bool], failure: String) {
        lock.lock(); defer { lock.unlock() }; return (starts, completed, deltas, ended, failure)
    }
    private func begin() throws -> Int {
        lock.lock(); defer { lock.unlock() }
        guard starts < 4 else { throw StreamProbeFailure.budget }
        let index = starts; starts += 1; deltas.append(0); ended.append(false); return index
    }
    private func delta(_ index: Int) { lock.lock(); defer { lock.unlock() }; deltas[index] += 1 }
    private func remember(_ task: Task<Void, Never>) { lock.lock(); defer { lock.unlock() }; workers.append(task) }
    private func capturedWorkers() -> [Task<Void, Never>] { lock.lock(); defer { lock.unlock() }; return workers }
    func join() async { for task in capturedWorkers() { await task.value } }
    private func end(_ index: Int, error: Error?) {
        lock.lock(); defer { lock.unlock() }; ended[index] = true
        if let error {
            switch error {
            case is CancellationError: failure = "cancelled"
            case HTTPChatModelError.httpStatus: failure = "http_rejected"
            case HTTPChatModelError.timedOut: failure = "timed_out"
            case HTTPChatModelError.incompleteResponse: failure = "incomplete_response"
            case HTTPChatModelError.transportFailure: failure = "transport_failure"
            default: failure = "model_failure"
            }
        } else { completed += 1 }
    }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        throw StreamProbeFailure.observation // No unbudgeted fallback/extraction request.
    }
    func stream(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingOldest(256)) { continuation in
            let worker = Task {
                var index: Int?
                do {
                    try Task.checkCancellation(); let current = try begin(); index = current
                    for try await text in client.stream(messages: messages, configuration: configuration, apiKey: apiKey) {
                        try Task.checkCancellation(); delta(current)
                        switch continuation.yield(text) {
                        case .enqueued: break
                        case .dropped: throw HTTPChatModelError.consumerTooSlow
                        case .terminated: throw CancellationError()
                        @unknown default: throw HTTPChatModelError.consumerTooSlow
                        }
                    }
                    end(current, error: nil); continuation.finish()
                } catch {
                    if let index { end(index, error: error) }
                    continuation.finish(throwing: error)
                }
            }
            remember(worker)
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}
@MainActor private final class ProbeNotifications: TaskNotificationClient {
    var completedAdds = 0
    func settings() async -> TaskNotificationSettings { .init(authorization: .authorized, sound: .enabled, alert: .enabled) }
    func requestAuthorization() async throws { throw StreamProbeFailure.observation }
    func add(_ payload: TaskNotificationPayload, sound: Bool) async throws { if payload.kind == .completed { completedAdds += 1 } }
    func remove(identifiers: [String]) async {}
    func removeAllOwned() async {}
}
@main private enum LiveChatStreamingAppSmoke {
    @MainActor static func main() async {
        let client = ProbeHTTP(); let start = ContinuousClock.now
        var result: [String: Any] = ["schema_version": 1, "status": "FAIL", "failure": "none", "phase": "configuration",
            "partial_observed": false, "partial_never_saved": false, "completed_pair_saved": false,
            "encrypted_relaunch_matches": false, "learning_unchanged": false, "cancel_covered": false,
            "cancel_no_archive": false, "cancel_draft_partial_retained": false, "cancel_no_completion_notification": false,
            "cancel_boundary": "not_attempted", "native_ios_ui": false, "synthetic_prompts_only": true,
            "personal_keychain": false, "private_defaults_on_disk": false, "maximum_http_attempts": 4]
        do { try await exercise(client, result: &result); result["status"] = "PASS" }
        catch { result["failure"] = (error as? StreamProbeFailure)?.rawValue ?? "unknown" }
        await client.join()
        let counts = client.counts
        result["http_stream_attempts"] = counts.attempts; result["http_stream_completions"] = counts.completed
        result["sse_text_deltas"] = counts.deltas; result["transport_failure"] = counts.failure
        let elapsed = start.duration(to: .now).components
        result["seconds"] = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        if let bytes = try? JSONSerialization.data(withJSONObject: result, options: .sortedKeys), let text = String(data: bytes, encoding: .utf8) { print(text) }
        exit(result["status"] as? String == "PASS" ? 0 : 1)
    }
    @MainActor private static func exercise(_ client: ProbeHTTP, result: inout [String: Any]) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["WOOW_MODEL_TEST_BASE_URL"], let model = env["WOOW_MODEL_TEST_MODEL"],
              let key = env["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty else { throw StreamProbeFailure.configuration }
        let repository = ModelSettingsRepository(defaults: ProbeDefaults(), credentials: ProbeCredentials())
        _ = try repository.save(baseURL: base, model: model, newKey: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-live-stream-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let keys = ProbeArchiveKeys(), learningKeys = ProbeArchiveKeys()
        let archiveURL = root.appendingPathComponent("conversations.vault"), learningURL = root.appendingPathComponent("learning.vault")
        let archive = ConversationArchiveStore(vault: EncryptedLearningFile(url: archiveURL, keys: keys))
        let learning = LearningStore(vault: EncryptedLearningFile(url: learningURL, keys: learningKeys))
        guard archive.available, learning.updatePreferences({ $0.useMemory = false }) else { throw StreamProbeFailure.storage }
        let learningBytes = try Data(contentsOf: learningURL)
        let session = ChatSession(learning: learning, repository: repository, client: client, archive: archive)
        let center = ProbeNotifications(); let notifications = TaskNotificationService(client: center, enabled: true)
        await notifications.refresh(); let bridge = TaskNotificationChatBridge(session: session, service: notifications)
        defer { bridge.invalidate() }
        var observations = 0, unsaved = true
        let observer = session.$replyPreview.sink { preview in
            guard preview?.phase == .receiving else { return }
            observations += 1
            unsaved = unsaved && session.entries.isEmpty && archive.conversations.isEmpty && !FileManager.default.fileExists(atPath: archiveURL.path)
        }
        let prompt = "Write a numbered list of twenty short, neutral tips for organizing a fictional library. Each item must be a complete sentence. Do not use tools or mention real people."
        result["phase"] = "complete_stream"
        session.draft = prompt; session.send()
        guard let task = session.capturedArchiveRequest else { throw StreamProbeFailure.observation }
        await task.value; observer.cancel(); await notifications.waitUntilIdle()
        guard observations > 0, unsaved else { throw StreamProbeFailure.observation }
        result["partial_observed"] = true; result["partial_never_saved"] = true
        guard session.entries.count == 2, session.chatError == nil, session.replyPreview == nil,
              archive.conversations.count == 1, center.completedAdds == 1 else { throw StreamProbeFailure.completion }
        result["completed_pair_saved"] = true
        let reopened = ConversationArchiveStore(vault: EncryptedLearningFile(url: archiveURL, keys: keys))
        guard reopened.conversations.first?.turns.first?.assistantText == session.entries.last?.content else { throw StreamProbeFailure.storage }
        result["encrypted_relaunch_matches"] = true
        guard try Data(contentsOf: learningURL) == learningBytes else { throw StreamProbeFailure.observation }
        result["learning_unchanged"] = true
        guard client.counts.deltas.first ?? 0 > 1 else {
            result["cancel_boundary"] = "not_covered_single_sse_delta"; result["phase"] = "finished"; return
        }
        result["phase"] = "cancel_stream"
        session.newConversation()
        let archiveBytes = try Data(contentsOf: archiveURL); var cancelObservations = 0, cancelledInFlight = false
        var cancellation: Task<Void, Never>?
        let cancellationObserver = session.$replyPreview.sink { value in
            guard value?.phase == .receiving else { return }
            cancelObservations += 1
            guard cancelObservations == 2 else { return }
            cancellation = Task { @MainActor in
                let snapshot = client.counts
                guard session.isSubmitting, snapshot.ended.count == 2, !snapshot.ended[1], snapshot.deltas[1] >= 2 else { return }
                cancelledInFlight = true; session.cancel()
            }
        }
        defer { cancellationObserver.cancel() }
        session.draft = prompt; session.send()
        guard let cancelTask = session.capturedArchiveRequest else { throw StreamProbeFailure.observation }
        await cancelTask.value; await cancellation?.value; await notifications.waitUntilIdle()
        if cancelledInFlight {
            guard session.entries.isEmpty, session.replyPreview?.phase == .cancelled, session.replyPreview?.text.isEmpty == false,
                  session.draft == prompt, try Data(contentsOf: archiveURL) == archiveBytes, center.completedAdds == 1 else { throw StreamProbeFailure.cancellation }
            result["cancel_covered"] = true; result["cancel_no_archive"] = true
            result["cancel_draft_partial_retained"] = true; result["cancel_no_completion_notification"] = true
            result["cancel_boundary"] = "cancelled_after_two_observed_deltas_while_transport_inflight"
        } else {
            result["cancel_boundary"] = client.counts.deltas.last ?? 0 <= 1 ? "not_covered_single_sse_delta" : "not_covered_no_inflight_window"
            guard session.chatError == nil, session.entries.count == 2 else { throw StreamProbeFailure.completion }
        }
        guard client.counts.attempts <= 4, try Data(contentsOf: learningURL) == learningBytes else { throw StreamProbeFailure.budget }
        result["phase"] = "finished"
    }
}
