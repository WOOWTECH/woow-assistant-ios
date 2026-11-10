#if TASK_NOTIFICATIONS_APP_STANDALONE || canImport(WoowAssistant)
import AssistantDomain
import AssistantMemory
import AssistantModels
import AssistantMCP
import AssistantPersistence
import Foundation
import UserNotifications
#if !TASK_NOTIFICATIONS_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private final class NotificationSyntheticKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private final class NotificationSyntheticCredentials: ModelCredentialStoring {
    var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}
private actor NotificationModelGate {
    private var waiting: CheckedContinuation<Void, Never>?
    private var open = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if !open { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { open = true; waiting?.resume(); waiting = nil }
}
private actor NotificationScriptedModel: ChatModelClient {
    var replies: [String]
    let gate: NotificationModelGate?
    private(set) var calls = 0
    init(_ replies: [String], gate: NotificationModelGate? = nil) { self.replies = replies; self.gate = gate }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        calls += 1
        if let gate { await gate.wait() }
        guard !replies.isEmpty else { throw URLError(.cannotParseResponse) }
        return replies.removeFirst()
    }
}
private struct NotificationMCPEndpoint: MCPEndpointStoring {
    func load() throws -> URL? { URL(string: "https://notifications.example.invalid/mcp") }
    func save(endpoint: String) throws { throw MCPSettingsError.invalidEndpoint }
    func remove() throws {}
}
private actor NotificationMCPServer: MCPDiscovering {
    private(set) var calls = 0
    func initialize() async throws -> MCPServerInfo { MCPServerInfo(protocolVersion: "2025-03-26", capabilities: ["tools"]) }
    func listTools() async throws -> [MCPTool] { [MCPTool(name: "synthetic_read", inputSchema: .object(["type": .string("object")]))] }
    func listResources() async throws -> [MCPResource] { [] }
    func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue {
        calls += 1
        return .object(["isError": .bool(false), "content": .array([.object(["type": .string("text"), "text": .string("SYNTHETIC_PRIVATE_TOOL_RESULT")])])])
    }
    func readResource(uri: String) async throws -> JSONValue { throw MCPError.invalidRequest }
    func cancel() async {}
}

@MainActor private final class NotificationEnvironment {
    let root: URL
    let defaultsName = "io.woowtech.notification-check." + UUID().uuidString
    let defaults: UserDefaults
    let learning: LearningStore
    let repository: ModelSettingsRepository
    init(memory: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-notification-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: defaultsName)!
        repository = ModelSettingsRepository(defaults: defaults, credentials: NotificationSyntheticCredentials())
        _ = try repository.save(baseURL: "https://notifications.example.invalid/v1", model: "synthetic", newKey: "synthetic-not-a-key")
        learning = LearningStore(vault: EncryptedLearningFile(url: root.appendingPathComponent("learning.vault"), keys: NotificationSyntheticKeys()))
        guard learning.updatePreferences({ $0.useMemory = memory; $0.autoRemember = false }) else {
            throw TaskNotificationChecks.Failure(check: "isolated learning ready")
        }
    }
    func close() throws { defaults.removePersistentDomain(forName: defaultsName); try FileManager.default.removeItem(at: root) }
    func session(_ model: NotificationScriptedModel) -> ChatSession {
        ChatSession(learning: learning, repository: repository, client: model)
    }
}

#if TASK_NOTIFICATIONS_APP_STANDALONE
@main
#endif
enum CheckTaskNotificationApp {
    typealias Checks = TaskNotificationChecks
    static let privateOutput = "SYNTHETIC_PRIVATE_MODEL_OUTPUT"
    static let finish = #"{"action":"finish","answer":"SYNTHETIC_PRIVATE_MODEL_OUTPUT"}"#
    @MainActor static func main() async {
        do {
            var groups: [String: Int] = [:]
            let cases: [(String, () async throws -> Void)] = [
                ("nativeUNContentAndScope", nativeContent), ("factoryAndPreferences", preferences),
                ("realChatSuccessFailureClear", realChat), ("realChatCancelGeneration", lateChat),
                ("realMCPApprovalCompleteDecline", realMCP), ("realProfileMemoryApprovals", localApprovals)
            ]
            for (name, body) in cases {
                let before = Checks.assertions; try await body(); groups[name] = Checks.assertions - before
            }
            let result: [String: Any] = ["status": "PASS", "assertions": Checks.assertions, "groups": groups,
                "actual_chat_session_and_combine": true, "actual_UNNotificationRequest_objects": true,
                "notification_delivery": false, "system_notification_center_access": false,
                "network_or_personal_keychain": false]
            print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
        } catch {
            print("FAIL: " + ((error as? Checks.Failure)?.check ?? "synthetic_app_check_failed")); exit(1)
        }
    }

