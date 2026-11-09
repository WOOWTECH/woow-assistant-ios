import AssistantBrowser
import AssistantModels
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
        for command in [#"{"action":"javascript","text":"document.cookie"}"#,
                        #"{"action":"open","linkID":999,"url":"https://other.invalid"}"#] {
            let browser = ResearchBrowser()
            do {
                _ = try await WebResearchRunner(client: ResearchModel([command])).run(goal: "Read", browser: browser, configuration: configuration, apiKey: "fixture")
                XCTFail("Invalid action accepted")
            } catch { XCTAssertTrue(error is WebResearchError) }
            let count = await browser.opens
            XCTAssertEqual(count, 0)
        }
    }

    func testExecutorFailureNeverBecomesCompletedAction() async throws {
        let browser = ResearchBrowser(failOpen: true)
        do {
            _ = try await WebResearchRunner(client: ResearchModel([#"{"action":"open","linkID":1}"#])).run(goal: "Read", browser: browser, configuration: configuration, apiKey: "fixture")
            XCTFail("Failed navigation was accepted")
        } catch { XCTAssertTrue(error is WebResearchError) }
    }
}

private actor ResearchModel: ChatModelClient {
    var replies: [String]
    private(set) var inputs: [[ModelMessage]] = []
    init(_ replies: [String]) { self.replies = replies }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        inputs.append(messages)
        guard !replies.isEmpty else { throw WebResearchError.invalidCommand }
        return replies.removeFirst()
    }
}

private actor ResearchBrowser: WebResearchExecuting {
    private(set) var opens = 0
    private(set) var finds = 0
    let failOpen: Bool
    init(failOpen: Bool = false) { self.failOpen = failOpen }
    func inspect() async throws -> WebObservation { page(second: false) }
    func openLink(id: Int) async throws -> WebObservation {
        if failOpen { throw WebResearchError.unsafeNavigation }
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
