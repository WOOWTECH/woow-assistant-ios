#if !SKILL_EXECUTION_SMOKE && !SKILLS_CORE_SMOKE
import AssistantModels
import Combine
import Foundation
@testable import AssistantSkills
#if !SELF_CONFIGURATION_SMOKE
import XCTest
#endif

@MainActor enum SelfConfigurationChecks {
    struct Failure: Error, LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
    @MainActor final class Scope {
        let name = "SelfConfigurationTests." + UUID().uuidString
        let defaults: UserDefaults
        let store: SelfConfigurationStore
        init() {
            defaults = UserDefaults(suiteName: name)!
            store = SelfConfigurationStore(defaults: defaults)
        }
        func cleanup() { defaults.removePersistentDomain(forName: name) }
    }
    static var assertions = 0
    static let list = "{\"action\":\"tool\",\"name\":\"settings_list\",\"arguments\":{}}"
    static let configuration = ModelConfiguration(baseURL: URL(string: "https://self-config.invalid/v1")!, model: "synthetic-model")
    static var key: String { SelfConfigurationSocketFixture.key }
    static func set(_ value: String, key: String = "appearance") throws -> String {
        let object: [String: Any] = ["action": "tool", "name": "settings_set", "arguments": ["key": key, "value": value]]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !value() { throw Failure(message: message) }
    }
    static func rejects(_ expected: SelfConfigurationError, _ operation: () async throws -> Void) async throws {
        do { try await operation(); throw Failure(message: "expected rejection: \(expected)") }
        catch let error as SelfConfigurationError { try expect(error == expected, "wrong rejection: \(error)") }
    }
    static func wait(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw Failure(message: "fixture did not reach bounded gate") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
    static func run(_ store: SelfConfigurationStore, replies: [String]) async throws -> SelfConfigurationOutcome {
        let runtime = try SelfConfigurationRuntime(request: "請把外觀改成深色", store: store)
        return try await runtime.run(client: SelfConfigurationSequenceModel(replies), configuration: configuration, apiKey: key)
    }

    static func defaultsAndIsolation() async throws {
        let scope = Scope(), other = Scope(); defer { scope.cleanup(); other.cleanup() }
        try expect(scope.store.appearance == .system && !scope.store.allowSelfConfiguration, "default follows system; model permission is off")
        try await rejects(.permissionRequired) { _ = try SelfConfigurationRuntime(request: "請改成深色", store: scope.store) }
        scope.defaults.set("synthetic-secret-sentinel", forKey: "model.apiKey")
        scope.defaults.set("synthetic-login-sentinel", forKey: "browser.login")
        scope.store.setPermissionFromUser(true)
        scope.store.setAppearanceFromUser(.light)
        let reopened = SelfConfigurationStore(defaults: UserDefaults(suiteName: scope.name)!)
        try expect(reopened.appearance == .light && reopened.allowSelfConfiguration, "real defaults survive store recreation")
        try expect(other.store.appearance == .system && !other.store.allowSelfConfiguration, "separate defaults suite remains untouched")
        try expect(scope.defaults.string(forKey: "model.apiKey") == "synthetic-secret-sentinel"
            && scope.defaults.string(forKey: "browser.login") == "synthetic-login-sentinel", "manual edits do not touch other preferences")
        reopened.setPermissionFromUser(false)
        try await rejects(.permissionRequired) { _ = try SelfConfigurationRuntime(request: "深色", store: scope.store) }
    }

    static func observableWriteReadback() async throws {
        let scope = Scope(); defer { scope.cleanup() }
        scope.store.setPermissionFromUser(true)
        var observed: [SelfConfigurationAppearance] = []
        let subscription = scope.store.$appearance.sink { observed.append($0) }; defer { subscription.cancel() }
        var previous = SelfConfigurationAppearance.system
        for appearance in [SelfConfigurationAppearance.dark, .light, .system] {
            let model = SelfConfigurationSequenceModel([list, try set(appearance.rawValue)])
            let runtime = try SelfConfigurationRuntime(request: "請調整外觀", store: scope.store)
            var steps: [String] = []
            var events: [SelfConfigurationEvent] = []
            let outcome = try await runtime.run(client: model, configuration: configuration, apiKey: key, onEvent: { events.append($0) }, onStep: { steps.append($0) })
            guard case .changed(let receipt) = outcome else { throw Failure(message: "expected a real store receipt") }
            try expect(events == [.listedOptions, .appliedAppearance(appearance)], "typed events describe actual readback")
            try expect(receipt.appearance == appearance && receipt.previous == previous, "receipt is actual old/new value")
            try expect(scope.store.appearance == appearance && observed.last == appearance, "appearance publishes immediately")
            try expect(SelfConfigurationStore(defaults: UserDefaults(suiteName: scope.name)!).appearance == appearance, "readback survives another store instance")
            let inputs = await model.inputs
            try expect(inputs.count == 2 && steps.count == 2, "exactly list then set, bounded to two model calls")
            let result = try JSONDecoder().decode(ListReply.self, from: Data(inputs[1].last!.content.utf8))
            try expect(result.tool_result == "settings_list" && result.settings.count == 1, "only one real option")
            try expect(result.settings[0].key == "appearance" && result.settings[0].value == previous.rawValue
                && result.settings[0].choices == ["system", "light", "dark"], "set turn receives current value and exact choices")
            try await rejects(.alreadyUsed) { _ = try await runtime.run(client: model, configuration: configuration, apiKey: key) }
            previous = appearance
        }
        try expect(observed == [.system, .dark, .light, .system], "reactive theme changes include resetting to system")
    }
    private struct ListReply: Decodable { let tool_result: String; let settings: [SelfConfigurationOption] }

    static func closedProtocol() async throws {
        let scope = Scope(); defer { scope.cleanup() }
        scope.store.setPermissionFromUser(true)
        for key in ["model", "apiKey", "login", "delete", "network", "proxy", "allowSelfConfig", "operating_pace", "mute_apps", "capsule", "keep_screen_on", "appearance/../model"] {
            try await rejects(.unavailableSetting) { _ = try await run(scope.store, replies: [list, try set("dark", key: key)]) }
        }
        for value in ["Dark", " light ", "true", "dark/../light", ""] {
            try await rejects(.invalidValue) { _ = try await run(scope.store, replies: [list, try set(value)]) }
        }
        try await rejects(.listRequired) { _ = try await run(scope.store, replies: [try set("dark")]) }
        let invalid = [
            "```json\n" + list + "\n```", "[" + list + "]", list + list,
            "{\"action\":\"tool\",\"name\":\"settings_list\",\"arguments\":{\"key\":\"model\"}}",
            "{\"action\":\"tool\",\"name\":\"settings_set\",\"arguments\":{\"key\":\"appearance\",\"value\":\"dark\",\"permission\":true}}",
            "{\"action\":\"tool\",\"name\":\"settings_set\",\"arguments\":{\"key\":\"appearance\",\"value\":false}}",
            String(repeating: "x", count: 8193)
        ]
        for response in invalid {
            try await rejects(.invalidCommand) { _ = try await run(scope.store, replies: [list, response]) }
        }
        try await rejects(.invalidCommand) { _ = try await run(scope.store, replies: [list, list]) }
        try expect(scope.store.appearance == .system, "all denied protocol cases preserve appearance")
        let question = "請確認要淺色還是深色？"
        let ask = String(decoding: try JSONSerialization.data(withJSONObject: ["action": "ask_user", "question": question]), as: UTF8.self)
        let clarification = try await run(scope.store, replies: [ask])
        try expect(clarification == .needsClarification(question), "ambiguous request stops without writing")
        let unchanged = try await run(scope.store, replies: ["{\"action\":\"finish\"}"])
        try expect(unchanged == .unchanged && scope.store.appearance == .system, "model finish is not a success receipt")
        for request in ["", String(repeating: "x", count: 2001)] {
            try await rejects(.invalidRequest) { _ = try SelfConfigurationRuntime(request: request, store: scope.store) }
        }
    }

    static func lateRepliesCannotWrite() async throws {
        // Each variant reaches the second request, when the next reply could write.
        for variant in 0..<6 {
            let scope = Scope(); defer { scope.cleanup() }
            scope.store.setPermissionFromUser(true)
            let model = SelfConfigurationLateModel()
            let runtime = try SelfConfigurationRuntime(request: "請改成深色", store: scope.store)
            let operation = Task { try await runtime.run(client: model, configuration: configuration, apiKey: key) }
            try await wait { await model.pending }
            switch variant {
            case 0: runtime.cancel()
            case 1: operation.cancel()
            case 2: scope.store.setPermissionFromUser(false)
            case 3: scope.store.setPermissionFromUser(false); scope.store.setPermissionFromUser(true)
            case 4: scope.store.setAppearanceFromUser(.light)
            default:
                let otherInstance = SelfConfigurationStore(defaults: UserDefaults(suiteName: scope.name)!)
                otherInstance.setPermissionFromUser(false); otherInstance.setPermissionFromUser(true)
            }
            await model.release(try set("dark"))
            try await rejects(variant < 2 ? .cancelled : .authorizationChanged) { _ = try await operation.value }
            try expect(scope.store.appearance == (variant == 4 ? .light : .system), "late write rejected for variant \(variant)")
            try expect(SelfConfigurationStore(defaults: UserDefaults(suiteName: scope.name)!).appearance == scope.store.appearance,
                       "late response did not change persisted appearance")
        }
    }

    static func cancellationBetweenTools() async throws {
        let scope = Scope(); defer { scope.cleanup() }
        scope.store.setPermissionFromUser(true)
        let runtime = try SelfConfigurationRuntime(request: "改為深色", store: scope.store)
        let model = SelfConfigurationSequenceModel([list, try set("dark")])
        try await rejects(.cancelled) {
            _ = try await runtime.run(client: model, configuration: configuration, apiKey: key, onStep: { _ in runtime.cancel() })
        }
        let inputs = await model.inputs
        try expect(inputs.count == 1 && scope.store.appearance == .system, "cancel after list prevents the second request")
    }

    static func realHTTPRoundTrip() async throws {
        let scope = Scope(); defer { scope.cleanup() }
        scope.store.setPermissionFromUser(true)
        scope.defaults.set("synthetic-secret-sentinel", forKey: "model.apiKey")
        let server = try SelfConfigurationSocketFixture([list, try set("dark")]); defer { server.stop() }
        let base = SelfConfigurationHTTPBridge.register(try await server.start()); defer { SelfConfigurationHTTPBridge.remove(base) }
        let transport = SelfConfigurationHTTPBridge.session(); defer { transport.invalidateAndCancel() }
        let runtime = try SelfConfigurationRuntime(request: "請把外觀改成深色", store: scope.store)
        var events: [SelfConfigurationEvent] = []
        let outcome = try await runtime.run(client: HTTPChatModelClient(session: transport),
            configuration: .init(baseURL: base, model: "synthetic-socket-model"), apiKey: key, onEvent: { events.append($0) })
        guard case .changed(let receipt) = outcome else { throw Failure(message: "HTTP operation did not produce a real receipt") }
        try expect(events == [.listedOptions, .appliedAppearance(.dark)], "typed events follow actual HTTP and persistent readback")
        try expect(receipt.appearance == .dark && scope.store.appearance == .dark, "socket replies cause the real store update")
        let bodies = server.requestBodies
        try expect(bodies.count == 2, "server actually received two HTTP requests")
        let requests = try bodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        try expect(requests.allSatisfy { ($0["model"] as? String) == "synthetic-socket-model" && ($0["stream"] as? Bool) == false }, "actual production request encoding")
        let messages = requests[1]["messages"] as! [[String: String]]
        let reply = try JSONDecoder().decode(ListReply.self, from: Data(messages.last!["content"]!.utf8))
        try expect(reply.settings.map(\.key) == ["appearance"] && reply.settings[0].value == "system", "server receives actual list result, not invented settings")
        try expect(!bodies.contains { String(decoding: $0, as: UTF8.self).contains("synthetic-secret-sentinel") }, "unrelated defaults never reach model HTTP body")
        try expect(SelfConfigurationStore(defaults: UserDefaults(suiteName: scope.name)!).appearance == .dark, "real HTTP result survives reopening defaults")
    }

    static func realHTTPLateRevocation() async throws {
        let scope = Scope(); defer { scope.cleanup() }
        scope.store.setPermissionFromUser(true)
        let server = try SelfConfigurationSocketFixture([list, try set("dark")], holdSecond: true); defer { server.stop() }
        let base = SelfConfigurationHTTPBridge.register(try await server.start()); defer { SelfConfigurationHTTPBridge.remove(base) }
        let transport = SelfConfigurationHTTPBridge.session(); defer { transport.invalidateAndCancel() }
        let runtime = try SelfConfigurationRuntime(request: "請改成深色", store: scope.store)
        let operation = Task { try await runtime.run(client: HTTPChatModelClient(session: transport),
            configuration: .init(baseURL: base, model: "synthetic-socket-model"), apiKey: key) }
        try await wait { server.requestBodies.count == 2 }
        scope.store.setPermissionFromUser(false); scope.store.setPermissionFromUser(true)
        server.release()
        try await rejects(.authorizationChanged) { _ = try await operation.value }
        try expect(scope.store.appearance == .system, "HTTP write reply arriving after revoke/regrant is rejected")
        try expect(SelfConfigurationStore(defaults: UserDefaults(suiteName: scope.name)!).appearance == .system, "revoked HTTP did not persist")
    }

    static func realHTTPFailure() async throws {
        let scope = Scope(); defer { scope.cleanup() }
        scope.store.setPermissionFromUser(true)
        let server = try SelfConfigurationSocketFixture(["synthetic-response-must-not-leak"], status: 401); defer { server.stop() }
        let base = SelfConfigurationHTTPBridge.register(try await server.start()); defer { SelfConfigurationHTTPBridge.remove(base) }
        let transport = SelfConfigurationHTTPBridge.session(); defer { transport.invalidateAndCancel() }
        let runtime = try SelfConfigurationRuntime(request: "請改成深色", store: scope.store)
        try await rejects(.modelFailed) { _ = try await runtime.run(client: HTTPChatModelClient(session: transport),
            configuration: .init(baseURL: base, model: "synthetic-socket-model"), apiKey: key) }
        try expect(server.requestBodies.count == 1 && scope.store.appearance == .system, "actual HTTP rejection performs no write or retry")
    }
}

#if SELF_CONFIGURATION_SMOKE
@main struct SelfConfigurationStandalone {
    @MainActor static func main() async throws {
        try await SelfConfigurationChecks.defaultsAndIsolation(); print("PASS isolated UserDefaults and default-off permission")
        try await SelfConfigurationChecks.observableWriteReadback(); print("PASS actual persistence, readback and immediate Combine appearance updates")
        try await SelfConfigurationChecks.closedProtocol(); print("PASS closed settings protocol, list-before-set and forbidden settings")
        try await SelfConfigurationChecks.lateRepliesCannotWrite(); print("PASS six late-response cancellation/revocation/manual-edit scenarios")
        try await SelfConfigurationChecks.cancellationBetweenTools(); print("PASS cancellation between list and set")
        try await SelfConfigurationChecks.realHTTPRoundTrip(); print("PASS production HTTP client -> real loopback server -> persisted readback")
        try await SelfConfigurationChecks.realHTTPLateRevocation(); print("PASS real delayed HTTP response rejected after revoke/regrant")
        try await SelfConfigurationChecks.realHTTPFailure(); print("PASS actual HTTP 401 is sanitized and performs no write")
        let scope = SelfConfigurationChecks.Scope(); defer { scope.cleanup() }
        try SelfConfigurationChecks.expect(scope.store.preferredColorScheme == nil, "system appearance removes override")
        scope.store.setAppearanceFromUser(.dark)
        try SelfConfigurationChecks.expect(scope.store.preferredColorScheme == .dark, "actual SwiftUI color scheme is dark")
        scope.store.setAppearanceFromUser(.light)
        try SelfConfigurationChecks.expect(scope.store.preferredColorScheme == .light, "actual SwiftUI color scheme is light")
        scope.store.setAppearanceFromUser(.system)
        try SelfConfigurationChecks.expect(scope.store.preferredColorScheme == nil, "reset restores system scheme")
        print("PASS SwiftUI ColorScheme mapping; total \(SelfConfigurationChecks.assertions) assertions")
    }
}
#else
final class SelfConfigurationTests: XCTestCase {
    func testDefaultPermissionAndIsolatedPersistence() async throws { try await SelfConfigurationChecks.defaultsAndIsolation() }
    func testListSetReadbackPublishesAppearance() async throws { try await SelfConfigurationChecks.observableWriteReadback() }
    func testClosedProtocolAndForbiddenSettings() async throws { try await SelfConfigurationChecks.closedProtocol() }
    func testCancellationRevocationAndManualEditsRejectLateReplies() async throws { try await SelfConfigurationChecks.lateRepliesCannotWrite() }
    func testCancellationBetweenTools() async throws { try await SelfConfigurationChecks.cancellationBetweenTools() }
    func testRealHTTPListSetAndPersistentReadback() async throws { try await SelfConfigurationChecks.realHTTPRoundTrip() }
    func testRealHTTPLateReplyAfterRevocation() async throws { try await SelfConfigurationChecks.realHTTPLateRevocation() }
    func testRealHTTPFailureHasNoWrite() async throws { try await SelfConfigurationChecks.realHTTPFailure() }
}
#endif
#endif
