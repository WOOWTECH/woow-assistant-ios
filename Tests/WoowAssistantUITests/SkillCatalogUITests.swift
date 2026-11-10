import XCTest

/// Isolated fixture mode: no live endpoint, model, original script or tool call.
final class SkillCatalogUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws { app.terminate() }

    func testAllPinnedSkillsSearchFullOriginalAssetsAndLicense() {
        launch()
        openCatalog()
        XCTAssertEqual(app.staticTexts["catalog.count"].label, "共 6 項原始技能 · 符合 6 項")
        XCTAssertTrue(app.staticTexts["catalog.scope"].label.contains("不會執行"))
        for id in ["configure-mika", "content-transcribe", "documents", "info-research", "messaging", "skill-authoring"] {
            search(id)
            XCTAssertEqual(app.staticTexts["catalog.count"].label, "共 6 項原始技能 · 符合 1 項")
            XCTAssertTrue(app.buttons["catalog.entry.\(id)"].exists)
        }
        search("pypdf")
        tap("catalog.entry.documents", scroll: true)
        revealLearningElement(app.staticTexts["catalog.requirement.python"], in: app)
        let pythonRequirement = app.staticTexts["catalog.requirement.python"].label
        XCTAssertTrue(pythonRequirement.contains("原始 PDF 腳本需另行設定服務"), pythonRequirement)
        XCTAssertTrue(pythonRequirement.contains("本機不執行 Python"), pythonRequirement)
        let readiness = app.staticTexts["catalog.readiness"].label
        XCTAssertTrue(readiness.contains("可選取 PDF 擷取文字"), readiness)
        XCTAssertTrue(readiness.contains("未完整支援"), readiness)
        tap("catalog.original", scroll: true)
        let document = app.staticTexts["catalog.document"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertTrue(document.label.contains("run_bundled_script"))
        XCTAssertTrue(document.label.contains("## 什么时候停下交给用户"))
        XCTAssertTrue(app.staticTexts["catalog.document.provenance"].label.contains("f5cfa97a04bab6fcbfba4b654c9a59018dd339eea83b260ace47928e3abf230c"))
        XCTAssertTrue(app.staticTexts["catalog.document.safety"].label.contains("不會執行"))
        back()
        tap("catalog.asset.extract_pdf.py", scroll: true)
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertTrue(document.label.contains("SPDX-License-Identifier: Apache-2.0"))
        XCTAssertTrue(document.label.contains("pypdf"))
        XCTAssertFalse(app.buttons["catalog.import"].exists)
        back()
        tap("catalog.asset.manifest.json", scroll: true)
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertTrue(document.label.contains("\"runnable\": true"))
        XCTAssertTrue(app.staticTexts["catalog.document.safety"].label.contains("唯讀文字"))
        back()
        back()
        tap("catalog.license", scroll: true)
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertTrue(document.label.contains("END OF TERMS AND CONDITIONS"))
        XCTAssertTrue(document.label.contains("limitations under the License."))
        back()
        tap("catalog.notice", scroll: true)
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertEqual(document.label, "Mika\nCopyright 2026 wangzan101\n")
    }

    func testTextAdaptationRequiresApprovalAndPersistsOnlyAsTrial() {
        let name = "ios-mika-messaging"
        launch()
        openCatalog()
        search("messaging")
        tap("catalog.entry.messaging", scroll: true)
        XCTAssertTrue(app.staticTexts["catalog.adaptation.scope"].label.contains("僅擬稿"))
        tap("catalog.adaptation.fullText", scroll: true)
        let text = app.staticTexts["catalog.document"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(text.label.contains("not execution parity"))
        XCTAssertTrue(text.label.contains("name: \(name)"))
        XCTAssertTrue(text.label.contains("Copyright 2026 wangzan101"))
        back()
        tap("catalog.import", scroll: true)
        XCTAssertTrue(app.staticTexts["catalog.import.pending"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["catalog.import"].isEnabled)
        XCTAssertFalse(app.staticTexts["catalog.import.error"].exists)
        back()
        tap("catalog.close")
        XCTAssertTrue(app.staticTexts["skills.empty"].waitForExistence(timeout: 5))
        tap("memory.segment.pending")
        XCTAssertTrue(app.staticTexts["skills.draft.\(name)"].waitForExistence(timeout: 5))
        tap("skills.approve.\(name)", scroll: true)
        tap("memory.segment.skills")
        let status = app.staticTexts["skills.state.\(name)"]
        revealLearningElement(status, in: app)
        XCTAssertEqual(status.label, "試用中 · 尚未驗證")
        launch(reset: false)
        openMemory()
        tap("memory.segment.skills")
        let restoredStatus = app.staticTexts["skills.state.\(name)"]
        revealLearningElement(restoredStatus, in: app)
        XCTAssertEqual(restoredStatus.label, "試用中 · 尚未驗證")
        tap("skills.fullText.\(name)", scroll: true)
        let approvedText = app.staticTexts["skills.document"]
        XCTAssertTrue(approvedText.waitForExistence(timeout: 5))
        XCTAssertTrue(approvedText.label.contains("not execution parity"))
        tap("skills.document.close")
        tap("skills.catalog.open", scroll: true)
        search("messaging")
        tap("catalog.entry.messaging", scroll: true)
        XCTAssertTrue(app.staticTexts["catalog.import.installed"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["catalog.import"].isEnabled)
    }

    func testEmptySearchAndRejectedAdaptationStayDisabled() {
        launch()
        openCatalog()
        search("fixture-no-catalog-result")
        XCTAssertTrue(app.staticTexts["catalog.empty"].exists)
        XCTAssertEqual(app.staticTexts["catalog.count"].label, "共 6 項原始技能 · 符合 0 項")
        search("documents")
        tap("catalog.entry.documents", scroll: true)
        XCTAssertTrue(app.staticTexts["catalog.adaptation.scope"].label.contains("未實作 PDF"))
        tap("catalog.import", scroll: true)
        XCTAssertTrue(app.staticTexts["catalog.import.pending"].waitForExistence(timeout: 5))
        back()
        tap("catalog.close")
        tap("memory.segment.pending")
        tap("skills.reject.ios-mika-documents", scroll: true)
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        launch(reset: false)
        openMemory()
        tap("memory.segment.skills")
        XCTAssertTrue(app.staticTexts["skills.empty"].exists)
        tap("skills.catalog.open", scroll: true)
        search("documents")
        tap("catalog.entry.documents", scroll: true)
        XCTAssertTrue(app.buttons["catalog.import"].isEnabled)
        XCTAssertFalse(app.staticTexts["catalog.import.pending"].exists)
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["uitest.banner"].exists)
    }

    private func openMemory() {
        tap("navigation.memory")
        XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["memory.unavailable"].exists)
    }

    private func openCatalog() {
        openMemory()
        tap("memory.segment.skills")
        tap("skills.catalog.open", scroll: true)
        XCTAssertTrue(app.staticTexts["catalog.count"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["catalog.error"].exists)
    }

    private func search(_ query: String) {
        let field = app.textFields["catalog.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let old = field.value as? String ?? ""
        if !old.isEmpty && old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        }
        field.typeText(query + "\n")
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", query), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 5), .completed)
    }

    private func tap(_ identifier: String, scroll: Bool = false) {
        let button = app.buttons.matching(identifier: identifier).firstMatch
        if scroll { revealLearningElement(button, in: app) }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        button.tap()
    }

    private func back() {
        let button = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertNotEqual(button.label, "關閉", "Must pop the document/detail, not dismiss the catalog")
        XCTAssertTrue(button.isHittable)
        button.tap()
    }
}
