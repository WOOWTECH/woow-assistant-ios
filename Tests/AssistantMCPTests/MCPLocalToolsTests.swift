import AssistantModels
import AssistantMCP
import Foundation

/// Runner/protocol checks use only synthetic model and host callbacks. Actual
/// encrypted commits and approval UI belong to the hosted App integration tests.
enum MCPLocalToolsChecks {
    struct Failed: Error { let check: String }
    struct Counter {
        var count = 0
        mutating func expect(_ value: Bool, _ label: String) throws {
            guard value else { throw Failed(check: label) }
            count += 1
        }
    }
    enum HostFailure: Error { case validation, storage }
    static let configuration = ModelConfiguration(baseURL: URL(string: "https://model.invalid")!, model: "fixture")
    static let tool = MCPTool(name: "fixture_echo", description: "Synthetic remote tool", inputSchema: .object([:]))
    static let resource = MCPResource(uri: "fixture://record", name: "Synthetic record", mimeType: "application/json")
    static let finish = #"{"action":"finish","answer":"依據實際結果完成。"}"#
    static let searchJSON = #"{"items":[{"id":"synthetic-id","content":"Prefer tea"}]}"#
    static let receiptJSON = #"{"applied":true,"id":"synthetic-id","effective":"next_run"}"#
    static let userText = "Remember that I prefer tea; use the selected remote tool."
    static let allActions: [MCPLocalAction] = [.memorySearch, .memorySave, .memoryEdit, .profileEdit]
    static let mutations: [MCPLocalAction] = [.memorySave, .memoryEdit, .profileEdit]

    static func local(_ action: MCPLocalAction, arguments: String = "{}") -> String {
        "{\"action\":\"" + action.rawValue + "\",\"arguments\":" + arguments + "}"
    }
    static func remote(_ index: Int = 0, name: String = tool.name) -> String {
        "{\"action\":\"call_tool\",\"name\":\"" + name + "\",\"arguments\":{\"index\":\(index)}}"
    }

