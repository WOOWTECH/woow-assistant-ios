#if SKILL_EXECUTION_UI_FIXTURE_CHECKS
import Foundation
#if DEBUG
import PDFKit
#endif

// CLT host verification of the exact fixture seeder, not an iOS UI test:
// swiftc -DDEBUG -D SKILL_EXECUTION_UI_FIXTURE_CHECKS -parse-as-library \
//   Sources/App/SkillExecutionUITestSupport.swift \
//   Tests/WoowAssistantUITests/SkillExecutionUITests.swift -o /tmp/woow-pdf-fixture-checks
// /tmp/woow-pdf-fixture-checks
// Omit -DDEBUG to verify release performs no file access even with all test flags.
@main
struct SkillExecutionUIFixtureChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func main() throws {
        let namespace = UUID()
        let args = ["app", "-UITestMode", "-UITestSkillExecution", "-UITestNamespace", namespace.uuidString]
        var resolvedDirectory = false
        let inactive = try SkillExecutionUITestSupport.seedIfRequested(arguments: ["app", "-UITestMode"]) {
            resolvedDirectory = true; throw Failure(message: "inactive seeder touched files")
        }
        try require(inactive == nil && !resolvedDirectory, "default must not access files")
        #if DEBUG
        let invalid = [
            ["-UITestSkillExecution"],
            ["-UITestSkillExecution", "-UITestMode", "-UITestNamespace", "../personal"],
            args + ["-UITestNamespace", UUID().uuidString],
            args + ["-UITestMode"], args + ["-LiveModelUITest"]
        ]
        for arguments in invalid {
            do {
                _ = try SkillExecutionUITestSupport.seedIfRequested(arguments: arguments) {
                    resolvedDirectory = true; throw Failure(message: "invalid gate touched files")
                }
                throw Failure(message: "invalid namespace accepted")
            } catch SkillExecutionUITestSupport.Failure.invalidNamespace { }
            try require(!resolvedDirectory, "validate before accessing Documents")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-ui-pdf-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let fixture = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: { root }),
              let pdf = PDFDocument(url: fixture.url) else { throw Failure(message: "real fixture PDF missing") }
        try require(pdf.pageCount == 2, "two actual PDFKit pages")
        for number in 1...2 {
            let text = pdf.page(at: number - 1)?.string ?? ""
            try require(text.contains("WOOW_SKILL_PDF_PAGE_\(number)"), "text marker must be extractable, not a bitmap")
            try require(text.contains(namespace.uuidString), "PDF content must identify its test namespace")
        }
        let original = try Data(contentsOf: fixture.url)
        let repeated = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: { root })
        try require(repeated?.url == fixture.url, "same test may reopen its fixture")
        let repeatedBytes = try Data(contentsOf: fixture.url)
        try require(repeatedBytes == original, "reopen must not rewrite PDF")
        let secondArgs = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", UUID().uuidString]
        let second = try SkillExecutionUITestSupport.seedIfRequested(arguments: secondArgs, documentsDirectory: { root })
        try require(second?.url != fixture.url, "namespaces must not share fixture paths")
        let unowned = Data("existing test sentinel".utf8)
        try unowned.write(to: fixture.url)
        do {
            _ = try SkillExecutionUITestSupport.seedIfRequested(arguments: args, documentsDirectory: { root })
            throw Failure(message: "overwrote unowned content")
        } catch SkillExecutionUITestSupport.Failure.existingFile { }
        let preserved = try Data(contentsOf: fixture.url)
        try require(preserved == unowned, "existing nonfixture bytes preserved")
        var audit = SkillExecutionUITestAudit()
        try require(audit.evidence.contains("extractionAttempts=0 results=0"), "audit starts empty")
        audit.reads += 1
        try require(audit.extractionAttempts == 0, "reading is not extracting")
        print("PASS DEBUG gates, namespace isolation, actual PDFKit fixture text, idempotence and overwrite refusal")
        #else
        let ignored = try SkillExecutionUITestSupport.seedIfRequested(arguments: args) {
            resolvedDirectory = true; throw Failure(message: "release touched files")
        }
        try require(ignored == nil && !resolvedDirectory, "release ignores all fixture switches")
        print("PASS release/default seeder performs no filesystem access")
        #endif
    }
}
#else
import XCTest

