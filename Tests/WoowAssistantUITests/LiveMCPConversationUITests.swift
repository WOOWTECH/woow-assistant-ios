import XCTest

/// Real model + real HA server through the App. Only audited read-only calls are
/// approved. No live screenshots, trees, response bodies or xcresult uploads.
final class LiveMCPConversationUITests: XCTestCase {
    private let namespace = UUID().uuidString
    private var app = XCUIApplication()
    private var launched = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let environment = ProcessInfo.processInfo.environment
        for key in ["WOOW_LIVE_API_KEY", "WOOW_LIVE_MODEL", "WOOW_LIVE_BASE_URL", "WOOW_LIVE_MCP_URL"] {
            guard environment[key]?.isEmpty == false else {
                throw XCTSkip("Combined private model/MCP configuration was not supplied.")
            }
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveMCPConversationUITest"]
        app.launchEnvironment = Dictionary(uniqueKeysWithValues:
            ["WOOW_LIVE_API_KEY", "WOOW_LIVE_MODEL", "WOOW_LIVE_BASE_URL", "WOOW_LIVE_MCP_URL"].map { ($0, environment[$0]!) })
        launched = true
        app.launch()
        navigate("tools")
        revealLearningElement(app.buttons["mcp.connect"], in: app)
        app.buttons["mcp.connect"].tap()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["mcp.status"].label == "已連線，目錄擷取完成" || self.app.staticTexts["mcp.error"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 95), .completed)
        XCTAssertFalse(app.staticTexts["mcp.error"].exists, "Actual MCP discovery failed.")
        selectTool("ha_eval_template")
        selectTool("ha_list_floors_areas")
        navigate("chat")
        let toggle = app.switches["chat.useMCP"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        setSwitch(toggle)
    }

