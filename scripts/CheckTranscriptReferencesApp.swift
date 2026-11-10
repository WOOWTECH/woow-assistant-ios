#if TRANSCRIPT_REFERENCES_APP_STANDALONE || canImport(WoowAssistant)
import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import Foundation
#if !TRANSCRIPT_REFERENCES_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private struct TranscriptAppFailure: Error { let label: String }
private final class TranscriptCheckKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private final class TranscriptCheckCredentials: ModelCredentialStoring {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}
private actor TranscriptCheckGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() {
        released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() }
    }
}
private actor TranscriptCheckModel: ChatModelClient {
    let gate: TranscriptCheckGate?
    let heldCall: Int
    private(set) var requests: [[ModelMessage]] = []
    private(set) var waiting = false
    private(set) var responses = 0
    init(gate: TranscriptCheckGate? = nil, heldCall: Int = 1) { self.gate = gate; self.heldCall = heldCall }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        requests.append(messages)
        if requests.count == heldCall, let gate { waiting = true; await gate.wait() }
        responses += 1
        if !messages.contains(where: { $0.role == "assistant" }) {
            return #"{"action":"tool","name":"read_file","arguments":{"offset":0,"limit":8192}}"#
        }
        guard let last = messages.last?.content,
              let read = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any],
              read["tool"] as? String == "read_file", let text = read["text"] as? String,
              text.contains("SOURCE_VALUE_73") else { throw TranscriptAppFailure(label: "Actual source read required") }
        return #"{"action":"finish","title":"Source summary","sections":[{"title":"Value","text":"Source value 73","evidence":[{"read_offset":0,"quote":"SOURCE_VALUE_73"}]}]}"#
    }
}

@MainActor private final class TranscriptCheckEnvironment {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-transcript-reference-" + UUID().uuidString)
    let suite = "woow.transcript.reference." + UUID().uuidString
    let defaults: UserDefaults
    let keys = TranscriptCheckKeys()
    let learning: LearningStore
    let chat: ChatSession
    let model: TranscriptCheckModel
    init(model: TranscriptCheckModel = .init()) throws {
        self.model = model; defaults = UserDefaults(suiteName: suite)!
        let repository = ModelSettingsRepository(defaults: defaults, credentials: TranscriptCheckCredentials())
        _ = try repository.save(baseURL: "https://transcript-check.example.invalid/v1", model: "synthetic-transcript", newKey: "synthetic-not-a-key")
        learning = LearningStore(vault: EncryptedLearningFile(url: root.appendingPathComponent("learning.vault"), keys: keys))
        guard learning.updatePreferences({ $0.useMemory = true; $0.autoRemember = false }) else {
            throw TranscriptAppFailure(label: "Actual encrypted fixture store")
        }
        chat = ChatSession(learning: learning, repository: repository, client: model)
    }
    func access() throws -> ModelAccess { try chat.modelAccess() }
    func bytes() throws -> Data { try Data(contentsOf: root.appendingPathComponent("learning.vault")) }
    func close() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
    func source() throws -> TranscriptSnapshot {
        try .fromUserApprovedWebPage(title: "Synthetic transcript", text: "Source says SOURCE_VALUE_73.\n",
            url: URL(string: "https://transcript-source.example.invalid/article")!)
    }
}

