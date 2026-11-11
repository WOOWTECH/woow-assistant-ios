import XCTest

/// Real model + real HA server through the App. Only audited read-only calls are
/// approved. No live screenshots, trees, response bodies or xcresult uploads.
final class LiveMCPConversationUITests: XCTestCase {
    private let namespace = UUID().uuidString
    private var app = XCUIApplication()
    private var launched = false
    private var initialLaunchCompleted = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
        let environment = ProcessInfo.processInfo.environment
        for key in ["WOOW_LIVE_API_KEY", "WOOW_LIVE_MODEL", "WOOW_LIVE_BASE_URL", "WOOW_LIVE_MCP_URL"] {
            guard environment[key]?.isEmpty == false else {
                throw XCTSkip("Combined private model/MCP configuration was not supplied.")
            }
        }
        try LiveMCPNativeLifecycle.stopAndShowHome(app)
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveMCPConversationUITest"]
        app.launchEnvironment = Dictionary(uniqueKeysWithValues:
            ["WOOW_LIVE_API_KEY", "WOOW_LIVE_MODEL", "WOOW_LIVE_BASE_URL", "WOOW_LIVE_MCP_URL"].map { ($0, environment[$0]!) })
        launched = true
        app.launch()
        try LiveMCPNativeLifecycle.requireForeground(app)
        initialLaunchCompleted = true
        navigate("tools")
        revealLearningElement(app.buttons["mcp.connect"], in: app)
        app.buttons["mcp.connect"].tap()
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            self.app.staticTexts["mcp.status"].label == "已連線，目錄擷取完成" || self.app.staticTexts["mcp.error"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 95), .completed)
        XCTAssertFalse(app.staticTexts["mcp.error"].exists, "Actual MCP discovery failed.")
        selectTool("ha_eval_template")
        if name.contains("testRealModelUsesRemoteToolThenReviewedLocalMemoryAndUndo") {
            let count = app.staticTexts["mcp.selectionCount"]
            revealLearningElement(count, in: app, visibility: .readableText)
            XCTAssertTrue(count.label == "已選取 1 個工具供對話使用")
        } else {
            selectTool("ha_list_floors_areas")
        }
        navigate("chat")
        let toggle = app.switches["chat.useMCP"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        setSwitch(toggle)
    }

    override func tearDownWithError() throws {
        guard launched else { return }
        try LiveMCPNativeLifecycle.stopAndShowHome(app)
        // Run 42816449809: initial launch was denied during install/uninstall;
        // launching cleanup immediately caused a second launch failure. Keep
        // the original failure and require the workflow's isolated simulator
        // removal; never report this namespace as successfully cleaned.
        guard initialLaunchCompleted else {
            XCTFail("LIVE_MCP_CLEANUP initial launch did not complete; namespace cleanup is unverified and isolated simulator removal is required.")
            return
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveModelUITestCleanup"]
        app.launchEnvironment = [:]
        app.launch()
        try LiveMCPNativeLifecycle.requireForeground(app)
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.status"].label == "尚未設定模型", "Private model cleanup failed.")
        navigate("tools")
        XCTAssertTrue(app.staticTexts["mcp.status"].label == "尚未設定 MCP", "Private MCP cleanup failed.")
        try LiveMCPNativeLifecycle.stopAndShowHome(app)
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

    func testRealModelUsesRemoteToolThenReviewedLocalMemoryAndUndo() throws {
        let sentence = "Prefer jasmine tea"
        // Same instruction as the successful actual MCP/App harness. Native UI
        // must deliver the prompt and approve each proposal; no seeded draft.
        let prompt = #"First call ha_eval_template exactly once with only {"template":"{{7*6}}"}. Wait for its actual successful result to equal 42. Then use local memory_save with kind preference, content and quote exactly "Prefer jasmine tea", and keywords ["jasmine","tea"]. I will review both the remote call and the local write separately. Only after the committed local receipt, finish with exactly MCP_MEMORY_OK_42. Do not search, edit my profile, read resources, or call any other tool."#
        let remoteName = app.staticTexts["mcp.approval.name"].firstMatch
        let memoryReview = app.staticTexts["memoryTool.operation"].firstMatch
        let profileReview = app.staticTexts["profileTool.operation"].firstMatch
        let error = app.staticTexts["chat.error"].firstMatch
        let answer = app.staticTexts["chat.message.1.assistant"].firstMatch

        func ready(_ element: XCUIElement) {
            let predicate = NSPredicate(format: "exists == true AND hittable == true AND enabled == true")
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5), .completed)
        }
        func tap(_ identifier: String) {
            let button = app.buttons.matching(identifier: identifier).firstMatch
            ready(button); button.tap()
        }
        func fixedChatVisible(_ element: XCUIElement) -> Bool {
            guard element.exists else { return false }
            var viewport = app.frame
            let bar = app.navigationBars.firstMatch
            if bar.exists, !bar.frame.isEmpty {
                let top = max(viewport.minY, bar.frame.maxY)
                viewport = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, viewport.maxY - top))
            }
            let navigation = app.buttons["navigation.chat"].firstMatch
            if navigation.exists { viewport.size.height = max(0, min(viewport.maxY, navigation.frame.minY) - viewport.minY) }
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { viewport.size.height = max(0, min(viewport.maxY, keyboard.frame.minY) - viewport.minY) }
            return learningFrameIsVisible(element.frame, in: viewport, visibility: .fullyVisible)
        }
        func readable(_ identifier: String, equals expected: String) {
            let label = app.staticTexts[identifier].firstMatch
            if ["chat.memoryReceipt", "chat.memoryNote.0"].contains(identifier) {
                // f737665: these are fixed Chat siblings ABOVE the messages
                // ScrollView. Scrolling messages cannot reveal either label.
                // Require their whole actual frames in the native viewport.
                let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixedChatVisible(label) }, object: nil)
                XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
            } else {
                revealLearningElement(label, in: app, visibility: .readableText)
            }
            XCTAssertTrue(label.label == expected, "The native label must match the explicit synthetic request.")
        }
        func segment(_ name: String) {
            let button = app.buttons["memory.segment.\(name)"].firstMatch
            ready(button)
            if button.value as? String != "已選取" { button.tap() }
            let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已選取"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 5), .completed)
        }
        func openMemory() {
            navigate("memory")
            XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["memory.unavailable"].firstMatch.exists)
            XCTAssertFalse(app.staticTexts["memory.error"].firstMatch.exists)
            segment("memories")
            let search = app.textFields["memory.search"].firstMatch
            XCTAssertTrue(search.waitForExistence(timeout: 5))
            let value = search.value as? String ?? ""
            XCTAssertTrue(value.isEmpty || value == "搜尋記憶或關鍵字", "Check absence in the unfiltered memory list.")
        }
        func emptyMemories() {
            readable("memory.empty", equals: "尚未儲存記憶。")
            XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.item.")).firstMatch.exists)
        }
        func diagnosticCount(_ key: String, in raw: String) -> Int? {
            let prefix = key + "="
            let matches = raw.split(separator: ";").filter { $0.hasPrefix(prefix) }
            guard matches.count == 1, let count = Int(matches[0].dropFirst(prefix.count)), (0...64).contains(count) else { return nil }
            return count
        }
        func fixedPhase(_ phase: String) -> String {
            let activity = app.staticTexts["chat.mcpActivity"].firstMatch
            let raw = activity.exists ? (activity.value as? String ?? "") : ""
            // A sheet may hide the underlying activity label. -1 means not
            // observed, never zero. Do not print the raw diagnostic or labels.
            print("Live MCP memory phase=\(phase);modelCalls=\(diagnosticCount("modelCalls", in: raw) ?? -1);corrections=\(diagnosticCount("formatCorrections", in: raw) ?? -1);attempts=\(diagnosticCount("attempts", in: raw) ?? -1);results=\(diagnosticCount("results", in: raw) ?? -1);toolErrors=\(diagnosticCount("toolErrors", in: raw) ?? -1);remoteReview=\(remoteName.exists);memoryReview=\(memoryReview.exists);profileReview=\(profileReview.exists);error=\(error.exists);answer=\(answer.exists)")
            return raw
        }
        func nextStage(_ phase: String) {
            let pending = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                remoteName.exists || memoryReview.exists || profileReview.exists || error.exists || answer.exists
            }, object: nil)
            let result = XCTWaiter.wait(for: [pending], timeout: 95)
            _ = fixedPhase(phase)
            XCTAssertEqual(result, .completed)
        }

        // Isolate explicit memory_save from optional after-reply extraction via
        // the actual user preference control, not a launch flag or stored seed.
        openMemory(); emptyMemories()
        let automatic = app.switches["memory.toggle.autoRemember"].firstMatch
        revealLearningElement(automatic, in: app)
        ready(automatic)
        XCTAssertTrue(["0", "1"].contains(automatic.value as? String ?? ""))
        if automatic.value as? String != "0" {
            let target = automatic.switches.firstMatch.exists ? automatic.switches.firstMatch : automatic
            ready(target); target.tap()
        }
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: automatic)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        navigate("chat")
        XCTAssertTrue(app.switches["chat.useMCP"].value as? String == "1")
        XCTAssertFalse(app.staticTexts["uitest.banner"].firstMatch.exists)
        send(prompt)

        nextStage("remote_proposal")
        guard remoteName.exists, remoteName.label == "ha_eval_template",
              !memoryReview.exists, !profileReview.exists, !error.exists, !answer.exists else {
            XCTFail("The first native review must be the selected arithmetic tool; no action was approved.")
            return
        }
        readable("mcp.approval.name", equals: "ha_eval_template")
        let argumentsLabel = app.staticTexts["mcp.approval.arguments"].firstMatch
        revealLearningElement(argumentsLabel, in: app, visibility: .readableText)
        let argumentsData = Data(argumentsLabel.label.utf8)
        guard argumentsData.count <= 4096,
              let object = try? JSONSerialization.jsonObject(with: argumentsData),
              let arguments = object as? [String: Any], Set(arguments.keys) == ["template"],
              arguments["template"] as? String == "{{7*6}}" else {
            XCTFail("Only the exact arithmetic template arguments may be approved.")
            return
        }
        tap("mcp.approval.approve")
        let remoteClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: remoteName)
        XCTAssertEqual(XCTWaiter.wait(for: [remoteClosed], timeout: 5), .completed)

        nextStage("memory_review")
        guard memoryReview.exists, !remoteName.exists, !profileReview.exists, !error.exists, !answer.exists else {
            XCTFail("An actual local memory_save review must follow the single remote call.")
            return
        }
        readable("memoryTool.operation", equals: "新增")
        readable("memoryTool.kind", equals: "偏好")
        readable("memoryTool.quote", equals: sentence)
        readable("memoryTool.after", equals: sentence)
        readable("memoryTool.keywords", equals: "jasmine、tea")
        XCTAssertFalse(app.staticTexts["memoryTool.before"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["memoryTool.pendingNotice"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.0"].firstMatch.exists)
        tap("memoryTool.approve")
        let reviewClosed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: memoryReview)
        XCTAssertEqual(XCTWaiter.wait(for: [reviewClosed], timeout: 5), .completed)

        nextStage("completion")
        XCTAssertFalse(remoteName.exists)
        XCTAssertFalse(memoryReview.exists)
        XCTAssertFalse(profileReview.exists)
        XCTAssertFalse(error.exists, "A committed receipt does not replace the required model finish.")
        XCTAssertTrue(answer.exists && answer.label == "MCP_MEMORY_OK_42")
        let diagnostics = fixedPhase("completed")
        XCTAssertTrue(diagnostics.hasPrefix("phase=finished;"))
        XCTAssertTrue(diagnostics.hasSuffix(";attempts=1;results=1;toolErrors=0;failure=none"),
                      "One actual remote result is required; local memory must not count as a remote step.")
        let corrections = diagnosticCount("formatCorrections", in: diagnostics)
        let calls = diagnosticCount("modelCalls", in: diagnostics)
        XCTAssertTrue(corrections == 0 || corrections == 1)
        XCTAssertTrue(calls != nil && calls == 3 + (corrections ?? -100),
                      "Require remote call, local save and finish, with only the runtime's bounded format correction.")
        readable("chat.memoryReceipt", equals: "本次對話曾儲存記憶修改；可在資料頁查看目前內容。")
        readable("chat.memoryNote.0", equals: "記住了：" + sentence)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.1"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.learningError"].firstMatch.exists)

        openMemory()
        let saved = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                                         "memory.item.", sentence)).firstMatch
        revealLearningElement(saved, in: app, visibility: .readableText)
        XCTAssertTrue(saved.label == sentence && saved.identifier.hasPrefix("memory.item."))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.item.")).count == 1)
        navigate("chat")
        let undo = app.buttons["chat.undoMemory.0"].firstMatch
        let undoVisible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in fixedChatVisible(undo) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [undoVisible], timeout: 5), .completed)
        tap("chat.undoMemory.0")
        let note = app.staticTexts["chat.memoryNote.0"].firstMatch
        let undone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [undone], timeout: 5), .completed)
        XCTAssertFalse(undo.exists)
        XCTAssertFalse(app.staticTexts["chat.learningError"].firstMatch.exists)
        openMemory(); emptyMemories()

        // Reuse this test's exact namespace/configuration. No reset, bootstrap
        // seed, second tool request or retry; teardown still owns key cleanup.
        try LiveMCPNativeLifecycle.stopAndShowHome(app)
        app.launch()
        try LiveMCPNativeLifecycle.requireForeground(app)
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.status"].label == "模型已設定")
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryNote.0"].firstMatch.exists)
        openMemory(); emptyMemories()
        let activeEmpty = app.staticTexts["memory.empty"].firstMatch.label == "尚未儲存記憶。"
        segment("pending")
        readable("memory.pending.empty", equals: "沒有待確認的內容。")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.item.")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["uitest.banner"].firstMatch.exists)
        print("Live MCP memory phase=relaunch;activeEmpty=\(activeEmpty);pendingEmpty=\(app.staticTexts["memory.pending.empty"].label == "沒有待確認的內容。")")
        // No screenshots, AX dumps, raw replies, tool results or private fields.
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
