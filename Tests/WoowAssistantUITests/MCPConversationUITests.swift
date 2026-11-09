import XCTest

final class MCPConversationUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestMCPFixture"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.tools"].waitForExistence(timeout: 10))
        app.buttons["navigation.tools"].tap()
        tap("mcp.connect")
        waitForStatus("已連線，目錄擷取完成")
        let enabled = app.switches["mcp.enable.fixture_echo"]
        revealLearningElement(enabled, in: app)
        setSwitch(enabled, on: true)
        app.buttons["navigation.chat"].tap()
        let chatEnabled = app.switches["chat.useMCP"]
        XCTAssertTrue(chatEnabled.waitForExistence(timeout: 5))
        setSwitch(chatEnabled, on: true)
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "mcp-conversation-fixture-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "mcp-conversation-fixture-tree"
            tree.lifetime = .keepAlways
            add(tree)
        }
        app.terminate()
    }

    func testModelSelectedToolRequiresExactApprovalAndReturnsResult() {
        send("[fixture:mcp] hello")
        assertApproval()
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        app.buttons["mcp.approval.approve"].tap()
        assertAnswer("FIXTURE_CALL_1: hello")
        let draft = app.textFields["chat.draft"].value as? String ?? ""
        XCTAssertTrue(draft.isEmpty || draft == "輸入訊息")
        XCTAssertTrue(app.staticTexts["chat.mcpActivity"].label.contains("1"))
    }

    func testSelectedResourceRequiresApprovalAndResultIsReviewable() {
        app.buttons["navigation.tools"].tap()
        let resource = app.switches["mcp.resource.0"]
        revealLearningElement(resource, in: app)
        setSwitch(resource, on: true)
        app.buttons["navigation.chat"].tap()
        send("[fixture:mcp-resource]")
        XCTAssertTrue(app.staticTexts["mcp.approval.name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["mcp.approval.name"].label, "讀取 MCP 資源")
        XCTAssertTrue(app.staticTexts["mcp.approval.arguments"].label.contains("fixture://guide"))
        app.buttons["mcp.approval.approve"].tap()
        assertAnswer("FIXTURE_RESOURCE_OK")
        app.buttons["chat.mcpResults"].tap()
        XCTAssertTrue(app.staticTexts["mcp.result.0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["mcp.result.0"].label.contains("FIXTURE_RESOURCE_OK"))
    }

    func testRefusalPreservesDraftAndMakesNoServerCall() {
        let prompt = "[fixture:mcp] hello"
        send(prompt)
        assertApproval()
        app.buttons["mcp.approval.decline"].tap()
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chat.error"].label.contains("拒絕"))
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, prompt)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        app.buttons["chat.send"].tap()
        assertApproval()
        app.buttons["mcp.approval.approve"].tap()
        // Same actor connection: count 1 proves the denied call never executed.
        assertAnswer("FIXTURE_CALL_1: hello")
    }

    func testBackgroundRevokesPendingApprovalAndRetainsDraft() {
        let prompt = "[fixture:mcp] hello"
        send(prompt)
        assertApproval()
        XCUIDevice.shared.press(.home)
        app.activate()
        XCTAssertTrue(app.buttons["chat.send"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["mcp.approval.approve"].exists)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, prompt)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["chat.error"].label.contains("連線"))
        app.buttons["navigation.tools"].tap()
        waitForStatus("已中斷本機連線")
    }

    func testToolErrorPreservesDraftAndActualErrorResult() {
        send("[fixture:mcp-error]")
        XCTAssertTrue(app.staticTexts["mcp.approval.name"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["mcp.approval.name"].label, "fixture_echo")
        XCTAssertTrue(app.staticTexts["mcp.approval.arguments"].label.contains("error"))
        app.buttons["mcp.approval.approve"].tap()
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.error"].label.contains("工具回報錯誤"))
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, "[fixture:mcp-error]")
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        app.buttons["chat.mcpResults"].tap()
        let result = app.staticTexts["mcp.result.0"]
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        XCTAssertTrue(result.label.contains("FIXTURE_CALL_1: error"))
        XCTAssertTrue(result.label.contains("\"isError\" : true"))
    }

    private func send(_ text: String) {
        let draft = app.textFields["chat.draft"]
        XCTAssertTrue(draft.isHittable)
        draft.tap(); draft.typeText(text + "\n")
        app.buttons["chat.send"].tap()
    }
    private func assertApproval() {
        let name = app.staticTexts["mcp.approval.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 10))
        XCTAssertEqual(name.label, "fixture_echo")
        let text = app.staticTexts["mcp.approval.arguments"].label
        let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]
        XCTAssertEqual(object, ["text": "hello"])
        XCTAssertTrue(app.buttons["mcp.approval.approve"].isHittable)
        XCTAssertTrue(app.buttons["mcp.approval.decline"].isHittable)
    }
    private func assertAnswer(_ text: String) {
        let answer = app.staticTexts["chat.message.1.assistant"]
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        XCTAssertEqual(answer.label, text)
        XCTAssertFalse(app.staticTexts["chat.error"].exists)
    }
    private func tap(_ id: String) {
        let button = app.buttons[id]
        revealLearningElement(button, in: app)
        button.tap()
    }
    private func waitForStatus(_ text: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", text),
                                               object: app.staticTexts["mcp.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        let target = toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle
        XCTAssertTrue(target.isHittable)
        target.tap()
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", on ? "1" : "0"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 5), .completed)
    }
}
