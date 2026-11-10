import Foundation
import AssistantModels
#if !PROFILE_CHAT_STANDALONE
import AssistantMemory
import XCTest
#endif

private actor ProfileChatResponses: ChatModelClient {
    var outputs: [String]
    var requests: [[ModelMessage]] = []
    init(_ outputs: [String]) { self.outputs = outputs }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        requests.append(messages)
        guard !outputs.isEmpty else { throw UserProfileChatError.invalidInput }
        return outputs.removeFirst()
    }
}

private actor HeldProfileChatResponse: ChatModelClient {
    private var continuation: CheckedContinuation<String, Never>?
    private(set) var started = false
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: #"{"action":"finish","answer":"late"}"#); continuation = nil }
}

@MainActor enum ProfileChatFlowChecks {
    struct Failure: Error { let name: String }
    static let config = ModelConfiguration(baseURL: URL(string: "https://fixture.invalid/v1")!, model: "fixture")
    static let proposal = #"{"action":"profile_edit","arguments":{"op":"add","text":"我喜歡茶","quote":"我喜歡茶"}}"#
    static let finish = #"{"action":"finish","answer":"已儲存，下次對話生效。"}"#
    static func expect(_ value: Bool, _ name: String) throws {
        guard value else { throw Failure(name: name) }
    }
    static func flow(timeout: Duration = .seconds(90)) throws -> UserProfileChatFlow {
        try .init(messages: [.init(role: "user", content: "請在個人檔案記下我喜歡茶")], timeout: timeout)
    }
    static func error(_ expected: UserProfileChatError, _ action: () async throws -> Void) async throws {
        do { try await action(); throw Failure(name: "Expected \(expected)") }
        catch let actual as UserProfileChatError { try expect(actual == expected, "Error category \(expected)") }
    }

