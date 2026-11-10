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
#elseif SKILL_EXECUTION_NATIVE_PICKER_CHECKS
import Foundation

/// CLT verifies the real experiment gates; UIKit presentation remains a native CI check.
/// Compile this file with Sources/App/PDFNativePicker.swift, with/without DEBUG.
@main
enum SkillExecutionNativePickerChecks {
    struct Failure: Error {}
    private static var checks = 0
    static func require(_ condition: Bool) throws {
        checks += 1
        if !condition { throw Failure() }
    }
    static func main() throws {
        let id = UUID(uuidString: "A1111111-2222-4333-8444-555555555555")!
        let control = ["app", "-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString]
        let openFlag = "-UITestPDFUIKitPicker"
        let copyFlag = "-UITestPDFUIKitCopyPicker"
        func configuration(_ arguments: [String], fixture: UUID? = nil) -> PDFNativePickerExperiment.Configuration? {
            PDFNativePickerExperiment.configuration(arguments: arguments, fixtureNamespace: fixture)
        }
        for flag in [openFlag, copyFlag] {
            let treatment = control + [flag]
            try require(configuration(treatment) == nil)
            try require(configuration(treatment, fixture: UUID()) == nil)
            let rejected: [[String]] = [
                ["app"], [flag],
                treatment.filter { $0 != "-UITestMode" }, treatment.filter { $0 != "-UITestSkillExecution" },
                treatment + ["-UITestMode"], treatment + ["-UITestSkillExecution"],
                treatment + ["-UITestNamespace", id.uuidString], treatment + [flag],
                treatment + ["-LiveModelUITest"], treatment + ["-LiveMCPUITest"],
                Array(control.dropLast()) + ["../personal", flag],
                Array(control.dropLast()) + [id.uuidString.lowercased(), flag],
                ["-UITestMode", "-UITestSkillExecution", flag, "-UITestNamespace"]
            ]
            for arguments in rejected { try require(configuration(arguments, fixture: id) == nil) }
        }
        for flags in [[openFlag, copyFlag], [copyFlag, openFlag], ["-UITestPDFUIKitCopyPicker=1"]] {
            try require(configuration(control + flags, fixture: id) == nil)
        }
        #if DEBUG
        let original = configuration(control, fixture: id)
        let open = configuration(control + [openFlag], fixture: id)
        let copy = configuration(control + [copyFlag], fixture: id)
        try require(original?.mode == .swiftUI && original?.usesUIKit == false)
        try require(original?.source == "swiftui" && original?.mode.asCopy == false)
        try require(open?.mode == .uikitOpen && open?.usesUIKit == true)
        try require(open?.source == "uikit" && open?.mode.asCopy == false)
        try require(copy?.mode == .uikitImportCopy && copy?.usesUIKit == true)
        try require(copy?.source == "uikit-copy" && copy?.mode.asCopy == true)
        try require(open?.namespace == id && copy?.namespace == id)
        print("PASS DEBUG \(checks) checks: namespace gates, mutually exclusive open/copy modes; default stays SwiftUI")
        #else
        try require(configuration(control, fixture: id) == nil)
        try require(configuration(control + [openFlag], fixture: id) == nil)
        try require(configuration(control + [copyFlag], fixture: id) == nil)
        print("PASS Release \(checks) checks: ignores open/copy experiments and mode observation flags")
        #endif
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
        // 74f7b71 assembly: the exact multi-select cell has three Images,
        // including a selection circle. Its native cell is the tap target.
        let multiCell = CGRect(x: 10, y: 212, width: 122, height: 189.7)
        try require(skillPDFMultiSelectionCellIsVisible(multiCell, viewport: viewport, navigation: navigation))
        let clippedViewport = CGRect(x: 0, y: 202, width: 402, height: 180)
        let visibleThumbnail = CGRect(x: 39, y: 216, width: 65, height: 84)
        try require(skillPDFThumbnailIsVisible(visibleThumbnail, cell: multiCell,
            viewport: clippedViewport, navigation: navigation))
        try require(!skillPDFMultiSelectionCellIsVisible(multiCell,
            viewport: clippedViewport, navigation: navigation))
        for invalid in [CGRect.zero, CGRect.infinite, multiCell.offsetBy(dx: 400, dy: 0),
                        multiCell.offsetBy(dx: 0, dy: -30)] {
            try require(!skillPDFMultiSelectionCellIsVisible(invalid, viewport: viewport, navigation: navigation))
        }
        print("PASS bounded Skills Files route: no repeated Browse, real successor progress, local folder and exact-file terminal")
        print("PASS observed PDF thumbnail geometry; reject absent, unrelated, covered and clipped targets")
        print("PASS multi-selection whole-cell geometry; a visible thumbnail alone cannot authorize a clipped cell tap")
    }
}
#else
import XCTest

/// Real native SwiftUI/UIKit Files pickers + real SkillExecutionRuntime/PDFKit. The DEBUG
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