    override func tearDownWithError() throws {
        guard launched else { return }
        app.terminate()
        app.launchArguments = ["-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveModelUITestCleanup"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.status"].label == "尚未設定模型", "Private model cleanup failed.")
        navigate("tools")
        XCTAssertTrue(app.staticTexts["mcp.status"].label == "尚未設定 MCP", "Private MCP cleanup failed.")
        app.terminate()
    }

    func testRealModelChoosesTwoReadOnlyToolsAndUsesTheirResults() throws {
        send("Call ha_eval_template once with only {\"template\":\"{{7*6}}\"}, and ha_list_floors_areas once with {}. After both successful tool results, reply exactly MCP_OK_42 only if the template result is 42. Use actual tool results.")
        var approved = Set<String>()
        for _ in 0..<2 {
            let nameElement = app.staticTexts["mcp.approval.name"]
            let next = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                nameElement.exists || self.app.staticTexts["chat.error"].exists
                    || self.app.staticTexts["chat.message.1.assistant"].exists
            }, object: nil)
            let waitResult = XCTWaiter.wait(for: [next], timeout: 95)
            let activity = app.staticTexts["chat.mcpActivity"]
            // App-owned fixed categories/counters only; never log proposals,
            // model replies, tool results or the full accessibility tree.
            print("Live MCP transition: \(activity.value as? String ?? "unavailable"); proposal=\(nameElement.exists); error=\(app.staticTexts["chat.error"].exists); answer=\(app.staticTexts["chat.message.1.assistant"].exists)")
            XCTAssertEqual(waitResult, .completed)
            XCTAssertTrue(nameElement.exists, "The model did not produce the next approval proposal; see fixed diagnostics.")
            let name = nameElement.label
            XCTAssertTrue(["ha_eval_template", "ha_list_floors_areas"].contains(name), "Unapproved tool proposal.")
            XCTAssertTrue(approved.insert(name).inserted, "The model repeated a call instead of selecting the other tool.")
            let data = Data(app.staticTexts["mcp.approval.arguments"].label.utf8)
            let arguments = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            if name == "ha_eval_template" {
                XCTAssertTrue(Set(arguments.keys) == ["template"], "Unexpected template arguments; no call was approved.")
                XCTAssertTrue(arguments["template"] as? String == "{{7*6}}", "Only the literal arithmetic template is authorized.")
            } else {
                XCTAssertTrue(arguments.isEmpty, "Only unfiltered floor/area listing is authorized.")
            }
            app.buttons["mcp.approval.approve"].tap()
            let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: nameElement)
            XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 5), .completed)
        }
        let answer = app.staticTexts["chat.message.1.assistant"]
        XCTAssertTrue(answer.waitForExistence(timeout: 95), "No final answer after actual tools returned.")
        XCTAssertTrue(answer.label.trimmingCharacters(in: .whitespacesAndNewlines) == "MCP_OK_42", "Final answer did not use the literal arithmetic result.")
        XCTAssertFalse(app.staticTexts["chat.error"].exists)
        let diagnostics = app.staticTexts["chat.mcpActivity"].value as? String ?? "unavailable"
        print("Live MCP completion: \(diagnostics)")
        XCTAssertTrue(diagnostics.hasPrefix("phase=finished;"))
        XCTAssertTrue(diagnostics.contains(";attempts=2;results=2;toolErrors=0;failure=none"),
                      "Exactly two actual results and zero tool errors must be reported.")
    }

    func testRealModelToolRefusalKeepsDraft() {
        let prompt = "Use ha_eval_template with only template={{7*6}} to calculate the result. Propose the tool call and wait for my approval."
        send(prompt)
        let next = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["mcp.approval.name"].exists || self.app.staticTexts["chat.error"].exists
                || self.app.staticTexts["chat.message.1.assistant"].exists
        }, object: nil)
        let waitResult = XCTWaiter.wait(for: [next], timeout: 95)
        let diagnostics = app.staticTexts["chat.mcpActivity"].value as? String ?? "unavailable"
        print("Live MCP refusal proposal: \(diagnostics); proposal=\(app.staticTexts["mcp.approval.name"].exists); error=\(app.staticTexts["chat.error"].exists)")
        XCTAssertEqual(waitResult, .completed)
        XCTAssertTrue(app.staticTexts["mcp.approval.name"].exists, "No real approval proposal; fixed diagnostics identify the terminal phase.")
        XCTAssertTrue(app.staticTexts["mcp.approval.name"].label == "ha_eval_template")
        app.buttons["mcp.approval.decline"].tap()
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.error"].label.contains("拒絕"))
        XCTAssertTrue(app.textFields["chat.draft"].value as? String == prompt, "Declining a real proposal must preserve its draft.")
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
    }

    private func selectTool(_ name: String) {
        let search = app.textFields["mcp.toolSearch"]
        revealLearningElement(search, in: app)
        search.tap()
        if let old = search.value as? String, old != "搜尋工具名稱", !old.isEmpty {
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        search.typeText(name + "\n")
        let toggle = app.switches["mcp.enable.\(name)"]
        revealLearningElement(toggle, in: app)
        setSwitch(toggle)
    }
    private func setSwitch(_ toggle: XCUIElement) {
        let target = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        XCTAssertTrue(target.isHittable)
        target.tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "1"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
    }
    private func navigate(_ section: String) {
        let button = app.buttons.matching(identifier: "navigation.\(section)").firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 10))
        XCTAssertTrue(button.isHittable)
        button.tap()
    }
    private func send(_ text: String) {
        let draft = app.textFields["chat.draft"]
        XCTAssertTrue(draft.isHittable)
        draft.tap()
        let characters = Array(text)
        for start in stride(from: 0, to: characters.count, by: 50) {
            let end = min(start + 50, characters.count)
            draft.typeText(String(characters[start..<end]))
            XCTAssertTrue(draft.value as? String == String(characters[..<end]), "A live prompt input segment was not received completely.")
        }
        draft.typeText("\n")
        XCTAssertTrue(draft.value as? String == text, "The complete live prompt must arrive before submission.")
        app.buttons["chat.send"].tap()
    }
}
