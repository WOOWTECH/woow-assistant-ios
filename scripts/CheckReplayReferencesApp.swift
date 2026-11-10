#if REPLAY_REFERENCE_APP_STANDALONE || canImport(WoowAssistant)
import Foundation
import AssistantBrowser
import AssistantModels
import AssistantMemory
import AssistantSkills
import AssistantPersistence
import WebKit
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
#if !REPLAY_REFERENCE_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

private final class ReplayReferenceKeys: LearningKeyStore {
    var values: [String: Data] = [:]
    var unavailable = false
    func read(id: String) throws -> Data? { if unavailable { throw LearningFileError.unavailable }; return values[id] }
    func insert(_ key: Data, id: String) throws { if unavailable { throw LearningFileError.unavailable }; values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private actor ReplayReferenceGate {
    private var open = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { if open { $0.resume() } else { waiter = $0 } } }
    func release() { open = true; let pending = waiter; waiter = nil; pending?.resume() }
}
private actor ReplayReferenceModel: ChatModelClient {
    let gate: ReplayReferenceGate?
    let returnGate: ReplayReferenceGate?
    let heldCall: Int
    let forgedJudge: Bool
    private(set) var requests: [[ModelMessage]] = []
    private(set) var produced = 0
    private(set) var returned = 0
    init(gate: ReplayReferenceGate? = nil, returnGate: ReplayReferenceGate? = nil,
         heldCall: Int = 1, forgedJudge: Bool = false) {
        self.gate = gate; self.returnGate = returnGate; self.heldCall = heldCall; self.forgedJudge = forgedJudge
    }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        requests.append(messages); let index = requests.count
        if index == heldCall, let gate { await gate.wait() }
        let judge = messages.first?.content.hasPrefix("Assess whether") == true
        let reply: String
        if judge {
            let quote = forgedJudge ? "PRIVATE_REPLAY_PROFILE" : "ACTUAL_REPLAY_PAGE"
            reply = String(decoding: try JSONSerialization.data(withJSONObject:
                ["outcome": "done", "evidence": [["actionID": "action-0", "quote": quote]]]), as: UTF8.self)
        } else {
            reply = "CURRENT_STYLE ACTUAL_REPLAY_PAGE — https://research.example.invalid/replay"
        }
        produced += 1
        // Deliberately ignores cancellation, so the host must reject a late
        // value. Tests await its actual Task after releasing BOTH gates.
        if index == heldCall, let returnGate { await returnGate.wait() }
        returned += 1
        return reply
    }
}

@MainActor enum ReplayReferenceAppChecks {
    struct Failure: Error { let label: String }
    static var counts: [String: Int] = [:]
    static var group = "" { didSet { fputs("Replay reference group: \(group)\n", stderr); fflush(stderr) } }
    static var lateEvidence: [[String: Any]] = []
    static let url = URL(string: "https://research.example.invalid/replay")!
    static let goal = "Reference answer starts CURRENT_STYLE instead of any saved preference; use only actual page evidence."
    static let configuration = ModelConfiguration(baseURL: URL(string: "https://model.example.invalid/v1")!, model: "synthetic")
    static func expect(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try value() else { throw Failure(label: label) }; counts[group, default: 0] += 1
    }

