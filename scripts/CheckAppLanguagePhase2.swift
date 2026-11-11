import Foundation
import UserNotifications
import AssistantDomain
import AssistantSkills
@testable import AssistantMCP

private final class LanguageMCPEndpoint: MCPEndpointStoring {
    var endpoint: URL?
    var unavailable = false
    init(_ endpoint: URL) { self.endpoint = endpoint }
    func load() throws -> URL? { if unavailable { throw MCPSettingsError.keychainStatus(-25308) }; return endpoint }
    func save(endpoint: String) throws { self.endpoint = try MCPSettingsStore.validate(endpoint) }
    func remove() throws { endpoint = nil }
}

@main enum LanguagePhase2Checks {
    struct Failure: Error { let check: String }
    @MainActor static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw Failure(check: label) }; count += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("language-phase2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1])
        let info = ["CFBundleIdentifier":"io.woowtech.language-phase2.check", "CFBundleDevelopmentRegion":"zh-Hant"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: root.appendingPathComponent("Info.plist"))
        for language in AppDisplayLanguage.allCases {
            try FileManager.default.copyItem(at: resources.appendingPathComponent(language.rawValue + ".lproj"),
                                             to: root.appendingPathComponent(language.rawValue + ".lproj"))
        }
        let bundle = Bundle(url: root)!
        let english = AppLocalizer(language: .english, bundle: bundle)
        let simplified = AppLocalizer(language: .simplifiedChinese, bundle: bundle)
        let traditional = AppLocalizer(language: .traditionalChinese, bundle: bundle)
        try check(english.text(.mcpSelectedCount(count: 1)) == "1 tool selected for chat", "English native plural singular")
        try check(english.text(.mcpSelectedCount(count: 2)) == "2 tools selected for chat", "English native plural other")
        try check(simplified.text(.mcpSelectedCount(count: 0)) == "已选取 0 个工具供对话使用", "Chinese native plural zero")
        let userQuery = "刪除 %@ %n %1$@ catalog.title %s"
        try check(english.text(.browserHistorySearch(query: userQuery)) == "Search: " + userQuery, "query is data, not a key or format")
        try check(traditional.text(.searchInvalid).contains("一個 %s"), "literal percent survives explicit formatting")
        try check(english.text(.searchTemplate) == "https://example.com/search?q=%s", "URL placeholder unchanged")
        let failures: [MCPSettingsError] = [.keychainStatus(-25308), .invalidEndpoint, .unavailableKeychain, .invalidTestNamespace, .missingLiveTestEndpoint]
        for error in failures {
            let message = AppLocalizer.mcpSettingsError(error)
            try check(traditional.text(message) == error.errorDescription, "legacy MCP error matches Traditional Chinese exactly")
            try check(!english.resolve(message).usedFallback && !simplified.resolve(message).usedFallback, "MCP typed error has both translations")
        }
        for requirement in SkillCatalogRequirement.allCases {
            let message = AppLocalizer.skillRequirement(requirement)
            try check(traditional.text(message) == requirement.title, "catalog capability semantics unchanged")
            try check(!english.resolve(message).usedFallback && !simplified.resolve(message).usedFallback, "catalog requirements translated")
        }
        let catalogBytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        let catalog = try BundledSkillCatalog.load(data: catalogBytes)
        for entry in catalog.entries {
            let message = AppLocalizer.skillReadiness(id: entry.id)
            try check(traditional.text(message) == entry.readiness, "catalog readiness semantics unchanged")
            try check(!english.resolve(message).usedFallback && !simplified.resolve(message).usedFallback, "catalog readiness translated")
            try check(entry.original.executable == false && !entry.originalExecutionSupported, "display language grants no execution authority")
        }
        try check(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) == catalogBytes, "pinned original archive unchanged")
        for kind in [TaskNotificationKind.completed, .approval, .test] {
            let payload = TaskNotificationPayload(kind: kind, destination: .chat)
            let scope = UUID().uuidString
            let zh = TaskNotificationCenterAdapter.request(payload, sound: true, scope: scope, localizer: traditional)
            let en = TaskNotificationCenterAdapter.request(payload, sound: false, scope: scope, localizer: english)
            let cn = TaskNotificationCenterAdapter.request(payload, sound: false, scope: scope, localizer: simplified)
            try check(zh.content.title == payload.title && zh.content.body == payload.body, "Traditional notification payload parity")
            try check(en.content.title != zh.content.title && cn.content.body != zh.content.body, "real UN content reflects language")
            try check(en.identifier == zh.identifier && cn.identifier == zh.identifier, "language preserves notification identity")
            try check(TaskNotificationCenterAdapter.logicalIdentifier(en.identifier, scope: scope) == payload.identifier,
                      "localized notification preserves exact route")
            try check(en.content.userInfo.isEmpty && en.content.attachments.isEmpty && en.content.categoryIdentifier.isEmpty
                      && en.content.subtitle.isEmpty && en.content.threadIdentifier.isEmpty && en.content.badge == nil,
                      "notification localization introduces no private or actionable payload")
            try check(en.content.sound == nil && zh.content.sound != nil, "language does not override sound choice")
        }
        for value in [TaskNotificationAuthorization.unknown, .notDetermined, .denied, .authorized, .provisional, .ephemeral] {
            try check(!english.resolve(AppLocalizer.notificationAuthorization(value)).usedFallback, "notification authorization translation")
        }
        for value in [TaskNotificationSetting.unknown, .notSupported, .disabled, .enabled] {
            try check(!simplified.resolve(AppLocalizer.notificationSetting(value)).usedFallback, "notification setting translation")
        }
        for value in [TaskNotificationNotice.authorizationUnavailable, .deliveryUnavailable] {
            try check(traditional.text(AppLocalizer.notificationNotice(value)) == value.message, "notification error semantics unchanged")
        }
        let suite = "language-mcp-check-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageStore(defaults: defaults, preferredLanguages: { ["zh-TW"] })
        let gate = DispatchSemaphore(value: 0)
        defer { gate.signal() }
        let toolName = "原始工具_mcpTitle_%@"
        let resourceName = "Original resource / 未選取"
        let scenario = MCPProtocolFixture.Scenario { _, body, _ in
            if body["method"] == .string("initialize") {
                guard gate.wait(timeout: .now() + 5) == .success else { throw Failure(check: "bounded MCP gate") }
                return try .result(.object(["protocolVersion": .string("2025-03-26"),
                    "capabilities": .object(["tools": .object([:]), "resources": .object([:])]),
                    "serverInfo": .object(["name": .string("Synthetic"), "version": .string("1")])]), request: body)
            }
            if body["method"] == .string("notifications/initialized") { return .init(status: 202) }
            if body["method"] == .string("tools/list") {
                return try .result(.object(["tools": .array([.object(["name": .string(toolName), "inputSchema": .object(["type": .string("object")])])])]), request: body)
            }
            if body["method"] == .string("resources/list") {
                return try .result(.object(["resources": .array([.object(["name": .string(resourceName), "uri": .string("synthetic://selected")])])]), request: body)
            }
            throw Failure(check: "unexpected MCP execution")
        }
        let endpoint = MCPProtocolFixture.register(scenario)
        defer { MCPProtocolFixture.remove(endpoint) }
        let repository = LanguageMCPEndpoint(endpoint)
        let client = MCPClient(endpoint: endpoint, configuration: MCPProtocolFixture.configuration())
        let session = MCPSession(repository: repository, clientFactory: { _ in client })
        var invalidations = 0
        session.onConnectionChange = { invalidations += 1 }
        session.connect()
        try await wait { scenario.records.count == 1 }
        try check(session.phase == .connecting && session.statusMessage == .mcpConnecting, "actual MCP initialize is in flight")
        try check(language.setFromUser(.english), "language changes while real URLSession request is held")
        try check(english.text(session.statusMessage) == "Establishing an MCP session…", "stored state re-renders without restarting MCP")
        try check(invalidations == 0 && scenario.records.count == 1, "language does not revoke or restart connection")
        gate.signal()
        try await wait { !session.isBusy }
        try check(session.phase == .connected && session.noticeText == .mcpDiscoveryNotice, "real MCP discovery completes")
        try check(session.tools.first?.name == toolName && session.resources.first?.name == resourceName, "catalog names stay verbatim")
        session.selectTool(toolName, enabled: true)
        session.selectResource("synthetic://selected", enabled: true)
        let connection = try session.conversationConnection()
        let selected = session.selectedToolNames
        let beforeInvalidations = invalidations
        try check(language.setFromUser(.simplifiedChinese), "language changes with existing tool selection")
        let after = try session.conversationConnection()
        try check((connection.0 as AnyObject) === (after.0 as AnyObject) && session.selectedToolNames == selected
                  && session.selectedResourceURIs == ["synthetic://selected"], "same client, tool selection and resource grant remain")
        try check(invalidations == beforeInvalidations && scenario.records.count == 4, "no extra network requests or permission invalidation")
        try check(scenario.records.map { $0.1["method"] } == [.string("initialize"), .string("notifications/initialized"), .string("tools/list"), .string("resources/list")], "only handshake and catalogs, no tools or resource reads")
        session.disconnect()
        try check(session.phase == .disconnected && !session.canUseInConversation && session.selectedToolNames.isEmpty,
                  "explicit disconnect still revokes all selections")
        try check(simplified.text(session.noticeText!) != english.text(session.noticeText!), "disconnect notice remains dynamically renderable")
        repository.unavailable = true
        let failed = MCPSession(repository: repository)
        try check(failed.phase == .failed && failed.errorText == .mcpKeychainStatus(code: "-25308"), "actual store failure maps to a closed message")
        try check(!english.text(failed.errorText!).contains(endpoint.absoluteString), "endpoint excluded from localized error")
        print("{\"passed\":\(count),\"failed\":0,\"actual_mcp_urlsession_requests\":4,\"external_network_requests\":0,\"system_notification_center_access\":false,\"actual_UN_content\":true,\"native_ios_ui\":false}")
    }
    @MainActor static func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw Failure(check: "bounded condition") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}