    @MainActor static func nativeContent() async throws {
        let scope = UUID().uuidString
        for kind in [TaskNotificationKind.completed, .approval, .test] {
            for sound in [false, true] {
                let payload = TaskNotificationPayload(kind: kind, destination: .chat)
                let request = TaskNotificationCenterAdapter.request(payload, sound: sound, scope: scope)
                try Checks.expect(request.content.title == payload.title && request.content.body == payload.body, "actual UN fixed text")
                try Checks.expect((request.content.sound != nil) == sound, "actual UN sound property")
                try Checks.expect(request.content.userInfo.isEmpty && request.content.attachments.isEmpty, "no user info or attachments")
                try Checks.expect(request.content.subtitle.isEmpty && request.content.categoryIdentifier.isEmpty && request.content.threadIdentifier.isEmpty, "no sensitive metadata or actionable category")
                try Checks.expect(request.content.badge == nil && request.trigger == nil, "immediate local notification, no badge")
                try Checks.expect(TaskNotificationCenterAdapter.logicalIdentifier(request.identifier, scope: scope) == payload.identifier, "own scope maps to logical ID")
                try Checks.expect(TaskNotificationCenterAdapter.logicalIdentifier(request.identifier, scope: "production") == nil, "cross-scope response rejected")
            }
        }
    }

    @MainActor static func preferences() async throws {
        let prod = try TaskNotificationStoreConfiguration.resolve(arguments: [])
        try Checks.expect(prod.scope == "production" && !prod.reset, "production factory config")
        #if DEBUG
        let namespace = UUID().uuidString
        let basic = ["-UITestMode", "-UITestNamespace", namespace]
        for args in [basic, basic + ["-LiveMCPUITest"], basic + ["-UITestMCPFixture"], basic + ["-UITestTranscript"],
                     ["-LiveModelUITest", "-LiveModelUITestNamespace", namespace],
                     ["-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveMCPConversationUITest"]] {
            let test = try TaskNotificationStoreConfiguration.resolve(arguments: args)
            try Checks.expect(test.scope == namespace && test.suite != prod.suite, "existing UI launch mode isolated")
        }
        for reset in ["-UITestResetStorage", "-LiveMCPUITestCleanup"] {
            let value = try TaskNotificationStoreConfiguration.resolve(arguments: basic + [reset])
            try Checks.expect(value.reset, "own reset flag honored")
        }
        for invalid in [["-UITestMode"], ["-LiveMCPUITest"], basic + ["-UITestMode"],
                        basic + ["-UITestNamespace", namespace], basic + ["-LiveModelUITest"],
                        basic + ["-LiveModelUITestNamespace", namespace], ["-UITestMode", "-UITestNamespace", "bad"]] {
            do { _ = try TaskNotificationStoreConfiguration.resolve(arguments: invalid); throw Checks.Failure(check: "invalid namespace accepted") }
            catch TaskNotificationStoreConfiguration.Invalid.namespace { Checks.assertions += 1 }
        }
        #endif
        let name = "io.woowtech.notification-persistence-check." + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let center = TaskNotificationFakeCenter()
        let first = TaskNotificationService(client: center, enabled: defaults.bool(forKey: TaskNotificationStore.preferenceKey),
            persistEnabled: { defaults.set($0, forKey: TaskNotificationStore.preferenceKey) })
        try Checks.expect(!first.enabled, "new isolated defaults off")
        await first.enableFromUserGesture()
        let reopened = UserDefaults(suiteName: name)!
        try Checks.expect(reopened.bool(forKey: TaskNotificationStore.preferenceKey), "actual defaults reopened enabled")
        let second = TaskNotificationService(client: center, enabled: reopened.bool(forKey: TaskNotificationStore.preferenceKey),
            persistEnabled: { reopened.set($0, forKey: TaskNotificationStore.preferenceKey) })
        await second.refresh()
        try Checks.expect(second.enabled && center.permissionCalls == 0, "relaunch preference without request")
        second.disable(); await second.waitUntilIdle()
        try Checks.expect(!defaults.bool(forKey: TaskNotificationStore.preferenceKey), "actual defaults disabled persists")
        try Checks.expect(second.systemSettings.authorization == .authorized, "App opt-out does not falsify OS authorization")
        first.disable(); await first.waitUntilIdle()
    }

