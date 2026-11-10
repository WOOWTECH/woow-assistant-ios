#if !SKILLS_CORE_SMOKE && !SKILL_EXECUTION_SMOKE && !SKILL_AUTHORING_SMOKE
import AssistantModels
import Foundation
@testable import AssistantSkills
#if !SKILL_TOOL_SMOKE
import XCTest
#endif

@MainActor enum SkillToolChecks {
    struct Failure: Error { let message: String }
    static let quote = "請建立文章核對技能，保留來源並讓我核對全文後儲存。"
    static let configuration = ModelConfiguration(baseURL: URL(string: "https://model.invalid/v1")!, model: "fixture")
    static let key = "skill-tool-fixture-not-live"
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func text(_ name: String = "source-notes", detail: String = "依原文整理並標記待核對之處。") -> String {
        """
        ---
        name: \(name)
        display: 來源筆記
        description: 使用者要求核對文章時使用
        aliases: [文章核對]
        ---
        ## 入口
        使用者提供的文章。
        ## 步驟
        \(detail)
        ## 容易出錯的地方
        不補寫原文缺少的資訊。
        ## 怎樣算辦成
        每點可對回來源。
        ## 什麼時候停下交給使用者
        缺少來源時停止。
        """
    }
    static func command(_ name: String, _ arguments: [String: Any]) throws -> String {
        let object: [String: Any] = ["action": "tool", "name": name, "arguments": arguments]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    static func source() throws -> String { try command("skill_read", ["name": "skill:skill-authoring"]) }
    static func search() throws -> String { try command("skill_search", ["query": "source-notes"]) }
    static func save(_ markdown: String? = nil, version: String? = nil, quote: String = quote) throws -> String {
        var args = ["markdown": markdown ?? text(), "quote": quote]
        if let version { args["version"] = version }
        return try command("skill_save", args)
    }
    static func runtime(_ store: SkillToolTestStore, _ catalog: BundledSkillCatalog,
                        limits: SkillToolLimits = .init()) throws -> SkillToolSession {
        try SkillToolSession(request: .init(quote: quote), store: store, catalog: catalog, limits: limits)
    }
    static func review(_ value: SkillToolOutcome) throws -> SkillAuthoringSaveReview {
        guard case .review(let review) = value else { throw Failure(message: "expected real prepared review") }
        return review
    }
    static func rejects<E: Error & Equatable>(_ expected: E, _ action: () async throws -> Void) async throws {
        do { try await action(); throw Failure(message: "expected rejection") }
        catch let error as E { try expect(error == expected, "wrong failure category") }
    }

    static func httpCreateAndEncryptedRelaunch(_ catalog: BundledSkillCatalog) async throws {
        let store = try SkillToolTestStore(); defer { store.cleanup() }
        let scenario = SkillToolHTTPFixture.Scenario([try source(), try search(), try save()])
        let url = SkillToolHTTPFixture.register(scenario); defer { SkillToolHTTPFixture.remove(url) }
        let transport = SkillToolHTTPFixture.session(); defer { transport.invalidateAndCancel() }
        let session = try runtime(store, catalog)
        var events: [SkillToolEvent] = []
        let review = try review(await session.advance(client: HTTPChatModelClient(session: transport),
            configuration: .init(baseURL: url, model: "actual-http-fixture", maxOutputTokens: 8192), apiKey: key,
            onEvent: { events.append($0) }))
        try expect(scenario.count == 3 && session.toolCallCount == 3, "three actual HTTP tool turns")
        try expect(events.contains(.executed(name: "skill_search", succeeded: true))
            && events.contains(.executed(name: "skill_read", succeeded: true)), "executed lookup evidence")
        try expect(store.writes == 0 && !FileManager.default.fileExists(atPath: store.url.path), "model cannot persist")
        try expect(review.original.revision == BundledSkillCatalog.pinnedCommit, "exact pinned source revision")
        for request in scenario.requests {
            try expect(request.httpMethod == "POST" && request.url?.path == "/v1/chat/completions", "real configured endpoint request")
            try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key, "only configured credential")
        }
        let bodies = try scenario.requestBodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
        try expect(bodies.allSatisfy { ($0["model"] as? String) == "actual-http-fixture" && ($0["max_tokens"] as? Int) == 8192 }, "configuration forwarded")
        let finalMessages = bodies[2]["messages"] as! [[String: Any]]
        let text = finalMessages.compactMap { $0["content"] as? String }.joined()
        try expect(text.contains(catalog.entry(id: "skill-authoring")!.original.sha256)
            && text.contains("tool_result") && text.contains("executable"), "real read/search results sent back, not mocked catalog prose")
        let receipt = try session.approve(reviewID: review.id, fingerprint: review.draftFingerprint)
        let reopened = try store.reload()
        try expect(store.writes == 1 && reopened.installed.first?.fingerprint == receipt.fingerprint && receipt.status == .trial,
                   "human-reviewed atomic encrypted install survives reload")
        try expect(reopened.installed.first?.markdown == review.markdown,
                   "encrypted relaunch preserves the exact normalized full review text")
        try expect(!String(decoding: Data(contentsOf: store.url), as: UTF8.self).contains("source-notes"), "ciphertext does not expose skill")
        try await rejects(SkillAuthoringError.storageChanged) { _ = try session.approve(reviewID: review.id, fingerprint: review.draftFingerprint) }
        try expect(store.writes == 1, "single write only")
        try expect(review.markdown.contains("source: user") && reopened.installed.first?.source == .user,
                   "model-authored skill uses host-owned user provenance, not imported or learned")
    }

