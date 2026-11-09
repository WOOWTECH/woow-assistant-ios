import AssistantBrowser
import AssistantModels
import Foundation
#if !WEB_RESEARCH_SMOKE
import XCTest

final class WebResearchRunnerTests: XCTestCase {
    private let configuration = ModelConfiguration(baseURL: URL(string: "https://model.invalid/v1")!, model: "fixture")

    func testActualExecutorResultsAndPriorEvidenceReachFinalAnswer() async throws {
        let model = ResearchModel([#"{"action":"open","linkID":1}"#, #"{"action":"finish","answer":"Both sources read."}"#])
        let browser = ResearchBrowser()
        let result = try await WebResearchRunner(client: model).run(goal: "Compare both pages", browser: browser, configuration: configuration, apiKey: "fixture")
        XCTAssertEqual(result.actions.count, 2)
        XCTAssertEqual(result.actions[1].tool, "browser_open_link")
        XCTAssertFalse(result.reachedLimit)
        let inputs = await model.inputs
        XCTAssertTrue(inputs.last!.contains { $0.content.contains("FIRST_PAGE_EVIDENCE") })
        XCTAssertTrue(inputs.last!.contains { $0.content.contains("SECOND_PAGE_EVIDENCE") })
        let count = await browser.opens
        XCTAssertEqual(count, 1)
    }

    func testRepeatedCallsStopWithoutCountingFabricatedProgress() async throws {
        let command = #"{"action":"find","text":"evidence"}"#
        let model = ResearchModel([command, command])
        let browser = ResearchBrowser()
        let result = try await WebResearchRunner(client: model).run(goal: "Read evidence", browser: browser, configuration: configuration, apiKey: "fixture")
        XCTAssertTrue(result.reachedLimit)
        XCTAssertEqual(result.actions.count, 2)
        let count = await browser.finds
        XCTAssertEqual(count, 1)
    }

    func testInvalidActionCannotExecuteArbitraryCodeOrURL() async throws {
        let count = try await ResearchDiagnosticChecks.commands()
        XCTAssertGreaterThan(count, 0)
    }

    func testExecutorFailureNeverBecomesCompletedAction() async throws {
        let count = try await ResearchDiagnosticChecks.failures()
        XCTAssertGreaterThan(count, 0)
    }
}
#endif

// The same regression assertions run in XCTest and a credential-free CLT smoke
// executable; fixtures never stand in for the separate real-model UI acceptance.
private enum ResearchDiagnosticChecks {
    struct Failure: Error { let label: String }
    struct Checks {
        var count = 0
        mutating func expect(_ condition: Bool, _ label: String) throws {
            count += 1
            if !condition { throw Failure(label: label) }
        }
    }
    static let configuration = ModelConfiguration(baseURL: URL(string: "https://model.invalid/v1")!, model: "fixture")
    static let open = #"{"action":"open","linkID":1}"#
    static let finish = #"{"action":"finish","answer":"Both sources read."}"#

    static func commands() async throws -> Int {
        var checks = Checks()
        let invalid: [(String, WebResearchError, String)] = [
            ("not-json", .invalidModelJSON, "invalid_command_json"),
            ("```json\n" + open + "\n```", .invalidModelJSON, "invalid_command_json"),
            (open + finish, .invalidModelJSON, "invalid_command_json"),
            (#"{"linkID":1}"#, .invalidModelJSON, "invalid_command_json"),
            (#"{"action":"open","linkID":"1"}"#, .invalidModelJSON, "invalid_command_json"),
            (#"{"action":"javascript","text":"document.cookie"}"#, .unsupportedCommand, "unsupported_command"),
            (#"{"action":"navigate","url":"https://other.invalid"}"#, .unsupportedCommand, "unsupported_command"),
            (#"{"action":"inspect"}"#, .unsupportedCommand, "unsupported_command"),
            (#"{"action":"open","linkID":999,"url":"https://other.invalid"}"#, .unknownLink, "unknown_link"),
            (#"{"action":"open","linkID":-1}"#, .unknownLink, "unknown_link"),
            (#"{"action":"open","url":"https://other.invalid"}"#, .invalidCommand, "invalid_command_arguments"),
            (#"{"action":"find","text":" "}"#, .invalidCommand, "invalid_command_arguments"),
            ("{\"action\":\"find\",\"text\":\"" + String(repeating: "x", count: 121) + "\"}", .invalidCommand, "invalid_command_arguments"),
            (#"{"action":"finish","answer":" "}"#, .invalidCommand, "invalid_command_arguments"),
            (#"{"action":"finish"}"#, .invalidCommand, "invalid_command_arguments"),
            ("{\"action\":\"finish\",\"answer\":\"" + String(repeating: "x", count: 8001) + "\"}", .invalidCommand, "invalid_command_arguments"),
            (String(repeating: "x", count: 24001), .modelResponseTooLarge, "command_too_large")
        ]
        for (command, expected, code) in invalid {
            let model = ResearchModel([command]), browser = ResearchBrowser(), completed = ResearchCompleted()
            do {
                _ = try await WebResearchRunner(client: model).run(goal: "Read", browser: browser, configuration: configuration,
                    apiKey: "fixture", onAction: { await completed.append($0) })
                throw Failure(label: "invalid command accepted")
            } catch let actual as WebResearchError {
                try checks.expect(actual == expected, "distinct invalid command category")
                try checks.expect(WebResearchRunner.failureDescription(for: actual).code == code, "safe command diagnostic category")
            }
            try checks.expect(await browser.opens == 0, "invalid command never opens a page")
            try checks.expect(await browser.finds == 0, "invalid command never searches a page")
            try checks.expect(await completed.count() == 1, "only real initial inspection is completed")
            try checks.expect(await model.inputs.count == 1, "invalid command is not silently retried")
        }
        // Still accept only the original supported commands and actual executor results.
        let model = ResearchModel([open, finish]), browser = ResearchBrowser()
        let result = try await WebResearchRunner(client: model).run(goal: "Read", browser: browser, configuration: configuration, apiKey: "fixture")
        try checks.expect(!result.reachedLimit && result.answer == "Both sources read.", "valid command result unchanged")
        try checks.expect(result.actions.count == 2 && result.actions[1].observation.text == "SECOND_PAGE_EVIDENCE", "real executor evidence retained")
        try checks.expect(await browser.opens == 1, "one supported open executes once")
        for repeated in [open, #"{"action":"find","text":"evidence"}"#] {
            let result = try await WebResearchRunner(client: ResearchModel([repeated, repeated])).run(goal: "Read", browser: ResearchBrowser(), configuration: configuration, apiKey: "fixture")
            try checks.expect(result.reachedLimit && result.actions.count == 2, "duplicate remains a stop, not a completed task")
        }
        return checks.count
    }

    static func failures() async throws -> Int {
        var checks = Checks()
        let pageErrors: [(WebResearchError, String)] = [
            (.noPage, "page_unavailable"), (.unsafeNavigation, "unsafe_navigation"), (.pageChanged, "page_changed"),
            (.navigationFailed, "navigation_failed"), (.navigationTimedOut, "navigation_timeout"),
            (.observationTimedOut, "page_read_timeout"), (.deadline, "research_timeout")
        ]
        for (failure, code) in pageErrors {
            let browser = ResearchBrowser(openingFailure: failure), completed = ResearchCompleted()
            do {
                _ = try await WebResearchRunner(client: ResearchModel([open])).run(goal: "Read", browser: browser,
                    configuration: configuration, apiKey: "fixture", onAction: { await completed.append($0) })
                throw Failure(label: "failed executor accepted")
            } catch let actual as WebResearchError {
                try checks.expect(actual == failure, "executor category preserved")
                try checks.expect(WebResearchRunner.failureDescription(for: actual).code == code, "page failure distinct from timeout")
            }
            try checks.expect(await completed.count() == 1, "failed navigation is never recorded as completed")
            try checks.expect(await browser.opens == 0, "failed navigation never increments successful opens")
        }
        let initialModel = ResearchModel([finish]), initialActions = ResearchCompleted()
        do {
            _ = try await WebResearchRunner(client: initialModel).run(goal: "Read", browser: ResearchBrowser(inspectionFailure: .noPage),
                configuration: configuration, apiKey: "fixture", onAction: { await initialActions.append($0) })
            throw Failure(label: "failed initial inspection accepted")
        } catch let actual as WebResearchError { try checks.expect(actual == .noPage, "initial inspection category") }
        try checks.expect(await initialActions.count() == 0, "zero completed actions identifies pre-model inspection failure")
        try checks.expect(await initialModel.inputs.count == 0, "failed initial inspection never calls model")
        let modelErrors: [(HTTPChatModelError, String)] = [
            (.invalidConfiguration, "model_configuration"), (.redirectRejected, "model_redirect"),
            (.httpStatus(403), "model_http_403"), (.httpStatus(429), "model_http_429"),
            (.invalidResponse, "model_invalid_response"), (.incompleteResponse, "model_incomplete_response"),
            (.responseTooLarge, "model_response_too_large"), (.consumerTooSlow, "model_output_backpressure"),
            (.timedOut, "model_timeout"), (.transportFailure, "model_connection_failed")
        ]
        for (failure, code) in modelErrors {
            let model = ResearchModel([], failure: failure), browser = ResearchBrowser(), completed = ResearchCompleted()
            do {
                _ = try await WebResearchRunner(client: model).run(goal: "Read", browser: browser, configuration: configuration,
                    apiKey: "fixture", onAction: { await completed.append($0) })
                throw Failure(label: "failed model accepted")
            } catch let actual as HTTPChatModelError {
                try checks.expect(actual == failure, "HTTP failure not conflated with command JSON")
                let diagnostic = WebResearchRunner.failureDescription(for: actual)
                try checks.expect(diagnostic.code == code, "model failure category")
                try checks.expect(!diagnostic.message.isEmpty && diagnostic.message.utf16.count <= 120, "bounded user-understandable message")
            }
            try checks.expect(await completed.count() == 1, "HTTP failure leaves only actual initial inspection")
            try checks.expect(await browser.opens == 0, "HTTP failure executes no navigation")
            try checks.expect(await model.inputs.count == 1, "HTTP failure is not retried to pass")
        }
        let secret = "fixture-private-body https://user:secret@private.invalid/path"
        let untrusted = NSError(domain: secret, code: 123, userInfo: [NSLocalizedDescriptionKey: secret, NSUnderlyingErrorKey: secret])
        let unknown = WebResearchRunner.failureDescription(for: untrusted)
        try checks.expect(unknown.code == "research_failed", "unknown errors use fixed fallback")
        try checks.expect(!unknown.message.contains("fixture-private") && !unknown.message.contains("https://") && !unknown.message.contains("secret"), "raw error body and URL never exposed")
        try checks.expect(WebResearchRunner.failureDescription(for: CancellationError()).code == "cancelled", "cancellation distinct from failure")
        try checks.expect(WebResearchRunner.failureDescription(for: HTTPChatModelError.httpStatus(Int.max)).code == "model_http_error", "invalid status values bounded")
        return checks.count
    }
}

#if WEB_RESEARCH_SMOKE
@main struct WebResearchStandaloneChecks {
    static func main() async throws {
        let commands = try await ResearchDiagnosticChecks.commands()
        let failures = try await ResearchDiagnosticChecks.failures()
        print("PASS research commands: \(commands) assertions")
        print("PASS research failure diagnostics: \(failures) assertions")
        print("PASS research native checks: \(commands + failures) assertions; no network/model calls")
    }
}
#endif

private actor ResearchCompleted {
    private var actions: [WebResearchAction] = []
    func append(_ action: WebResearchAction) { actions.append(action) }
    func count() -> Int { actions.count }
}

private actor ResearchModel: ChatModelClient {
    var replies: [String]
    let failure: HTTPChatModelError?
    private(set) var inputs: [[ModelMessage]] = []
    init(_ replies: [String], failure: HTTPChatModelError? = nil) { self.replies = replies; self.failure = failure }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        inputs.append(messages)
        if let failure { throw failure }
        guard !replies.isEmpty else { throw WebResearchError.invalidCommand }
        return replies.removeFirst()
    }
}

private actor ResearchBrowser: WebResearchExecuting {
    private(set) var opens = 0
    private(set) var finds = 0
    let openingFailure: WebResearchError?
    let inspectionFailure: WebResearchError?
    init(openingFailure: WebResearchError? = nil, inspectionFailure: WebResearchError? = nil) {
        self.openingFailure = openingFailure; self.inspectionFailure = inspectionFailure
    }
    func inspect() async throws -> WebObservation {
        if let inspectionFailure { throw inspectionFailure }
        return page(second: false)
    }
    func openLink(id: Int) async throws -> WebObservation {
        if let openingFailure { throw openingFailure }
        opens += 1; return page(second: true)
    }
    func find(text: String) async throws -> WebObservation { finds += 1; return page(second: false) }
    private func page(second: Bool) -> WebObservation {
        let next = URL(string: "https://research.invalid/second")!
        return WebObservation(url: second ? next : URL(string: "https://research.invalid/first")!, title: "Fixture",
            text: second ? "SECOND_PAGE_EVIDENCE" : "FIRST_PAGE_EVIDENCE",
            links: [WebResearchLink(id: 1, title: "Second", url: next)])
    }
}
