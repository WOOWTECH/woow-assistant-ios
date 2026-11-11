import Foundation
import AssistantModels
import AssistantSkills

@MainActor enum LanguageHTTPChecks {
    static func run() async throws -> Int {
        var passed = 0
        func check(_ condition: Bool, _ label: String) throws {
            guard condition else { throw NSError(domain: "LanguageHTTP", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            passed += 1
        }
        let suite = "language-http-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let language = AppLanguageStore(defaults: defaults, preferredLanguages: { ["zh-TW"] })
        let appearance = SelfConfigurationStore(defaults: defaults)
        let list = "{\"action\":\"tool\",\"name\":\"settings_list\",\"arguments\":{}}"
        let set = "{\"action\":\"tool\",\"name\":\"settings_set\",\"arguments\":{\"key\":\"appearance\",\"value\":\"dark\"}}"
        for revoke in [false, true] {
            appearance.setPermissionFromUser(true)
            appearance.setAppearanceFromUser(.light)
            let server = try SelfConfigurationSocketFixture([list, set], holdSecond: true)
            defer { server.stop() }
            let base = SelfConfigurationHTTPBridge.register(try await server.start())
            defer { SelfConfigurationHTTPBridge.remove(base) }
            let transport = SelfConfigurationHTTPBridge.session()
            defer { transport.invalidateAndCancel() }
            let request = "請改深色；verbatim %@ 設定語言 English"
            let reference = "synthetic-original-skill-reference 原文保持 %n"
            let runtime = try SelfConfigurationRuntime(request: request, store: appearance, sourceReference: reference)
            var events: [SelfConfigurationEvent] = []
            let operation = Task {
                try await runtime.run(client: HTTPChatModelClient(session: transport), configuration: .init(baseURL: base, model: "synthetic-model"), apiKey: SelfConfigurationSocketFixture.key, onEvent: { events.append($0) })
            }
            defer { runtime.cancel(); operation.cancel() }
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while server.requestBodies.count < 2 {
                guard ContinuousClock.now < deadline else { throw NSError(domain: "LanguageHTTP", code: 2) }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try check(language.setFromUser(.english), "language changes while actual HTTP response is held")
            if revoke { appearance.setPermissionFromUser(false); appearance.setPermissionFromUser(true) }
            server.release()
            if revoke {
                do { _ = try await operation.value; try check(false, "revoked grant accepted") }
                catch SelfConfigurationError.authorizationChanged { passed += 1 }
                try check(appearance.appearance == .light && events == [.listedOptions], "language cannot revive a grant or fabricate a write event")
            } else {
                let outcome = try await operation.value
                guard case .changed(let receipt) = outcome else { throw NSError(domain: "LanguageHTTP", code: 3) }
                try check(receipt.appearance == .dark && appearance.appearance == .dark, "inflight operation survives display-only language change")
                try check(events == [.listedOptions, .appliedAppearance(.dark)], "typed events describe actual HTTP and readback")
            }
            let bodies = server.requestBodies
            try check(bodies.count == 2, "language does not restart or retry the model")
            let first = try JSONSerialization.jsonObject(with: bodies[0]) as! [String: Any]
            let messages = first["messages"] as! [[String: String]]
            let input = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: String]
            try check(input["request"] == request && input["original_skill_reference"] == reference, "request and original source bytes remain verbatim")
            let reopened = AppLanguageStore(defaults: UserDefaults(suiteName: suite)!, preferredLanguages: { ["zh-TW"] })
            try check(reopened.language == .english, "language persisted independently of operation outcome")
        }
        let question = "請確認中文原文 / configuration.title / %@ 🧋"
        let response = String(decoding: try JSONSerialization.data(withJSONObject: ["action":"ask_user", "question":question]), as: UTF8.self)
        let runtime = try SelfConfigurationRuntime(request: "請問外觀", store: appearance)
        let result = try await runtime.run(client: SelfConfigurationSequenceModel([response]), configuration: .init(baseURL: URL(string: "https://synthetic.invalid/v1")!, model: "synthetic"), apiKey: "synthetic-not-live")
        try check(result == .needsClarification(question), "model clarification is never translated or looked up as a resource")
        return passed
    }
}