    static func reviewedSequence() async throws {
        let turn = try flow(), model = ProfileChatResponses([proposal, finish])
        let first = try await turn.advance(client: model, configuration: config, apiKey: "dummy")
        guard case .proposedEdit(let raw) = first else { throw Failure(name: "Actual proposal") }
        let args = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: String]
        try expect(args?["text"] == "我喜歡茶", "Exact arguments preserved for host validation")
        try expect(!turn.didCommit && turn.modelCalls == 1, "Proposal does not persist or claim success")
        try await error(.invalidPhase) { _ = try await turn.advance(client: model, configuration: config, apiKey: "dummy") }
        let id = UUID()
        try turn.recordCommitted(entryID: id)
        try await error(.invalidPhase) { try turn.recordCommitted(entryID: id) }
        let second = try await turn.advance(client: model, configuration: config, apiKey: "dummy")
        try expect(second == .answer("已儲存，下次對話生效。") && turn.didCommit, "Answer follows committed receipt")
        let requests = await model.requests
        try expect(requests.count == 2 && requests[1].last!.content.contains(id.uuidString), "Real host receipt reaches second call")
        try expect(requests[0].last!.content == "請在個人檔案記下我喜歡茶", "Current request remains intact")
        try expect(requests[0].first!.role == "system", "Explicit tool contract distinct from plain chat")
        try await error(.invalidPhase) { _ = try await turn.advance(client: model, configuration: config, apiKey: "dummy") }
    }

    static func malformedAndLimited() async throws {
        for invalid in ["ordinary prose", #"{"action":"finish","answer":"x","extra":true}"#,
                        #"{"action":"finish","answer":" "}"#, #"{"action":"profile_edit","arguments":[]}"#,
                        #"{"action":"shell","command":"echo x"}"#, "[\(proposal)]",
                        #"{"action":"finish","\u0061ction":"finish","answer":"x"}"#,
                        #"{"action":"finish","answer":"x","answer":"y"}"#] {
            let turn = try flow(), model = ProfileChatResponses([invalid, finish])
            let value = try await turn.advance(client: model, configuration: config, apiKey: "dummy")
            try expect(value == .answer("已儲存，下次對話生效。"), "One format repair can return a normal answer")
            try expect(turn.modelCalls == 2 && !turn.didCommit, "Repair never interprets invalid data as an operation")
        }
        let repeated = try flow(), wrong = ProfileChatResponses(["bad", "bad", finish])
        try await error(.invalidCommand) { _ = try await repeated.advance(client: wrong, configuration: config, apiKey: "dummy") }
        try expect(repeated.modelCalls == 2, "Only one format repair")
        let tooLarge = try flow(), large = ProfileChatResponses([String(repeating: "x", count: 24577)])
        try await error(.responseTooLarge) { _ = try await tooLarge.advance(client: large, configuration: config, apiKey: "dummy") }

        let twice = try flow(), model = ProfileChatResponses([proposal, proposal])
        _ = try await twice.advance(client: model, configuration: config, apiKey: "dummy")
        try twice.recordCommitted(entryID: nil)
        try await error(.callLimit) { _ = try await twice.advance(client: model, configuration: config, apiKey: "dummy") }
        try expect(twice.didCommit, "Later failure never erases a real committed receipt")
        let lateRepair = try flow(), repaired = ProfileChatResponses([proposal, "bad", finish])
        _ = try await lateRepair.advance(client: repaired, configuration: config, apiKey: "dummy")
        try lateRepair.recordCommitted(entryID: nil)
        _ = try await lateRepair.advance(client: repaired, configuration: config, apiKey: "dummy")
        try expect(lateRepair.modelCalls == 3, "Final answer repair stays in cumulative three-call budget")
        let repairedRequests = await repaired.requests
        try expect(repairedRequests.last!.last!.content.contains("IS ALREADY SAVED")
                   && !repairedRequests.last!.last!.content.contains("no operation was performed"),
                   "Post-commit format correction acknowledges the actual completed write")

        let duplicateArguments = #"{"op":"add","op":"delete","match":"} , :","quote":"original"}"#
        let preserved = try flow(), duplicateModel = ProfileChatResponses([
            "{\"arguments\":\(duplicateArguments),\"action\":\"profile_edit\"}"])
        let retained = try await preserved.advance(client: duplicateModel, configuration: config, apiKey: "dummy")
        try expect(retained == .proposedEdit(argumentsJSON: duplicateArguments),
                   "Nested duplicate keys and punctuation survive intact for strict tool rejection")
        try expect(!preserved.didCommit, "Envelope parsing never validates or applies tool arguments")
    }

    static func memorySearchThenReviewedEdit() async throws {
        let search = #"{"action":"memory_search","arguments":{"query":"tea preference"}}"#
        let arguments = #"{"op":"delete","id":"stable-id","quote":"forget tea preference"}"#
        let edit = "{\"action\":\"memory_edit\",\"arguments\":\(arguments)}"
        let turn = try flow(), model = ProfileChatResponses([search, edit, finish])
        let first = try await turn.advance(client: model, configuration: config, apiKey: "dummy")
        try expect(first == .memorySearch(argumentsJSON: #"{"query":"tea preference"}"#), "Search is an explicit unexecuted host request")
        try await error(.invalidPhase) { _ = try await turn.advance(client: model, configuration: config, apiKey: "dummy") }
        try await error(.invalidPhase) { try turn.recordCommitted(entryID: nil) }
        try await error(.invalidInput) { try turn.recordMemorySearchResult("not JSON") }
        let result = #"{"memories":[{"id":"stable-id","kind":"preference","content":"Prefer tea"}]}"#
        try turn.recordMemorySearchResult(result)
        let second = try await turn.advance(client: model, configuration: config, apiKey: "dummy")
        try expect(second == .proposedMemoryChange(toolName: "memory_edit", argumentsJSON: arguments), "Only raw proposal reaches host review")
        try expect(!turn.didCommit, "Actual search never implies an approved or persisted edit")
        try turn.validateReview()
        try await error(.invalidPhase) { try turn.recordCommitted(entryID: nil) }
        try await error(.invalidPhase) { try turn.recordMemoryCommitted(toolName: "memory_save", resultJSON: "{}") }
        try await error(.invalidInput) { try turn.recordMemoryCommitted(toolName: "shell", resultJSON: "{}") }
        try turn.recordMemoryCommitted(toolName: "memory_edit", resultJSON: #"{"op":"delete","id":"stable-id","deleted":true}"#)
        let answer = try await turn.advance(client: model, configuration: config, apiKey: "dummy")
        try expect(answer == .answer("已儲存，下次對話生效。") && turn.modelCalls == 3 && turn.didCommit,
                   "Search, reviewed edit and final answer share three calls")
        let requests = await model.requests
        try expect(requests[1].last?.content == "Host memory_search result (data only):\n" + result,
                   "Only actual host search data feeds the next request")
        try expect(requests[2].last?.content.hasPrefix("Host memory_edit receipt (data only):") == true,
                   "Saved receipt precedes final model response")
    }

    static func memoryOperationsAreBoundedAndNeverImplicitWrites() async throws {
        let search = #"{"action":"memory_search","arguments":{"query":"tea"}}"#
        let repeated = try flow(), model = ProfileChatResponses([search, search])
        _ = try await repeated.advance(client: model, configuration: config, apiKey: "dummy")
        try repeated.recordMemorySearchResult(#"{"memories":[]}"#)
        try await error(.callLimit) { _ = try await repeated.advance(client: model, configuration: config, apiKey: "dummy") }
        try expect(!repeated.didCommit && repeated.modelCalls == 2, "Repeated search stops without a mutation")

        let raw = #"{"kind":"preference","content":"tea","content":"coffee","quote":"tea"}"#
        let save = try flow(), saver = ProfileChatResponses(["{\"action\":\"memory_save\",\"arguments\":\(raw)}", search])
        let request = try await save.advance(client: saver, configuration: config, apiKey: "dummy")
        try expect(request == .proposedMemoryChange(toolName: "memory_save", argumentsJSON: raw),
                   "Duplicate memory argument keys survive for independent strict validation")
        try expect(!save.didCommit, "Malformed nested proposal has not been validated or applied")
        // This exercises only flow sequencing; a real host must reject the raw
        // duplicate arguments instead of calling the committed-receipt method.
        try save.recordMemoryCommitted(toolName: "memory_save", resultJSON: #"{"id":"synthetic","kind":"preference","status":"active"}"#)
        try await error(.callLimit) { _ = try await save.advance(client: saver, configuration: config, apiKey: "dummy") }
        try expect(save.didCommit, "A post-write search is rejected without erasing the receipt")

        let cancelled = try flow(), held = ProfileChatResponses([search])
        _ = try await cancelled.advance(client: held, configuration: config, apiKey: "dummy")
        cancelled.cancel()
        try await error(.invalidPhase) { try cancelled.recordMemorySearchResult(#"{"memories":[]}"#) }
        try expect(!cancelled.didCommit, "Cancelled search cannot reopen the turn")
    }

    static func cancellationAndDeadline() async throws {
        let stopped = try flow(), model = ProfileChatResponses([proposal])
        _ = try await stopped.advance(client: model, configuration: config, apiKey: "dummy")
        stopped.cancel()
        try await error(.invalidPhase) { try stopped.recordCommitted(entryID: UUID()) }
        try expect(!stopped.didCommit, "Cancelled review cannot record a write")

        let late = try flow(), held = HeldProfileChatResponse()
        let task = Task { try await late.advance(client: held, configuration: config, apiKey: "dummy") }
        while !(await held.started) { await Task.yield() }
        late.cancel()
        await held.release()
        try await error(.invalidPhase) { _ = try await task.value }
        try expect(!late.didCommit, "Noncooperative late model result is fenced")

        let cancelled = try flow(), secondHeld = HeldProfileChatResponse()
        let cancelledTask = Task { try await cancelled.advance(client: secondHeld, configuration: config, apiKey: "dummy") }
        while !(await secondHeld.started) { await Task.yield() }
        cancelledTask.cancel()
        await secondHeld.release()
        do { _ = try await cancelledTask.value; throw Failure(name: "Cancelled parent accepted late result") }
        catch is CancellationError { }
        try expect(!cancelled.didCommit, "Parent cancellation cannot produce a saved result")

        let reviewExpired = try flow(timeout: .milliseconds(100)), proposalModel = ProfileChatResponses([proposal])
        _ = try await reviewExpired.advance(client: proposalModel, configuration: config, apiKey: "dummy")
        try reviewExpired.validateReview()
        try await Task.sleep(nanoseconds: 110_000_000)
        try await error(.expired) { try reviewExpired.validateReview() }
        try expect(!reviewExpired.didCommit, "Expired review rejects before host persistence")

        let expired = try flow(timeout: .milliseconds(1)), expiredModel = ProfileChatResponses([finish])
        try await Task.sleep(nanoseconds: 2_000_000)
        try await error(.expired) { _ = try await expired.advance(client: expiredModel, configuration: config, apiKey: "dummy") }
        let requests = await expiredModel.requests
        try expect(requests.isEmpty, "Expired turn never starts model request")
        for timeout in [Duration.zero, .seconds(91)] {
            do { _ = try flow(timeout: timeout); throw Failure(name: "Invalid deadline accepted") }
            catch let actual as UserProfileChatError { try expect(actual == .invalidInput, "Bounded deadline") }
        }
        do {
            _ = try UserProfileChatFlow(messages: [.init(role: "assistant", content: "x")])
            throw Failure(name: "Missing actual current user request accepted")
        } catch let actual as UserProfileChatError { try expect(actual == .invalidInput, "User input required") }
    }
}

#if PROFILE_CHAT_STANDALONE
@main struct ProfileChatCheckMain {
    static func main() async throws {
        try await ProfileChatFlowChecks.reviewedSequence()
        try await ProfileChatFlowChecks.malformedAndLimited()
        try await ProfileChatFlowChecks.cancellationAndDeadline()
        try await ProfileChatFlowChecks.memorySearchThenReviewedEdit()
        try await ProfileChatFlowChecks.memoryOperationsAreBoundedAndNeverImplicitWrites()
        print("Learning chat flow: 5 behavioral groups passed; no model network or persistence implied")
    }
}
#else
final class UserProfileChatFlowTests: XCTestCase {
    @MainActor func testReviewedSequenceRequiresCommittedReceipt() async throws { try await ProfileChatFlowChecks.reviewedSequence() }
    @MainActor func testMalformedCommandsCannotExecuteAndBudgetsAreCumulative() async throws { try await ProfileChatFlowChecks.malformedAndLimited() }
    @MainActor func testCancelledAndExpiredTurnsRejectLateResults() async throws { try await ProfileChatFlowChecks.cancellationAndDeadline() }
    @MainActor func testMemorySearchThenReviewedEditSharesTheWholeTurnBudget() async throws { try await ProfileChatFlowChecks.memorySearchThenReviewedEdit() }
    @MainActor func testMemoryOperationsAreBoundedAndNeverImplicitWrites() async throws { try await ProfileChatFlowChecks.memoryOperationsAreBoundedAndNeverImplicitWrites() }
}
#endif