    @MainActor private final class Host {
        let browser = BrowserSession(dataStore: .nonPersistent())
        #if canImport(AppKit)
        let window: NSWindow
        #else
        let window: UIWindow
        let previous: UIWindow?
        #endif
        init() throws {
            let web = browser.webView; web.frame = CGRect(x: 0, y: 0, width: 600, height: 500)
            #if canImport(AppKit)
            window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
            #else
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { throw Failure(label: "hosted UIWindowScene unavailable") }
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene); let controller = UIViewController()
            window.rootViewController = controller; window.makeKeyAndVisible(); controller.view.addSubview(web)
            #endif
            browser.canPresentUI = { false }
        }
        func load(html: String = "<!doctype html><title>Replay reference fixture</title><p>ACTUAL_REPLAY_PAGE</p><p id='second'>ACTUAL_SECOND_QUOTE</p>") async throws {
            browser.webView.loadHTMLString(html, baseURL: url)
            let end = ContinuousClock.now.advanced(by: .seconds(75))
            while (browser.current?.url != url || browser.webView.isLoading), ContinuousClock.now < end {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
            try expect(browser.current?.text.contains("ACTUAL_REPLAY_PAGE") == true, "real WebKit page is observed")
            try expect(!browser.webView.configuration.websiteDataStore.isPersistent, "ephemeral actual WebKit store")
        }
        func close() {
            browser.cancel(); browser.webView.stopLoading()
            #if canImport(AppKit)
            window.close(); window.contentView = nil
            #else
            browser.webView.removeFromSuperview(); window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
            #endif
        }
    }
    @MainActor private final class Environment {
        let root: URL, vaultURL: URL, store: LearningStore
        let keys = ReplayReferenceKeys()
        var configuration = ReplayReferenceAppChecks.configuration
        var key = "synthetic-not-a-key"
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-replay-reference-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            vaultURL = root.appendingPathComponent("learning.vault")
            store = LearningStore(vault: .init(url: vaultURL, keys: keys))
            try expect(store.available, "real encrypted store available")
            try expect(store.mutateMemory { _ = try $0.add(kind: .preference, content: "PRIVATE_REPLAY_MEMORY prefers SAVED_STYLE") }, "persist reference memory")
            try expect(store.mutateProfile { _ = try $0.add(text: "PRIVATE_REPLAY_PROFILE") }, "persist profile")
            try expect(store.mutateSkills { state in
                for (name, tool) in [("replay-observe", "browser_inspect"), ("replay-find", "browser_find")] {
                    let markdown = """
                    ---
                    name: \(name)
                    description: reference replay
                    ---
                    ## 入口
                    User confirmed the route.
                    ## 步驟
                    Use `\(tool)` only within the reviewed route.
                    ## 容易出錯的地方
                    Never invent evidence.
                    ## 怎樣算辦成
                    Actual observed evidence supports the answer.
                    ## 什麼時候停下交給使用者
                    Stop when observations disagree.
                    """
                    let draft = try state.importMarkdown(markdown, availableToolNames: BrowserSession.toolNames)
                    _ = try state.approveDraft(id: draft.id, availableToolNames: BrowserSession.toolNames)
                }
            }, "persist approved skills with available and unavailable operations")
        }
        func route(_ observation: WebObservation, second: Bool = false, repeated: Int = 1) throws -> WebRoute {
            let snapshot = PageSnapshot(url: observation.url, title: observation.title, visibleText: observation.text, capturedAt: observation.capturedAt)
            var steps = try (0..<repeated).map { _ in try WebRouteStep(kind: .observe, snapshot: snapshot, evidenceQuote: "ACTUAL_REPLAY_PAGE") }
            if second { steps.append(try .init(kind: .observe, snapshot: snapshot, evidenceQuote: "ACTUAL_SECOND_QUOTE")) }
            let task = try WebTaskEvidence(outcome: .succeeded, confirmed: true, summary: "Actual local fixture observed")
            try expect(store.mutateWeb { web, routes in
                _ = try web.addManual(text: "PRIVATE_REPLAY_SITE", evidence: .init(snapshot: snapshot, quote: "ACTUAL_REPLAY_PAGE"))
                _ = try routes.record(intent: goal, steps: steps, task: task)
            }, "persist actual observed route and approved site knowledge")
            return store.routes.routes[0]
        }
        func access(_ model: ReplayReferenceModel) -> ModelAccess { .init(client: model, configuration: configuration, key: key) }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
    private static func waitForRequest(_ model: ReplayReferenceModel, count: Int = 1) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(20))
        while await model.requests.count < count, ContinuousClock.now < end { try await Task.sleep(nanoseconds: 10_000_000) }
        let actual = await model.requests.count
        try expect(actual == count, "actual replay reached the intended model boundary")
    }
    private static func captured(_ browser: BrowserSession) throws -> Task<Void, Never> {
        guard let task = browser.capturedRunCompletion else { throw Failure(label: "actual replay task missing") }
        return task
    }

    static func frozenReferencesAndCurrentGoal() async throws {
        group = "frozenReferencesAndCurrentGoal"
        let host = try Host(); defer { host.close() }; try await host.load()
        let env = try Environment(); defer { env.close() }
        let route = try env.route(host.browser.current!), gate = ReplayReferenceGate(), model = ReplayReferenceModel(gate: gate)
        let before = try Data(contentsOf: env.vaultURL), generation = env.store.generation
        host.browser.replay(route: route, store: env.store, modelAccess: { env.access(model) })
        let completion = try captured(host.browser)
        do {
            try await waitForRequest(model)
            let input = await model.requests[0]
            try expect(input.count == 4 && input[1].role == "user" && input[2].content == goal, "frozen user-role reference precedes exact confirmed current goal")
            try expect(input[0].content.contains("current user goal overrides") && input.filter { $0.role == "system" }.count == 1, "fixed system gives current request priority")
            try expect(["PRIVATE_REPLAY_MEMORY", "PRIVATE_REPLAY_PROFILE", "PRIVATE_REPLAY_SITE", "replay-observe"].allSatisfy { input[1].content.contains($0) }, "actual store capture reaches answer model")
            try expect(!input[1].content.contains("replay-find"), "skill needing a non-route operation excluded")
            try expect(input[3].content.contains("ACTUAL_REPLAY_PAGE") && !input[3].content.contains("PRIVATE_REPLAY"), "only actual observations in source evidence")
            try expect(try Data(contentsOf: env.vaultURL) == before && env.store.generation == generation && env.store.memory.memories.allSatisfy { $0.useCount == 0 }, "capture and actual reads do not persist or increment useCount")
            try expect(env.store.mutateMemory { _ = try $0.edit(id: $0.memories[0].id, content: "NEXT_RUN_MEMORY") }, "persist ordinary edit while awaiting model")
            try expect(env.store.replaceProfileReference(segment: "PRIVATE_REPLAY_PROFILE", replacement: "NEXT_RUN_PROFILE"), "persist profile replacement")
            try expect(env.store.mutateWeb { web, _ in let row = web.lessons[0]; try web.edit(id: row.id, text: "NEXT_RUN_SITE", evidence: row.evidence) }, "persist ordinary website edit")
            env.store.cancelLearning()
            try expect(host.browser.isRunning && host.browser.hasActiveRunReferences, "ordinary edits and unrelated learning generation do not cancel replay")
            let snapshot = try env.store.captureRunReferences(goal: goal, capabilities: ["browser_inspect"], websiteURL: url)
            try expect(snapshot.references.message!.content.contains("NEXT_RUN_PROFILE") && snapshot.references.message!.content.contains("NEXT_RUN_SITE"), "next capture sees edits")
            let unchanged = await model.requests[0]
            try expect(unchanged == input && !unchanged[1].content.contains("NEXT_RUN"), "in-flight immutable capture stays unchanged")
            await gate.release(); await completion.value
            let requests = await model.requests
            try expect(requests.count == 2 && host.browser.answer?.hasPrefix("CURRENT_STYLE") == true, "one answer and one judge; no model command loop")
            try expect(!host.browser.isRunning && !host.browser.hasActiveRunReferences, "actual completed task released capture")
            try expect(env.store.routes.routes[0].successes == route.successes + 1, "only actual valid judged replay records success")
            try expect(!requests[1].last!.content.contains("PRIVATE_REPLAY") && !requests[1].last!.content.contains("NEXT_RUN"), "private reference block never enters judge evidence")
            let disk = LearningStore(vault: .init(url: env.vaultURL, keys: env.keys))
            try expect(disk.routes == env.store.routes && disk.profile == env.store.profile, "real encrypted readback preserves edits and route result")
        } catch { await gate.release(); await completion.value; throw error }
    }

    static func revocationsAndActualLateCompletion() async throws {
        group = "revocationsAndActualLateCompletion"
        let host = try Host(); defer { host.close() }; try await host.load()
        for operation in ["memoryDelete", "profileDelete", "profileLineageDelete", "skillDisable", "websiteDelete", "masterOff", "clear", "reload", "cancel"] {
            let env = try Environment(); defer { env.close() }
            let route = try env.route(try await host.browser.inspect())
            let gate = ReplayReferenceGate(), returnGate = ReplayReferenceGate()
            let model = ReplayReferenceModel(gate: gate, returnGate: returnGate)
            host.browser.replay(route: route, store: env.store, modelAccess: { env.access(model) })
            let completion = try captured(host.browser)
            do {
                try await waitForRequest(model)
                switch operation {
                case "memoryDelete": try expect(env.store.mutateMemory { _ = try $0.delete(id: $0.memories[0].id) }, "delete captured memory")
                case "profileDelete": try expect(env.store.deleteProfileReference(segment: "PRIVATE_REPLAY_PROFILE"), "delete captured profile")
                case "profileLineageDelete":
                    try expect(env.store.replaceProfileReference(segment: "PRIVATE_REPLAY_PROFILE", replacement: "NEXT_PROFILE"), "replace captured ancestor")
                    try expect(env.store.deleteProfileReference(segment: "NEXT_PROFILE"), "delete captured descendant")
                case "skillDisable": try expect(env.store.mutateSkills { try $0.suspend(name: "replay-observe") }, "disable captured skill")
                case "websiteDelete": try expect(env.store.mutateWeb { web, _ in try web.delete(id: web.lessons[0].id) }, "delete captured website")
                case "masterOff": try expect(env.store.updatePreferences { $0.useMemory = false }, "persist master off")
                case "clear": try expect(env.store.clearAll(), "actual encrypted clear")
                case "reload": env.store.reload()
                default: host.browser.cancel()
                }
                try expect(!host.browser.isRunning && !host.browser.hasActiveRunReferences, "revocation immediately cancels host work")
                let bytes = try Data(contentsOf: env.vaultURL), actions = host.browser.actions.count, lastURL = host.browser.webView.url
                await gate.release()
                let end = ContinuousClock.now.advanced(by: .seconds(5))
                while await model.produced == 0, ContinuousClock.now < end { try await Task.sleep(nanoseconds: 10_000_000) }
                let produced = await model.produced, beforeReturn = await model.returned
                try expect(produced == 1 && beforeReturn == 0, "counter can advance before actual client returns; not completion proof")
                await returnGate.release(); await completion.value
                let returned = await model.returned, calls = await model.requests.count
                try expect(returned == 1 && calls == 1 && host.browser.answer == nil, "awaited actual task rejects late answer and never starts judge")
                try expect(host.browser.actions.count == actions && host.browser.webView.url == lastURL, "no post-revocation route action or navigation")
                try expect(try Data(contentsOf: env.vaultURL) == bytes, "no late route success or write after revocation")
                lateEvidence.append(["operation": operation, "produced_before_return": produced, "returned_before_release": beforeReturn,
                    "returned_after_actual_task_await": returned, "client_calls": calls, "late_answer_published": false, "extra_actions": 0])
            } catch { await gate.release(); await returnGate.release(); await completion.value; throw error }
        }
    }

    static func lateJudgeAndCitationIsolation() async throws {
        group = "lateJudgeAndCitationIsolation"
        let host = try Host(); defer { host.close() }; try await host.load()
        for forged in [false, true] {
            let env = try Environment(); defer { env.close() }
            let route = try env.route(try await host.browser.inspect()), gate = ReplayReferenceGate(), returnGate = ReplayReferenceGate()
            let model = ReplayReferenceModel(gate: gate, returnGate: returnGate, heldCall: 2, forgedJudge: forged)
            host.browser.replay(route: route, store: env.store, modelAccess: { env.access(model) })
            let completion = try captured(host.browser)
            do {
                try await waitForRequest(model, count: 2)
                let requests = await model.requests
                try expect(requests[0][1].content.contains("PRIVATE_REPLAY_PROFILE") && !requests[1].last!.content.contains("PRIVATE_REPLAY_PROFILE"), "reference available only to answer, absent from actual judge source observations")
                try expect(host.browser.answer != nil, "answer delivered before independent judgment")
                if !forged { try expect(env.store.updatePreferences { $0.useMemory = false }, "revoke during judge") }
                let bytes = try Data(contentsOf: env.vaultURL), delivered = host.browser.answer
                await gate.release(); await returnGate.release(); await completion.value
                try expect(env.store.routes.routes[0].successes == route.successes, "late or forged judgment cannot mark route success")
                try expect(host.browser.answer == delivered, "already delivered answer retained after judge failure or cancellation")
                try expect(try Data(contentsOf: env.vaultURL) == bytes, "invalid or revoked citation result publishes no store write")
                if forged { try expect(host.browser.learningStatus?.contains("尚未確認完成") == true, "saved-text fabricated citation rejected by actual outcome parser") }
            } catch { await gate.release(); await returnGate.release(); await completion.value; throw error }
        }
    }

    static func switchesAndRouteHostFences() async throws {
        group = "switchesAndRouteHostFences"
        let host = try Host(); defer { host.close() }; try await host.load()
        for operation in ["masterOffAtStart", "routeDelete", "modelChanged", "keyChanged", "outputLimitChanged"] {
            let env = try Environment(); defer { env.close() }
            let route = try env.route(try await host.browser.inspect()), gate = ReplayReferenceGate(), model = ReplayReferenceModel(gate: gate)
            if operation == "masterOffAtStart" { try expect(env.store.updatePreferences { $0.useMemory = false }, "disable memory before capture") }
            host.browser.replay(route: route, store: env.store, modelAccess: { env.access(model) })
            let completion = try captured(host.browser)
            do {
                try await waitForRequest(model)
                let sent = await model.requests[0]
                switch operation {
                case "masterOffAtStart": try expect(!sent[1].content.contains("PRIVATE_REPLAY_PROFILE") && !sent[1].content.contains("PRIVATE_REPLAY_MEMORY") && sent[1].content.contains("replay-observe"), "master gates profile/memory while reviewed skill stays independent")
                case "routeDelete": try expect(env.store.mutateWeb { _, routes in try routes.delete(id: route.id) }, "delete actual confirmed route")
                case "modelChanged": env.configuration = .init(baseURL: configuration.baseURL, model: "changed")
                case "keyChanged": env.key = "changed-synthetic-key"
                default: env.configuration = .init(baseURL: configuration.baseURL, model: configuration.model, maxOutputTokens: 2048)
                }
                let bytes = try Data(contentsOf: env.vaultURL)
                await gate.release(); await completion.value
                let calls = await model.requests.count
                if operation == "masterOffAtStart" { try expect(calls == 2 && host.browser.answer != nil, "master-off still permits confirmed replay with independent skills") }
                else {
                    try expect(calls == 1 && host.browser.answer == nil && !host.browser.isRunning, "route/settings identity checked before late publication or judge")
                    try expect(try Data(contentsOf: env.vaultURL) == bytes, "host identity failure cannot write route outcome")
                }
            } catch { await gate.release(); await completion.value; throw error }
        }
    }

    static func actualPageDivergenceStillDisablesRoute() async throws {
        group = "actualPageDivergenceStillDisablesRoute"
        let host = try Host(); defer { host.close() }; try await host.load()
        let env = try Environment(); defer { env.close() }
        let route = try env.route(host.browser.current!, second: true), model = ReplayReferenceModel()
        // Return an actual JavaScript value: the older macOS WebKit async
        // overlay represents `undefined` as an implicitly unwrapped nil.
        _ = try await host.browser.webView.evaluateJavaScript("document.getElementById('second').remove(); true")
        for _ in 0..<2 {
            host.browser.replay(route: env.store.routes.routes[0], store: env.store, modelAccess: { env.access(model) })
            await (try captured(host.browser)).value
            try expect(host.browser.answer == nil && host.browser.actions.count == 1, "actual changed second quote stops before answer model")
        }
        let calls = await model.requests.count
        try expect(calls == 0 && env.store.routes.routes[0].disabled && env.store.routes.routes[0].consecutiveMisses == 2, "existing two same-step misses disable route without model calls")
        try expect(env.store.routes.routes[0].successes == route.successes && !host.browser.hasActiveRunReferences, "no false success; snapshot released")
        host.browser.replay(route: env.store.routes.routes[0], store: env.store, modelAccess: { env.access(model) })
        try expect(!host.browser.isRunning && host.browser.capturedRunCompletion == nil, "disabled route rejected before work")
    }

    static func combinedBudgetAndNoTruncation() async throws {
        group = "combinedBudgetAndNoTruncation"
        let references = try RunReferenceContext(entries: [.init(kind: .profile, id: "synthetic", text: String(repeating: "r", count: 4000))])
        var sawOmission = false, sawOverflow = false
        for linkCount in 0...30 {
            let links = (0..<linkCount).map { WebResearchLink(id: $0, title: String(repeating: "t", count: 120), url: URL(string: "https://research.example.invalid/" + String(repeating: "guide/", count: 20) + "page")!) }
            let pages = (0..<13).map { _ in WebObservation(url: url, title: "Observed", text: String(repeating: "w", count: 8000), links: links) }
            do {
                let messages = try BrowserSession.replayAnswerMessages(goal: goal, observations: pages, references: references)
                let encodedCount = try JSONEncoder().encode(messages).count
                try expect(messages.reduce(0, { $0 + $1.content.count }) <= MultiSourceResearchRunner.maximumContextCharacters && encodedCount <= MultiSourceResearchRunner.maximumContextUTF8Bytes, "required pages and optional references share the NEW replay total ceiling")
                let decoded = try JSONDecoder().decode([WebObservation].self, from: Data(messages.last!.content.utf8))
                try expect(decoded == pages, "no observation or citation source truncated to fit references")
                if messages.count == 3 {
                    sawOmission = true
                    try expect(!messages.contains { $0.role == "user" && $0.content.hasPrefix("Saved references (data only") }, "reference block is omitted whole, never partially serialized")
                    try expect(messages[1].content == goal, "required exact current goal retained at omission boundary")
                }
            } catch MultiSourceResearchContextError.tooLarge {
                sawOverflow = true
                do {
                    _ = try BrowserSession.replayAnswerMessages(goal: goal, observations: pages, references: .empty)
                    throw Failure(label: "required-only oversized context was accepted")
                } catch MultiSourceResearchContextError.tooLarge {
                    try expect(true, "required-only oversized context refused even with zero references")
                }
                break
            }
        }
        try expect(sawOmission && sawOverflow, "whole-reference omission and required-data overflow both exercised")
        // Also exercise the real App path: thirteen actual WebKit observations
        // exceed the NEW total envelope despite each page satisfying its limit.
        let host = try Host(); defer { host.close() }
        let links = (0..<30).map { index in
            "<a href='https://research.example.invalid/\(index)/\(String(repeating: "guide/", count: 20))page'>\(String(repeating: "t", count: 120))</a>"
        }.joined()
        try await host.load(html: "<!doctype html><title>Replay size fixture</title><p>ACTUAL_REPLAY_PAGE \(String(repeating: "w", count: 8000))</p>" + links)
        let env = try Environment(); defer { env.close() }
        let route = try env.route(host.browser.current!, repeated: 13), model = ReplayReferenceModel()
        let bytes = try Data(contentsOf: env.vaultURL)
        host.browser.replay(route: route, store: env.store, modelAccess: { env.access(model) })
        await (try captured(host.browser)).value
        let calls = await model.requests.count
        try expect(calls == 0 && host.browser.answer == nil, "actual oversized replay refuses before answer or judge request")
        try expect(host.browser.actions.count == 13 && host.browser.actions.allSatisfy { $0.observation.text.count == 8000 && $0.observation.links.count == 30 }, "all actual per-page observations retained intact on total overflow")
        try expect(host.browser.error?.contains(MultiSourceResearchContextError.tooLarge.errorDescription!) == true && !host.browser.isRunning, "fixed overflow error and completed actual task")
        try expect(try Data(contentsOf: env.vaultURL) == bytes, "context refusal cannot record a route success")
    }
}

