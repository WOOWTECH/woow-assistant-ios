import CoreGraphics

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
#elseif SKILL_EXECUTION_EXPORT_CHECKS
import Foundation
import SwiftUI

/// Host check of the exact FileDocument serialization used by fileExporter.
/// This verifies real UTF-8 file bytes, not native iOS dialog behavior.
@main
struct SkillExecutionTextExportChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-export-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let text = "--- page 1 ---\n繁體中文逐字稿 😀\n\n--- page 3 ---\n原文與頁碼保持不變。\n"
        let document = try SkillExecutionTextDocument(text: text)
        let destination = root.appendingPathComponent("使用者選擇的文字.txt")
        try require(!FileManager.default.fileExists(atPath: destination.path), "preparing a document must not write a destination")
        try document.snapshot().write(to: destination, options: .atomic, originalContentsURL: nil)
        let saved = try Data(contentsOf: destination)
        try require(saved == Data(text.utf8), "saved bytes must be exact UTF-8, including page citations and Traditional Chinese")
        let reopened = try SkillExecutionTextDocument(fileWrapper: FileWrapper(url: destination, options: .immediate))
        try require(reopened.text == text, "actual exported file must round-trip without normalization")
        for invalid in [FileWrapper(directoryWithFileWrappers: [:]),
                        FileWrapper(regularFileWithContents: Data([0xff])),
                        FileWrapper(regularFileWithContents: Data(repeating: 32, count: SkillExecutionLimits.outputBytes + 1))] {
            do {
                _ = try SkillExecutionTextDocument(fileWrapper: invalid)
                throw Failure(message: "must reject invalid or oversized document data")
            } catch is CocoaError { }
        }
        do {
            _ = try SkillExecutionTextDocument(text: String(repeating: "字", count: SkillExecutionLimits.outputBytes / 3 + 1))
            throw Failure(message: "export limit must count UTF-8 bytes, not characters")
        } catch SkillExecutionError.outputTooLarge { }
        print("PASS actual export FileDocument UTF-8 round-trip, page citations, invalid input and byte limit")
    }
}
#elseif SKILL_EXECUTION_PICKER_CHECKS
/// swiftc -D SKILL_EXECUTION_PICKER_CHECKS -parse-as-library <this file> -o /tmp/woow-skill-picker-checks
@main
struct SkillExecutionPickerChecks {
    struct Failure: Error {}
    static func require(_ condition: Bool) throws { if !condition { throw Failure() } }
    static func main() throws {
        var stalled = SkillPickerRoute()
        try require(stalled.next { $0 == .browseTab } == .browseTab)
        try require(!stalled.progress(after: .browseTab) { $0 == .browseTab || $0 == .browseButton })
        try require(stalled.next { $0 == .browseTab } == nil)
        var local = SkillPickerRoute()
        try require(local.next { $0 == .back } == .back)
        try require(local.progress(after: .back) { $0 == .locations })
        try require(local.next { $0 == .locations } == .locations)
        try require(local.progress(after: .locations) { $0 == .local })
        try require(local.next { $0 == .local } == .local)
        try require(local.progress(after: .local) { $0 == .application })
        try require(local.next { $0 == .application } == .application)
        try require(!local.progress(after: .application) { $0 == .application || $0 == .browseButton })
        try require(local.progress(after: .application) { $0 == .file })
        try require(local.next { $0 == .file } == .file)
        try require(local.next { $0 == .file } == nil)
        var bounded = SkillPickerRoute()
        for expected in SkillPickerStep.allCases { try require(bounded.next { _ in true } == expected) }
        try require(bounded.next { _ in true } == nil)
        // Frames from the e1024aa iOS 26 failure: the image is visible even
        // though XCTest cannot derive a hittable point for its AX Image.
        let cell = CGRect(x: 140, y: 212, width: 122, height: 189.7)
        let image = CGRect(x: 168.7, y: 216, width: 65, height: 84)
        let viewport = CGRect(x: 0, y: 72, width: 402, height: 802)
        let navigation = CGRect(x: 0, y: 88, width: 402, height: 114)
        try require(skillPDFThumbnailIsVisible(image, cell: cell, viewport: viewport, navigation: navigation))
        for invalid in [CGRect.zero, CGRect.infinite, image.offsetBy(dx: 130, dy: 0), image.offsetBy(dx: 0, dy: -40)] {
            try require(!skillPDFThumbnailIsVisible(invalid, cell: cell, viewport: viewport, navigation: navigation))
        }
        try require(!skillPDFThumbnailIsVisible(image, cell: cell,
            viewport: CGRect(x: 0, y: 250, width: 402, height: 624), navigation: navigation))
        print("PASS bounded Skills Files route: no repeated Browse, real successor progress, local folder and exact-file terminal")
        print("PASS observed PDF thumbnail geometry; reject absent, unrelated, covered and clipped targets")
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
    private var exportStem: String { stem + "-文字" }

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

    func testNativeExportSavesTextToChosenLocalFolder() {
        extractFixtureForExport()
        openNativeExporter()
        chooseLocalExportFolder()
        let save = nativeExportConfirmation
        requireHittable(save)
        save.tap()
        assertExportStatus("文字已儲存至所選位置。")
        assertAudit(selections: 1, reads: 1, extractionAttempts: 1, results: 1)

        // Reopen the real system dialog and verify that the selected destination
        // contains the exported file. Never inject a URL or write from the test.
        openNativeExporter()
        chooseLocalExportFolder()
        let exportedNames = NSPredicate(format: "label IN %@", [exportStem, exportStem + ".txt"])
        // Restrict evidence to a file-list cell, not the proposed filename field.
        let exported = app.cells.staticTexts.matching(exportedNames).firstMatch
        let exportedCell = app.cells.matching(exportedNames).firstMatch
        for _ in 0..<10 {
            if exported.exists || exportedCell.exists { break }
            scrollNativeFileList()
        }
        if !exported.exists && !exportedCell.exists { recordPickerDiagnostics(stage: "export-file-not-visible") }
        XCTAssertTrue(exported.exists || exportedCell.exists, "The actual Files destination must contain this namespace's exact exported text basename.")
        cancelNativeExporter()
        assertExportStatus("已取消匯出，擷取結果仍保留。")
    }

    func testNativeExportCancellationPreservesResultAndAllowsRetry() {
        extractFixtureForExport()
        openNativeExporter()
        cancelNativeExporter()
        assertExportStatus("已取消匯出，擷取結果仍保留。")
        assertAudit(selections: 1, reads: 1, extractionAttempts: 1, results: 1)
        let output = app.staticTexts["skillExecution.result.text"]
        scrollExecutionToTop()
        revealLearningElement(output, in: app, visibility: .readableText)
        XCTAssertTrue(output.label.contains(namespace))
        XCTAssertTrue(output.label.contains("WOOW_SKILL_PDF_PAGE_2"))
        openNativeExporter()
        cancelNativeExporter()
        assertExportStatus("已取消匯出，擷取結果仍保留。")
        assertAudit(selections: 1, reads: 1, extractionAttempts: 1, results: 1)
    }

    private func extractFixtureForExport() {
        launchFixture(fromCatalog: false)
        XCTAssertFalse(app.buttons["skillExecutionExportText"].exists)
        chooseSyntheticPDF()
        approve(capability: "selectedPDFRead")
        XCTAssertFalse(app.buttons["skillExecutionExportText"].exists,
                       "Export must not be available before extraction approval.")
        approve(capability: "nativePDFText")
    }

    private func openNativeExporter() {
        tap("skillExecutionExportText", scroll: true)
        // 4dbbddb recordings: the exporter opens inside the app folder with
        // Move (iOS 18: 搬移) / Save (iOS 26), but no Cancel at that depth.
        requireHittable(nativeExportConfirmation)
    }

    private var nativeExportConfirmation: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@",
            ["儲存", "Save", "匯出", "Export", "搬移", "移動", "Move"])).firstMatch
    }

    private func cancelNativeExporter() {
        // Return only through known local ancestors to the native Cancel button.
        // Each label is tapped at most once; never save or dismiss app state to
        // simulate cancellation. Callers still verify the real cancel callback.
        let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        let ancestorLabels = localLabels + browseLabels + locationsLabels
        var attempted = Set<String>()
        for attempt in 0...3 {
            if nativeCancel.exists {
                requireHittable(nativeCancel)
                nativeCancel.tap()
                return
            }
            guard attempt < 3 else { break }
            guard let back = firstHittable(navigation.buttons.matching(
                NSPredicate(format: "label IN %@", ancestorLabels))),
                attempted.insert(back.label).inserted else {
                recordPickerDiagnostics(stage: "export-cancel-no-known-ancestor")
                XCTFail("Native export cancellation must expose Cancel or a known local ancestor.")
                return
            }
            let previous = back.label
            back.tap()
            let changed = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.nativeCancel.exists || !navigation.buttons.matching(
                    NSPredicate(format: "label == %@", previous)).firstMatch.exists
            }, object: nil)
            guard XCTWaiter.wait(for: [changed], timeout: 12) == .completed else {
                recordPickerDiagnostics(stage: "export-cancel-no-navigation-progress")
                XCTFail("Native exporter must leave the previous folder before another navigation action.")
                return
            }
        }
        XCTFail("Native exporter must expose Cancel within the bounded local ancestor route.")
    }

    private func chooseLocalExportFolder() {
        _ = navigateNativeFiles(exporting: true)
    }

    private func scrollNativeFileList() {
        let lists = app.collectionViews.allElementsBoundByIndex + app.tables.allElementsBoundByIndex
        guard let list = lists.first(where: { $0.isHittable }) else {
            XCTFail("Native destination must expose its file list."); return
        }
        list.swipeUp()
    }

    private func assertExportStatus(_ expected: String) {
        let status = app.staticTexts["skillExecution.export.status"]
        scrollExecutionToTop()
        revealLearningElement(status, in: app, visibility: .readableText)
        wait(status, "label == %@", expected)
        XCTAssertFalse(nativeCancel.exists)
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
        // iOS 17 evidence: Files initialization can exhaust the old 15-second
        // readiness budget. Wait for the actual native control once;
        // do not retap the launch button or bypass the document picker.
        requireHittable(nativeCancel, timeout: 45)
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].isHittable,
                       "Native picker must be shown before any runtime plan is approved.")
    }

    private var nativeCancel: XCUIElement {
        app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
    }

    private func chooseSyntheticPDF() {
        openNativePicker()
        guard let file = navigateNativeFiles(exporting: false) else { return }
        // The iOS 26 failure recording shows a visible PDF thumbnail whose AX
        // Image is not hittable. A whole-cell tap lands on the filename instead.
        // Anchor the gesture to the exact cell's verified visible image; never
        // substitute a label/cell-center tap or a fixed screen coordinate.
        let images = file.images.allElementsBoundByIndex
        let list = app.collectionViews["File View"]
        let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        guard images.count == 1, let thumbnail = images.first, thumbnail.exists,
              file.isEnabled, file.isHittable, list.exists, navigation.exists,
              skillPDFThumbnailIsVisible(thumbnail.frame, cell: file.frame,
                  viewport: list.frame.intersection(app.frame), navigation: navigation.frame) else {
            recordPickerDiagnostics(stage: "exact-thumbnail-not-visible")
            XCTFail("The exact selected PDF must expose one fully visible thumbnail inside its Files cell.")
            return
        }
        thumbnail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = app.staticTexts["skillExecution.filename"]
        if !selected.waitForExistence(timeout: 3), let open = knownButton(["開啟", "Open", "完成", "Done"]) { open.tap() }
        let received = selected.waitForExistence(timeout: 15)
        if !received { recordPickerDiagnostics(stage: "selection-not-delivered") }
        XCTAssertTrue(received, "Files selection must reach the real importer callback.")
        XCTAssertEqual(selected.label, filename)
        XCTAssertFalse(nativeCancel.exists, "The document picker must have dismissed.")
    }

    private let applicationLabels = ["渥屋助理", "WoowAssistant"]
    private let localLabels = ["我的 iPhone", "我的iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]
    private let browseLabels = ["瀏覽", "Browse"]
    private let locationsLabels = ["位置", "Locations"]
    private var selectedFileNames: NSPredicate { NSPredicate(format: "label IN %@", [filename, stem]) }
    private var localAppFolderTitle: XCUIElement {
        let title = app.navigationBars.staticTexts.matching(NSPredicate(format: "label IN %@", applicationLabels)).firstMatch
        if title.exists { return title }
        // Actual iOS 18 screenshot/AX: the folder title is an actions-menu button,
        // not a StaticText. This proves the destination without opening that menu.
        return app.navigationBars.buttons.matching(NSPredicate(format: "label == %@", "渥屋助理, 「動作」選單")).firstMatch
    }

    private func syntheticPDFCell() -> XCUIElement? {
        // Actual Files identifier includes the type suffix; the visible label also
        // includes timestamp/size. Keep the complete namespace basename exact.
        if let cell = firstHittable(app.cells.matching(NSPredicate(format: "identifier == %@", stem + ", pdf"))) { return cell }
        for exactName in [filename, stem] {
            if let cell = firstHittable(app.cells.containing(.staticText, identifier: exactName)) { return cell }
        }
        return nil // Never fall back to a detached filename StaticText.
    }

    /// Port of Raman's bounded known-location route. Import terminates only at
    /// the exact PDF basename; export requires the actual local folder title.
    private func navigateNativeFiles(exporting: Bool) -> XCUIElement? {
        var route = SkillPickerRoute()
        let mode = exporting ? "export" : "import"
        while true {
            if localAppFolderTitle.exists {
                if exporting { return localAppFolderTitle }
                // Scroll only after confirming this app's local Documents folder.
                for attempt in 0...10 {
                    if let file = pickerElement(for: .file, exporting: false) { return file }
                    if attempt < 10 { scrollNativeFileList() }
                }
                recordPickerDiagnostics(stage: mode + "-exact-file-not-visible")
                XCTFail("The known local app folder did not reveal this namespace's exact PDF basename.")
                return nil
            }
            var target: XCUIElement?
            guard let step = route.next(where: { candidate in
                target = pickerElement(for: candidate, exporting: exporting)
                return target != nil
            }), let target else {
                recordPickerDiagnostics(stage: mode + "-no-known-local-destination")
                XCTFail("Native Files must expose the known local app folder. Check built file-sharing plist keys; no provider or direct-URL fallback is allowed.")
                return nil
            }
            if step == .file { return target }
            target.tap()
            let loaded = XCTNSPredicateExpectation(predicate: NSPredicate { [weak self] _, _ in
                guard let self else { return false }
                return self.localAppFolderTitle.exists
                    || route.progress(after: step) { self.pickerElement(for: $0, exporting: exporting) != nil }
            }, object: nil)
            guard XCTWaiter.wait(for: [loaded], timeout: 12) == .completed else {
                recordPickerDiagnostics(stage: mode + "-no-progress-after-" + step.rawValue)
                XCTFail("Native Files did not reveal the next known destination after \(step.rawValue); the same control will not be tapped again.")
                return nil
            }
        }
    }

    private func pickerElement(for step: SkillPickerStep, exporting: Bool) -> XCUIElement? {
        switch step {
        case .file: return exporting ? nil : syntheticPDFCell()
        case .application: return nativeItem(predicate: NSPredicate(format: "label IN %@", applicationLabels))
        case .local: return nativeItem(predicate: NSPredicate(format: "label IN %@", localLabels))
        case .locations: return knownButton(locationsLabels)
        case .back:
            return firstHittable(app.navigationBars.buttons.matching(NSPredicate(format: "label IN %@", browseLabels + locationsLabels)))
        case .browseTab:
            return firstHittable(app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", browseLabels)), excludingSelected: true)
        case .browseButton:
            return firstHittable(app.buttons.matching(NSPredicate(format: "label IN %@", browseLabels)), excludingSelected: true)
        }
    }

    private func recordPickerDiagnostics(stage: String) {
        // Counts for known labels only: no filenames/provider enumeration,
        // screenshots, element values, identifiers or accessibility/debug tree.
        let groups: [(String, NSPredicate)] = [
            ("synthetic", selectedFileNames),
            ("synthetic-cell-id", NSPredicate(format: "identifier == %@", stem + ", pdf")),
            ("exported", NSPredicate(format: "label IN %@", [exportStem, exportStem + ".txt"])),
            ("application", NSPredicate(format: "label IN %@", applicationLabels)),
            ("application-title", NSPredicate(format: "label == %@", "渥屋助理, 「動作」選單")),
            ("local", NSPredicate(format: "label IN %@", localLabels)),
            ("local-no-space", NSPredicate(format: "label IN %@", localLabels.map { $0.replacingOccurrences(of: " ", with: "") })),
            ("local-nbsp", NSPredicate(format: "label IN %@", localLabels.flatMap { name in
                [name.replacingOccurrences(of: " ", with: "\u{00a0}"), name.replacingOccurrences(of: " ", with: "\u{202f}")]
            })),
            ("browse", NSPredicate(format: "label IN %@", browseLabels)),
            ("locations", NSPredicate(format: "label IN %@", locationsLabels)),
            ("cancel", NSPredicate(format: "label IN %@", ["取消", "Cancel"])),
            ("export-confirm", NSPredicate(format: "label IN %@", ["儲存", "Save", "匯出", "Export", "搬移", "移動", "Move"]))
        ]
        let counts = groups.map { name, predicate in
            "\(name)[cell=\(app.cells.matching(predicate).count),button=\(app.buttons.matching(predicate).count),text=\(app.staticTexts.matching(predicate).count),other=\(app.otherElements.matching(predicate).count)]"
        }
        print("SKILL_PICKER_KNOWN_COUNTS stage=\(stage) " + counts.joined(separator: " "))
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

    private func nativeItem(predicate: NSPredicate) -> XCUIElement? {
        for query in [app.cells, app.buttons, app.staticTexts] {
            if let element = firstHittable(query.matching(predicate)) { return element }
        }
        return nil
    }
    private func firstHittable(_ query: XCUIElementQuery, excludingSelected: Bool = false) -> XCUIElement? {
        query.allElementsBoundByIndex.prefix(6).first { $0.exists && $0.isHittable && $0.isEnabled && (!excludingSelected || !$0.isSelected) }
    }
    private func knownButton(_ labels: [String]) -> XCUIElement? {
        firstHittable(app.buttons.matching(NSPredicate(format: "label IN %@", labels)))
    }
    private func tap(_ id: String, scroll: Bool = false) {
        let button = app.buttons[id]
        if id.hasPrefix("skillExecution") { scrollExecutionToTop() }
        if scroll { revealLearningElement(button, in: app) }
        requireHittable(button); button.tap()
    }
    private func requireHittable(_ element: XCUIElement, timeout: TimeInterval = 15) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: timeout), .completed)
    }
    private func wait(_ element: XCUIElement, _ format: String, _ value: String) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 15), .completed)
    }
}
#endif

