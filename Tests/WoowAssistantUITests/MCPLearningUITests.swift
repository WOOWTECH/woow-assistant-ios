import XCTest

/// Synthetic in-process MCP/model fixtures through native approvals and the
/// encrypted learning store. Neither fixture can approve or persist a proposal.
final class MCPLearningUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private let memoryReceipt = "本次對話曾儲存記憶修改；可在資料頁查看目前內容。"
    private let profileReceipt = "本次對話曾儲存個人檔案；可到資料頁查看目前內容。"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            // Only isolated synthetic fixtures; never use these attachments for
            // live MCP/model credentials or a personal learning store.
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "mcp-learning-fixture-failure-AX"
            tree.lifetime = .keepAlways; add(tree)
            let screen = XCTAttachment(screenshot: app.screenshot())
            screen.name = "mcp-learning-fixture-failure-screen"
            screen.lifetime = .keepAlways; add(screen)
        }
        app.terminate()
    }

    func testRemoteThenMemoryApprovalFinishesAndUndoRemainsAbsentAfterRelaunch() {
        launch(); connectFixture()
        let prompt = "[fixture:mcp-memory] Remember preference Prefer jasmine tea"
        send(prompt)
        assertRemoteReview()
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.0"].firstMatch.exists)
        tap("mcp.approval.approve")
        absent(app.buttons["mcp.approval.approve"].firstMatch)
        assertMemoryReview(quote: prompt, content: "Prefer jasmine tea", keywords: "jasmine、tea")
        tap("memoryTool.approve")
        absent(app.buttons["memoryTool.approve"].firstMatch)
        assertLabel(app.staticTexts["chat.message.1.assistant"].firstMatch, "MCP 記憶流程已完成。")
        assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定")
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        assertLabel(app.staticTexts["chat.memoryReceipt"].firstMatch, memoryReceipt)
        assertLabel(app.staticTexts["chat.memoryNote.0"].firstMatch, "記住了：Prefer jasmine tea")
        XCTAssertFalse(app.staticTexts["chat.memoryNote.1"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        assertActivity(attempts: 1, results: 1, modelCalls: 3, failure: "none")
        let draft = app.textFields["chat.draft"].firstMatch.value as? String ?? ""
        XCTAssertTrue(draft.isEmpty || draft == "輸入訊息")
        tap("chat.mcpResults")
        let result = app.staticTexts["mcp.result.0"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        revealLearningElement(result, in: app, visibility: .readableText)
        let object = try? JSONSerialization.jsonObject(with: Data(result.label.utf8)) as? [String: Any]
        XCTAssertEqual(object?["isError"] as? Bool, false)
        let content = object?["content"] as? [[String: String]]
        XCTAssertEqual(content, [["type": "text", "text": "FIXTURE_CALL_1: hello"]])
        XCTAssertFalse(app.staticTexts["mcp.result.1"].firstMatch.exists)
        let close = app.buttons["mcp.results.close"].firstMatch
        ready(close); XCTAssertEqual(close.label, "關閉")
        close.tap(); absent(result)

        openMemory(); assertSingleMemory("Prefer jasmine tea")
        navigate("chat")
        tap("chat.undoMemory.0")
        absent(app.staticTexts["chat.memoryNote.0"].firstMatch)
        XCTAssertFalse(app.buttons["chat.undoMemory.0"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.learningError"].firstMatch.exists)
        assertLabel(app.staticTexts["chat.memoryReceipt"].firstMatch, memoryReceipt)
        openMemory(); assertEmptyMemories()
        launch(reset: false); openMemory(); assertEmptyMemories()
        selectSegment("pending"); assertEmptyPending()
    }

    func testProfileApprovalSurvivesRemoteDeclineAndRelaunch() {
        launch(); connectFixture()
        let prompt = "[fixture:mcp-profile] Please remember Prefer jasmine tea"
        send(prompt)
        let operation = app.staticTexts["profileTool.operation"].firstMatch
        XCTAssertTrue(operation.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        assertReadable(operation, equals: "新增")
        assertReadable(app.staticTexts["profileTool.quote"].firstMatch, equals: prompt)
        assertReadable(app.staticTexts["profileTool.after"].firstMatch, equals: "Prefer jasmine tea")
        XCTAssertFalse(app.staticTexts["profileTool.before"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        XCTAssertFalse(app.buttons["mcp.approval.approve"].firstMatch.exists)
        ready(app.buttons["profileTool.decline"].firstMatch)
        tap("profileTool.approve")
        absent(app.buttons["profileTool.approve"].firstMatch)
        assertRemoteReview()
        tap("mcp.approval.decline")
        absent(app.buttons["mcp.approval.decline"].firstMatch)
        assertLabel(app.staticTexts["chat.error"].firstMatch,
                    "個人檔案已儲存，但後續模型回覆未完成；請先查看已保存內容，避免重複修改。草稿保留。")
        assertLabel(app.staticTexts["chat.profileReceipt"].firstMatch, profileReceipt)
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, prompt)
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.0"].firstMatch.exists)
        XCTAssertFalse(app.buttons["chat.mcpResults"].firstMatch.exists)
        assertActivity(attempts: 0, results: 0, modelCalls: 2, failure: "approvalDenied")
        ready(app.buttons["chat.send"].firstMatch)
        openProfile(); assertSingleProfile("Prefer jasmine tea")
        let savedID = profileItem("Prefer jasmine tea").identifier
        tap("profile.close"); absent(app.buttons["profile.close"].firstMatch)
        navigate("chat")
        assertLabel(app.staticTexts["chat.profileReceipt"].firstMatch, profileReceipt)
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, prompt)
        launch(reset: false); openProfile(); assertSingleProfile("Prefer jasmine tea")
        XCTAssertEqual(profileItem("Prefer jasmine tea").identifier, savedID,
                       "Relaunch must load the approved entry with its original identity.")
    }

    func testDeclinedLocalMemoryPreservesDraftWithoutDataOrRemoteAttempt() {
        launch(); connectFixture()
        let prompt = "[fixture:mcp-memory-decline] Remember preference Prefer quiet"
        send(prompt)
        assertMemoryReview(quote: prompt, content: "Prefer quiet", keywords: "quiet")
        XCTAssertFalse(app.buttons["mcp.approval.approve"].firstMatch.exists)
        tap("memoryTool.decline")
        absent(app.buttons["memoryTool.decline"].firstMatch)
        assertLabel(app.staticTexts["chat.error"].firstMatch,
                    "你已拒絕這次呼叫，MCP 對話已停止；草稿與先前工具結果保留。")
        assertActivity(attempts: 0, results: 0, modelCalls: 1, failure: "approvalDenied")
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, prompt)
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.0"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
        XCTAssertFalse(app.buttons["chat.mcpResults"].firstMatch.exists)
        ready(app.buttons["chat.send"].firstMatch)
        openMemory(); assertEmptyMemories()
        selectSegment("pending"); assertEmptyPending()
        navigate("chat")
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, prompt)
        assertActivity(attempts: 0, results: 0, modelCalls: 1, failure: "approvalDenied")
        launch(reset: false); openMemory(); assertEmptyMemories()
        selectSegment("pending"); assertEmptyPending()
        selectSegment("memories")
        tap("memory.profile.open", scroll: true)
        assertReadable(app.staticTexts["profile.count"].firstMatch, equals: "現用 0／20 條")
        assertReadable(app.staticTexts["profile.empty"].firstMatch, equals: "尚未儲存個人檔案。")
        XCTAssertFalse(profileItems.firstMatch.exists)
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["profile.unavailable"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["profile.error"].firstMatch.exists)
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace, "-UITestMCPFixture"]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["uitest.banner"].firstMatch.exists)
        assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定")
    }

    private func connectFixture() {
        navigate("tools")
        tap("mcp.connect", scroll: true)
        assertLabel(app.staticTexts["mcp.status"].firstMatch, "已連線，目錄擷取完成")
        XCTAssertFalse(app.staticTexts["mcp.error"].firstMatch.exists)
        let enabled = app.switches["mcp.enable.fixture_echo"].firstMatch
        revealLearningElement(enabled, in: app)
        setSwitch(enabled, on: true)
        navigate("chat")
        setSwitch(app.switches["chat.useMCP"].firstMatch, on: true)
    }

    private func send(_ prompt: String) {
        let draft = app.textFields["chat.draft"].firstMatch
        writeASCII(prompt, into: draft)
        // Explicit native Done; newline is not a substitute for committing and
        // dismissing the keyboard before the Send button is hit-tested.
        tap("chat.dismissKeyboard")
        absent(app.keyboards.firstMatch)
        XCTAssertEqual(draft.value as? String, prompt)
        tap("chat.send")
    }

    private func assertRemoteReview() {
        let name = app.staticTexts["mcp.approval.name"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 15))
        assertReadable(name, equals: "fixture_echo")
        let arguments = app.staticTexts["mcp.approval.arguments"].firstMatch
        revealLearningElement(arguments, in: app, visibility: .readableText)
        let object = try? JSONSerialization.jsonObject(with: Data(arguments.label.utf8)) as? [String: String]
        XCTAssertEqual(object, ["text": "hello"])
        ready(app.buttons["mcp.approval.approve"].firstMatch)
        ready(app.buttons["mcp.approval.decline"].firstMatch)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
    }

    private func assertMemoryReview(quote: String, content: String, keywords: String) {
        let operation = app.staticTexts["memoryTool.operation"].firstMatch
        XCTAssertTrue(operation.waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        assertReadable(operation, equals: "新增")
        assertReadable(app.staticTexts["memoryTool.kind"].firstMatch, equals: "偏好")
        assertReadable(app.staticTexts["memoryTool.quote"].firstMatch, equals: quote)
        assertReadable(app.staticTexts["memoryTool.after"].firstMatch, equals: content)
        assertReadable(app.staticTexts["memoryTool.keywords"].firstMatch, equals: keywords)
        XCTAssertFalse(app.staticTexts["memoryTool.before"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["memoryTool.pendingNotice"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.0"].firstMatch.exists)
        ready(app.buttons["memoryTool.approve"].firstMatch)
        ready(app.buttons["memoryTool.decline"].firstMatch)
    }

    private func assertActivity(attempts: Int, results: Int, modelCalls: Int, failure: String) {
        let activity = app.staticTexts["chat.mcpActivity"].firstMatch
        assertLabel(activity, "MCP 嘗試呼叫 \(attempts) 次；已收到 \(results) 次結果；工具錯誤 0 次。")
        let raw = activity.value as? String ?? ""
        var fields: [String: String] = [:]
        for field in raw.split(separator: ";") {
            let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            XCTAssertEqual(pair.count, 2, "The fixed counter diagnostic must be well formed.")
            guard pair.count == 2 else { return }
            let key = String(pair[0])
            XCTAssertNil(fields[key], "Duplicate diagnostic fields cannot establish counters.")
            fields[key] = String(pair[1])
        }
        XCTAssertEqual(fields["attempts"], String(attempts))
        XCTAssertEqual(fields["results"], String(results))
        XCTAssertEqual(fields["toolErrors"], "0")
        XCTAssertEqual(fields["modelCalls"], String(modelCalls))
        XCTAssertEqual(fields["formatCorrections"], "0")
        XCTAssertEqual(fields["failure"], failure)
    }

    private func openMemory() {
        navigate("memory")
        XCTAssertFalse(app.staticTexts["memory.unavailable"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["memory.error"].firstMatch.exists)
        selectSegment("memories")
        let query = app.textFields["memory.search"].firstMatch.value as? String ?? ""
        XCTAssertTrue(query.isEmpty || query == "搜尋記憶或關鍵字",
                      "Data absence requires an unfiltered list.")
    }

    private func selectSegment(_ name: String) {
        let button = app.buttons["memory.segment.\(name)"].firstMatch
        ready(button)
        if button.value as? String != "已選取" { button.tap() }
        assertValue(button, "已選取")
    }

    private var memoryItems: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.item."))
    }

    private func assertSingleMemory(_ text: String) {
        let item = memoryItems.matching(NSPredicate(format: "label == %@", text)).firstMatch
        assertReadable(item, equals: text)
        XCTAssertEqual(memoryItems.count, 1)
        XCTAssertFalse(app.staticTexts["memory.error"].firstMatch.exists)
    }

    private func assertEmptyMemories() {
        assertReadable(app.staticTexts["memory.empty"].firstMatch, equals: "尚未儲存記憶。")
        XCTAssertFalse(memoryItems.firstMatch.exists)
    }

    private func assertEmptyPending() {
        assertReadable(app.staticTexts["memory.pending.empty"].firstMatch, equals: "沒有待確認的內容。")
        XCTAssertFalse(memoryItems.firstMatch.exists)
    }

    private func openProfile() {
        openMemory()
        tap("memory.profile.open", scroll: true)
        XCTAssertTrue(app.staticTexts["profile.scope"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["profile.disabled"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["profile.unavailable"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["profile.error"].firstMatch.exists)
    }

    private var profileItems: XCUIElementQuery {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profile.item."))
    }

    private func profileItem(_ text: String) -> XCUIElement {
        profileItems.matching(NSPredicate(format: "label == %@", text)).firstMatch
    }

    private func assertSingleProfile(_ text: String) {
        assertReadable(app.staticTexts["profile.count"].firstMatch, equals: "現用 1／20 條")
        assertReadable(profileItem(text), equals: text)
        XCTAssertEqual(profileItems.count, 1)
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
    }

    private func navigate(_ section: String) {
        let button = app.buttons["navigation.\(section)"].firstMatch
        ready(button)
        XCTAssertFalse(button.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(button.frame))
        // Same verified native center selection as existing learning fixtures.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertValue(button, "已選取")
        XCTAssertTrue(app.staticTexts["\(section).status"].firstMatch.waitForExistence(timeout: 5))
    }

    private func setSwitch(_ toggle: XCUIElement, on: Bool) {
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let wanted = on ? "1" : "0"
        if toggle.value as? String != wanted {
            let nested = toggle.switches.firstMatch
            let target = nested.exists ? nested : toggle
            ready(target); target.tap()
        }
        assertValue(toggle, wanted)
    }

    private func writeASCII(_ text: String, into field: XCUIElement) {
        // The composer is a sibling below the messages ScrollView. Its full
        // native frame, not that ScrollView's viewport, governs visibility.
        ready(field)
        XCTAssertEqual(field.identifier, "chat.draft")
        let frame = field.frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(app.frame.contains(frame))
        let navigation = app.buttons["navigation.chat"].firstMatch
        ready(navigation)
        XCTAssertLessThanOrEqual(frame.maxY, navigation.frame.minY)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { XCTAssertLessThanOrEqual(frame.maxY, keyboard.frame.minY) }
        field.tap()
        prepareLatinKeyboard()
        var remaining = text[...]
        var entered = ""
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(entered.isEmpty ? 1 : 16))
            field.typeText(chunk); entered += chunk; remaining = remaining.dropFirst(chunk.count)
            let actual = field.value as? String
            XCTAssertEqual(actual, entered, "Native input must match exactly; never repair or retry lost characters.")
            guard actual == entered else { return }
        }
        XCTAssertEqual(field.value as? String, text)
    }

    private func prepareLatinKeyboard() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        dismissKeyboardIntroductionIfPresented()
        let keyboard = app.keyboards.firstMatch
        func latin() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q"])).firstMatch.exists
                && keyboard.keys.matching(NSPredicate(format: "label IN %@", ["a", "A"])).firstMatch.exists
        }
        if latin() { return }
        // The native keyboard switch is localized by iOS, even when the app's
        // own test language is fixed. iOS 26 exposes the same visible globe as
        // 「下一個鍵盤」; earlier runtimes expose it as "Next keyboard".
        let globe = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Next keyboard", "下一個鍵盤"]
        )).firstMatch
        ready(globe)
        // On iOS 17 the system globe's accessibility frame can extend a
        // fraction of a point past the bottom edge while its tappable center
        // remains on screen. Hittability is checked above.
        XCTAssertTrue(
            app.frame.contains(CGPoint(x: globe.frame.midX, y: globe.frame.midY)),
            "The native keyboard switch must be visible"
        )
        globe.press(forDuration: 1)
        let english = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "English (US)")).firstMatch
        ready(english); english.tap()
        dismissKeyboardIntroductionIfPresented()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in latin() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    private func dismissKeyboardIntroductionIfPresented() {
        let button = app.buttons["Continue"].firstMatch
        guard button.waitForExistence(timeout: 3) else { return }
        let explanation = app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].firstMatch
        XCTAssertTrue(explanation.exists, "Only the known native keyboard introduction may be dismissed.")
        ready(button); button.tap(); absent(button)
    }

    private func assertReadable(_ element: XCUIElement, equals text: String) {
        revealLearningElement(element, in: app, visibility: .readableText)
        XCTAssertEqual(element.label, text)
    }

    private func assertLabel(_ element: XCUIElement, _ text: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND label == %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    private func assertValue(_ element: XCUIElement, _ text: String) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", text), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    private func tap(_ identifier: String, scroll: Bool = false) {
        let button = app.buttons[identifier].firstMatch
        if scroll { revealLearningElement(button, in: app) }
        ready(button); button.tap()
    }

    private func ready(_ element: XCUIElement) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    private func absent(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