#if REPLAY_REFERENCE_APP_STANDALONE
@main enum ReplayReferenceAppMain {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await ReplayReferenceAppChecks.combinedBudgetAndNoTruncation()
                try await ReplayReferenceAppChecks.frozenReferencesAndCurrentGoal()
                try await ReplayReferenceAppChecks.revocationsAndActualLateCompletion()
                try await ReplayReferenceAppChecks.lateJudgeAndCitationIsolation()
                try await ReplayReferenceAppChecks.switchesAndRouteHostFences()
                try await ReplayReferenceAppChecks.actualPageDivergenceStillDisablesRoute()
                print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": ReplayReferenceAppChecks.counts.values.reduce(0, +), "failed": 0,
                    "groups": ReplayReferenceAppChecks.counts, "late_completion": ReplayReferenceAppChecks.lateEvidence], options: .sortedKeys), as: UTF8.self))
                fflush(stdout); exit(0)
            } catch {
                print(String(decoding: try! JSONSerialization.data(withJSONObject: ["failed": 1, "group": ReplayReferenceAppChecks.group,
                    "failure": (error as? ReplayReferenceAppChecks.Failure)?.label ?? "operation_failed"], options: .sortedKeys), as: UTF8.self))
                fflush(stdout); exit(1)
            }
        }
        app.run()
    }
}
#else
final class ReplayReferenceAppIntegrationTests: XCTestCase {
    @MainActor func testFrozenReferencesAndCurrentGoal() async throws { try await ReplayReferenceAppChecks.frozenReferencesAndCurrentGoal() }
    @MainActor func testRevocationsAndActualLateCompletion() async throws { try await ReplayReferenceAppChecks.revocationsAndActualLateCompletion() }
    @MainActor func testLateJudgeAndCitationIsolation() async throws { try await ReplayReferenceAppChecks.lateJudgeAndCitationIsolation() }
    @MainActor func testSwitchesAndRouteHostFences() async throws { try await ReplayReferenceAppChecks.switchesAndRouteHostFences() }
    @MainActor func testActualPageDivergenceStillDisablesRoute() async throws { try await ReplayReferenceAppChecks.actualPageDivergenceStillDisablesRoute() }
    @MainActor func testCombinedBudgetAndNoTruncation() async throws { try await ReplayReferenceAppChecks.combinedBudgetAndNoTruncation() }
}
#endif
#endif
