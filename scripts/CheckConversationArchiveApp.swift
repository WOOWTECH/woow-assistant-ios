#if CONVERSATION_ARCHIVE_APP_STANDALONE || canImport(WoowAssistant)
import AssistantPersistence
import AssistantMemory
import AssistantModels
import AssistantDomain
import Foundation
#if !CONVERSATION_ARCHIVE_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private final class ArchiveKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    var rejectWrites = false
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws {
        if rejectWrites { throw LearningFileError.unavailable }; values[id] = key
    }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private final class ArchiveCredentials: ModelCredentialStoring {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}
private actor ArchiveGate {
    private var started = false, released = false
    private var starts: [CheckedContinuation<Void, Never>] = []
    private var releases: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        started = true; let pending = starts; starts = []; pending.forEach { $0.resume() }
        if !released { await withCheckedContinuation { releases.append($0) } }
    }
    func waitUntilStarted() async { if !started { await withCheckedContinuation { starts.append($0) } } }
    func release() { released = true; let pending = releases; releases = []; pending.forEach { $0.resume() } }
}
private actor ArchiveModel: ChatModelClient {
    let replies: [String]
    let gate: ArchiveGate?
    private(set) var requests: [[ModelMessage]] = []
    init(_ replies: [String], gate: ArchiveGate? = nil) { self.replies = replies; self.gate = gate }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        let index = requests.count; requests.append(messages)
        if let gate { await gate.wait() }
        guard index < replies.count else { throw ArchiveAppChecks.Failure(name: "Unexpected model/extraction call") }
        return replies[index]
    }
}
@MainActor private final class ArchiveNotifications: TaskNotificationClient {
    var operations = 0
    func settings() async -> TaskNotificationSettings { operations += 1; return .init(authorization: .authorized, sound: .enabled, alert: .enabled) }
    func requestAuthorization() async throws { operations += 1 }
    func add(_ payload: TaskNotificationPayload, sound: Bool) async throws { operations += 1 }
    func remove(identifiers: [String]) async { operations += 1 }
    func removeAllOwned() async { operations += 1 }
}
@MainActor private final class ArchiveEnvironment {
    let root: URL
    let file: URL
    let learningFile: URL
    let keys = ArchiveKeys()
    let learningKeys = ArchiveKeys()
    let suite = "woow.archive.check." + UUID().uuidString
    let defaults: UserDefaults
    let repository: ModelSettingsRepository
    let learning: LearningStore
    let archive: ConversationArchiveStore
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-archive-" + UUID().uuidString)
        file = root.appendingPathComponent("conversations.vault"); learningFile = root.appendingPathComponent("learning.vault")
        defaults = UserDefaults(suiteName: suite)!
        repository = ModelSettingsRepository(defaults: defaults, credentials: ArchiveCredentials())
        _ = try repository.save(baseURL: "https://archive.example.invalid/v1", model: "fixture", newKey: "synthetic-not-a-key")
        learning = LearningStore(vault: EncryptedLearningFile(url: learningFile, keys: learningKeys))
        guard learning.updatePreferences({ $0.useMemory = false; $0.autoRemember = false }) else { throw ArchiveAppChecks.Failure(name: "learning creation") }
        archive = ConversationArchiveStore(vault: EncryptedLearningFile(url: file, keys: keys))
    }
    func reopen() -> ConversationArchiveStore { ConversationArchiveStore(vault: EncryptedLearningFile(url: file, keys: keys)) }
    func session(_ model: ArchiveModel, store: ConversationArchiveStore? = nil) -> ChatSession {
        ChatSession(learning: learning, repository: repository, client: model, archive: store ?? archive)
    }
    func close() { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
}