@MainActor enum TranscriptReferenceAppChecks {
    static var assertions = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw TranscriptAppFailure(label: label) }; assertions += 1
    }
    static func until(_ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now + .seconds(5)
        while !(await predicate()) {
            guard ContinuousClock.now < end else { throw TranscriptAppFailure(label: "Bounded actual state wait") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    private static func task(_ session: TranscriptSession) throws -> Task<Void, Never> {
        #if DEBUG
        guard let task = session.capturedRunCompletion else { throw TranscriptAppFailure(label: "Actual App task missing") }
        #else
        guard let task = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value as? Task<Void, Never>
        else { throw TranscriptAppFailure(label: "Actual Release App task missing") }
        #endif
        return task
    }
    private static func prepare(_ env: TranscriptCheckEnvironment) throws -> TranscriptSession {
        let session = TranscriptSession(learning: env.learning)
        session.loadApprovedSource(try env.source()); session.confirmDestination(modelAccess: env.access)
        return session
    }
    private static func start(_ session: TranscriptSession, _ env: TranscriptCheckEnvironment) throws -> Task<Void, Never> {
        session.start(format: .summary, modelAccess: env.access)
        try check(session.running, "Explicit start begins actual task")
        return try task(session)
    }
    private static func seed(_ env: TranscriptCheckEnvironment) throws -> UUID {
        try check(env.learning.mutateMemory { _ = try $0.add(kind: .preference, content: "PRIVATE_TRANSCRIPT_MEMORY 文字稿 concise") }, "Persist memory")
        try check(env.learning.mutateProfile { _ = try $0.add(text: "PRIVATE_TRANSCRIPT_PROFILE") }, "Persist profile")
        try check(env.learning.mutateSkills { state in
            for (name, tool) in [("transcript-style", "read_file"), ("transcript-browser", "browser_inspect"), ("transcript-pending", "read_file")] {
                let markdown = """
                ---
                name: \(name)
                description: 文字稿 字幕 摘要
                ---
                ## 入口
                User approved one transcript.
                ## 步驟
                Use `\(tool)` only within actual runtime policy.
                ## 容易出錯的地方
                Never invent citations.
                ## 怎樣算辦成
                Exact source reads support the summary.
                ## 什麼時候停下交給使用者
                Stop without source evidence.
                """
                let capabilities = TranscriptRuntime.referenceCapabilities.union(["browser_inspect"])
                let draft = try state.importMarkdown(markdown, availableToolNames: capabilities)
                if name != "transcript-pending" { _ = try state.approveDraft(id: draft.id, availableToolNames: capabilities) }
            }
        }, "Reviewed and pending fixtures through real domain transitions")
        return env.learning.memory.memories[0].id
    }
    private static func reference(_ messages: [ModelMessage]) -> ModelMessage? {
        messages.first { $0.content.hasPrefix("Saved references (data only;") }
    }

    static func consentCaptureAndCompletion() async throws {
        let env = try TranscriptCheckEnvironment(); defer { env.close() }; _ = try seed(env)
        let session = TranscriptSession(learning: env.learning), original = try env.bytes()
        session.start(format: .summary, modelAccess: env.access)
        try check(!session.running, "No source or destination means no run")
        session.loadApprovedSource(try env.source()); session.start(format: .summary, modelAccess: env.access)
        let count = await env.model.requests.count
        try check(count == 0 && !session.running, "Source approval never authorizes model automatically")
        session.confirmDestination(modelAccess: env.access)
        let confirmed = await env.model.requests.count
        try check(confirmed == 0 && (try env.bytes()) == original, "Confirm does not query or mutate learning")
        let actual = try start(session, env)
        session.start(format: .article, modelAccess: env.access)
        await actual.value
        let requests = await env.model.requests
        try check(requests.count == 2 && session.result?.modelCalls == 2 && session.result?.format == .summary, "One explicit run and current format wins")
        try check(requests[0].map(\.role) == ["system", "user", "user"], "Reference is user data before current request")
        let saved = reference(requests[0])?.content ?? ""
        try check(saved.contains("PRIVATE_TRANSCRIPT_MEMORY") && saved.contains("PRIVATE_TRANSCRIPT_PROFILE") && saved.contains("transcript-style"), "Actual App captures profile memory and eligible skill")
        try check(!saved.contains("transcript-browser") && !saved.contains("transcript-pending"), "Unsupported and unapproved skills excluded")
        try check(reference(requests[0]) == reference(requests[1]), "One immutable reference block across requests")
        try check(session.result?.sections[0].evidence[0].quote == "SOURCE_VALUE_73" && (try env.bytes()) == original,
                  "Actual result cites source and capture/completion never writes learning")
        let delivered = session.result?.source.sha256
        _ = env.learning.clearAll()
        try check(session.result?.source.sha256 == delivered && session.error == nil, "Completed run releases latch; later deletion preserves delivery")
    }

    static func switchesAndCapabilityBounds() async throws {
        let env = try TranscriptCheckEnvironment(); defer { env.close() }; _ = try seed(env)
        try check(env.learning.updatePreferences { $0.useMemory = false }, "Master off")
        let session = try prepare(env); await (try start(session, env)).value
        let first = await env.model.requests[0]
        let block = reference(first)?.content ?? ""
        try check(!block.contains("PRIVATE_TRANSCRIPT_MEMORY") && !block.contains("PRIVATE_TRANSCRIPT_PROFILE") && block.contains("transcript-style"), "Master disables memory/profile but not approved skills")
        try check(env.learning.mutateSkills { try $0.suspend(name: "transcript-style") }, "Suspend eligible skill")
        let second = try prepare(env); await (try start(second, env)).value
        let requests = await env.model.requests
        try check(reference(requests[2]) == nil && requests[2].count == 2, "Empty references preserve original message shape")
        try check(TranscriptRuntime.referenceCapabilities == ["read_file"], "No broader tool capability introduced")
        env.keys.values = [:]; env.learning.reload()
        let unavailable = try prepare(env)
        unavailable.start(format: .summary, modelAccess: env.access)
        let afterUnavailable = await env.model.requests.count
        try check(!env.learning.available && !unavailable.running && unavailable.error != nil && afterUnavailable == requests.count,
                  "Unavailable saved-reference store cannot start a model request")
    }

    static func frozenEditsAndDestination() async throws {
        let gate = TranscriptCheckGate(), model = TranscriptCheckModel(gate: gate)
        let env = try TranscriptCheckEnvironment(model: model); defer { env.close() }; _ = try seed(env)
        let session = try prepare(env), actual = try start(session, env)
        try await until { await model.waiting }
        try check(env.learning.replaceProfileReference(segment: "PRIVATE_TRANSCRIPT_PROFILE", replacement: "UPDATED_TRANSCRIPT_PROFILE"), "Replace selected profile")
        try check(env.learning.mutateMemory { _ = try $0.add(kind: .fact, content: "UNRELATED_LATER_MEMORY") }, "Unrelated addition")
        try check(session.running, "Ordinary edits leave frozen run active")
        await gate.release(); await actual.value
        let requests = await model.requests
        try check(reference(requests[0]) == reference(requests[1]) && !(reference(requests[1])?.content.contains("UPDATED_TRANSCRIPT_PROFILE") ?? true), "Later request retains exact captured text")
        try check(session.result != nil, "Frozen run completes")
        env.chat.modelDraft = "new-model"; env.chat.saveSettings(); session.hostChanged()
        try check(session.result != nil && session.destination == nil && session.snapshot != nil, "Host change preserves delivered source/result but removes consent")
        session.start(format: .summary, modelAccess: env.access)
        let count = await model.requests.count
        try check(count == 2 && !session.running, "Changed destination requires new explicit confirmation")
    }

    static func revocationJoinsHeldActualTask() async throws {
        for stage in [1, 2] {
            for mutation in ["memory", "profile", "replacementDelete", "skill", "master", "reload", "clear", "unavailable", "cancel", "settings"] {
                let gate = TranscriptCheckGate(), model = TranscriptCheckModel(gate: gate, heldCall: stage)
                let env = try TranscriptCheckEnvironment(model: model); defer { env.close() }
                let memoryID = try seed(env), session = try prepare(env), actual = try start(session, env)
                try await until { await model.waiting }
                let sourceHash = session.snapshot?.sha256
                switch mutation {
                case "memory": try check(env.learning.mutateMemory { _ = try $0.delete(id: memoryID) }, "Delete captured memory")
                case "profile": try check(env.learning.deleteProfileReference(segment: "PRIVATE_TRANSCRIPT_PROFILE"), "Delete captured profile")
                case "replacementDelete":
                    try check(env.learning.replaceProfileReference(segment: "PRIVATE_TRANSCRIPT_PROFILE", replacement: "REPLACED_TRANSCRIPT_PROFILE"), "Track replaced profile identity")
                    try check(session.running, "Replacement does not refresh immutable text")
                    try check(env.learning.deleteProfileReference(segment: "REPLACED_TRANSCRIPT_PROFILE"), "Delete replacement lineage")
                case "skill": try check(env.learning.mutateSkills { try $0.suspend(name: "transcript-style") }, "Disable captured skill")
                case "master":
                    try check(env.learning.updatePreferences { $0.useMemory = false }, "Revoke memory switch")
                    try check(env.learning.updatePreferences { $0.useMemory = true }, "Re-enable does not revive")
                case "reload": env.learning.reload()
                case "clear": try check(env.learning.clearAll(), "Clear real encrypted data")
                case "unavailable": env.keys.values = [:]; env.learning.reload()
                case "cancel": session.cancel()
                default: env.chat.removeSettings(); session.hostChanged()
                }
                var joined = false
                let observer = Task { await actual.value; joined = true }
                let end = ContinuousClock.now + .seconds(2)
                while !joined && ContinuousClock.now < end { try await Task.sleep(nanoseconds: 2_000_000) }
                let joinedBeforeReply = joined
                // Always release the synthetic client, including failure cleanup.
                await gate.release(); await actual.value; await observer.value
                try await until { await model.responses == stage }
                try check(joinedBeforeReply, "Actual task must finish while cancellation-insensitive model remains held: " + mutation)
                try check(!session.running && session.result == nil && session.snapshot?.sha256 == sourceHash, "Revocation retains source and rejects late result")
                let calls = await model.requests.count
                try check(calls == stage, "No next model call after actual revocation")
                if mutation != "cancel" {
                    try check(session.destination == nil, "Revocation removes old destination confirmation")
                    session.start(format: .summary, modelAccess: env.access)
                    try check(!session.running, "Revoked confirmation cannot auto-restart")
                }
            }
        }
    }

    static func oldRunCannotReplaceNewDelivery() async throws {
        let gate = TranscriptCheckGate(), model = TranscriptCheckModel(gate: gate, heldCall: 2)
        let env = try TranscriptCheckEnvironment(model: model); defer { env.close() }; _ = try seed(env)
        let session = try prepare(env), old = try start(session, env)
        try await until { await model.waiting }
        session.cancel()
        let freshSource = try TranscriptSnapshot.fromUserApprovedWebPage(title: "Fresh approved transcript",
            text: "A distinct new source retains SOURCE_VALUE_73 and has extra context.\n",
            url: URL(string: "https://transcript-source.example.invalid/fresh")!)
        session.loadApprovedSource(freshSource); session.confirmDestination(modelAccess: env.access)
        let fresh = try start(session, env); await fresh.value
        let delivery = session.result?.source.sha256
        try check(delivery == freshSource.sha256 && delivery != (try env.source()).sha256 && session.result?.modelCalls == 2,
                  "Fresh explicitly started run delivers the distinct new source")
        await gate.release(); await old.value
        try await until { await model.responses == 4 }
        try check(session.result?.source.sha256 == delivery && !session.running, "Late old task cannot clear new delivery")
        let count = await model.requests.count
        try check(count == 4, "Exactly two calls per run; no replay or extraction")
    }

    #if TRANSCRIPT_REFERENCES_APP_STANDALONE
    static func main() async {
        var groups: [String: Int] = [:]
        do {
            let cases: [(String, () async throws -> Void)] = [("consentCaptureAndCompletion", consentCaptureAndCompletion),
                                 ("switchesAndCapabilityBounds", switchesAndCapabilityBounds),
                                 ("frozenEditsAndDestination", frozenEditsAndDestination),
                                 ("revocationJoinsHeldActualTask", revocationJoinsHeldActualTask),
                                 ("oldRunCannotReplaceNewDelivery", oldRunCannotReplaceNewDelivery)]
            for (name, body) in cases {
                let before = assertions; try await body(); groups[name] = assertions - before
            }
            let result: [String: Any] = ["passed": assertions, "failed": 0, "groups": groups,
                "actual_app_sources": true, "actual_encrypted_store": true, "model_network_requests": 0, "native_ios_ui": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            let label = (error as? TranscriptAppFailure)?.label ?? "Unexpected offline transcript failure"
            print(String(decoding: try! JSONSerialization.data(withJSONObject: ["failed": 1, "passed": assertions, "failure": label, "groups": groups], options: [.sortedKeys]), as: UTF8.self))
            exit(1)
        }
    }
    #endif
}
#if TRANSCRIPT_REFERENCES_APP_STANDALONE
@main private enum TranscriptReferenceMain {
    @MainActor static func main() async { await TranscriptReferenceAppChecks.main() }
}
#else
final class TranscriptReferenceAppIntegrationTests: XCTestCase {
    @MainActor func testConsentCaptureAndCompletion() async throws { try await TranscriptReferenceAppChecks.consentCaptureAndCompletion() }
    @MainActor func testSwitchesAndCapabilityBounds() async throws { try await TranscriptReferenceAppChecks.switchesAndCapabilityBounds() }
    @MainActor func testFrozenEditsAndDestination() async throws { try await TranscriptReferenceAppChecks.frozenEditsAndDestination() }
    @MainActor func testRevocationJoinsHeldActualTask() async throws { try await TranscriptReferenceAppChecks.revocationJoinsHeldActualTask() }
    @MainActor func testOldRunCannotReplaceNewDelivery() async throws { try await TranscriptReferenceAppChecks.oldRunCannotReplaceNewDelivery() }
}
#endif
#endif