    @MainActor static func realChat() async throws {
        let env = try NotificationEnvironment(); defer { try? env.close() }
        let model = NotificationScriptedModel([privateOutput, privateOutput])
        let chat = env.session(model)
        let center = TaskNotificationFakeCenter(); let service = await Checks.active(center)
        let bridge = TaskNotificationChatBridge(session: chat, service: service)
        defer { bridge.invalidate(); service.disable() }
        chat.draft = "SYNTHETIC_PRIVATE_UTTERANCE"; chat.send()
        try await Checks.until { !chat.isSubmitting }; await service.waitUntilIdle()
        try Checks.expect(chat.entries.count == 2 && center.pending.count == 1, "actual ChatSession success notifies")
        try privacy(center)
        center.deliver(); chat.newConversation(); await service.waitUntilIdle()
        try Checks.expect(center.delivered.isEmpty, "actual newConversation clears result")
        chat.draft = "synthetic second request"; chat.send()
        try await Checks.until { !chat.isSubmitting }; await service.waitUntilIdle()
        chat.removeSettings(); await service.waitUntilIdle()
        try Checks.expect(chat.savedSettings == nil && center.pending.isEmpty, "actual removeSettings clears notification")

        let failedEnv = try NotificationEnvironment(); defer { try? failedEnv.close() }
        let failed = failedEnv.session(NotificationScriptedModel([]))
        let failedBridge = TaskNotificationChatBridge(session: failed, service: service)
        failed.draft = "synthetic failed request"; failed.send()
        try await Checks.until { !failed.isSubmitting }; await service.waitUntilIdle()
        try Checks.expect(failed.chatError != nil && center.additions.count == 2, "actual model failure emits no completion")
        failedBridge.invalidate()
    }

