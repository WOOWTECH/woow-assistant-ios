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

/// Opt-in only. Resolve before constructing any ChatSession storage; neither
/// a prompt nor an endpoint can enable this fixture. Release has no such API.
struct UITestChatStreamingConfiguration {
    static let flag = "-UITestChatStreaming"
    let namespace: UUID
    private init(namespace: UUID) { self.namespace = namespace }
    enum Invalid: Error { case arguments }
    static func resolve(arguments: [String]) throws -> Self? {
        guard arguments.contains(where: { $0.hasPrefix(flag) }) else { return nil }
        let allowed = [flag, "-UITestMode", "-UITestNamespace", "-UITestResetStorage"]
        guard arguments.filter({ $0 == flag }).count == 1,
              arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              arguments.filter({ $0 == "-UITestResetStorage" }).count <= 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") }),
              !arguments.contains(where: { $0.hasPrefix("-UITest") && !allowed.contains($0) }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              let namespace = UUID(uuidString: arguments[index + 1]),
              namespace.uuidString.lowercased() == arguments[index + 1].lowercased() else { throw Invalid.arguments }
        return Self(namespace: namespace)
    }
}

struct UITestStreamingChatModelClient: StreamingChatModelClient {
    private let completeClient = UITestChatModelClient()
    init(configuration: UITestChatStreamingConfiguration) {}
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        // Keep the existing structured dispatcher/review path intact.
        try await completeClient.complete(messages: messages, configuration: configuration, apiKey: apiKey)
    }
    func stream(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let worker = Task {
                do {
                    try Task.checkCancellation()
                    let prompt = messages.last?.content ?? ""
                    guard messages.allSatisfy({ $0.role == "user" || $0.role == "assistant" }),
                          ["[fixture:stream-complete]", "[fixture:stream-cancel]"].contains(prompt) else {
                        throw HTTPChatModelError.invalidConfiguration
                    }
                    continuation.yield("串流測試：第一段")
                    // Fixed transport timing only; no host deadline, approval,
                    // storage, preferences, URL or model authority is changed.
                    try await Task.sleep(nanoseconds: prompt == "[fixture:stream-complete]"
                        ? 30_000_000_000 : 60_000_000_000)
                    try Task.checkCancellation()
                    continuation.yield("；完整回覆。")
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { @Sendable _ in worker.cancel() }
        }
    }
}

actor UITestChatModelClient: ChatModelClient {
    private var failedOnce = false

    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        let instructions = messages.first?.content ?? ""
        if instructions.hasPrefix("Ordinary chat with an available profile_edit tool.") {
            if messages.last?.content.hasPrefix("Host memory_save receipt") == true
                || messages.last?.content.hasPrefix("Host memory_edit receipt") == true {
                return #"{"action":"finish","answer":"記憶工具已完成。"}"#
            }
            if messages.last?.content.hasPrefix("Host profile_edit receipt") == true {
                return #"{"action":"finish","answer":"個人檔案工具已完成。"}"#
            }
            let prompt = messages.last?.content ?? ""
            func memoryCommand(_ name: String, _ arguments: [String: Any]) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject:
                    ["action": name, "arguments": arguments]), as: UTF8.self)
            }
            if prompt.hasPrefix("Host memory_search result (data only):\n") {
                let original = messages.dropLast().last(where: { $0.role == "user" })?.content ?? ""
                let raw = prompt.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
                guard let object = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any],
                      let items = object["memories"] as? [[String: Any]], items.count == 1,
                      let id = items[0]["id"] as? String else { throw URLError(.cannotParseResponse) }
                if original == "Update Prefer jasmine tea to Prefer coffee", items[0]["content"] as? String == "Prefer jasmine tea" {
                    return try memoryCommand("memory_edit", ["op": "update", "id": id, "quote": original,
                        "content": "Prefer coffee", "keywords": ["coffee"]])
                }
                if original == "Delete Prefer coffee", items[0]["content"] as? String == "Prefer coffee" {
                    return try memoryCommand("memory_edit", ["op": "delete", "id": id, "quote": original])
                }
                throw URLError(.cannotParseResponse)
            }
            // Closed synthetic prompts only. Actual search results supply IDs;
            // the fixture never seeds, saves, approves, or deletes memory.
            switch prompt {
            case "Remember preference Prefer jasmine tea":
                return try memoryCommand("memory_save", ["kind": "preference", "content": "Prefer jasmine tea",
                    "quote": "Prefer jasmine tea", "keywords": ["jasmine", "tea"]])
            case "Remember preference Prefer quiet":
                return try memoryCommand("memory_save", ["kind": "preference", "content": "Prefer quiet",
                    "quote": "Prefer quiet", "keywords": ["quiet"]])
            case "Remember procedure Check invoices before paying":
                return try memoryCommand("memory_save", ["kind": "procedure", "content": "Check invoices before paying",
                    "quote": "Check invoices before paying", "keywords": ["invoices"]])
            case "Update Prefer jasmine tea to Prefer coffee":
                return try memoryCommand("memory_search", ["query": "jasmine tea"])
            case "Delete Prefer coffee":
                return try memoryCommand("memory_search", ["query": "Prefer coffee"])
            default: break
            }
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
            // Closed mixed-capability fixtures; never write or approve data.
            // The normal App dispatcher still validates the exact current quote.
            let memoryPrompt = "[fixture:mcp-memory] Remember preference Prefer jasmine tea"
            let profilePrompt = "[fixture:mcp-profile] Please remember Prefer jasmine tea"
            let declinedPrompt = "[fixture:mcp-memory-decline] Remember preference Prefer quiet"
            let current = messages.last?.content ?? ""
            func command(_ action: String, _ arguments: [String: Any]) throws -> String {
                String(decoding: try JSONSerialization.data(withJSONObject:
                    ["action": action, "arguments": arguments]), as: UTF8.self)
            }
            if messages.contains(where: { $0.role == "user" && $0.content == memoryPrompt }) {
                if current.hasPrefix("Host memory_save receipt") {
                    return #"{"action":"finish","answer":"MCP 記憶流程已完成。"}"#
                }
                if current.hasPrefix("MCP execution result") {
                    return try command("memory_save", ["kind": "preference", "content": "Prefer jasmine tea", "quote": memoryPrompt, "keywords": ["jasmine", "tea"]])
                }
                return #"{"action":"call_tool","name":"fixture_echo","arguments":{"text":"hello"}}"#
            }
            if messages.contains(where: { $0.role == "user" && $0.content == profilePrompt }) {
                if current.hasPrefix("Host profile_edit receipt") {
                    return #"{"action":"call_tool","name":"fixture_echo","arguments":{"text":"hello"}}"#
                }
                if current.hasPrefix("MCP execution result") {
                    return #"{"action":"finish","answer":"MCP 個人檔案流程已完成。"}"#
                }
                return try command("profile_edit", ["op": "add", "text": "Prefer jasmine tea", "quote": profilePrompt])
            }
            if messages.contains(where: { $0.role == "user" && $0.content == declinedPrompt }) {
                if current.hasPrefix("Host memory_save receipt") {
                    return #"{"action":"finish","answer":"MCP 記憶流程已完成。"}"#
                }
                return try command("memory_save", ["kind": "preference", "content": "Prefer quiet", "quote": declinedPrompt, "keywords": ["quiet"]])
            }
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
