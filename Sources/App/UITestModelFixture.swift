#if DEBUG
import AssistantModels
import Foundation

// DEBUG-only UI-test API. Release builds contain neither this client nor these switches.
// -UITestMode: replace HTTPChatModelClient; never contact a model provider.
// -UITestNamespace <UUID>: dedicated defaults suite AND Keychain service for this test.
// -UITestResetStorage: clear only that test namespace at launch; omit to test relaunch.
// -UITestKeychainWriteFailure: fail writes before changing the test Keychain/config.
// Prompts: [fixture:wait] waits cancellably; [fixture:error-once] fails once per launch.
// Every other prompt returns "測試回覆：<prompt>". Keys entered by tests are dummy strings.
enum UITestModelFixture {
    static func repository(arguments: [String]) -> ModelSettingsRepository {
        guard let flag = arguments.firstIndex(of: "-UITestNamespace"),
              arguments.indices.contains(flag + 1),
              let namespace = UUID(uuidString: arguments[flag + 1]) else {
            preconditionFailure("-UITestMode requires an isolated -UITestNamespace UUID")
        }
        let name = "io.woowtech.assistant.uitest.\(namespace.uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            preconditionFailure("Cannot create isolated UI test defaults")
        }
        let keychain = KeychainModelCredentials(service: name)
        if arguments.contains("-UITestResetStorage") {
            do { try keychain.removeAll() }
            catch { preconditionFailure("Cannot reset isolated UI test Keychain") }
            defaults.removePersistentDomain(forName: name)
        }
        let credentials: any ModelCredentialStoring = arguments.contains("-UITestKeychainWriteFailure")
            ? FailingWrites(base: keychain) : keychain
        let repository = ModelSettingsRepository(defaults: defaults, credentials: credentials)
        if arguments.contains("-UITestMCPFixture") {
            do { _ = try repository.save(baseURL: "https://model.example.invalid/v1", model: "fixture", newKey: "fixture-not-a-key") }
            catch { preconditionFailure("Cannot configure isolated MCP conversation fixture") }
        }
        return repository
    }

    private struct FailingWrites: ModelCredentialStoring {
        let base: KeychainModelCredentials
        func read(account: String) throws -> String? { try base.read(account: account) }
        func insert(_ key: String, account: String) throws { throw ModelSettingsError.unavailableKeychain }
        func remove(account: String) throws { try base.remove(account: account) }
        func removeAll() throws { try base.removeAll() }
    }
}

actor UITestChatModelClient: ChatModelClient {
    private var failedOnce = false

    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        let instructions = messages.first?.content ?? ""
        if instructions.hasPrefix("Ordinary chat with an available profile_edit tool.") {
            if messages.last?.content.hasPrefix("Host profile_edit receipt") == true {
                return #"{"action":"finish","answer":"個人檔案工具已完成。"}"#
            }
            let prompt = messages.last?.content ?? ""
            let operation: [String: String]?
            switch prompt {
            case "Remember Prefer tea": operation = ["op": "add", "text": "Prefer tea", "quote": prompt]
            case "Remember Prefer quiet": operation = ["op": "add", "text": "Prefer quiet", "quote": prompt]
            case "Replace Prefer tea with Prefer walks":
                operation = ["op": "replace", "match": "Prefer tea", "text": "Prefer walks", "quote": prompt]
            case "Delete Prefer walks": operation = ["op": "delete", "match": "Prefer walks", "quote": prompt]
            default: operation = nil
            }
            if let operation {
                // An actual proposal only; the fixture never applies or stores
                // it. Native review, approval and persistence remain required.
                return String(decoding: try JSONSerialization.data(withJSONObject:
                    ["action": "profile_edit", "arguments": operation]), as: UTF8.self)
            }
            let answer = try await complete(messages: Array(messages.dropFirst()), configuration: configuration, apiKey: apiKey)
            return String(decoding: try JSONSerialization.data(withJSONObject: ["action": "finish", "answer": answer]), as: UTF8.self)
        }
        if instructions.hasPrefix("You operate selected MCP tools") {
            if let result = messages.last?.content, result.hasPrefix("MCP execution result") {
                let raw = result.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                let payload = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
                let body = payload?["result"] as? [String: Any]
                let parts = (body?["content"] ?? body?["contents"]) as? [[String: Any]]
                let answer = parts?.first?["text"] as? String ?? "Missing fixture result"
                return String(decoding: try JSONSerialization.data(withJSONObject: ["action": "finish", "answer": answer]), as: UTF8.self)
            }
            if messages.contains(where: { $0.content == "[fixture:mcp-resource]" }) {
                return #"{"action":"read_resource","uri":"fixture://guide"}"#
            }
            if messages.contains(where: { $0.content == "[fixture:mcp-error]" }) {
                return #"{"action":"call_tool","name":"fixture_echo","arguments":{"text":"error"}}"#
            }
            return #"{"action":"call_tool","name":"fixture_echo","arguments":{"text":"hello"}}"#
        }
        if instructions.hasPrefix("You research the currently open website") {
            if messages.contains(where: { $0.content.contains("[fixture:wait]") }) {
                try await Task.sleep(nanoseconds: 60_000_000_000)
            }
            let raw = messages.last?.content.components(separatedBy: "\n").dropFirst().joined(separator: "\n") ?? ""
            let page = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]
            let path = (page?["url"] as? String).flatMap(URL.init(string:))?.lastPathComponent ?? "start"
            let names = ["start", "alpha", "beta", "gamma", "delta"]
            if let index = names.firstIndex(of: path) { return "{\"action\":\"open\",\"linkID\":\(index)}" }
            return #"{"action":"finish","answer":"WOOW_WEB_GUIDE: five sections reviewed."}"#
        }
        if instructions.hasPrefix("Assess whether the final answer") {
            return #"{"outcome":"done","reason":"The observed pages support the answer.","evidence":[{"actionID":"action-0","quote":"WOOW_WEB_GUIDE"}]}"#
        }
        if instructions.hasPrefix("Draft a reusable") {
            return """
            ---
            name: website-research
            description: Research a website and compare its guide sections.
            ---
            ## Entry
            Open the requested public website.
            ## Steps
            Use `browser_inspect` and `browser_open_link` to read relevant guide sections.
            ## Pitfalls
            Stop when the pages change or evidence is missing.
            ## Success criteria
            Give a grounded summary with page sources.
            ## When to stop
            Ask the user when the requested scope changes.
            """
        }
        if instructions.hasPrefix("Answer the user's website research goal") { return "WOOW_WEB_GUIDE: five sections reviewed." }
        // Extraction is a separate system-instructed call; ordinary UI fixtures
        // intentionally create no learned records. Real behavior has a live suite.
        if messages.first?.role == "system" {
            if messages.last?.content.contains("[fixture:remember") == true {
                return "{\"ops\":[{\"op\":\"add\",\"kind\":\"preference\",\"content\":\"用戶喜歡喝茶\",\"quote\":\"我喜歡喝茶\"}]}"
            }
            return "{\"ops\":[]}"
        }
        let prompt = messages.last?.content ?? ""
        if prompt.hasPrefix("[fixture:remember-after-delay]") {
            try await Task.sleep(nanoseconds: 45_000_000_000)
        } else if prompt == "[fixture:wait]" {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        } else {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        try Task.checkCancellation()
        if prompt == "[fixture:error-once]", !failedOnce {
            failedOnce = true
            throw URLError(.cannotConnectToHost)
        }
        return "測試回覆：\(prompt)"
    }
}
#endif
