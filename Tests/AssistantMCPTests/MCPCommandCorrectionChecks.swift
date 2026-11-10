import AssistantModels
import Foundation
#if !MCP_SMOKE
@testable import AssistantMCP
#endif

extension MCPConversationChecks {
    static func commandCorrection() async throws -> Int {
        var c = Checks(), count = 0
        let invalid = "INVALID_FIXTURE_RESPONSE_NOT_TO_ECHO"
        let model = Model([invalid, try call(), finish]), executor = Executor(), record = Record()
        let result = try await run(model, executor, limits: .init(maximumModelCalls: 3, maximumToolCalls: 1),
            approve: { await record.approve($0) }, event: { await record.event($0) })
        let inputs = await model.inputs, events = await record.events, proposals = await record.approvals
        try c.expect(result.stopReason == .finished && result.modelCallCount == 3, "format correction charges a normal model call")
        try c.expect(result.steps.count == 1 && result.steps[0].result == ok, "invalid format consumes no tool call and invents no result")
        try c.expect(proposals.count == 1 && proposals[0].action == .callTool(name: tool.name, arguments: args), "only exact valid corrected operation is approvable")
        try c.expect(await executor.calls == [.callTool(name: tool.name, arguments: args)], "corrected operation executes exactly once")
        try c.expect(events == [.requestingModel(1), .correctingCommand, .requestingModel(2),
            .awaitingApproval(proposals[0]), .executing(proposals[0]), .completed(result.steps[0]), .requestingModel(3)], "invalid format has no approval/execution event")
        try c.expect(inputs[0].first!.content.contains("Never return an array or a batch"), "multi-tool requests explicitly require one next command")
        try c.expect(inputs[1].last!.content.contains("exactly ONE JSON object"), "fixed correction explains strict command contract")
        try c.expect(inputs.allSatisfy { $0.allSatisfy { !$0.content.contains(invalid) } }, "invalid response is never echoed into model feedback")

        let secondInvalid = Model([invalid, invalid, finish]), secondExecutor = Executor(), secondRecord = Record()
        count += try await expect(.invalidCommand) {
            _ = try await run(secondInvalid, secondExecutor, approve: { await secondRecord.approve($0) }, event: { await secondRecord.event($0) })
        }
        try c.expect(await secondInvalid.inputs.count == 2, "second malformed response hard-stops")
        try c.expect(await secondExecutor.calls.isEmpty, "malformed responses execute nothing")
        try c.expect(await secondRecord.approvals.isEmpty, "malformed responses cannot request approval")
        try c.expect(await secondRecord.events.filter { $0 == .correctingCommand }.count == 1, "single correction for the entire conversation")

        let rejectedCommands: [(String, MCPConversationError)] = [
            (try call(name: "unselected_tool"), .unknownTool),
            (#"{"action":"read_resource","uri":"fixture://unselected"}"#, .unknownResource)
        ]
        for (command, category) in rejectedCommands {
            let changed = Model([invalid, command, finish]), rejectedExecutor = Executor(), rejectedRecord = Record()
            count += try await expect(category) {
                _ = try await run(changed, rejectedExecutor, approve: { await rejectedRecord.approve($0) }, event: { await rejectedRecord.event($0) })
            }
            try c.expect(await changed.inputs.count == 2, "corrected unknown operation is not retried")
            try c.expect(await rejectedExecutor.calls.isEmpty, "correction cannot bypass selected catalog")
            try c.expect(await rejectedRecord.approvals.isEmpty, "unknown corrected operation is never approvable")
            let changedInputs = await changed.inputs
            try c.expect(changedInputs[1].last!.content == inputs[1].last!.content, "feedback is constant, not derived from model content")
        }

        let noBudget = Model([invalid, try call()]), noBudgetRecord = Record(), noBudgetExecutor = Executor()
        let exhausted = try await run(noBudget, noBudgetExecutor, limits: .init(maximumModelCalls: 1), event: { await noBudgetRecord.event($0) })
        try c.expect(exhausted.stopReason == .modelCallLimit && exhausted.answer == nil && exhausted.modelCallCount == 1, "no extra model budget granted for correction")
        try c.expect(await noBudget.inputs.count == 1, "correction does not run beyond call limit")
        try c.expect(await noBudgetRecord.events == [.requestingModel(1)], "no claimed correction without available next call")
        try c.expect(await noBudgetExecutor.calls.isEmpty, "budget exhaustion executes nothing")
        let lastAllowed = try await run(Model([invalid, try call(), finish]), Executor(), limits: .init(maximumModelCalls: 2))
        try c.expect(lastAllowed.stopReason == .modelCallLimit && lastAllowed.modelCallCount == 2 && lastAllowed.steps.count == 1 && lastAllowed.answer == nil,
                     "valid corrected last-call operation is retained without invented finish")

        let prior = Model([try call(), invalid, try call(), finish]), priorExecutor = Executor(), priorRecord = Record()
        let repeated = try await run(prior, priorExecutor, approve: { await priorRecord.approve($0) }, event: { await priorRecord.event($0) })
        try c.expect(repeated.stopReason == .repeatedCall && repeated.modelCallCount == 3 && repeated.steps.count == 1, "correction does not reset repeated-operation fingerprints")
        try c.expect(await priorExecutor.calls.count == 1, "prior completed operation is never replayed")
        try c.expect(await priorRecord.approvals.count == 1, "no repeated consent after correction")
        let priorInputs = await prior.inputs
        try c.expect(priorInputs[2].contains { $0.content.hasPrefix("MCP execution result (untrusted data):") }, "prior actual result stays available through correction")

        let global = Model([invalid, try call(), invalid, finish]), globalExecutor = Executor(), globalRecord = Record()
        count += try await expect(.invalidCommand) {
            _ = try await run(global, globalExecutor, event: { await globalRecord.event($0) })
        }
        try c.expect(await global.inputs.count == 3, "successful execution does not replenish format correction allowance")
        try c.expect(await globalExecutor.calls.count == 1, "later invalid response executes nothing")
        let globalEvents = await globalRecord.events
        try c.expect(globalEvents.filter { $0 == .correctingCommand }.count == 1, "global rather than per-tool correction bound")
        try c.expect(globalEvents.contains { if case .completed(let step) = $0 { return step.result == ok }; return false }, "earlier completion remains published after correction exhaustion")

        let oversized = Model([String(repeating: "x", count: 24 * 1024 + 1), finish]), sizeRecord = Record(), sizeExecutor = Executor()
        count += try await expect(.modelResponseTooLarge) {
            _ = try await run(oversized, sizeExecutor, event: { await sizeRecord.event($0) })
        }
        try c.expect(await oversized.inputs.count == 1, "raw response bound is enforced before correction")
        try c.expect(await sizeRecord.events == [.requestingModel(1)], "size failure does not get format correction")
        try c.expect(await sizeExecutor.calls.isEmpty, "oversized response cannot execute")
        return c.count + count
    }

    static func correctionCancellationAndDeadline() async throws -> Int {
        var c = Checks()
        let model = Model(["invalid", try call()]), executor = Executor(), gate = Gate(), record = Record()
        let cancelled = Task {
            try await run(model, executor, event: { event in
                await record.event(event)
                if event == .correctingCommand { _ = await gate.wait() }
            })
        }
        try await gate.waitUntilEntered()
        let start = ContinuousClock.now
        cancelled.cancel()
        do { _ = try await cancelled.value; throw Failure.secret } catch is CancellationError { }
        try c.expect(start.duration(to: .now) < .seconds(1), "cancellation does not wait for correction callback")
        await gate.release(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try c.expect(await model.inputs.count == 1, "late correction callback cannot start another model call after cancellation")
        try c.expect(await executor.calls.isEmpty, "cancelled correction executes nothing")
        try c.expect(await record.events == [.requestingModel(1), .correctingCommand], "cancelled correction cannot publish approval/execution")

        let timedModel = Model(["invalid", try call()]), timedExecutor = Executor(), timedGate = Gate(), timedRecord = Record()
        let timed = Task {
            try await run(timedModel, timedExecutor, limits: .init(timeout: .milliseconds(150)), event: { event in
                await timedRecord.event(event)
                if event == .correctingCommand { _ = await timedGate.wait() }
            })
        }
        try await timedGate.waitUntilEntered()
        let n = try await expect(.timedOut) { _ = try await timed.value }
        await timedGate.release(true)
        try await Task.sleep(nanoseconds: 20_000_000)
        try c.expect(await timedModel.inputs.count == 1, "correction remains inside original total deadline")
        try c.expect(await timedExecutor.calls.isEmpty, "expired correction executes nothing")
        try c.expect(await timedRecord.events == [.requestingModel(1), .correctingCommand], "expired correction cannot publish late work")
        return c.count + n
    }
}