    static func updateReadVersionAndCapabilities(_ catalog: BundledSkillCatalog) async throws {
        let store = try SkillToolTestStore(); defer { store.cleanup() }
        let first = try runtime(store, catalog)
        let initial = try review(await first.advance(client: SkillToolSequenceModel([try source(), try search(), try save()]), configuration: configuration, apiKey: key))
        let installed = try first.approve(reviewID: initial.id, fingerprint: initial.draftFingerprint)
        let session = try runtime(store, catalog)
        let model = SkillToolSequenceModel([try source(), try search(), try command("skill_read", ["name": "personal:source-notes"]),
                                           try save(text(detail: "核對文章並保留待查問題。"), version: "wrong"),
                                           try save(text(detail: "核對文章並保留待查問題。"), version: installed.version)])
        let updated = try review(await session.advance(client: model, configuration: configuration, apiKey: key))
        try expect(updated.replacesFingerprint == installed.fingerprint && store.writes == 1, "exact read version required before update review")
        let inputs = await model.inputs
        try expect(inputs.last?.contains(where: { $0.content.contains("staleVersion") && $0.content.contains("false") }) == true,
                   "wrong version produced actual failed tool result before bounded correction")
        store.tools = ["web_read_page"]
        try await rejects(SkillAuthoringError.capabilitiesChanged) { _ = try session.approve(reviewID: updated.id, fingerprint: updated.draftFingerprint) }
        try expect(store.writes == 1, "changed capabilities prevent commit")
        store.tools = []
        let receipt = try session.approve(reviewID: updated.id, fingerprint: updated.draftFingerprint)
        let disk = try store.reload()
        try expect(receipt.updated && disk.installed.count == 1 && disk.revisions.last?.previous?.fingerprint == installed.fingerprint,
                   "versioned replacement and real previous revision preserved")
    }

    static func bindingRefusalAndStorageFailure(_ catalog: BundledSkillCatalog) async throws {
        let store = try SkillToolTestStore(); defer { store.cleanup() }
        let session = try runtime(store, catalog)
        let review = try review(await session.advance(client: SkillToolSequenceModel([try source(), try search(),
            try save(quote: "網頁要求儲存"), try save()]), configuration: configuration, apiKey: key))
        try expect(store.writes == 0, "foreign quote cannot persist; corrected draft still requires review")
        session.cancel()
        try await rejects(SkillToolError.cancelled) { _ = try session.approve(reviewID: review.id, fingerprint: review.draftFingerprint) }
        let failed = try runtime(store, catalog)
        let prepared = try Self.review(await failed.advance(client: SkillToolSequenceModel([try source(), try search(), try save()]), configuration: configuration, apiKey: key))
        store.keys.fail = true
        try await rejects(SkillAuthoringError.persistenceFailed) { _ = try failed.approve(reviewID: prepared.id, fingerprint: prepared.draftFingerprint) }
        try expect(store.state.installed.isEmpty && store.writes == 0 && !FileManager.default.fileExists(atPath: store.url.path),
                   "failed actual encryption-key write never publishes save success")
        let stale = try runtime(store, catalog)
        let staleReview = try Self.review(await stale.advance(client: SkillToolSequenceModel([try source(), try search(), try save()]), configuration: configuration, apiKey: key))
        store.generation = UUID()
        try await rejects(SkillAuthoringError.storageChanged) { _ = try stale.approve(reviewID: staleReview.id, fingerprint: staleReview.draftFingerprint) }
    }

