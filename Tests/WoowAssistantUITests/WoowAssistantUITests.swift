import XCTest

// These tests always use the DEBUG fixture, never provider credentials or the network.
final class WoowAssistantUITests: XCTestCase {
    private let sections = ["chat", "browser", "tools", "memory", "settings"]
    private let namespace = UUID().uuidString
    private let fixtureURL = "https://model.example.invalid/v1"
    private var capturedSections = Set<String>()

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
        capturedSections.removeAll()
    }

    override func tearDownWithError() throws {
        if let testRun = testRun, testRun.failureCount > 0 {
            attachScreenshot("failure", in: XCUIApplication())
        }
        XCUIApplication().terminate()
    }

    func testEverySectionIsReachableAndPhoneControlIsExcluded() {
        let app = launchApp()
        let excluded = NSPredicate(format: "label MATCHES[c] %@", ".*(手機操作|手機控制|App 操作|螢幕錄影|無障礙控制|ADB|USB helper).*")
        for section in sections {
            openSection(section, in: app)
            XCTAssertEqual(app.buttons["navigation.\(section)"].value as? String, "已選取")
            XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "navigation.")).count, 5)
            XCTAssertEqual(app.descendants(matching: .any).matching(excluded).count, 0)
        }
        openSection("chat", in: app)
    }

    func testUnconfiguredSendIsDisabledAndDraftSurvivesNavigation() {
        let app = launchApp()
        XCTAssertEqual(app.staticTexts["chat.status"].label, "尚未設定模型")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        let draft = app.textFields["chat.draft"]
        waitUntilHittable(draft)
        draft.tap()
        draft.typeText("Keep this draft 42")
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        // First navigation deliberately leaves the keyboard visible.
        openSection("browser", in: app)
        openSection("settings", in: app)
        openSection("chat", in: app)
        assertDraft("Keep this draft 42", in: app)
        draft.tap()
        draft.typeText("\n")
        assertDraft("Keep this draft 42", in: app)
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        attachScreenshot("unconfigured-draft-retained", in: app)
    }

    func testBrowserReportsCurrentLimitationsAndToolsIsReachable() {
        let app = launchApp()
        openSection("browser", in: app)
        XCTAssertEqual(app.staticTexts["browser.status"].label, "輸入網址開始瀏覽")
        XCTAssertTrue(app.textFields["browser.address"].exists)
        XCTAssertTrue(app.buttons["browser.open"].isEnabled)
        XCTAssertFalse(app.buttons["browser.research"].isEnabled)
        XCTAssertEqual(app.staticTexts["browser.explanation"].label,
                       "可手動登入網站及選取上傳檔案；網站資料保留於此 App。模型研究與每次核准的操作各自受限。")
        XCTAssertFalse(app.staticTexts["公開 HTTPS 頁面已通過第一層安全政策"].exists)
        XCTAssertFalse(app.staticTexts["browser.answer"].exists)
        XCTAssertFalse(app.staticTexts["browser.learning"].exists)
        openSection("tools", in: app)
        XCTAssertEqual(app.buttons["navigation.tools"].value as? String, "已選取")
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "尚未設定 MCP")
        XCTAssertTrue(app.staticTexts["mcp.testIsolation"].exists)
        for _ in 0..<4 where !app.buttons["mcp.connect"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["mcp.connect"].exists)
        XCTAssertFalse(app.buttons["mcp.connect"].isEnabled)
    }

    func testHTTPSValidationThenConfiguredChatWithoutAutomaticHistoryRestore() {
        let app = launchApp()
        fillConfiguration(in: app, baseURL: "http://model.example.invalid/v1")
        save(in: app)
        XCTAssertTrue(app.staticTexts["settings.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.error"].label.contains("HTTPS"))
        XCTAssertEqual(app.staticTexts["settings.keyStatus"].label, "尚未儲存金鑰。")
        replaceBaseURL(fixtureURL, in: app)
        save(in: app)
        assertSaved(in: app)
        openSection("chat", in: app)
        send("Hello fixture 17", in: app)
        assertReply("測試回覆：Hello fixture 17", in: app)
        XCTAssertTrue(app.staticTexts["chat.historyNotice"].label.contains("加密保存在此裝置"))
        assertDraft("", in: app)
        attachScreenshot("fixture-reply", in: app)

        app.terminate()
        let relaunched = launchApp(resetStorage: false)
        XCTAssertEqual(relaunched.staticTexts["chat.status"].label, "模型已設定")
        XCTAssertFalse(relaunched.staticTexts["chat.message.1.assistant"].exists)
        assertDraft("", in: relaunched)
    }

    func testStoredKeyCanBeReusedButNotForDifferentHost() {
        let app = launchApp()
        configure(in: app)
        // An empty SecureField reuses the existing Keychain item.
        save(in: app)
        assertSaved(in: app)
        replaceBaseURL("https://other.example.invalid/v1", in: app)
        save(in: app)
        XCTAssertTrue(app.staticTexts["settings.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.error"].label.contains("重新輸入"))
        app.terminate()
        let relaunched = launchApp(resetStorage: false)
        openSection("settings", in: relaunched)
        XCTAssertEqual(relaunched.textFields["settings.baseURL"].value as? String, fixtureURL)
        XCTAssertTrue(relaunched.staticTexts["settings.keyStatus"].label.contains("已儲存金鑰"))
    }

    func testCancellationPreservesDraftAndAllowsAnotherAttempt() {
        let app = launchApp()
        configure(in: app)
        openSection("chat", in: app)
        send("[fixture:wait]", in: app)
        let cancel = app.buttons["chat.cancel"]
        waitUntilHittable(cancel)
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        cancel.tap()
        XCTAssertTrue(app.staticTexts["chat.notice"].waitForExistence(timeout: 5))
        assertDraft("[fixture:wait]", in: app)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        XCTAssertTrue(app.textFields["chat.draft"].isEnabled)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        attachScreenshot("cancel-draft-retained", in: app)
    }

    func testFailureRetainsDraftAndRetryProducesReply() {
        let app = launchApp()
        configure(in: app)
        openSection("chat", in: app)
        send("[fixture:error-once]", in: app)
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 5))
        assertDraft("[fixture:error-once]", in: app)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        attachScreenshot("error-draft-retained", in: app)
        app.buttons["chat.send"].tap()
        assertReply("測試回覆：[fixture:error-once]", in: app)
        XCTAssertFalse(app.staticTexts["chat.error"].exists)
        assertDraft("", in: app)
    }

    func testKeychainWriteFailureDoesNotPublishConfiguration() {
        let app = launchApp(keychainWriteFails: true)
        fillConfiguration(in: app)
        save(in: app)
        XCTAssertTrue(app.staticTexts["settings.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.error"].label.contains("Keychain"))
        app.terminate()
        let relaunched = launchApp(resetStorage: false)
        XCTAssertEqual(relaunched.staticTexts["chat.status"].label, "尚未設定模型")
        XCTAssertFalse(relaunched.buttons["chat.send"].isEnabled)
    }

    func testRemovingConfigurationKeepsDraftAndDisablesSending() {
        let app = launchApp()
        enter("Draft after key removal", into: app.textFields["chat.draft"])
        configure(in: app)
        let remove = app.buttons["settings.remove"]
        revealSettings(remove, in: app)
        remove.tap()
        XCTAssertTrue(app.staticTexts["settings.notice"].label.contains("已移除"))
        openSection("chat", in: app)
        assertDraft("Draft after key removal", in: app)
        XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        app.terminate()
        let relaunched = launchApp(resetStorage: false)
        XCTAssertEqual(relaunched.staticTexts["chat.status"].label, "尚未設定模型")
    }

    func testMCPEndpointValidationAndKeychainPersistenceWithoutNetworking() {
        let app = launchApp()
        openSection("tools", in: app)
        let endpoint = app.secureTextFields["mcp.endpoint"]
        revealMCP(endpoint, in: app)
        enter("http://mcp.example.invalid/private", into: endpoint)
        revealMCP(app.buttons["mcp.save"], in: app)
        app.buttons["mcp.save"].tap()
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "尚未設定 MCP")
        revealMCP(app.staticTexts["mcp.error"], in: app)
        XCTAssertTrue(app.staticTexts["mcp.error"].label.contains("HTTPS"))
        revealMCP(app.buttons["mcp.clearDraft"], in: app, upward: false)
        app.buttons["mcp.clearDraft"].tap()
        revealMCP(endpoint, in: app, upward: false)
        enter("https://mcp.example.invalid/fixture-private", into: endpoint)
        revealMCP(app.buttons["mcp.save"], in: app)
        app.buttons["mcp.save"].tap()
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "端點已儲存，尚未驗證連線")
        XCTAssertFalse(app.buttons["mcp.clearDraft"].isEnabled)
        app.terminate()
        let relaunched = launchApp(resetStorage: false)
        openSection("tools", in: relaunched)
        XCTAssertEqual(relaunched.staticTexts["mcp.status"].label, "端點已儲存，尚未驗證連線")
        XCTAssertTrue(relaunched.staticTexts["mcp.testIsolation"].exists)
        revealMCP(relaunched.buttons["mcp.connect"], in: relaunched)
        XCTAssertFalse(relaunched.buttons["mcp.connect"].isEnabled)
    }

    func testMCPKeychainWriteFailureIsNotReportedAsSaved() {
        let app = launchApp(keychainWriteFails: true)
        openSection("tools", in: app)
        let endpoint = app.secureTextFields["mcp.endpoint"]
        revealMCP(endpoint, in: app)
        enter("https://mcp.example.invalid/fixture-private", into: endpoint)
        revealMCP(app.buttons["mcp.save"], in: app)
        app.buttons["mcp.save"].tap()
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "尚未設定 MCP")
        revealMCP(app.staticTexts["mcp.error"], in: app)
        XCTAssertTrue(app.staticTexts["mcp.error"].label.contains("Keychain"))
    }

    func testMCPRemovalClearsOnlyItsSavedEndpoint() {
        let app = launchApp()
        configure(in: app)
        openSection("tools", in: app)
        let endpoint = app.secureTextFields["mcp.endpoint"]
        revealMCP(endpoint, in: app)
        enter("https://mcp.example.invalid/fixture-private", into: endpoint)
        revealMCP(app.buttons["mcp.save"], in: app)
        app.buttons["mcp.save"].tap()
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "端點已儲存，尚未驗證連線")
        revealMCP(app.buttons["mcp.remove"], in: app)
        app.buttons["mcp.remove"].tap()
        // iOS 26 exposes the confirmation row before its nested action button.
        // firstMatch can tap the wrapper; use the last exact identifier/label
        // match (the single action on older iOS), without coordinate taps.
        let confirmations = app.buttons.matching(identifier: "mcp.confirmRemove")
            .matching(NSPredicate(format: "label == %@", "移除端點"))
        XCTAssertTrue(confirmations.firstMatch.waitForExistence(timeout: 5))
        guard let confirm = confirmations.allElementsBoundByIndex.last else {
            XCTFail("The MCP endpoint removal confirmation is missing.")
            return
        }
        waitUntilHittable(confirm)
        confirm.tap()
        let status = app.staticTexts["mcp.status"]
        let removed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "尚未設定 MCP"),
            object: status
        )
        XCTAssertEqual(XCTWaiter.wait(for: [removed], timeout: 5), .completed)
        XCTAssertEqual(status.label, "尚未設定 MCP")
        app.terminate()
        let relaunched = launchApp(resetStorage: false)
        XCTAssertEqual(relaunched.staticTexts["chat.status"].label, "模型已設定")
        openSection("tools", in: relaunched)
        XCTAssertEqual(relaunched.staticTexts["mcp.status"].label, "尚未設定 MCP")
    }

    private func revealMCP(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<5 where !element.isHittable {
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        waitUntilHittable(element)
    }

    private func launchApp(resetStorage: Bool = true, keychainWriteFails: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode", "-UITestNamespace", namespace]
        if resetStorage { app.launchArguments.append("-UITestResetStorage") }
        if keychainWriteFails { app.launchArguments.append("-UITestKeychainWriteFailure") }
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["uitest.banner"].exists)
        attachScreenshot("launch", in: app)
        return app
    }

    private func fillConfiguration(in app: XCUIApplication, baseURL: String? = nil) {
        openSection("settings", in: app)
        enter(baseURL ?? fixtureURL, into: app.textFields["settings.baseURL"])
        let model = app.textFields["settings.model"]
        revealSettings(model, in: app)
        enter("ui-test-model", into: model)
        let key = app.secureTextFields["settings.apiKey"]
        revealSettings(key, in: app)
        enter("fixture-only-not-a-real-key", into: key)
    }

    private func configure(in app: XCUIApplication) {
        fillConfiguration(in: app)
        save(in: app)
        assertSaved(in: app)
    }

    private func save(in app: XCUIApplication) {
        let save = app.buttons["settings.save"]
        revealSettings(save, in: app)
        save.tap()
    }

    private func assertSaved(in app: XCUIApplication) {
        XCTAssertTrue(app.staticTexts["settings.notice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["settings.notice"].label.contains("尚未驗證連線"))
        XCTAssertFalse(app.staticTexts["settings.error"].exists)
    }

    private func replaceBaseURL(_ value: String, in app: XCUIApplication) {
        let clear = app.buttons["settings.clearBaseURL"]
        revealSettings(clear, in: app, upward: false)
        clear.tap()
        enter(value, into: app.textFields["settings.baseURL"])
    }

    private func enter(_ text: String, into field: XCUIElement) {
        waitUntilHittable(field)
        field.tap()
        field.typeText(text + "\n")
    }

    private func send(_ text: String, in app: XCUIApplication) {
        enter(text, into: app.textFields["chat.draft"])
        let send = app.buttons["chat.send"]
        waitUntilHittable(send)
        XCTAssertTrue(send.isEnabled)
        send.tap()
    }

    private func assertReply(_ expected: String, in app: XCUIApplication) {
        let reply = app.staticTexts["chat.message.1.assistant"]
        XCTAssertTrue(reply.waitForExistence(timeout: 5))
        XCTAssertEqual(reply.label, expected)
    }

    private func revealSettings(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<3 where !element.isHittable {
            if upward { app.scrollViews.firstMatch.swipeUp() }
            else { app.scrollViews.firstMatch.swipeDown() }
        }
        waitUntilHittable(element)
    }

    private func openSection(_ section: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["navigation.\(section)"]
        waitUntilHittable(button, file: file, line: line)
        button.tap()
        XCTAssertTrue(app.staticTexts["\(section).status"].waitForExistence(timeout: 5), file: file, line: line)
        if capturedSections.insert(section).inserted { attachScreenshot("section-\(section)", in: app) }
    }

    private func attachScreenshot(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func waitUntilHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file, line: line)
    }

    private func assertDraft(_ expected: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["chat.draft"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        let expectedValue = expected.isEmpty ? "輸入訊息" : expected
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@ OR value == %@", expected, expectedValue), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed, file: file, line: line)
    }
}