private enum SkillPickerStep: String, CaseIterable {
    case file, application, local, back, locations, browseTab, browseButton
    var successors: [Self] {
        switch self {
        case .file: return []
        case .application: return [.file]
        case .local: return [.file, .application]
        case .locations: return [.file, .application, .local]
        case .back, .browseTab, .browseButton: return [.file, .application, .local, .locations]
        }
    }
}

private struct SkillPickerRoute {
    private var attempted = Set<SkillPickerStep>()
    mutating func next(where available: (SkillPickerStep) -> Bool) -> SkillPickerStep? {
        for step in SkillPickerStep.allCases where !attempted.contains(step) && available(step) {
            attempted.insert(step)
            return step
        }
        return nil
    }
    func progress(after step: SkillPickerStep, where available: (SkillPickerStep) -> Bool) -> Bool {
        step.successors.contains { !attempted.contains($0) && available($0) }
    }
}

private func skillPDFThumbnailIsVisible(_ image: CGRect, cell: CGRect, viewport: CGRect, navigation: CGRect) -> Bool {
    guard [image, cell, viewport, navigation].allSatisfy({ !$0.isEmpty && !$0.isNull && !$0.isInfinite }) else { return false }
    return cell.contains(image) && viewport.contains(image) && !navigation.intersects(image)
}