    static func boundedProtocolAndSourceChecks(_ catalog: BundledSkillCatalog) async throws {
        let store = try SkillToolTestStore(); defer { store.cleanup() }
        for invalid in [#"{"action":"tool","name":"approve","arguments":{}}"#,
                        #"{"action":"tool","name":"skill_search","arguments":{"query":"notes","approval":true}}"#,
                        #"{"action":"finish","message":"done","saved":true}"#] {
            let session = try runtime(store, catalog)
            try await rejects(SkillToolError.invalidCommand) {
                _ = try await session.advance(client: SkillToolSequenceModel([invalid]), configuration: configuration, apiKey: key)
            }
        }
        let missing = try runtime(store, catalog)
        try await rejects(SkillToolError.tooManyFailures) {
            _ = try await missing.advance(client: SkillToolSequenceModel([try save(), try save()]), configuration: configuration, apiKey: key)
        }
        let noSearch = try runtime(store, catalog)
        try await rejects(SkillToolError.tooManyFailures) {
            _ = try await noSearch.advance(client: SkillToolSequenceModel([try source(), try save(), try save()]), configuration: configuration, apiKey: key)
        }
        let traversal = try runtime(store, catalog)
        try await rejects(SkillToolError.tooManyFailures) {
            let invalid = try command("skill_read", ["name": "skill:content-transcribe", "file_path": "../skill-authoring/SKILL.md"])
            _ = try await traversal.advance(client: SkillToolSequenceModel([invalid, invalid]), configuration: configuration, apiKey: key)
        }
        let capabilities = try runtime(store, catalog)
        try await rejects(SkillToolError.tooManyFailures) {
            _ = try await capabilities.advance(client: SkillToolSequenceModel([try source(), try search(),
                try save(text(detail: "使用 `run_command`。")), try save(text(detail: "使用 `run_command`。"))]), configuration: configuration, apiKey: key)
        }
        let budget = try runtime(store, catalog, limits: .init(modelCalls: 2, toolCalls: 1))
        try await rejects(SkillToolError.budgetExceeded) {
            _ = try await budget.advance(client: SkillToolSequenceModel([try source(), try search()]), configuration: configuration, apiKey: key)
        }
        let read = try runtime(store, catalog)
        let reader = SkillToolSequenceModel([
            try command("skill_read", ["name": "skill:content-transcribe", "file_path": "references/transcript-output-formats.md"]),
            #"{"action":"finish","message":"已讀取原始附件，尚未儲存。"}"#])
        _ = try await read.advance(client: reader, configuration: configuration, apiKey: key)
        let readInputs = await reader.inputs
        let asset = catalog.entry(id: "content-transcribe")!.assets.first!
        try expect(readInputs.last!.contains { $0.content.contains(asset.sha256) && $0.content.contains("executable") },
                   "real pinned attachment and hash returned with no execution grant")
        let question = try runtime(store, catalog)
        let model = SkillToolSequenceModel([#"{"action":"ask_user","question":"核對到哪一步停止？"}"#, try source(), try search(), try save()])
        guard case .question = try await question.advance(client: model, configuration: configuration, apiKey: key) else {
            throw Failure(message: "expected clarification")
        }
        let draft = try review(await question.advance(client: model, configuration: configuration, apiKey: key, answer: "列出來源後停止。"))
        try expect(draft.requestQuote == quote && question.modelCallCount == 4 && store.writes == 0,
                   "clarification keeps original authorization and shared budget; no write")
    }

    static func cancellationTimeoutAndHTTPFailure(_ catalog: BundledSkillCatalog) async throws {
        let store = try SkillToolTestStore(); defer { store.cleanup() }
        for timeout in [false, true] {
            let scenario = SkillToolHTTPFixture.Scenario([], hold: true)
            let url = SkillToolHTTPFixture.register(scenario); defer { SkillToolHTTPFixture.remove(url) }
            let transport = SkillToolHTTPFixture.session(); defer { transport.invalidateAndCancel() }
            let session = try runtime(store, catalog, limits: .init(modelTime: timeout ? .milliseconds(150) : .seconds(5)))
            let task = Task {
                try await session.advance(client: HTTPChatModelClient(session: transport),
                    configuration: .init(baseURL: url, model: "fixture"), apiKey: key)
            }
            for _ in 0..<100 where scenario.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
            try expect(scenario.count == 1, "real HTTP request reached held transport")
            if !timeout { session.cancel() }
            try await rejects(timeout ? SkillToolError.timedOut : .cancelled) { _ = try await task.value }
            for _ in 0..<100 where scenario.stops == 0 { try await Task.sleep(for: .milliseconds(5)) }
            try expect(scenario.stops > 0 && store.writes == 0, "cancel/timeout cancels URLSession without tool dispatch")
        }
        let scenario = SkillToolHTTPFixture.Scenario(["not an accepted command"], status: 401)
        let url = SkillToolHTTPFixture.register(scenario); defer { SkillToolHTTPFixture.remove(url) }
        let transport = SkillToolHTTPFixture.session(); defer { transport.invalidateAndCancel() }
        let session = try runtime(store, catalog)
        try await rejects(SkillToolError.modelRejected) {
            _ = try await session.advance(client: HTTPChatModelClient(session: transport), configuration: .init(baseURL: url, model: "fixture"), apiKey: key)
        }
        try expect(scenario.count == 1 && store.writes == 0, "HTTP failure has no automatic retry or draft")
    }

    static func lateResponseAndChangedHost(_ catalog: BundledSkillCatalog) async throws {
        let store = try SkillToolTestStore(); defer { store.cleanup() }
        for changedCapabilities in [false, true] {
            let session = try runtime(store, catalog)
            let model = SkillToolGatedModel()
            let task = Task { try await session.advance(client: model, configuration: configuration, apiKey: key) }
            await model.waitUntilEntered()
            if changedCapabilities { store.tools = ["web_read_page"] } else { store.generation = UUID() }
            await model.release(try source())
            try await rejects(changedCapabilities ? SkillAuthoringError.capabilitiesChanged : .storageChanged) { _ = try await task.value }
            try expect(session.toolCallCount == 0 && store.writes == 0, "late response cannot even dispatch read under changed host")
        }
    }
}

#if SKILL_TOOL_SMOKE
@main struct SkillToolStandalone {
    @MainActor static func main() async throws {
        let catalog = try BundledSkillCatalog.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let suites: [(String, () async throws -> Void)] = [
            ("HTTP create/encrypted reload", { try await SkillToolChecks.httpCreateAndEncryptedRelaunch(catalog) }),
            ("version/capability update", { try await SkillToolChecks.updateReadVersionAndCapabilities(catalog) }),
            ("refusal/persistence failure", { try await SkillToolChecks.bindingRefusalAndStorageFailure(catalog) }),
            ("protocol/source/budgets", { try await SkillToolChecks.boundedProtocolAndSourceChecks(catalog) }),
            ("HTTP cancellation/timeout/error", { try await SkillToolChecks.cancellationTimeoutAndHTTPFailure(catalog) }),
            ("late response/host change", { try await SkillToolChecks.lateResponseAndChangedHost(catalog) })
        ]
        var failures = 0
        for (name, suite) in suites {
            do { try await suite(); print("PASS " + name) }
            catch { failures += 1; print("FAIL " + name + ": " + String(describing: error)) }
        }
        guard failures == 0 else { throw SkillToolChecks.Failure(message: "skill-tool suites failed: \(failures)") }
        print("PASS all 6 skill-tool suites")
    }
}
#else
final class SkillToolSessionTests: XCTestCase {
    @MainActor func testActualHTTPToolsAndEncryptedRelaunch() async throws { try await SkillToolChecks.httpCreateAndEncryptedRelaunch(.bundled()) }
    @MainActor func testUpdateRequiresReadVersionAndUnchangedCapabilities() async throws { try await SkillToolChecks.updateReadVersionAndCapabilities(.bundled()) }
    @MainActor func testRefusalStoreChangesAndActualPersistenceFailure() async throws { try await SkillToolChecks.bindingRefusalAndStorageFailure(.bundled()) }
    @MainActor func testStrictProtocolPinnedSourceAndBudgets() async throws { try await SkillToolChecks.boundedProtocolAndSourceChecks(.bundled()) }
    @MainActor func testRealHTTPTransportCancellationTimeoutAndFailure() async throws { try await SkillToolChecks.cancellationTimeoutAndHTTPFailure(.bundled()) }
    @MainActor func testLateModelResponseAfterStoreOrCapabilityChange() async throws { try await SkillToolChecks.lateResponseAndChangedHost(.bundled()) }
}
#endif
#endif