/// Real native fileImporter/Files + real SkillExecutionRuntime/PDFKit. The DEBUG
/// fixture only creates a synthetic PDF and reports actual dispatch counters.
/// No picker shortcut, direct URL injection, model, Python or remote endpoint.
/// Parent entry IDs: catalog.documents.execute and skills.documents.execute.
/// Files requires BOTH UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace.
final class SkillExecutionUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private var filename: String { "SkillExecution-\(namespace).pdf" }
    private var stem: String { "SkillExecution-\(namespace)" }

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Files tests require an isolated iOS simulator.")
        #endif
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        // Do not collect Files-provider screenshots or an unrestricted AX tree.
        app.terminate()
    }

    func testNativeFilesPDFNeedsBothApprovalsAndReturnsActualText() {
        launchFixture(fromCatalog: true)
        chooseSyntheticPDF()
        assertAudit(selections: 1, reads: 0, extractionAttempts: 0, results: 0)
        XCTAssertFalse(app.staticTexts["skillExecution.fingerprint"].exists,
                       "Implementation fingerprint must stay inside collapsed source details.")
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        approve(capability: "selectedPDFRead")
        assertAudit(selections: 1, reads: 1, extractionAttempts: 0, results: 0)
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists,
                       "File read approval must not authorize PDF extraction.")
        approve(capability: "nativePDFText")
        let summary = app.staticTexts["skillExecution.result.summary"]
        scrollExecutionToTop()
        revealLearningElement(summary, in: app, visibility: .readableText)
        XCTAssertEqual(summary.label, "共 2 頁；引擎：Apple PDFKit")
        let output = app.staticTexts["skillExecution.result.text"]
        scrollExecutionToTop()
        revealLearningElement(output, in: app, visibility: .readableText)
        XCTAssertTrue(output.label.contains("--- page 1 ---"))
        XCTAssertTrue(output.label.contains("--- page 2 ---"))
        XCTAssertTrue(output.label.contains("WOOW_SKILL_PDF_PAGE_1"))
        XCTAssertTrue(output.label.contains("WOOW_SKILL_PDF_PAGE_2"))
        XCTAssertTrue(output.label.contains(namespace), "Must extract this namespace's actual selected PDF.")
        assertAudit(selections: 1, reads: 1, extractionAttempts: 1, results: 1)
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
    }

    func testNativePickerCancellationDoesNotReadOrExtract() {
        launchFixture(fromCatalog: false)
        openNativePicker()
        requireHittable(nativeCancel)
        nativeCancel.tap()
        XCTAssertTrue(app.buttons["skillExecutionSelectPDF"].waitForExistence(timeout: 10))
        assertNoExtractionAfterRefusal(selections: 0, reads: 0)
    }

    func testRefusingFirstStepDoesNotReadOrExtract() {
        launchFixture(fromCatalog: false)
        chooseSyntheticPDF()
        assertAudit(selections: 1, reads: 0, extractionAttempts: 0, results: 0)
        clearPlan()
        assertNoExtractionAfterRefusal(selections: 1, reads: 0)
    }

    func testRefusingSecondStepKeepsExtractionUnauthorized() {
        launchFixture(fromCatalog: false)
        chooseSyntheticPDF()
        approve(capability: "selectedPDFRead")
        assertAudit(selections: 1, reads: 1, extractionAttempts: 0, results: 0)
        clearPlan()
        assertNoExtractionAfterRefusal(selections: 1, reads: 1)
    }

    private func launchFixture(fromCatalog: Bool) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestSkillExecution"]
        app.launchEnvironment = [:]
        app.launch()
        tap("navigation.memory")
        XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: 15))
        tap("memory.segment.skills")
        if fromCatalog {
            tap("skills.catalog.open", scroll: true)
            XCTAssertTrue(app.staticTexts["catalog.count"].waitForExistence(timeout: 10))
            let search = app.textFields["catalog.search"]
            requireHittable(search)
            search.tap(); search.typeText("documents\n")
            wait(search, "value == %@", "documents")
            tap("catalog.entry.documents", scroll: true)
            tap("catalog.documents.execute", scroll: true)
        } else { tap("skills.documents.execute", scroll: true) }
        let fixture = app.staticTexts["skillExecution.uitest.fixture"]
        revealLearningElement(fixture, in: app, visibility: .readableText)
        XCTAssertEqual(fixture.label, "測試文件已建立：" + filename,
                       "DEBUG seeder must create only this namespace's real PDF.")
        assertAudit(selections: 0, reads: 0, extractionAttempts: 0, results: 0)
    }

    private func openNativePicker() {
        tap("skillExecutionSelectPDF", scroll: true)
        requireHittable(nativeCancel)
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].isHittable,
                       "Native picker must be shown before any runtime plan is approved.")
    }

    private var nativeCancel: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
    }

    private func chooseSyntheticPDF() {
        openNativePicker()
        var enteredAppFolder = false
        for _ in 0..<10 {
            if let file = nativeItem(containing: stem) {
                file.tap()
                let selected = app.staticTexts["skillExecution.filename"]
                if !selected.waitForExistence(timeout: 3), let open = knownButton(["開啟", "Open", "完成", "Done"]) {
                    open.tap()
                }
                XCTAssertTrue(selected.waitForExistence(timeout: 15), "Files selection must reach the real importer callback.")
                XCTAssertEqual(selected.label, filename)
                XCTAssertFalse(nativeCancel.exists, "The document picker must have dismissed.")
                return
            }
            if enteredAppFolder {
                // Prior cases retain their separately named synthetic PDFs. Only
                // scroll inside the app folder we deliberately entered; never
                // search an unknown/cloud provider for a different document.
                let lists = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
                guard let list = lists.first(where: { $0.isHittable }) else {
                    XCTFail("Native app Documents folder must expose its file list.")
                    return
                }
                list.swipeUp()
                continue
            }
            if let folder = nativeItem(exact: ["渥屋助理", "WoowAssistant"]) {
                folder.tap(); enteredAppFolder = true
            }
            else if let local = nativeItem(exact: ["我的 iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]) { local.tap() }
            else if let browse = knownButton(["瀏覽", "Browse", "位置", "Locations"]) { browse.tap() }
            else {
                XCTFail("Native Files must expose this app's local synthetic PDF; no cloud, real-file or direct-URL fallback is permitted.")
                return
            }
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.nativeItem(containing: self.stem) != nil
                    || self.nativeItem(exact: ["渥屋助理", "WoowAssistant", "我的 iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]) != nil
                    || self.knownButton(["瀏覽", "Browse", "位置", "Locations"]) != nil
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 10), .completed)
        }
        XCTFail("Synthetic PDF was not reached within bounded native Files navigation.")
    }

    private func approve(capability: String) {
        let button = app.buttons["skillExecutionApproveStep"]
        scrollExecutionToTop()
        revealLearningElement(button, in: app)
        wait(button, "value == %@", capability == "selectedPDFRead" ? "讀取選取的 PDF" : "在裝置上擷取 PDF")
        requireHittable(button)
        button.tap()
        // Do not confuse the first completed read with the second extraction.
        let status = app.staticTexts["skillExecutionStatus"]
        let expected = capability == "selectedPDFRead" ? "請核准下一個步驟" : "擷取完成"
        scrollExecutionToTop()
        revealLearningElement(status, in: app, visibility: .readableText)
        wait(status, "label CONTAINS %@", expected)
    }

    private func clearPlan() {
        tap("skillExecutionClearPlan", scroll: true)
        XCTAssertTrue(app.buttons["skillExecutionSelectPDF"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["skillExecution.filename"].exists)
    }

    private func assertNoExtractionAfterRefusal(selections: Int, reads: Int) {
        assertAudit(selections: selections, reads: reads, extractionAttempts: 0, results: 0)
        let audit = app.staticTexts["skillExecution.uitest.audit"]
        let expected = evidence(selections: selections, reads: reads, extractionAttempts: 0, results: 0)
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@", expected), object: audit)
        changed.isInverted = true
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 3), .completed,
                       "Cancellation/refusal must not dispatch any delayed extraction.")
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
    }

    private func assertAudit(selections: Int, reads: Int, extractionAttempts: Int, results: Int) {
        let audit = app.staticTexts["skillExecution.uitest.audit"]
        scrollExecutionToTop()
        revealLearningElement(audit, in: app, visibility: .readableText)
        XCTAssertTrue(audit.waitForExistence(timeout: 5))
        XCTAssertEqual(audit.label, evidence(selections: selections, reads: reads, extractionAttempts: extractionAttempts, results: results))
    }

    private func scrollExecutionToTop() {
        // Begin at a known anchor so virtualized rows above the viewport are
        // never searched by swiping farther down. Scrolling never chooses files.
        let intro = app.staticTexts["skillExecution.intro"]
        let form = app.descendants(matching: .any).matching(identifier: "skillExecution.form").firstMatch
        for _ in 0..<6 {
            if intro.exists && intro.isHittable { return }
            if form.exists { form.swipeDown() } else { app.swipeDown() }
        }
        XCTFail("PDF execution form must expose its first row within bounded scrolling.")
    }

    private func evidence(selections: Int, reads: Int, extractionAttempts: Int, results: Int) -> String {
        "SKILL_EXECUTION_AUDIT selections=\(selections) reads=\(reads) extractionAttempts=\(extractionAttempts) results=\(results)"
    }

    private func nativeItem(exact labels: [String]) -> XCUIElement? { nativeItem(predicate: NSPredicate(format: "label IN %@", labels)) }
    private func nativeItem(containing value: String) -> XCUIElement? { nativeItem(predicate: NSPredicate(format: "label CONTAINS %@", value)) }
    private func nativeItem(predicate: NSPredicate) -> XCUIElement? {
        let items = app.cells.matching(predicate).allElementsBoundByIndex
            + app.buttons.matching(predicate).allElementsBoundByIndex
            + app.staticTexts.matching(predicate).allElementsBoundByIndex
        return items.first { $0.exists && $0.isHittable }
    }
    private func knownButton(_ labels: [String]) -> XCUIElement? {
        app.buttons.matching(NSPredicate(format: "label IN %@", labels)).allElementsBoundByIndex.first { $0.exists && $0.isHittable }
    }
    private func tap(_ id: String, scroll: Bool = false) {
        let button = app.buttons[id]
        if id.hasPrefix("skillExecution") { scrollExecutionToTop() }
        if scroll { revealLearningElement(button, in: app) }
        requireHittable(button); button.tap()
    }
    private func requireHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
    private func wait(_ element: XCUIElement, _ format: String, _ value: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
}
#endif
