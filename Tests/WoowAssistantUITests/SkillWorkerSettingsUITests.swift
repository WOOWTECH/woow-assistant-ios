import XCTest

final class SkillWorkerSettingsUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 240 }
    override func tearDownWithError() throws { app.terminate() }

    func testDedicatedWorkerSettingsPersistWithoutSelectingOrReadingAFile() {
        launch()
        openSettings()
        let endpoint = app.textFields["skillWorker.endpoint"]
        XCTAssertTrue(endpoint.waitForExistence(timeout: 10))
        endpoint.tap(); endpoint.typeText("https://worker.invalid/v1/extract-pdf")
        let key = app.secureTextFields["skillWorker.token"]
        revealLearningElement(key, in: app); key.tap(); key.typeText("synthetic-worker-ui-token")
        app.buttons["skillWorker.keyboard.done"].tap()
        tap("skillWorker.save")
        revealLearningElement(app.staticTexts["skillWorker.notice"], in: app)
        XCTAssertEqual(app.staticTexts["skillWorker.notice"].label, "設定已儲存；尚未連線或上傳文件。")
        XCTAssertFalse(app.staticTexts["skillWorker.error"].exists)
        app.terminate()
        launch()
        let audit = app.staticTexts["skillExecution.uitest.audit"]
        revealLearningElement(audit, in: app)
        XCTAssertEqual(audit.label, "SKILL_EXECUTION_AUDIT selections=0 reads=0 extractionAttempts=0 results=0")
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
        openSettings()
        XCTAssertEqual(app.textFields["skillWorker.endpoint"].value as? String, "https://worker.invalid/v1/extract-pdf")
        let status = app.staticTexts["skillWorker.status"]
        revealLearningElement(status, in: app)
        XCTAssertEqual(status.label, "服務已設定；每次仍須選擇使用服務，並核准讀檔與上傳。")
        tap("skillWorker.remove")
        revealLearningElement(app.staticTexts["skillWorker.notice"], in: app)
        XCTAssertTrue(app.staticTexts["skillWorker.notice"].label == "已移除腳本服務設定與金鑰。")
        app.terminate(); launch(); openSettings()
        revealLearningElement(app.staticTexts["skillWorker.status"], in: app)
        XCTAssertEqual(app.staticTexts["skillWorker.status"].label, "目前使用裝置上的 PDFKit。")
        XCTAssertFalse(app.staticTexts["skillWorker.error"].exists)
    }

    private func launch() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
                               "-UITestSkillExecution", "-UITestNamespace", namespace]
        app.launch()
        tapFixed("navigation.memory")
        // The segment is a fixed header above Form. The Form scrolling helper
        // intentionally rejects that geometry (2055c30 SE and large evidence).
        tapFixed("memory.segment.skills")
        XCTAssertEqual(app.buttons["memory.segment.skills"].value as? String, "已選取")
        tap("skills.documents.execute")
        XCTAssertTrue(app.buttons["skillExecutionSelectPDF"].waitForExistence(timeout: 10))
    }
    private func openSettings() { tapFixed("skillExecution.workerSettings") }
    private func tapFixed(_ identifier: String) {
        let button = app.buttons[identifier]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        button.tap()
    }
    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        revealLearningElement(button, in: app); button.tap()
    }
}