@MainActor enum ArchiveAppChecks {
    struct Failure: Error { let name: String }
    struct Assertions {
        var count = 0
        mutating func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(name: name) }; count += 1
        }
        mutating func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { count += 1; return }; throw Failure(name: name)
        }
    }
    private static func send(_ session: ChatSession, _ text: String) async throws {
        session.draft = text; session.send()
        guard let task = session.capturedArchiveRequest else { throw Failure(name: "Actual request not created") }
        await task.value
    }
    private static func wait(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() {
            guard Date() < deadline else { throw Failure(name: "Actual state transition deadline") }
            await Task.yield()
        }
    }

    static func namespaceGates() throws -> Int {
        var a = Assertions(); let id = UUID().uuidString; let root = URL(fileURLWithPath: "/unused-fixture-support")
        var calls = 0
        let resolver = { calls += 1; return root }
        let normal = try ConversationArchiveStore.location(arguments: ["app"], supportDirectory: resolver)
        try a.check(normal.service == "io.woowtech.assistant.conversations.v1.personal" && !normal.reset, "production namespace")
        try a.check(normal.url.path.hasSuffix("/Conversations/personal/conversations.vault"), "independent archive path")
        let invalid = [["-UITestMode"], ["-UITestNamespace", id], ["-UITestResetStorage"],
            ["-UITestMode", "-LiveModelUITest", "-UITestNamespace", id],
            ["-UITestMode", "-UITestMode", "-UITestNamespace", id],
            ["-UITestMode", "-UITestNamespace", "../outside"],
            ["-UITestMode", "-UITestNamespace", id, "-UITestNamespace", id],
            ["-UITestMode", "-UITestNamespace", id, "-LiveModelUITestNamespace", id],
            ["-UITestMode", "-UITestNamespace", id, "-LiveModelUITestCleanup"],
            ["-LiveModelUITest", "-LiveModelUITestNamespace", id, "-LiveModelUITestCleanup", "-LiveModelUITestCleanup"]]
        #if DEBUG
        for args in invalid {
            let prior = calls
            try a.rejects("invalid test flags") { _ = try ConversationArchiveStore.location(arguments: args, supportDirectory: resolver) }
            try a.check(calls == prior, "rejected before ApplicationSupport IO")
        }
        for (mode, namespace, reset) in [("-UITestMode", "-UITestNamespace", "-UITestResetStorage"),
                                        ("-LiveModelUITest", "-LiveModelUITestNamespace", "-LiveModelUITestCleanup")] {
            let result = try ConversationArchiveStore.location(arguments: [mode, namespace, id, reset], supportDirectory: resolver)
            try a.check(result.reset && result.service.hasSuffix("test-" + id), "valid test-only reset")
            try a.check(result.service != normal.service && result.url != normal.url, "no personal test storage")
        }
        #else
        for args in invalid {
            let result = try ConversationArchiveStore.location(arguments: args, supportDirectory: resolver)
            try a.check(result.service == normal.service && result.url == normal.url && !result.reset, "Release ignores fixture flags")
        }
        #endif
        return a.count
    }

    static func completedPairsAndRestore() async throws -> Int {
        var a = Assertions(); let e = try ArchiveEnvironment(); defer { e.close() }
        let model = ArchiveModel(["First actual reply", "Second actual reply"])
        let session = e.session(model)
        try a.check(session.entries.isEmpty && e.archive.conversations.isEmpty, "fresh has no automatic restore")
        try await send(session, "First actual user request")
        try a.check(session.entries.count == 2 && session.archiveNotice == nil, "completed reply displayed and saved")
        let first = e.archive.conversations[0]
        try a.check(first.turns[0].userID == session.entries[0].id && first.turns[0].assistantID == session.entries[1].id, "stable pair IDs")
        let bytes = try Data(contentsOf: e.file)
        try a.check(!String(decoding: bytes, as: UTF8.self).contains("First actual"), "ciphertext excludes plaintext")
        let reopened = e.reopen(); try a.check(reopened.state == e.archive.state, "actual encrypted relaunch")
        _ = e.learning.updatePreferences { $0.useMemory = true; $0.autoRemember = true }
        let learningBytes = try Data(contentsOf: e.learningFile)
        let never = ArchiveModel([]); let restored = e.session(never, store: reopened)
        let client = ArchiveNotifications(); let service = TaskNotificationService(client: client, enabled: true)
        await service.refresh(); let baseline = client.operations
        let bridge = TaskNotificationChatBridge(session: restored, service: service); defer { bridge.invalidate() }
        try a.check(restored.openConversation(id: first.id), "explicit same destination open")
        await service.waitUntilIdle()
        let restoreRequests = await never.requests
        try a.check(restoreRequests.isEmpty && client.operations == baseline && service.trackedCount == 0, "restore zero model/extraction/notification calls")
        try a.check(try Data(contentsOf: e.learningFile) == learningBytes, "restore zero learning writes")
        try a.check(restored.pendingMCPApproval == nil && restored.pendingProfileReview == nil && restored.pendingMemoryReview == nil,
                    "no restored approvals")
        try a.check(restored.mcpSteps.isEmpty && restored.profileReceipt == nil && restored.memoryReceipt == nil && !restored.usesMCP,
                    "no tool receipts or capability restored")
        try a.check(restored.entries.map(\.id) == session.entries.map(\.id) && restored.draft.isEmpty && !restored.isSubmitting, "restore is display only")
        let injected = ChatSession(learning: e.learning, repository: e.repository, client: never)
        try a.check(injected.archive == nil, "old injected initializer never opens personal archive")
        try a.check(e.learning.clearAll(), "learning clear uses its own vault")
        try a.check(try Data(contentsOf: e.file) == bytes && e.reopen().state == reopened.state && e.keys.values.count == 1,
                    "learning key rotation cannot erase archive keys or ciphertext")
        _ = e.learning.updatePreferences { $0.useMemory = false; $0.autoRemember = false }
        try await send(session, "Second actual request")
        let requests = await model.requests
        try a.check(requests.count == 2 && requests[1].map(\.role) == ["user", "assistant", "user"], "existing window receives complete pairs")
        try a.check(requests[1][0].content == first.turns[0].userText && e.archive.conversations[0].turns.count == 2, "continued complete transcript")
        session.newConversation(); try a.check(e.archive.conversations.count == 1 && session.entries.isEmpty, "new does not delete archive")
        return a.count
    }

    static func destinationIsolation() async throws -> Int {
        var a = Assertions(); let e = try ArchiveEnvironment(); defer { e.close() }
        let model = ArchiveModel(["First", "Other destination reply"]); let session = e.session(model)
        try await send(session, "Original private history"); let record = e.archive.conversations[0]
        session.modelDraft = "other-model"; session.saveSettings()
        try a.check(session.entries.isEmpty && !session.canOpenConversation(record), "model change does not transfer context")
        try a.check(!session.openConversation(id: record.id) && e.archive.conversations.contains(record), "old archive remains viewable only")
        try await send(session, "New destination request")
        let requests = await model.requests
        try a.check(requests.count == 2 && requests[1].count == 1 && requests[1][0].content == "New destination request", "no old transcript sent")
        session.modelDraft = "fixture"; session.saveSettings()
        try a.check(session.canOpenConversation(record), "exact original model identity reusable")
        session.keyDraft = "replacement-not-a-key"; session.saveSettings()
        try a.check(!session.canOpenConversation(record), "new credential account cannot continue old history")
        session.baseURLDraft = "https://other.example.invalid/v1"; session.keyDraft = "other-not-a-key"; session.saveSettings()
        try a.check(!session.canOpenConversation(record) && e.archive.conversations.count == 2, "destination change preserves readable rows")
        session.removeSettings()
        try a.check(!session.canOpenConversation(record) && e.reopen().conversations.count == 2, "removing settings does not remove archive encryption keys")
        return a.count
    }

    static func failuresAndRetry() async throws -> Int {
        var a = Assertions(); let e = try ArchiveEnvironment(); defer { e.close() }
        let model = ArchiveModel(["Saved reply", "Visible unsaved reply"]); let session = e.session(model)
        try await send(session, "Saved request"); let original = try Data(contentsOf: e.file); let prior = e.archive.state
        let backup = e.root.appendingPathComponent("prior.vault")
        try FileManager.default.moveItem(at: e.file, to: backup)
        try FileManager.default.createDirectory(at: e.file, withIntermediateDirectories: false)
        try a.check(!session.deleteConversation(id: prior.conversations[0].id) && session.entries.count == 2 && e.archive.state == prior,
                    "failed delete retains displayed and saved conversation")
        try await send(session, "Request with write failure")
        try a.check(session.entries.count == 4 && session.entries.last?.content == "Visible unsaved reply", "write failure cannot discard delivered answer")
        try a.check(session.archiveNotice != nil && session.canRetryArchiveSave && e.archive.state == prior, "write failure distinguished and state rollback")
        try a.check(try Data(contentsOf: backup) == original, "old encrypted bytes unchanged")
        let ids = session.entries.map(\.id); let rowID = prior.conversations[0].id
        try FileManager.default.removeItem(at: e.file); try FileManager.default.moveItem(at: backup, to: e.file)
        let beforeRetry = await model.requests.count
        session.retryArchiveSave()
        let afterRetry = await model.requests.count
        try a.check(session.archiveNotice == nil && !session.canRetryArchiveSave && beforeRetry == afterRetry, "retry only saves; no model replay")
        try a.check(e.archive.conversations[0].id == rowID && e.archive.conversations[0].turns.flatMap { [$0.userID, $0.assistantID] } == ids,
                    "retry preserves pair and row IDs")
        let saved = try Data(contentsOf: e.file)
        e.keys.values = [:]; let missing = e.reopen()
        try a.check(!missing.available, "missing key blocks archive")
        try a.rejects("missing key cannot overwrite") { try missing.save(e.archive.conversations[0], expected: nil) }
        try a.check(try Data(contentsOf: e.file) == saved, "missing key preserves ciphertext")
        let corrupted = Data("corrupted synthetic vault".utf8); try corrupted.write(to: e.file)
        let broken = e.reopen(); try a.check(!broken.available, "corruption blocks archive")
        try a.rejects("corruption cannot overwrite") { try broken.save(e.archive.conversations[0], expected: nil) }
        try a.check(try Data(contentsOf: e.file) == corrupted, "corruption preserves original bytes")
        let empty = try ArchiveEnvironment(); defer { empty.close() }; empty.keys.rejectWrites = true
        let failed = empty.session(ArchiveModel(["Still visible"]))
        try await send(failed, "Key write failure")
        try a.check(failed.entries.count == 2 && failed.archiveNotice != nil && empty.archive.conversations.isEmpty, "new key insertion failure is transactional")
        try a.check(!FileManager.default.fileExists(atPath: empty.file.path), "no plaintext or incomplete archive created")
        return a.count
    }

    static func lateCompletionAndDeletion() async throws -> Int {
        var a = Assertions(); let e = try ArchiveEnvironment(); defer { e.close() }
        let initial = e.session(ArchiveModel(["Seed answer"])); try await send(initial, "Seed actual request")
        var row = e.archive.conversations[0]
        let other = e.session(ArchiveModel(["Unrelated reply"])); try await send(other, "Unrelated actual request")
        let unrelated = e.archive.conversations.first { $0.id != row.id }!
        let continuedGate = ArchiveGate(); let continued = e.session(ArchiveModel(["Continued reply"], gate: continuedGate))
        try a.check(continued.openConversation(id: row.id), "open current row before unrelated delete")
        continued.draft = "Continue after unrelated deletion"; continued.send()
        guard let continuedTask = continued.capturedArchiveRequest else { throw Failure(name: "capture continuation") }
        await continuedGate.waitUntilStarted()
        try a.check(continued.deleteConversation(id: unrelated.id), "delete unrelated archived row")
        await continuedGate.release(); await continuedTask.value
        try a.check(continued.archiveNotice == nil && e.archive.conversations.count == 1 && e.archive.conversations[0].turns.count == 2,
                    "unrelated deletion does not invalidate expected row")
        row = e.archive.conversations[0]
        for mode in ["cancel", "open", "delete"] {
            let gate = ArchiveGate(); let model = ArchiveModel(["Late result must not publish"], gate: gate); let session = e.session(model)
            try a.check(session.openConversation(id: row.id), "seed open before delayed run")
            let client = ArchiveNotifications(); let service = TaskNotificationService(client: client, enabled: true)
            await service.refresh(); let baseline = client.operations
            let bridge = TaskNotificationChatBridge(session: session, service: service)
            session.draft = "Delayed request"; session.send(); guard let task = session.capturedArchiveRequest else { throw Failure(name: "capture actual running task") }
            await gate.waitUntilStarted()
            if mode == "cancel" { session.cancel() }
            if mode == "open" { try a.check(session.openConversation(id: row.id), "explicit open cancels old run") }
            if mode == "delete" { try a.check(session.deleteConversation(id: row.id), "active delete persists") }
            let entries = session.entries.map(\.id); let state = e.archive.state
            await gate.release(); await task.value
            await service.waitUntilIdle()
            try a.check(client.operations == baseline && service.trackedCount == 0, "actual notification bridge cannot complete cancelled/restored run")
            bridge.invalidate()
            try a.check(session.entries.map(\.id) == entries && e.archive.state == state && !session.isSubmitting,
                        "joined late response cannot overwrite after " + mode)
            try a.check(session.pendingMCPApproval == nil && session.pendingProfileReview == nil && session.pendingMemoryReview == nil, "no pending actions survive " + mode)
        }
        try a.check(e.reopen().conversations.isEmpty, "deleted conversation stays absent after relaunch")
        try a.rejects("old expected row cannot resurrect") { try e.archive.save(row, expected: row) }
        return a.count
    }

    static func reviewDoesNotReplay() async throws -> Int {
        var a = Assertions(); let e = try ArchiveEnvironment(); defer { e.close() }
        _ = e.learning.updatePreferences { $0.useMemory = true; $0.autoRemember = false }
        let request = "Please remember that I prefer jasmine tea"
        let command = #"{"action":"profile_edit","arguments":{"op":"add","text":"I prefer jasmine tea","quote":"Please remember that I prefer jasmine tea"}}"#
        let model = ArchiveModel([command, #"{"action":"finish","answer":"Saved the requested profile preference."}"#])
        let session = e.session(model); session.draft = request; session.send()
        guard let task = session.capturedArchiveRequest else { throw Failure(name: "review request") }
        try await wait { session.pendingProfileReview != nil || !session.isSubmitting }
        guard let review = session.pendingProfileReview else { throw Failure(name: "actual profile review") }
        try a.check(e.archive.conversations.isEmpty, "unfinished approval is not archived")
        session.resolveProfileReview(id: review.id, approved: true); await task.value
        try a.check(session.profileReceipt != nil && session.entries.count == 2 && e.archive.conversations.count == 1, "actual reviewed completion archived")
        let savedProfile = e.learning.profile; let savedBytes = try Data(contentsOf: e.learningFile)
        let never = ArchiveModel([]); let restored = e.session(never, store: e.reopen())
        try a.check(restored.openConversation(id: e.archive.conversations[0].id), "open actual reviewed history")
        try a.check(restored.profileReceipt == nil && restored.memoryReceipt == nil && restored.pendingProfileReview == nil && restored.mcpSteps.isEmpty,
                    "historical mutation does not become executable receipt")
        let calls = await never.requests.count
        try a.check(calls == 0 && e.learning.profile == savedProfile && (try Data(contentsOf: e.learningFile)) == savedBytes, "restore does not repeat mutation or extraction")
        try a.check(restored.deleteConversation(id: e.archive.conversations[0].id), "delete reviewed transcript")
        try a.check(e.learning.profile == savedProfile && (try Data(contentsOf: e.learningFile)) == savedBytes, "history deletion preserves confirmed profile")
        return a.count
    }
}

#if CONVERSATION_ARCHIVE_APP_STANDALONE
@main enum ConversationArchiveAppMain {
    @MainActor static func main() async {
        do {
            let groups = try await [ArchiveAppChecks.namespaceGates(), ArchiveAppChecks.completedPairsAndRestore(),
                ArchiveAppChecks.destinationIsolation(), ArchiveAppChecks.failuresAndRetry(),
                ArchiveAppChecks.lateCompletionAndDeletion(), ArchiveAppChecks.reviewDoesNotReplay()]
            print("{\"groups\":6,\"assertions\":\(groups.reduce(0,+)),\"group_counts\":\(groups)}")
        } catch { print("ARCHIVE_APP_FAILURE: \(error)"); exit(1) }
    }
}
#else
final class ConversationArchiveAppTests: XCTestCase {
    @MainActor func testNamespaceGates() throws { XCTAssertGreaterThan(try ArchiveAppChecks.namespaceGates(), 0) }
    @MainActor func testCompletedPairsAndRestore() async throws { let n = try await ArchiveAppChecks.completedPairsAndRestore(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testDestinationIsolation() async throws { let n = try await ArchiveAppChecks.destinationIsolation(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testFailuresAndRetry() async throws { let n = try await ArchiveAppChecks.failuresAndRetry(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testLateCompletionAndDeletion() async throws { let n = try await ArchiveAppChecks.lateCompletionAndDeletion(); XCTAssertGreaterThan(n, 0) }
    @MainActor func testReviewDoesNotReplay() async throws { let n = try await ArchiveAppChecks.reviewDoesNotReplay(); XCTAssertGreaterThan(n, 0) }
}
#endif
#endif