    private enum PickerArm {
        case swiftUI, uikitOpen, uikitImportCopy, userImportCopy
        var launchFlag: String? {
            switch self {
            case .swiftUI, .userImportCopy: return nil
            case .uikitOpen: return "-UITestPDFUIKitPicker"
            case .uikitImportCopy: return "-UITestPDFUIKitCopyPicker"
            }
        }
        var expectedObservation: String? {
            switch self {
            case .swiftUI: return nil
            case .uikitOpen: return "source=uikit mode=open allowsMultipleSelection=false"
            case .uikitImportCopy: return "source=uikit-copy mode=import allowsMultipleSelection=false"
            case .userImportCopy: return "source=user-copy mode=import allowsMultipleSelection=false"
            }
        }
    }

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
        assertNativePDFRead(fixtureWriteMode: nil)
    }

    func testCoordinatedFixtureCreationNativePDFNeedsBothApprovalsAndReturnsActualText() {
        assertNativePDFRead(fixtureWriteMode: "coordinated")
    }

    func testUIKitOpenInPlaceCoordinatedPDFNeedsBothApprovalsAndReturnsActualText() {
        assertNativePDFRead(fixtureWriteMode: "coordinated", picker: .uikitOpen)
    }

    func testUIKitImportCopyCoordinatedPDFNeedsBothApprovalsAndReturnsActualText() {
        // The OS may read/write while importing the selected file. The runtime
        // audit below measures App operations, not provider/system I/O.
        print("SKILL_PICKER_COPY_EXPERIMENT namespace=\(namespace) 系統匯入副本可能先讀寫檔案；App 讀取與 PDF 擷取仍須分別核准。")
        assertNativePDFRead(fixtureWriteMode: "coordinated", picker: .uikitImportCopy)
    }

    func testUserChosenPDFImportCopyNeedsBothApprovalsAndReturnsActualText() {
        // Standard fixture creation and an explicit product UI choice; no
        // launch flag selects the picker mode for this acceptance case.
        assertNativePDFRead(fixtureWriteMode: nil, picker: .userImportCopy)
    }

    func testNativePDFAssemblyReviewsReversedPagesAndExportCancellationPreservesResult() {
        launchPDFScreen(fromCatalog: true, catalogEntry: "catalog.documents.assemble",
                        fixtureIdentifier: "pdfAssembly.uitest.fixture")
        let form = app.collectionViews["pdfAssembly.form"]
        XCTAssertFalse(form.staticTexts["pdfAssembly.source.1"].exists)
        XCTAssertFalse(form.staticTexts["pdfAssembly.result"].exists)
        tap("pdfAssembly.select", scroll: true)
        requireHittable(nativeCancel, timeout: 45)
        chooseSyntheticPDFInPresentedPicker(selected: form.staticTexts["pdfAssembly.source.1"],
                                            expectedLabel: "來源 1：" + filename,
                                            allowsMultipleSelection: true)
        XCTAssertFalse(form.staticTexts["pdfAssembly.receipt.1"].exists,
                       "Native selection must not approve reading the source.")
        XCTAssertFalse(form.buttons["pdfAssembly.assemble"].exists)
        tap("pdfAssembly.read.1", scroll: true)
        let receipt = form.staticTexts["pdfAssembly.receipt.1"]
        revealLearningElement(receipt, in: app, visibility: .readableText)
        XCTAssertTrue(receipt.waitForExistence(timeout: 15))
        XCTAssertNotNil(receipt.label.range(of: "^已讀取 2 頁，[1-9][0-9]* 位元組$", options: .regularExpression))
        XCTAssertFalse(form.buttons["pdfAssembly.read.1"].exists)
        XCTAssertFalse(form.staticTexts["pdfAssembly.result"].exists,
                       "Reading approval must not authorize PDF assembly.")

        // SwiftUI's vertical TextField may expose a TextField or TextView.
        // Bind to the exact identifier and require an actual editable AX role.
        let order = form.descendants(matching: .any).matching(identifier: "pdfAssembly.order").firstMatch
        revealLearningElement(order, in: app)
        XCTAssertTrue(order.elementType == .textField || order.elementType == .textView)
        requireHittable(order)
        XCTAssertEqual(order.value as? String, "1:1-2")
        order.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        order.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: "1:1-2".count))
        wait(order, "value == %@", "")
        order.typeText("1:2,1:1")
        wait(order, "value == %@", "1:2,1:1")
        tap("pdfAssembly.keyboardDone")
        tap("pdfAssembly.prepare", scroll: true)
        let count = form.staticTexts["pdfAssembly.plan.count"]
        revealLearningElement(count, in: app, visibility: .readableText)
        XCTAssertTrue(count.waitForExistence(timeout: 15))
        XCTAssertEqual(count.label, "共 2 頁")
        for (index, label) in ["第 1 頁 ← 來源 1 第 2 頁", "第 2 頁 ← 來源 1 第 1 頁"].enumerated() {
            let row = form.staticTexts["pdfAssembly.plan.page.\(index + 1)"]
            revealLearningElement(row, in: app, visibility: .readableText)
            XCTAssertEqual(row.label, label)
        }
        XCTAssertFalse(form.staticTexts["pdfAssembly.result"].exists,
                       "Reviewing an exact page order must not produce a PDF before approval.")
        tap("pdfAssembly.assemble", scroll: true)
        let result = form.staticTexts["pdfAssembly.result"]
        revealLearningElement(result, in: app, visibility: .readableText)
        XCTAssertTrue(result.waitForExistence(timeout: 15))
        let originalResult = result.label
        XCTAssertNotNil(originalResult.range(of: "^已產生 2 頁，[1-9][0-9]* 位元組$", options: .regularExpression))
        XCTAssertFalse(form.buttons["pdfAssembly.assemble"].exists)
        tap("pdfAssembly.export", scroll: true)
        requireHittable(nativeExportConfirmation)
        cancelNativeExporter()
        guard waitForNativeExporterDismissal() else { return }
        let exportStatus = form.staticTexts["pdfAssembly.export.status"]
        revealLearningElement(exportStatus, in: app, visibility: .readableText)
        wait(exportStatus, "label == %@", "已取消儲存，新 PDF 仍保留。")
        revealLearningElement(result, in: app, visibility: .readableText)
        XCTAssertEqual(result.label, originalResult)
        let export = form.buttons["pdfAssembly.export"]
        revealLearningElement(export, in: app)
        requireHittable(export)
        XCTAssertFalse(nativeCancel.exists)
    }

    private func assertNativePDFRead(fixtureWriteMode: String?, picker: PickerArm = .swiftUI) {
        launchFixture(fromCatalog: true, fixtureWriteMode: fixtureWriteMode, picker: picker)
        chooseSyntheticPDF(picker: picker)
        assertAudit(selections: 1, reads: 0, extractionAttempts: 0, results: 0)
        if let expectedObservation = picker.expectedObservation {
            XCTAssertEqual(app.staticTexts["skillExecution.uitest.fixture"].value as? String,
                           expectedObservation,
                           "The actual public UIKit picker must match this arm's mode and allow only one file.")
        }
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
        // The text follows the summary in the same result section. Keep this
        // viewport instead of returning to the intro and searching down again.
        revealLearningElement(output, in: app, visibility: .readableText)
        let extractedText = output.label
        XCTAssertTrue(extractedText.contains("--- page 1 ---"))
        XCTAssertTrue(extractedText.contains("--- page 2 ---"))
        XCTAssertTrue(extractedText.contains("WOOW_SKILL_PDF_PAGE_1"))
        XCTAssertTrue(extractedText.contains("WOOW_SKILL_PDF_PAGE_2"))
        XCTAssertTrue(extractedText.contains(namespace), "Must extract this namespace's actual selected PDF.")
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
        let exported = nativeFileList.cells.staticTexts.matching(exportedNames).firstMatch
        let exportedCell = nativeFileList.cells.matching(exportedNames).firstMatch
        for _ in 0..<10 {
            if exported.exists || exportedCell.exists { break }
            guard nativeFileList.exists, nativeFileList.isHittable else {
                XCTFail("Native destination must expose its file list."); return
            }
            nativeFileList.swipeUp()
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
        nativeFilesNavigation.buttons.matching(NSPredicate(format: "label IN %@",
            ["儲存", "Save", "匯出", "Export", "搬移", "移動", "Move"])).firstMatch
    }

    private var nativeFilesNavigation: XCUIElement {
        app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
    }

    private var nativeFileList: XCUIElement { app.collectionViews["File View"] }

    private func cancelNativeExporter() {
        // Return only through known local ancestors to the native Cancel button.
        // Each label is tapped at most once; never save or dismiss app state to
        // simulate cancellation. Callers still verify the real cancel callback.
        let navigation = nativeFilesNavigation
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
        guard waitForNativeExporterDismissal() else { return }
        let status = executionForm.staticTexts["skillExecution.export.status"]
        scrollExecutionToTop()
        revealLearningElement(status, in: app, visibility: .readableText)
        wait(status, "label == %@", expected)
        XCTAssertFalse(nativeCancel.exists)
    }

    private func waitForNativeExporterDismissal() -> Bool {
        // Save can return while Files is still saving. Wait for dismissal before
        // any gesture can drag that sheet instead of scrolling the app form.
        // This readiness wait remains inside the case's 240-second allowance.
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: nativeFilesNavigation)
        guard XCTWaiter.wait(for: [dismissed], timeout: 30) == .completed else {
            XCTFail("Native Files exporter must dismiss within 30 seconds before inspecting the execution form.")
            return false
        }
        return true
    }

    private func launchFixture(fromCatalog: Bool, fixtureWriteMode: String? = nil, picker: PickerArm = .swiftUI) {
        launchPDFScreen(fromCatalog: fromCatalog, fixtureWriteMode: fixtureWriteMode, picker: picker)
        assertAudit(selections: 0, reads: 0, extractionAttempts: 0, results: 0)
    }

    private func launchPDFScreen(fromCatalog: Bool, fixtureWriteMode: String? = nil, picker: PickerArm = .swiftUI,
                                 catalogEntry: String = "catalog.documents.execute",
                                 fixtureIdentifier: String = "skillExecution.uitest.fixture") {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestSkillExecution"]
        if let fixtureWriteMode { app.launchArguments += ["-UITestSkillFixtureWriteMode", fixtureWriteMode] }
        if let flag = picker.launchFlag { app.launchArguments.append(flag) }
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
            tap(catalogEntry, scroll: true)
        } else { tap("skills.documents.execute", scroll: true) }
        let fixture = app.staticTexts[fixtureIdentifier]
        revealLearningElement(fixture, in: app, visibility: .readableText)
        XCTAssertEqual(fixture.label, "測試文件已建立：" + filename,
                       "DEBUG seeder must create only this namespace's real PDF.")
    }

    private func openNativePicker(picker: PickerArm = .swiftUI) {
        let presentationTimeout: TimeInterval
        if case .userImportCopy = picker {
            // 74f7b71 SE: the import controller appeared immediately, but Files
            // rendered its first controls about 48–50 seconds later. Only this
            // initial presentation gets 60 seconds within the unchanged 240.
            presentationTimeout = 60
            XCTAssertFalse(app.launchArguments.contains { $0.hasPrefix("-UITestPDFUIKit") },
                           "The user entry must select import-copy without a picker experiment flag.")
            XCTAssertFalse(app.launchArguments.contains("-UITestSkillFixtureWriteMode"))
            tap("skillExecution.importCopy.options", scroll: true)
            let notice = app.staticTexts["skillExecution.importCopy.notice"]
            revealLearningElement(notice, in: app, visibility: .readableText)
            XCTAssertEqual(notice.label,
                           "選檔後，系統會先建立暫存副本並占用儲存空間，不會更動原檔。App 讀取與後續擷取仍需分別核准。App 最多讀取 10 MiB；系統複製的大小不受此上限限制。")
            let copy = app.buttons["skillExecutionImportPDFCopy"]
            // The copy button follows its disclosure. Keep this viewport and
            // retain the same visibility/hittability rules as other controls.
            revealLearningElement(copy, in: app)
            requireHittable(copy)
            copy.tap()
        } else {
            presentationTimeout = 45
            tap("skillExecutionSelectPDF", scroll: true)
        }
        // iOS 17 evidence: Files initialization can exhaust the old 15-second
        // readiness budget. Wait for the actual native control once;
        // do not retap the launch button or bypass the document picker.
        requireHittable(nativeCancel, timeout: presentationTimeout)
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].isHittable,
                       "Native picker must be shown before any runtime plan is approved.")
    }

    private var nativeCancel: XCUIElement {
        nativeFilesNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
    }

    private func chooseSyntheticPDF(picker: PickerArm = .swiftUI) {
        openNativePicker(picker: picker)
        chooseSyntheticPDFInPresentedPicker(selected: app.staticTexts["skillExecution.filename"], expectedLabel: filename)
    }

    private func chooseSyntheticPDFInPresentedPicker(selected: XCUIElement, expectedLabel: String,
                                                     allowsMultipleSelection: Bool = false) {
        guard let file = navigateNativeFiles(exporting: false) else { return }
        let list = app.collectionViews["File View"]
        let navigation = app.navigationBars["FullDocumentManagerViewControllerNavigationBar"]
        if allowsMultipleSelection {
            // 74f7b71 actual multi-picker AX: three Images, including a circle.
            // Select the unique exact-name native cell, not an arbitrary Image.
            // Whole-cell visibility is stricter than the single-picker target.
            let matches = list.cells.matching(NSPredicate(format: "identifier == %@", stem + ", pdf"))
            let exactFile = matches.firstMatch
            guard list.exists, navigation.exists, matches.count == 1,
                  exactFile.staticTexts.matching(selectedFileNames).count == 1,
                  exactFile.isEnabled, exactFile.isHittable,
                  skillPDFMultiSelectionCellIsVisible(exactFile.frame,
                      viewport: list.frame.intersection(app.frame), navigation: navigation.frame) else {
                recordPickerDiagnostics(stage: "exact-multi-selection-cell-not-visible")
                XCTFail("Multi-selection requires one fully visible, hittable Files cell with this exact PDF filename.")
                return
            }
            exactFile.tap()
        } else {
            // Single-picker evidence: the thumbnail's AX Image is not hittable,
            // and a whole-cell tap can land on its filename. Keep this route.
            let images = file.images.allElementsBoundByIndex
            guard images.count == 1, let thumbnail = images.first, thumbnail.exists,
                  file.isEnabled, file.isHittable, list.exists, navigation.exists,
                  skillPDFThumbnailIsVisible(thumbnail.frame, cell: file.frame,
                      viewport: list.frame.intersection(app.frame), navigation: navigation.frame) else {
                recordPickerDiagnostics(stage: "exact-thumbnail-not-visible")
                XCTFail("The exact selected PDF must expose one fully visible thumbnail inside its Files cell.")
                return
            }
            thumbnail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        if allowsMultipleSelection {
            // Assembly uses a multi-select importer. Files may either return
            // immediately or enable its own confirmation after selection.
            // Wait for actual readiness; never retap the file or a disabled
            // confirmation. Both waits remain inside the same 240-second case.
            // 30bcaf1 iOS 18.5 AX exposes this confirmation as「打開」.
            // Keep the query inside the native Files navigation bar.
            let open = nativeFilesNavigation.buttons.matching(
                NSPredicate(format: "label IN %@", ["打開", "開啟", "Open"])).firstMatch
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                selected.exists || (open.exists && open.isEnabled && open.isHittable)
            }, object: nil)
            guard XCTWaiter.wait(for: [ready], timeout: 15) == .completed else {
                recordPickerDiagnostics(stage: "multi-selection-not-ready")
                XCTFail("Files must deliver the selected source or expose an enabled, hittable Open confirmation within 15 seconds.")
                return
            }
            // Auto-dismissal can race this check. If Open has disappeared,
            // require the real callback below instead of tapping another item.
            if !selected.exists && open.exists && open.isEnabled && open.isHittable {
                open.tap()
            }
        } else {
            if !selected.waitForExistence(timeout: 3), let open = knownButton(["開啟", "Open", "完成", "Done"]) { open.tap() }
        }
        let received = selected.waitForExistence(timeout: 15)
        if !received { recordPickerDiagnostics(stage: "selection-not-delivered") }
        XCTAssertTrue(received, "Files selection must reach the real importer callback.")
        XCTAssertEqual(selected.label, expectedLabel)
        XCTAssertFalse(nativeCancel.exists, "The document picker must have dismissed.")
    }

    private let applicationLabels = ["渥屋助理", "WoowAssistant"]
    private let localLabels = ["我的 iPhone", "我的iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]
    private let browseLabels = ["瀏覽", "Browse"]
    private let locationsLabels = ["位置", "Locations"]
    private var selectedFileNames: NSPredicate { NSPredicate(format: "label IN %@", [filename, stem]) }
    private var localAppFolderTitle: XCUIElement {
        let title = nativeFilesNavigation.staticTexts.matching(NSPredicate(format: "label IN %@", applicationLabels)).firstMatch
        if title.exists { return title }
        // Actual iOS 18 screenshot/AX: the folder title is an actions-menu button,
        // not a StaticText. This proves the destination without opening that menu.
        return nativeFilesNavigation.buttons.matching(NSPredicate(format: "label == %@", "渥屋助理, 「動作」選單")).firstMatch
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

    private var executionForm: XCUIElement { app.collectionViews["skillExecution.form"] }

    private func scrollExecutionToTop() {
        // Begin at a known anchor so virtualized rows above the viewport are
        // never searched by swiping farther down. Scrolling never chooses files.
        // Actual SE/current AX exposes a CollectionView with this identifier.
        // e2b's global intro lookup waited 122s on remote Files AX after Save.
        let form = executionForm
        let intro = form.staticTexts["skillExecution.intro"]
        for _ in 0..<6 {
            if executionIntroIsVisible(intro, in: form) { return }
            if form.exists { form.swipeDown() } else { app.swipeDown() }
        }
        XCTFail("PDF execution form must expose its first row within bounded scrolling.")
    }

    private func executionIntroIsVisible(_ intro: XCUIElement, in form: XCUIElement) -> Bool {
        // copy21 spent 43s in this static text's hit-test after Files dismissed.
        // The anchor is never tapped: require its whole frame in the unobscured
        // Form instead. Actual approval buttons still require hittability.
        let titleBar = app.navigationBars["執行 PDF 技能"]
        guard form.exists, intro.exists, titleBar.exists else { return false }
        let bounds = form.frame.intersection(app.frame)
        let top = max(bounds.minY, titleBar.frame.maxY)
        var bottom = bounds.maxY
        let navigation = app.buttons["navigation.chat"]
        if navigation.exists { bottom = min(bottom, navigation.frame.minY) }
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
        guard bottom > top else { return false }
        let viewport = CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
        return learningFrameIsVisible(intro.frame, in: viewport.insetBy(dx: 0, dy: 4), visibility: .fullyVisible)
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

private func skillPDFMultiSelectionCellIsVisible(_ cell: CGRect, viewport: CGRect, navigation: CGRect) -> Bool {
    skillPDFThumbnailIsVisible(cell, cell: cell, viewport: viewport, navigation: navigation)
}