    actor Model: ChatModelClient {
        let replies: [String]
        let pauseAt: Int?
        let gate: Gate?
        private(set) var inputs: [[ModelMessage]] = []
        init(_ replies: [String], pauseAt: Int? = nil, gate: Gate? = nil) {
            self.replies = replies; self.pauseAt = pauseAt; self.gate = gate
        }
        func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
            let index = inputs.count
            inputs.append(messages)
            if pauseAt == index, let gate { await gate.wait() }
            guard index < replies.count else { throw HTTPChatModelError.transportFailure }
            return replies[index]
        }
    }
    actor Executor: MCPConversationExecuting {
        let output: JSONValue
        let fails: Bool
        private(set) var actions: [MCPConversationAction] = []
        init(output: JSONValue = .object(["value": .string("actual synthetic remote result")]), fails: Bool = false) {
            self.output = output; self.fails = fails
        }
        func callAuthorizedTool(name: String, arguments: JSONValue) throws -> JSONValue {
            actions.append(.callTool(name: name, arguments: arguments))
            if fails { throw HostFailure.storage }
            return output
        }
        func readResource(uri: String) throws -> JSONValue {
            actions.append(.readResource(uri: uri))
            if fails { throw HostFailure.storage }
            return output
        }
    }
    actor Record {
        private(set) var local: [MCPLocalProposal] = []
        private(set) var approvals: [MCPConversationProposal] = []
        private(set) var events: [MCPConversationEvent] = []
        private(set) var receipts = 0
        func observe(_ proposal: MCPLocalProposal) { local.append(proposal) }
        func commit() { receipts += 1 }
        func approve(_ proposal: MCPConversationProposal, allowed: Bool = true) -> Bool {
            approvals.append(proposal); return allowed
        }
        func event(_ event: MCPConversationEvent) { events.append(event) }
        func handle(_ proposal: MCPLocalProposal, _ lease: MCPLocalLease) throws -> MCPLocalOutcome {
            try lease.check()
            local.append(proposal)
            if proposal.action == .memorySearch { return .searchResult(json: searchJSON) }
            receipts += 1
            return .committedReceipt(json: receiptJSON)
        }
    }

    /// State check and continuation registration share one actor turn; release
    /// is latched, including when it arrives before wait. Deliberately ignores
    /// task cancellation to model a native review continuation that finishes late.
    actor Gate {
        private var released = false
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        func wait() async {
            await withCheckedContinuation { continuation in
                entered = true
                if released { continuation.resume() }
                else { self.continuation = continuation }
            }
        }
        func release() {
            released = true
            let pending = continuation; continuation = nil; pending?.resume()
        }
    }
    /// Synchronous host-side check/write probe: no suspension between lease
    /// validation and simulated publication. Does not pretend to test persistence.
    final class LeaseProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var lease: MCPLocalLease?
        private var writeCount = 0
        private var exited = false
        func capture(_ value: MCPLocalLease) { lock.lock(); lease = value; lock.unlock() }
        func write() { lock.lock(); writeCount += 1; lock.unlock() }
        func finish() { lock.lock(); exited = true; lock.unlock() }
        var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }
        var finished: Bool { lock.lock(); defer { lock.unlock() }; return exited }
        func checkCaptured() throws {
            lock.lock(); let captured = lease; lock.unlock()
            guard let captured else { throw Failed(check: "lease was not captured") }
            try captured.check()
        }
    }
    static func waitUntil(_ label: String, _ predicate: () async -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < end {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        throw Failed(check: label)
    }
    static func run(_ model: Model, executor: Executor = Executor(), tools: [MCPTool] = [tool],
                    resources: [MCPResource] = [], limits: MCPConversationLimits = .init(),
                    approve: @escaping @Sendable (MCPConversationProposal) async throws -> Bool = { _ in true },
                    events: @escaping @Sendable (MCPConversationEvent) async -> Void = { _ in },
                    local: MCPLocalHandler? = nil) async throws -> MCPConversationResult {
        try await MCPConversationRunner(client: model).run(
            messages: [.init(role: "user", content: userText)], configuration: configuration,
            apiKey: "synthetic-not-a-key", tools: tools, resources: resources, executor: executor,
            limits: limits, approve: approve, onEvent: events, handleLocal: local)
    }
    static func expect(_ expected: MCPConversationError, _ body: () async throws -> Void) async throws -> Int {
        do { try await body() }
        catch let error as MCPConversationError where error == expected { return 1 }
        catch { throw Failed(check: "unexpected error instead of " + expected.rawValue) }
        throw Failed(check: "missing expected " + expected.rawValue)
    }

    static func rawEnvelopeAndTypedErrors() async throws -> Int {
        var c = Counter()
        let raw = #"{ "quote":"記住 { } : , \" 原話", "nested":{"content":"first","content":"second"}, "items":[{},[1,2]] } "#
        let fields = try RawCommandEnvelope.fields(in: local(.memorySave, arguments: raw))
        try c.expect(fields["arguments"] == raw, "raw nested duplicates/Unicode/escaping/whitespace preserved")
        for invalid in ["[]", "{}{}", "{\"x\":1,}", #"{"action":"a","action":"b"}"#,
                        #"{"action":"a","\u0061ction":"b"}"#, #"{"x":[1,,2]}"#, #"{"x":"unterminated}"#] {
            do { _ = try RawCommandEnvelope.fields(in: invalid); throw Failed(check: "invalid envelope accepted") }
            catch RawCommandEnvelopeError.invalidEnvelope { try c.expect(true, "invalid envelope rejected") }
        }
        for action in allActions {
            let record = Record(), executor = Executor(), model = Model([local(action, arguments: raw), finish])
            do {
                _ = try await run(model, executor: executor, local: { proposal, lease in
                    try lease.check(); await record.observe(proposal)
                    // The host sees original bytes and rejects them with its own
                    // typed validation failure; no decode/re-encode in runner.
                    throw HostFailure.validation
                })
                throw Failed(check: "host validation failure swallowed")
            } catch HostFailure.validation { try c.expect(true, "typed host validation error preserved") }
            let proposals = await record.local
            try c.expect(proposals.count == 1 && proposals.first?.argumentsJSON == raw, "all local actions preserve raw arguments")
            try c.expect(await model.inputs.count == 1, "host failure stops model loop")
            try c.expect(await executor.actions.isEmpty, "local validation never dispatches remote")
        }
        for bad in [#"{"action":"memory_save","arguments":{},"arguments":{}}"#,
                    #"{"action":"memory_save","\u0061ction":"memory_save","arguments":{}}"#,
                    #"{"action":"memory_save","arguments":[],"approved":true}"#] {
            let record = Record(), model = Model([bad, finish])
            let result = try await run(model, local: { try await record.handle($0, $1) })
            try c.expect(result.stopReason == .finished && result.modelCallCount == 2, "one bounded format repair")
            try c.expect(await record.local.isEmpty, "invalid root cannot reach host")
        }
        return c.count
    }

    static func distinctNamespacesAndMixedApproval() async throws -> Int {
        var c = Counter(), extra = 0
        let unavailable = Model([local(.memorySearch)]), absent = Record()
        extra += try await expect(.localUnavailable) {
            _ = try await run(unavailable, approve: { await absent.approve($0) })
        }
        let disabledInput = await unavailable.inputs[0]
        try c.expect(!disabledInput[0].content.contains("memory_search"), "nil handler does not advertise locals")
        try c.expect(await absent.approvals.isEmpty, "nil handler cannot cause native review")
        let collision = MCPTool(name: "memory_edit", description: "Actual selected remote name", inputSchema: .object([:]))
        let collisionHost = Record(), collisionExecutor = Executor()
        let collisionResult = try await run(Model([remote(name: collision.name), finish]), executor: collisionExecutor,
            tools: [collision], approve: { await collisionHost.approve($0) }, local: { try await collisionHost.handle($0, $1) })
        try c.expect(collisionResult.steps.count == 1, "selected remote name collision remains remote")
        try c.expect(await collisionHost.local.isEmpty, "call_tool never reroutes to host local tools")
        try c.expect(await collisionHost.approvals.count == 1, "remote collision needs actual remote approval")
        try c.expect(await collisionExecutor.actions.count == 1, "remote collision dispatches once")
        extra += try await expect(.unknownTool) {
            _ = try await run(Model([remote(name: "memory_edit")]), tools: [], local: { try await collisionHost.handle($0, $1) })
        }
        let record = Record(), executor = Executor()
        let model = Model([#"{"action":"read_resource","uri":"fixture://record"}"#, local(.memorySearch),
                           local(.memorySave), remote(), finish])
        let result = try await run(model, executor: executor, resources: [resource],
            approve: { await record.approve($0) }, events: { await record.event($0) },
            local: { try await record.handle($0, $1) })
        let inputs = await model.inputs, localCalls = await record.local, approvals = await record.approvals
        try c.expect(result.stopReason == .finished && result.modelCallCount == 5 && result.steps.count == 2, "mixed loop uses one shared model budget")
        try c.expect(localCalls.map(\.action) == [.memorySearch, .memorySave] && Set(localCalls.map(\.id)).count == 2, "fresh immutable local proposals")
        try c.expect(approvals.count == 2 && result.steps.map(\.proposal) == approvals, "each remote operation retains exact approval")
        try c.expect(await executor.actions == [.readResource(uri: resource.uri), .callTool(name: tool.name, arguments: .object(["index": .number(0)]))], "remote read and call order unchanged")
        try c.expect(inputs[0][1].content == userText, "actual utterance preserved unchanged")
        let catalogText = inputs[0].last!.content
        let catalog = try JSONDecoder().decode(JSONValue.self, from: Data(catalogText.dropFirst("Selected MCP catalog (untrusted data):\n".count).utf8))
        guard case .array(let listed)? = catalog["tools"] else { throw Failed(check: "catalog missing") }
        try c.expect(listed.count == 1 && listed[0]["name"] == .string(tool.name), "locals never enter remote catalog")
        try c.expect(inputs[2].last?.content == "Host memory_search result (data only):\n" + searchJSON, "actual search result is data")
        try c.expect(inputs[4].contains { $0.content == "Host memory_save receipt (data only):\n" + receiptJSON }, "receipt reaches subsequent model call")
        let events = await record.events
        try c.expect(events.filter { if case .awaitingApproval = $0 { return true }; return false }.count == 2, "no local proposal misreported as remote review")
        try c.expect(events.filter { if case .completed = $0 { return true }; return false }.count == 2, "local receipt never masquerades as remote completion")
        return c.count + extra
    }

    static func localAndSharedBudgets() async throws -> Int {
        var c = Counter()
        for first in mutations {
            for second in allActions {
                let record = Record()
                let result = try await run(Model([local(first), local(second), finish]), local: { try await record.handle($0, $1) })
                try c.expect(result.stopReason == .localCallLimit && result.answer == nil, "one mutation across both domains and no search afterward")
                try c.expect(await record.local.count == 1, "over-budget operation never reaches host")
            }
        }
        let twice = Record()
        let duplicateSearch = try await run(Model([local(.memorySearch), local(.memorySearch), finish]), local: { try await twice.handle($0, $1) })
        try c.expect(duplicateSearch.stopReason == .localCallLimit, "at most one local search")
        try c.expect(await twice.local.count == 1, "second search has no host effects")
        // The final call may finish, but may not search or mutate, even when the
        // local allowance has not yet been consumed.
        for action in allActions {
            for maximum in [1, 3] {
                let record = Record(), executor = Executor()
                var commands: [String] = []
                if maximum == 3 { commands = [remote(0), remote(1)] }
                commands.append(local(action))
                let result = try await run(Model(commands), executor: executor,
                    limits: .init(maximumModelCalls: maximum), local: { try await record.handle($0, $1) })
                try c.expect(result.stopReason == .modelCallLimit && result.modelCallCount == maximum, "reserve a final model call for result consumption")
                try c.expect(await record.local.isEmpty, "last-call local search/mutation has zero host callbacks")
            }
        }
        let record = Record(), executor = Executor()
        let commands = [local(.memorySearch), local(.memorySave)] + (0..<6).map { remote($0) } + [finish]
        let result = try await run(Model(commands), executor: executor, local: { try await record.handle($0, $1) })
        try c.expect(result.stopReason == .finished && result.steps.count == 6 && result.modelCallCount == 9, "local actions do not consume remote six-call budget")
        try c.expect(await record.local.count == 2, "search plus one mutation both run")
        let seventh = try await run(Model([local(.memorySave)] + (0..<7).map { remote($0) } + [finish]),
                                    local: { try await Record().handle($0, $1) })
        try c.expect(seventh.stopReason == .toolCallLimit && seventh.steps.count == 6 && seventh.modelCallCount == 8, "local commit never raises remote limit")
        let defaults = MCPConversationLimits()
        try c.expect(defaults.maximumModelCalls == 12 && defaults.maximumToolCalls == 6 && defaults.timeout == .seconds(180), "original default limits unchanged")
        let small = try await run(Model([local(.memorySearch), local(.memorySave), remote(), finish]),
                                  limits: .init(maximumModelCalls: 3), local: { try await Record().handle($0, $1) })
        try c.expect(small.modelCallCount == 3 && small.stopReason == .modelCallLimit && small.steps.count == 1, "local calls share, never restart, model budget")
        return c.count
    }

    static func outcomesErrorsAndOutputBounds() async throws -> Int {
        var c = Counter(), extra = 0
        let invalid: [(MCPLocalAction, MCPLocalOutcome, MCPConversationError)] = [
            (.memorySearch, .committedReceipt(json: receiptJSON), .invalidLocalResult),
            (.memorySave, .searchResult(json: searchJSON), .invalidLocalResult),
            (.memorySearch, .searchResult(json: "[]"), .invalidLocalResult),
            (.memorySearch, .searchResult(json: #"{"a":1,"a":2}"#), .invalidLocalResult),
            (.profileEdit, .committedReceipt(json: "not JSON"), .invalidLocalResult),
            (.memorySearch, .searchResult(json: "{\"data\":\"" + String(repeating: "x", count: 12 * 1024) + "\"}"), .outputTooLarge),
            (.memorySave, .committedReceipt(json: "{\"data\":\"" + String(repeating: "x", count: 2048) + "\"}"), .outputTooLarge)
        ]
        for (action, outcome, error) in invalid {
            let model = Model([local(action), finish]), record = Record()
            extra += try await expect(error) {
                _ = try await run(model, local: { proposal, _ in await record.observe(proposal); return outcome })
            }
            try c.expect(await record.local.count == 1, "invalid outcome is never retried")
            try c.expect(await model.inputs.count == 1, "invalid result never sent to model")
        }
        let hugeRemote = Executor(output: .object(["value": .string(String(repeating: "r", count: 16_000))]))
        extra += try await expect(.outputTooLarge) {
            _ = try await run(Model([local(.memorySearch)] + (0..<4).map { remote($0) }), executor: hugeRemote,
                local: { _, _ in .searchResult(json: "{\"value\":\"" + String(repeating: "s", count: 11_000) + "\"}") })
        }
        try c.expect(await hugeRemote.actions.count == 4, "local bytes participate in existing 64KiB cumulative output bound")
        let host = Record(), model = Model([local(.memorySave), finish])
        do {
            _ = try await run(model, local: { proposal, _ in await host.observe(proposal); throw HostFailure.storage })
            throw Failed(check: "host storage failure lost")
        } catch HostFailure.storage { try c.expect(true, "typed storage failure remains visible to trusted host") }
        try c.expect(await host.receipts == 0, "failure publishes no receipt")
        try c.expect(await model.inputs.count == 1, "no fake success after storage failure")
        return c.count + extra
    }

    static func denialAndPostcommitFailures() async throws -> Int {
        var c = Counter(), extra = 0
        let denied = Record(), executor = Executor()
        let denialModel = Model([remote(), local(.memorySave), remote(1), finish])
        let denial = try await run(denialModel, executor: executor, local: { proposal, _ in
            await denied.observe(proposal); return .declined
        })
        try c.expect(denial.stopReason == .approvalDenied && denial.steps.count == 1 && denial.answer == nil, "local denial stops whole run and preserves prior remote result")
        try c.expect(await executor.actions.count == 1, "no later remote dispatch after local denial")
        try c.expect(await denialModel.inputs.count == 2, "no final model call after refusal")
        let saved = Record(), disconnected = Model([local(.memorySave)])
        extra += try await expect(.modelTransportFailed) {
            _ = try await run(disconnected, local: { try await saved.handle($0, $1) })
        }
        try c.expect(await saved.receipts == 1, "model disconnect cannot undo already published host receipt")
        let deniedRemote = Record()
        let laterDenied = try await run(Model([local(.profileEdit), remote(), finish]),
            approve: { await deniedRemote.approve($0, allowed: false) }, local: { try await deniedRemote.handle($0, $1) })
        try c.expect(laterDenied.stopReason == .approvalDenied && laterDenied.steps.isEmpty, "later remote rejection stays rejection")
        try c.expect(await deniedRemote.receipts == 1, "remote refusal preserves prior local commit")
        let correctedHost = Record(), correctedModel = Model([local(.memorySave), "plain invalid reply", finish])
        let corrected = try await run(correctedModel, local: { try await correctedHost.handle($0, $1) })
        try c.expect(corrected.stopReason == .finished && corrected.modelCallCount == 3, "one format correction remains shared")
        try c.expect(await correctedHost.receipts == 1, "format correction does not replay commit")
        let correctionInput = await correctedModel.inputs[2]
        try c.expect(correctionInput.contains { $0.content == "Host memory_save receipt (data only):\n" + receiptJSON }, "prior actual receipt survives correction")
        let remoteFailureHost = Record()
        extra += try await expect(.executionFailed) {
            _ = try await run(Model([local(.memorySave), remote()]), executor: Executor(fails: true),
                              local: { try await remoteFailureHost.handle($0, $1) })
        }
        try c.expect(await remoteFailureHost.receipts == 1, "remote failure does not discard prior host commit")
        return c.count + extra
    }

    static func cancellationDeadlineAndLeaseLifetime() async throws -> Int {
        var c = Counter(), extra = 0
        for timeout in [false, true] {
            let gate = Gate(), probe = LeaseProbe(), model = Model([local(.memorySave), finish])
            let task = Task {
                try await run(model, limits: .init(timeout: timeout ? .milliseconds(350) : .seconds(5)),
                    local: { _, lease in
                        probe.capture(lease)
                        await gate.wait()
                        defer { probe.finish() }
                        try lease.check()
                        probe.write()
                        return .committedReceipt(json: receiptJSON)
                    })
            }
            do { try await waitUntil("local review was never reached") { await gate.entered } }
            catch { task.cancel(); await gate.release(); _ = try? await task.value; throw error }
            if !timeout { task.cancel() }
            let outcome = await task.result
            await gate.release()
            try await waitUntil("late callback was not drained") { probe.finished }
            switch outcome {
            case .failure(is CancellationError) where !timeout:
                try c.expect(true, "cancellation returns without unresumed UI")
            case .failure(MCPConversationError.timedOut) where timeout:
                try c.expect(true, "deadline returns without unresumed UI")
            default: throw Failed(check: "late review incorrectly completed")
            }
            try c.expect(probe.writes == 0, "lease checked inside host prevents late write after approval")
            try c.expect(await model.inputs.count == 1, "no follow-up model after cancelled review")
            do { try probe.checkCaptured(); throw Failed(check: "completed run lease still usable") }
            catch is CancellationError { try c.expect(true, "retained cancelled lease is dead") }
            catch MCPConversationError.timedOut { try c.expect(true, "retained timed-out lease is dead") }
        }
        // A callback's lease must expire even while the run remains alive and is
        // awaiting its next model result, not merely when the whole run finishes.
        let nextModel = Gate(), completedProbe = LeaseProbe()
        let running = Task {
            try await run(Model([local(.memorySave), finish], pauseAt: 1, gate: nextModel), local: { _, lease in
                completedProbe.capture(lease); try lease.check(); completedProbe.write()
                return .committedReceipt(json: receiptJSON)
            })
        }
        do {
            try await waitUntil("next model call not reached") { await nextModel.entered }
            extra += try await expect(.localLeaseExpired) { try completedProbe.checkCaptured() }
        } catch { running.cancel(); await nextModel.release(); _ = try? await running.value; throw error }
        await nextModel.release()
        let result = try await running.value
        try c.expect(result.stopReason == .finished && completedProbe.writes == 1, "lease invalidation does not abort legitimate next model call")
        let failureProbe = LeaseProbe()
        do {
            _ = try await run(Model([local(.memorySave)]), local: { _, lease in
                failureProbe.capture(lease); throw HostFailure.validation
            })
            throw Failed(check: "typed rejection expected")
        } catch HostFailure.validation { try c.expect(true, "host throw retains type") }
        do { try failureProbe.checkCaptured(); throw Failed(check: "failed callback lease still usable") }
        catch is CancellationError { try c.expect(true, "host failure closes run and lease") }
        return c.count + extra
    }

    static let groups: [(String, () async throws -> Int)] = [
        ("rawEnvelopeAndTypedErrors", rawEnvelopeAndTypedErrors),
        ("distinctNamespacesAndMixedApproval", distinctNamespacesAndMixedApproval),
        ("localAndSharedBudgets", localAndSharedBudgets),
        ("outcomesErrorsAndOutputBounds", outcomesErrorsAndOutputBounds),
        ("denialAndPostcommitFailures", denialAndPostcommitFailures),
        ("cancellationDeadlineAndLeaseLifetime", cancellationDeadlineAndLeaseLifetime)
    ]
}

#if MCP_LOCAL_STANDALONE
@main struct MCPLocalToolsStandalone {
    static func main() async throws {
        var total = 0
        for (name, body) in MCPLocalToolsChecks.groups {
            let count = try await body(); total += count
            print("PASS \(name): \(count) checks")
        }
        print("PASS MCP local: \(MCPLocalToolsChecks.groups.count) groups, \(total) checks; synthetic host/model only")
    }
}
#else
import XCTest
final class MCPLocalToolsTests: XCTestCase {
    func testRawEnvelopeAndTypedHostErrors() async throws {
        let count = try await MCPLocalToolsChecks.rawEnvelopeAndTypedErrors(); XCTAssertGreaterThan(count, 0)
    }
    func testLocalNamespaceAndMixedRemoteApproval() async throws {
        let count = try await MCPLocalToolsChecks.distinctNamespacesAndMixedApproval(); XCTAssertGreaterThan(count, 0)
    }
    func testLocalAndSharedModelRemoteBudgets() async throws {
        let count = try await MCPLocalToolsChecks.localAndSharedBudgets(); XCTAssertGreaterThan(count, 0)
    }
    func testOutcomeTypesHostFailuresAndByteBounds() async throws {
        let count = try await MCPLocalToolsChecks.outcomesErrorsAndOutputBounds(); XCTAssertGreaterThan(count, 0)
    }
    func testLocalDenialAndPostcommitFailureRetention() async throws {
        let count = try await MCPLocalToolsChecks.denialAndPostcommitFailures(); XCTAssertGreaterThan(count, 0)
    }
    func testCancellationDeadlineLateReviewAndLeaseLifetime() async throws {
        let count = try await MCPLocalToolsChecks.cancellationDeadlineAndLeaseLifetime(); XCTAssertGreaterThan(count, 0)
    }
}
#endif