    @MainActor static func lateChat() async throws {
        let env = try NotificationEnvironment(); defer { try? env.close() }
        let gate = NotificationModelGate(); let model = NotificationScriptedModel([privateOutput, privateOutput], gate: gate)
        let chat = env.session(model); let center = TaskNotificationFakeCenter(); let service = await Checks.active(center)
        let bridge = TaskNotificationChatBridge(session: chat, service: service)
        defer { bridge.invalidate(); service.disable() }
        chat.draft = "synthetic cancelled request"; chat.send()
        let end = Date().addingTimeInterval(3)
        while !(await gate.entered) {
            guard Date() < end else { throw Checks.Failure(check: "actual model entered bounded wait") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard let task = Mirror(reflecting: chat).children.first(where: { $0.label == "request" })?.value as? Task<Void, Never> else {
            throw Checks.Failure(check: "observe actual request for deterministic join")
        }
        chat.cancel(); await gate.release(); await task.value; await service.waitUntilIdle()
        try Checks.expect(chat.entries.isEmpty && center.addCalls == 0, "actual cancelled late model reply rejected")
        chat.draft = "synthetic new generation"; chat.send()
        try await Checks.until { !chat.isSubmitting }; await service.waitUntilIdle()
        try Checks.expect(center.addCalls == 1, "new generation can complete after cancellation")
        let rebound = TaskNotificationChatBridge(session: chat, service: service)
        await service.waitUntilIdle()
        try Checks.expect(center.addCalls == 1, "binding to actual existing transcript never replays")
        rebound.invalidate()
    }

    @MainActor static func realMCP() async throws {
        for approve in [true, false] {
            let env = try NotificationEnvironment(); defer { try? env.close() }
            let model = NotificationScriptedModel([
                #"{"action":"call_tool","name":"synthetic_read","arguments":{"text":"SYNTHETIC_PRIVATE_MCP_ARGUMENT"}}"#, finish])
            let chat = env.session(model)
            let server = NotificationMCPServer()
            let mcp = MCPSession(repository: NotificationMCPEndpoint(), clientFactory: { _ in server })
            mcp.connect(); try await Checks.until { mcp.phase == .connected }; mcp.selectTool("synthetic_read", enabled: true)
            chat.usesMCP = true
            let center = TaskNotificationFakeCenter(); let service = await Checks.active(center)
            let bridge = TaskNotificationChatBridge(session: chat, service: service)
            defer { bridge.invalidate(); service.disable(); mcp.disconnect() }
            chat.draft = "synthetic MCP request"; chat.send(mcp: mcp)
            try await Checks.until { chat.pendingMCPApproval != nil }; await service.waitUntilIdle()
            try Checks.expect(center.pending.values.first?.kind == .approval, "actual MCP pending approval notifies")
            let calls = await server.calls
            try Checks.expect(calls == 0, "notification does not approve MCP")
            let approvalID = chat.pendingMCPApproval!.id
            let id = center.pending.keys.first!
            let destination = TaskNotificationPayload.destination(for: id)
            try Checks.expect(destination == .chat && chat.pendingMCPApproval?.id == approvalID, "route extraction leaves approval pending")
            chat.resolveMCPApproval(id: approvalID, approved: approve)
            try await Checks.until { !chat.isSubmitting }; await service.waitUntilIdle()
            let finalCalls = await server.calls
            try Checks.expect(finalCalls == (approve ? 1 : 0), "only actual App approval executes MCP")
            try Checks.expect(!center.pending.values.contains { $0.kind == .approval }, "actual MCP resolve revokes prompt")
            try Checks.expect(center.pending.count == (approve ? 1 : 0), "actual MCP success/decline distinguished")
            try privacy(center)
        }
    }

    @MainActor static func localApprovals() async throws {
        for memory in [false, true] {
            let env = try NotificationEnvironment(memory: true); defer { try? env.close() }
            let proposal = memory
                ? #"{"action":"memory_save","arguments":{"kind":"preference","content":"Prefer jasmine tea","quote":"Prefer jasmine tea","keywords":["tea"]}}"#
                : #"{"action":"profile_edit","arguments":{"op":"add","text":"Prefer jasmine tea","quote":"Please remember Prefer jasmine tea"}}"#
            let chat = env.session(NotificationScriptedModel([proposal, finish]))
            let center = TaskNotificationFakeCenter(); let service = await Checks.active(center)
            let bridge = TaskNotificationChatBridge(session: chat, service: service)
            defer { bridge.invalidate(); service.disable() }
            chat.draft = "Please remember Prefer jasmine tea"; chat.send()
            try await Checks.until { memory ? chat.pendingMemoryReview != nil : chat.pendingProfileReview != nil }
            await service.waitUntilIdle()
            try Checks.expect(center.pending.values.first?.kind == .approval, "actual local review notifies")
            if memory { chat.resolveMemoryReview(id: chat.pendingMemoryReview!.id, approved: true) }
            else { chat.resolveProfileReview(id: chat.pendingProfileReview!.id, approved: true) }
            try await Checks.until { !chat.isSubmitting }; await service.waitUntilIdle()
            try Checks.expect(chat.chatError == nil && center.pending.values.first?.kind == .completed, "actual local approval completion replaces prompt")
            try Checks.expect(center.pending.count == 1, "no leftover local approval notification")
            try privacy(center)
        }
    }

    @MainActor static func privacy(_ center: TaskNotificationFakeCenter) throws {
        for entry in center.additions {
            let request = TaskNotificationCenterAdapter.request(entry.payload, sound: entry.sound)
            let text = request.identifier + request.content.title + request.content.body
            for sentinel in [privateOutput, "SYNTHETIC_PRIVATE_UTTERANCE", "SYNTHETIC_PRIVATE_MCP_ARGUMENT", "SYNTHETIC_PRIVATE_TOOL_RESULT", "Prefer jasmine tea"] {
                try Checks.expect(!text.contains(sentinel), "real flow notification excludes private synthetic data")
            }
            try Checks.expect(request.content.userInfo.isEmpty, "real flow carries no private payload")
        }
    }
}

#if !TASK_NOTIFICATIONS_APP_STANDALONE
final class TaskNotificationAppTests: XCTestCase {
    @MainActor func testNativeUNContentAndScope() async throws { try await CheckTaskNotificationApp.nativeContent() }
    @MainActor func testFactoryAndPreferences() async throws { try await CheckTaskNotificationApp.preferences() }
    @MainActor func testRealChatSuccessFailureClear() async throws { try await CheckTaskNotificationApp.realChat() }
    @MainActor func testRealChatCancelGeneration() async throws { try await CheckTaskNotificationApp.lateChat() }
    @MainActor func testRealMCPApprovalCompleteDecline() async throws { try await CheckTaskNotificationApp.realMCP() }
    @MainActor func testRealProfileMemoryApprovals() async throws { try await CheckTaskNotificationApp.localApprovals() }
}
#endif
#endif
