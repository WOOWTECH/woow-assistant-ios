#if !SKILLS_CORE_SMOKE && !SKILL_EXECUTION_SMOKE && !SKILL_AUTHORING_SMOKE
import AssistantModels
import Foundation
@testable import AssistantSkills
#if !TRANSCRIPT_SMOKE
import XCTest
#endif

extension TranscriptChecks {
    static func requestMessages(_ scenario: TranscriptHTTPFixture.Scenario, at index: Int) throws -> [[String: String]] {
        let body = try JSONSerialization.jsonObject(with: scenario.requestBodies[index]) as! [String: Any]
        return body["messages"] as! [[String: String]]
    }

    static func schemaCorrection(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        let marker = "UNTRUSTED_REPLY_MUST_NOT_BE_REPLAYED"
        let cases: [(String, TranscriptCommandFailureReason)] = [
            (marker, .syntax),
            (String(repeating: marker, count: 2048), .size),
            (try json(["action": "refuse", "reason": marker, "unexpected": marker]), .fields),
            (try json(["action": marker]), .action),
            (try json(["action": "tool", "name": marker, "arguments": [String: Any]()]), .tool),
            (try json(["action": "tool", "name": "read_file", "arguments": ["path": marker, "offset": 0, "limit": 20] as [String: Any]]), .arguments)
        ]
        var correctionMessages: [String] = []
        for (invalid, reason) in cases {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog)
            let scenario = TranscriptHTTPFixture.Scenario([invalid, try read(0), try finish()])
            var rejected: [(TranscriptCommandFailureReason, Bool, Int)] = []
            let result = try completed(await http(runtime, scenario, onEvent: { event in
                if case .commandFormatRejected(let reason, let issued) = event {
                    rejected.append((reason, issued, runtime.coveredBytes))
                }
            }))
            try expect(result.modelCalls == 3 && scenario.count == 3 && runtime.formatCorrections == 1,
                       "one correction must count as an actual HTTP model call")
            try expect(rejected.count == 1 && rejected[0].0 == reason && rejected[0].1 && rejected[0].2 == 0,
                       "fixed parser reason must precede any tool execution")
            try expect(runtime.lastCommandFailureReason == reason && runtime.reads.count == 1
                && runtime.coveredBytes == source.byteCount, "valid command still needs actual read and full evidence")
            try expect(Data(result.sections[0].evidence[0].quote.utf8) == Data(caption.utf8), "correction cannot relax quotes")
            let messages = try requestMessages(scenario, at: 1)
            try expect(messages.count == 3 && messages.last?["role"] == "user"
                && messages.allSatisfy { $0["role"] != "assistant" && $0["content"]?.contains(marker) == false },
                "rejected replies, paths and arbitrary text must never enter correction history")
            correctionMessages.append(messages.last!["content"]!)
            try expect(!String(decoding: scenario.requestBodies[1], as: UTF8.self).contains("逐字保留"),
                       "format feedback cannot disclose unread approved source bytes")
        }
        try expect(Set(correctionMessages).count == 1, "all parser failures receive the same fixed schema correction")
        try expect(Set(cases.map { $0.1 }) == Set(TranscriptCommandFailureReason.allCases), "all fixed reason codes exercised over HTTP")
    }

    static func correctionLimit(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot(), runtime = try TranscriptRuntime(source: source, catalog: catalog)
        let unknown = try json(["action": "tool", "name": "arbitrary_tool", "arguments": [String: Any]()])
        let scenario = TranscriptHTTPFixture.Scenario(["not JSON", try read(0), unknown, try finish()])
        var issued: [Bool] = []
        try await rejects(.invalidCommand) {
            _ = try await http(runtime, scenario, onEvent: { event in
                if case .commandFormatRejected(_, let correction) = event { issued.append(correction) }
            })
        }
        try expect(scenario.count == 3 && runtime.modelCalls == 3 && runtime.formatCorrections == 1
            && issued == [true, false], "successful intervening reads must not reset the single correction allowance")
        try expect(runtime.lastCommandFailureReason == .tool && runtime.reads.count == 1,
                   "second invalid command is recorded without executing it")
        let history = try requestMessages(scenario, at: 2)
        try expect(history.filter { $0["role"] == "assistant" }.count == 1
            && history.allSatisfy { $0["content"] != "not JSON" }, "only successfully parsed commands enter history")
    }

    static func correctionAuthority(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        let unauthorized = [
            try json(["action": "tool", "name": "read_file", "arguments": ["path": "/etc/passwd", "offset": 0, "limit": 8192] as [String: Any]]),
            try json(["action": "tool", "name": "web_read_page", "arguments": ["url": "https://unapproved.invalid/"]]),
            try json(["action": "tool", "name": "skill_save", "arguments": ["markdown": "unapproved"]])
        ]
        for command in unauthorized {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog)
            let scenario = TranscriptHTTPFixture.Scenario([command, command, try read(0)])
            try await rejects(.invalidCommand) { _ = try await http(runtime, scenario) }
            try expect(scenario.count == 2 && runtime.reads.isEmpty && runtime.coveredBytes == 0,
                       "neither rejected action may read a snapshot, follow a URL or invoke a storage tool")
            let messages = try requestMessages(scenario, at: 1)
            try expect(messages.count == 3 && messages.allSatisfy { $0["role"] != "assistant" },
                       "unknown action has neither a tool result nor replay in history")
        }
    }

    static func correctionBudgets(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        for calls in [1, 24] {
            _ = try TranscriptRuntime(source: source, catalog: catalog, limits: .init(modelCalls: calls))
        }
        for calls in [0, 25, 32] {
            try await rejects(.invalidCommand) {
                _ = try TranscriptRuntime(source: source, catalog: catalog, limits: .init(modelCalls: calls))
            }
        }
        for calls in [1, 2] {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog, limits: .init(modelCalls: calls))
            let scenario = TranscriptHTTPFixture.Scenario(["not JSON", try read(0), try finish()])
            try await rejects(.budgetExceeded) { _ = try await http(runtime, scenario) }
            try expect(runtime.modelCalls == calls && scenario.count == calls && runtime.formatCorrections == calls - 1,
                       "correction must not add a call beyond the original task budget")
            try expect(runtime.reads.count == calls - 1, "a read occurs only on the second authorized model command")
        }
        let cases: [([String], TranscriptError, Int)] = [
            ([try read(1)], .invalidRange, 1),
            ([try finish(offset: Int.max)], .invalidRange, 1),
            ([try finish()], .incompleteCoverage, 1),
            ([try read(0), try finish(quote: "fabricated")], .invalidEvidence, 2),
            ([try json(["action": "finish", "title": "title", "sections": [
                ["title": "section", "text": "text", "evidence": [[String: Any]]()] as [String: Any]
            ]])], .invalidEvidence, 1)
        ]
        for (commands, error, calls) in cases {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog)
            let scenario = TranscriptHTTPFixture.Scenario(commands + [try read(0)])
            try await rejects(error) { _ = try await http(runtime, scenario) }
            try expect(runtime.formatCorrections == 0 && runtime.lastCommandFailureReason == nil && scenario.count == calls,
                       "non-format safety failures must stop without schema correction")
        }
        // Cancellation/context changes triggered by the event must prevent even
        // the correction HTTP request, not just reject its eventual result.
        for cancel in [true, false] {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog)
            let scenario = TranscriptHTTPFixture.Scenario(["not JSON", try read(0)])
            var current = true
            try await rejects(cancel ? .cancelled : .contextChanged) {
                _ = try await http(runtime, scenario, context: {
                    if !current { throw TranscriptError.contextChanged }
                }, onEvent: { event in
                    if case .commandFormatRejected = event {
                        if cancel { runtime.cancel() } else { current = false }
                    }
                })
            }
            try expect(scenario.count == 1 && runtime.reads.isEmpty, "revoked context cannot send a correction request")
        }
    }

    static func correctionCancellation(_ catalog: BundledSkillCatalog) async throws {
        enum Stop { case runtime, parent, context, timeout }
        let source = try await snapshot()
        for stop in [Stop.runtime, .parent, .context, .timeout] {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog,
                limits: .init(modelTime: stop == .timeout ? .seconds(2) : .seconds(180)))
            let scenario = TranscriptHTTPFixture.Scenario([], hold: true)
            let url = TranscriptHTTPFixture.register(scenario), session = TranscriptHTTPFixture.session()
            defer { session.invalidateAndCancel(); TranscriptHTTPFixture.remove(url) }
            var current = true
            let started = ContinuousClock.now
            let request = Task {
                try await runtime.run(client: HTTPChatModelClient(session: session),
                    configuration: .init(baseURL: url, model: "transcript-fixture", maxOutputTokens: 8192), apiKey: key,
                    validateContext: { if !current { throw TranscriptError.contextChanged } })
            }
            try await waitForRequest(scenario)
            // Consume real HTTP waiting time before invalid JSON. The held
            // correction must receive only the remaining time, not a new 2s.
            if stop == .timeout { try await Task.sleep(for: .milliseconds(1200)) }
            scenario.release("not JSON")
            let secondDeadline = ContinuousClock.now + .seconds(2)
            while (scenario.count < 2 || !scenario.ready) && ContinuousClock.now < secondDeadline {
                try await Task.sleep(for: .milliseconds(5))
            }
            try expect(scenario.count == 2 && scenario.ready, "real correction HTTP request entered")
            switch stop {
            case .runtime: runtime.cancel()
            case .parent: request.cancel()
            case .context: current = false; scenario.release(try read(0))
            case .timeout: break
            }
            let error: TranscriptError = stop == .context ? .contextChanged : (stop == .timeout ? .timedOut : .cancelled)
            try await rejects(error) { _ = try await request.value }
            if stop != .context {
                let deadline = ContinuousClock.now + .seconds(2)
                while scenario.stops == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
                try expect(scenario.stops > 0, "held correction HTTP transport must acknowledge cancellation before teardown")
            }
            if stop == .timeout {
                try expect(started.duration(to: .now) < .milliseconds(2900), "format correction must not reset cumulative model wait budget")
            }
            try expect(scenario.count == 2 && runtime.modelCalls == 2 && runtime.formatCorrections == 1
                && runtime.reads.isEmpty, "late or cancelled correction cannot disclose bytes or issue another call")
        }
    }
}

#if !TRANSCRIPT_SMOKE
@MainActor final class TranscriptCommandRecoveryTests: XCTestCase {
    func testActualHTTPFormatCorrectionAndSafeReasons() async throws { try await TranscriptChecks.schemaCorrection(.bundled()) }
    func testSecondInvalidCommandStopsEvenAfterSuccessfulRead() async throws { try await TranscriptChecks.correctionLimit(.bundled()) }
    func testUnknownToolsAndPathsCannotExecuteDuringCorrection() async throws { try await TranscriptChecks.correctionAuthority(.bundled()) }
    func testCorrectionRespectsBudgetsContextAndOtherSafetyFailures() async throws { try await TranscriptChecks.correctionBudgets(.bundled()) }
    func testHeldCorrectionHTTPCancellationContextChangeAndCumulativeDeadline() async throws { try await TranscriptChecks.correctionCancellation(.bundled()) }
}
#endif
#endif
