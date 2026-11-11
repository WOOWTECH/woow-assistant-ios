import XCTest

/// Real in-App browser link -> WebKit download -> completed row -> explicit
/// plan/read/extraction gestures. No file seeding, picker, model, replay or grant.
final class BrowserDownloadedPDFUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 300 }
    override func tearDownWithError() throws { app.terminate() }

    func testRealBrowserDownloadRequiresBothApprovalsAndReturnsExactPDFText() throws {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
                               "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestBrowserDownloadedPDF"]
        app.launchEnvironment = [:]
        app.launch()
        tapFixed(app.buttons["navigation.browser"], timeout: 30)
        let web = app.webViews.firstMatch
        XCTAssertTrue(web.staticTexts["DLPDF_NAMESPACE_" + namespace].waitForExistence(timeout: 20))
        XCTAssertTrue(web.staticTexts["DLPDF_REQUESTS_0"].exists)
        tapFixed(web.links["下載測試 PDF"])
        let started = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "下載已開始，可在下載項目查看進度。"), object: app.staticTexts["browser.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [started], timeout: 15), .completed)
        tapFixed(web.links["檢查下載傳送次數"])
        XCTAssertTrue(web.staticTexts["DLPDF_REQUESTS_1"].waitForExistence(timeout: 15))
        XCTAssertFalse(web.staticTexts["DLPDF_REQUESTS_2"].exists)
        tapFixed(app.buttons["browser.library"])
        tapFixed(app.buttons["browser.downloads.open"])
        let downloads = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "download.pdf."))
        XCTAssertTrue(downloads.firstMatch.waitForExistence(timeout: 20), "Only a genuinely completed PDF exposes the production entry")
        XCTAssertEqual(downloads.count, 1)
        let row = downloads.firstMatch
        let selectedID = String(row.identifier.dropFirst("download.pdf.".count))
        XCTAssertNotNil(UUID(uuidString: selectedID))
        revealLearningElement(row, in: app); row.tap()
        let filename = app.staticTexts["downloadPDF.filename"]
        revealLearningElement(filename, in: app, visibility: .readableText)
        XCTAssertEqual(filename.label, "BrowserDownloadedPDF-" + namespace + ".pdf")
        let source = app.staticTexts["downloadPDF.source"]
        revealLearningElement(source, in: app, visibility: .readableText)
        XCTAssertEqual(source.label, "來源：此 App 的已完成下載。下載成功尚未授權讀取或擷取。")
        XCTAssertFalse(app.buttons["skillExecutionSelectPDF"].exists)
        XCTAssertFalse(app.staticTexts["skillExecution.uitest.fixture"].exists)
        var audit = try readAudit()
        XCTAssertEqual(audit.download, selectedID); XCTAssertNil(audit.plan)
        XCTAssertEqual(audit.counts, [0, 0, 0])
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
        tapForm("downloadPDF.prepare")
        audit = try readAudit()
        XCTAssertEqual(audit.download, selectedID); let planID = try XCTUnwrap(audit.plan)
        XCTAssertEqual(audit.counts, [0, 0, 0], "Preparing a plan grants nothing")
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        let approve = app.buttons["skillExecutionApproveStep"]
        revealLearningElement(approve, in: app)
        XCTAssertEqual(approve.value as? String, "讀取選取的 PDF")
        XCTAssertTrue(approve.isEnabled); approve.tap() // First explicit grant only.
        waitForNextApproval("在裝置上擷取 PDF")
        audit = try readAudit()
        XCTAssertEqual(audit.download, selectedID); XCTAssertEqual(audit.plan, planID)
        XCTAssertEqual(audit.counts, [1, 0, 0], "Reading must not dispatch extraction")
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        revealLearningElement(approve, in: app)
        XCTAssertEqual(approve.value as? String, "在裝置上擷取 PDF")
        XCTAssertTrue(approve.isEnabled); approve.tap() // Second explicit grant.
        waitAuditCompletion()
        let summary = app.staticTexts["skillExecution.result.summary"]
        revealLearningElement(summary, in: app, visibility: .readableText)
        XCTAssertEqual(summary.label, "共 2 頁；引擎：Apple PDFKit")
        let result = app.staticTexts["skillExecution.result.text"]
        revealLearningElement(result, in: app, visibility: .readableText)
        XCTAssertEqual(result.label.trimmingCharacters(in: .whitespacesAndNewlines), "--- page 1 ---\nWOOW_DOWNLOADED_PDF_ALPHA\n\n--- page 2 ---\nWOOW_DOWNLOADED_PDF_BETA")
        audit = try readAudit()
        XCTAssertEqual(audit.download, selectedID); XCTAssertEqual(audit.plan, planID)
        XCTAssertEqual(audit.counts, [1, 1, 1], "One dispatch per explicit approval, one actual result")
        let digest = app.staticTexts["downloadPDF.resultDigest"]
        revealLearningElement(digest, in: app, visibility: .readableText)
        XCTAssertEqual(digest.label, "d77115473f53f41562bda05062ca3c1b5a4c1f781b8cf998fa641018206cea4d")
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "actual-download-PDF-result-and-digest"; attachment.lifetime = .keepAlways; add(attachment)
        tapForm("skillExecutionClearPlan")
        audit = try readAudit()
        XCTAssertNil(audit.plan); XCTAssertEqual(audit.counts, [1, 1, 1])
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
    }

    private struct Audit { let download: String; let plan: String?; let counts: [Int] }
    private func readAudit() throws -> Audit {
        let element = app.staticTexts["downloadPDF.audit"]
        revealLearningElement(element, in: app, visibility: .readableText)
        let fields = element.label.split(separator: " ").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }
        XCTAssertEqual(fields.count, 5)
        guard fields.count == 5, fields.allSatisfy({ $0.count == 2 }),
              fields.map({ $0[0] }) == ["download", "plan", "reads", "extractions", "results"],
              UUID(uuidString: fields[0][1]) != nil else { throw NSError(domain: "DownloadPDFUITestAudit", code: 1) }
        let plan = fields[1][1] == "none" ? nil : fields[1][1]
        if let plan { XCTAssertNotNil(UUID(uuidString: plan)) }
        let counts = try fields.dropFirst(2).map { try XCTUnwrap(Int($0[1])) }
        let text = XCTAttachment(string: element.label); text.name = "actual-download-caller-audit"; text.lifetime = .keepAlways; add(text)
        return Audit(download: fields[0][1], plan: plan, counts: counts)
    }
    private func waitAuditCompletion() {
        let audit = app.staticTexts["downloadPDF.audit"]
        revealLearningElement(audit, in: app, visibility: .readableText)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label ENDSWITH %@", "reads=1 extractions=1 results=1"), object: audit)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
    private func waitForNextApproval(_ title: String) {
        let button = app.buttons["skillExecutionApproveStep"]
        revealLearningElement(button, in: app)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND enabled == true AND value == %@", title), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
    private func tapForm(_ id: String) {
        let button = app.buttons[id]; revealLearningElement(button, in: app); XCTAssertTrue(button.isEnabled); button.tap()
    }
    private func tapFixed(_ element: XCUIElement, timeout: TimeInterval = 10) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed); element.tap()
    }
}
