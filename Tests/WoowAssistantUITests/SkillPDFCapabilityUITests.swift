import XCTest

/// Label-only native check. Does not select/read a PDF, grant permission, call a
/// model or claim WKDownload delivery; that chain has separate hosted checks.
final class SkillPDFCapabilityUITests: XCTestCase {
    private let app = XCUIApplication()
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 120 }
    override func tearDownWithError() throws { app.terminate() }

    func testPDFQueryScopeIsAvailableWithoutGrantingWorkspaceAccess() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
                               "-UITestNamespace", UUID().uuidString, "-UITestResetStorage"]
        app.launchEnvironment = [:]
        app.launch()
        tapFixed("navigation.memory")
        tapFixed("memory.segment.skills")
        XCTAssertEqual(app.buttons["memory.segment.skills"].value as? String, "已選取")
        let open = app.buttons["skills.documents.execute"]
        revealLearningElement(open, in: app); open.tap()
        let scope = app.staticTexts["skillExecution.pdfQuery.scope"]
        revealLearningElement(scope, in: app, visibility: .readableText)
        XCTAssertEqual(scope.label, "僅在獨立 PDF 查詢流程，確認模型目的服務後，讀取或逐字搜尋本次已擷取 PDF 的文字快照；引文需對應實際讀取。不開放任意路徑、workspace 或無上限讀取。")
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        XCTAssertFalse(app.staticTexts["skillExecution.uitest.fixture"].exists)
    }

    private func tapFixed(_ identifier: String) {
        let button = app.buttons[identifier]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        button.tap()
    }
}
