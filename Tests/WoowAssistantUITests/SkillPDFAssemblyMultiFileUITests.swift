#if SKILL_ASSEMBLY_PAIR_CHECKS
import Foundation
#if DEBUG
import PDFKit
#if SKILL_ASSEMBLY_PAIR_MODULE
import AssistantSkills
#endif
#endif

/// Compiles with actual AssistantSkills sources and the production DEBUG seeder.
/// This host check never claims to exercise the native picker or exporter.
@main struct SkillAssemblyPairChecks {
    struct Failure: Error { let code: String }
    static var count = 0
    static func require(_ value: Bool, _ code: String) throws {
        count += 1
        if !value { throw Failure(code: code) }
    }
    static func main() async throws {
        let id = UUID()
        let flag = "-UITestSkillAssemblyPair"
        let args = ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString, flag]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("assembly-pair-" + id.uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var touched = false
        let invalid: [[String]] = [args, args + [flag], args + ["-LiveModelUITest"], args + ["-LiveMCPUITest"],
                       args + ["-UITestPDFAssemblyUIKitOpen"], args + ["-UITestSkillFixtureWriteMode", "coordinated"],
                       args + ["-UITestNamespace", id.uuidString], args + [flag + "=1"],
                       args.filter { $0 != "-UITestMode" }, args.filter { $0 != "-UITestSkillExecution" },
                       args.map { $0 == id.uuidString ? "../outside" : $0 },
                       args.map { $0 == id.uuidString ? id.uuidString.lowercased() : $0 }]
        // The existing single/Live seeder rejects every pair flag before IO.
        for argument in invalid {
            touched = false
            do {
                let ignored = try SkillExecutionUITestSupport.seedIfRequested(arguments: argument) {
                    touched = true; throw Failure(code: "directory_touched")
                }
                #if DEBUG
                try require(ignored == nil, "inactive_single_seeder_declines_pair")
                #else
                try require(ignored == nil, "release_ignores_pair")
                #endif
            } catch SkillExecutionUITestSupport.Failure.invalidNamespace { }
            try require(!touched, "single_seeder_no_pair_io")
        }
        #if DEBUG
        for argument in invalid.dropFirst() {
            touched = false
            do {
                _ = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested(arguments: argument) {
                    touched = true; throw Failure(code: "directory_touched")
                }
                throw Failure(code: "invalid_gate_accepted")
            } catch SkillExecutionUITestSupport.Failure.invalidNamespace { }
            try require(!touched, "pair_gate_before_io")
        }
        let inactive = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested(arguments: []) {
            throw Failure(code: "inactive_io")
        }
        try require(inactive == nil, "inactive_pair")
        guard let pair = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested(arguments: args, documentsDirectory: { directory }) else {
            throw Failure(code: "missing_pair")
        }
        try require(pair.sources.count == 2 && Set(pair.sources.map(\.sha256)).count == 2, "distinct_real_inputs")
        let originals = try pair.sources.map { try Data(contentsOf: $0.url) }
        for bytes in originals { try require(PDFDocument(data: bytes)?.pageCount == 2 && bytes.count < 128 * 1024, "two_bounded_pages") }
        let again = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested(arguments: args, documentsDirectory: { directory })!
        try require(again.sources.map(\.sha256) == pair.sources.map(\.sha256), "idempotent_seed")
        let catalog = try BundledSkillCatalog.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        // Deliberately reverse the two selected URLs: source numbers follow the
        // actual returned filenames, never an assumption about picker ordering.
        let runtime = try SkillPDFAssemblyRuntime(selectedFiles: pair.sources.reversed().map {
            try SkillExecutionSelectedFile(userSelectedURL: $0.url)
        }, catalog: catalog)
        let sources = runtime.sources
        try require(await runtime.receipts.isEmpty, "selection_does_not_approve_read")
        _ = try await runtime.read(runtime.authorizeRead(sourceID: sources[0].id))
        try require(await runtime.receipts.count == 1, "first_read_does_not_approve_second")
        do {
            _ = try await runtime.prepare(orderText: "2:2,1:1,2:1")
            throw Failure(code: "unread_second_source_accepted")
        } catch SkillExecutionError.approvalRequired { count += 1 }
        _ = try await runtime.read(runtime.authorizeRead(sourceID: sources[1].id))
        let receipts = await runtime.receipts
        try require(receipts.count == 2, "separate_actual_reads")
        let plan = try await runtime.prepare(orderText: "2:2,1:1,2:1")
        try require(!plan.grantsAuthorization && plan.order.count == 3, "review_not_assembly_approval")
        let output = try await runtime.assemble(runtime.authorizeAssembly(planID: plan.id))
        let digests = Dictionary(uniqueKeysWithValues: receipts.map { ($0.source.filename, $0.sha256) })
        func observe(_ data: Data, _ hashes: [String: String]? = nil) -> String {
            SkillExecutionUITestSupport.assemblyPairOutputObservation(data, receiptDigests: hashes ?? digests, fixture: pair)
        }
        let positive = observe(output.data)
        try require(positive == "pair=verified pages=A2,B1,A1 originals=unchanged sha256=" + output.sha256, "actual_native_interleaving")
        try require(observe(output.data, [:]) == "pair=failed", "no_receipt_rejected")
        var badHashes = digests; badHashes[pair.sources[0].filename] = pair.sources[1].sha256
        try require(observe(output.data, badHashes) == "pair=failed", "wrong_source_digest_rejected")
        try require(observe(Data()) == "pair=failed", "empty_rejected")
        try require(observe(Data(repeating: 0, count: 20 * 1024 * 1024 + 1)) == "pair=failed", "oversize_rejected")
        let shuffled = PDFDocument(data: output.data)!
        shuffled.exchangePage(at: 0, withPageAt: 1)
        try require(observe(shuffled.dataRepresentation()!) == "pair=failed", "actual_wrong_order_rejected")
        let duplicated = PDFDocument(data: output.data)!
        duplicated.removePage(at: 1)
        duplicated.insert(PDFDocument(data: output.data)!.page(at: 0)!.copy() as! PDFPage, at: 1)
        try require(observe(duplicated.dataRepresentation()!) == "pair=failed", "actual_missing_second_source_rejected")
        for (source, original) in zip(pair.sources, originals) {
            try require(try Data(contentsOf: source.url) == original, "originals_unchanged_after_assembly")
        }
        let sentinel = Data("synthetic sentinel, must not overwrite".utf8)
        try sentinel.write(to: pair.sources[0].url)
        try require(observe(output.data) == "pair=failed", "changed_original_rejected")
        do {
            _ = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested(arguments: args, documentsDirectory: { directory })
            throw Failure(code: "existing_invalid_overwritten")
        } catch SkillExecutionUITestSupport.Failure.existingFile { count += 1 }
        try require(try Data(contentsOf: pair.sources[0].url) == sentinel, "invalid_original_preserved")
        let target = directory.appendingPathComponent("sentinel.pdf")
        try sentinel.write(to: target)
        try FileManager.default.removeItem(at: pair.sources[0].url)
        try FileManager.default.createSymbolicLink(at: pair.sources[0].url, withDestinationURL: target)
        try require(observe(output.data) == "pair=failed", "symlink_original_rejected")
        try require(try Data(contentsOf: target) == sentinel, "link_target_unchanged")
        #endif
        print("PAIR_CHECKS passed=\(count) nativePicker=false")
    }
}
#else
import XCTest
import CoreGraphics

@MainActor final class SkillPDFAssemblyMultiFileUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private var form: XCUIElement { app.collectionViews["pdfAssembly.form"] }
    private var filesNavigation: XCUIElement { app.navigationBars["FullDocumentManagerViewControllerNavigationBar"] }
    private var filesList: XCUIElement { app.collectionViews["File View"] }
    private let localLabels = ["我的 iPhone", "我的iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]
    private let appLabels = ["渥屋助理", "WoowAssistant"]
    private var cancel: XCUIElement { filesNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch }
    private func filename(_ role: String) -> String { "SkillAssembly-\(role)-\(namespace).pdf" }

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The synthetic two-file fixture requires an isolated simulator.")
        #endif
        continueAfterFailure = false
        executionTimeAllowance = 300 // New larger case; old single-file cases stay at 240.
    }
    override func tearDownWithError() throws { app.terminate() }

    func testUserChosenCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages() {
        runTwoDistinctPDFAssembly(directoryCoordinated: false)
    }

    func testDirectoryCoordinatedFixtureCopyAddsTwoDistinctPDFsAndInterleavesApprovedPages() {
        runTwoDistinctPDFAssembly(directoryCoordinated: true)
    }

    private func runTwoDistinctPDFAssembly(directoryCoordinated: Bool) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
            "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestSkillExecution", "-UITestSkillAssemblyPair"]
        if directoryCoordinated {
            app.launchArguments.append("-UITestSkillAssemblyPairDirectoryCoordinatedCreation")
        }
        app.launchEnvironment = [:]; app.launch()
        tapFixed("navigation.memory")
        XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: 15))
        tapFixed("memory.segment.skills")
        let catalog = app.buttons["skills.catalog.open"]
        revealLearningElement(catalog, in: app); ready(catalog); catalog.tap()
        XCTAssertTrue(app.staticTexts["catalog.count"].waitForExistence(timeout: 10))
        let search = app.textFields["catalog.search"]
        ready(search); search.tap(); search.typeText("documents\n")
        predicate(search, "value == %@", "documents")
        for id in ["catalog.entry.documents", "catalog.documents.assemble"] {
            let button = app.buttons[id]; revealLearningElement(button, in: app); ready(button); button.tap()
        }
        reveal(form.staticTexts["pdfAssembly.uitest.pair"], reading: true)
        XCTAssertEqual(form.staticTexts["pdfAssembly.uitest.pair"].label, "測試雙檔已建立")
        let creation = directoryCoordinated
            ? "creation=directoryCoordinated coordinationAttempts=1 accessorCalls=1 createdFiles=2 existingFiles=0"
            : "creation=direct coordinationAttempts=0 accessorCalls=0 createdFiles=2 existingFiles=0"
        XCTAssertEqual(form.staticTexts["pdfAssembly.uitest.pair"].value as? String, "callbacks=0 sources=0 " + creation)
        XCTAssertFalse(form.staticTexts["pdfAssembly.result"].exists)
        let notice = form.staticTexts["pdfAssembly.importCopy.notice"]
        reveal(notice, reading: true); XCTAssertTrue(notice.label.contains("系統會在你選檔時建立副本"))
        tapForm("pdfAssembly.importCopy")
        ready(cancel, timeout: 45)
        chooseOneNativeFile("A", index: 1)
        XCTAssertEqual(form.staticTexts["pdfAssembly.source.1"].label, "來源 1：" + filename("A"))
        XCTAssertFalse(form.staticTexts["pdfAssembly.receipt.1"].exists)
        XCTAssertFalse(form.staticTexts["pdfAssembly.source.2"].exists)
        let addNotice = form.staticTexts["pdfAssembly.add.notice"]
        reveal(addNotice, reading: true); XCTAssertTrue(addNotice.label.contains("重新核准各文件"))
        tapForm("pdfAssembly.addCopy") // A second deliberate action, never automatic reopening.
        ready(cancel, timeout: 45)
        chooseOneNativeFile("B", index: 2)
        XCTAssertEqual(form.staticTexts["pdfAssembly.source.1"].label, "來源 1：" + filename("A"))
        XCTAssertEqual(form.staticTexts["pdfAssembly.uitest.pair"].value as? String, "callbacks=2 sources=2")

        var indices: [String: Int] = [:]
        for index in 1...2 {
            let source = form.staticTexts["pdfAssembly.source.\(index)"]
            reveal(source, reading: true)
            let label = source.label
            let matches = ["A", "B"].filter { label == "來源 \(index)：" + filename($0) }
            XCTAssertEqual(matches.count, 1, "Both actual callback filenames must match the two distinct fixture PDFs.")
            guard let role = matches.first else { return }
            XCTAssertNil(indices.updateValue(index, forKey: role), "The picker must not return one source twice.")
            XCTAssertEqual(source.value as? String,
                "source=user-copy mode=import allowsMultipleSelection=false callbacks=1 outcome=one sources=2")
        }
        guard let a = indices["A"], let b = indices["B"], a != b else {
            XCTFail("The two actual callbacks must retain both distinct PDFs."); return
        }
        XCTAssertFalse(cancel.exists)
        XCTAssertFalse(form.staticTexts["pdfAssembly.receipt.1"].exists)
        XCTAssertFalse(form.staticTexts["pdfAssembly.receipt.2"].exists)
        // These are the real per-source consent buttons, not an invented dialog.
        for (step, index) in [a, b].enumerated() {
            tapForm("pdfAssembly.read.\(index)")
            let receipt = form.staticTexts["pdfAssembly.receipt.\(index)"]
            reveal(receipt, reading: true)
            XCTAssertTrue(validReceipt(receipt.label, pages: 2, prefix: "已讀取", limit: 10 * 1024 * 1024))
            XCTAssertEqual(receipt.value as? String, "sources=2 reads=\(step + 1)")
            XCTAssertFalse(form.buttons["pdfAssembly.read.\(index)"].exists)
            XCTAssertFalse(form.staticTexts["pdfAssembly.result"].exists)
            if step == 0 {
                let remaining = form.buttons["pdfAssembly.read.\(b)"]
                reveal(remaining); ready(remaining)
                XCTAssertFalse(form.buttons["pdfAssembly.assemble"].exists)
            }
        }
        let order = form.descendants(matching: .any).matching(identifier: "pdfAssembly.order").firstMatch
        reveal(order); ready(order)
        XCTAssertTrue(order.elementType == .textField || order.elementType == .textView)
        XCTAssertEqual(order.value as? String, "1:1-2,2:1-2")
        let desired = "\(a):2,\(b):1,\(a):1"
        order.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        reveal(order)
        order.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.5)).press(forDuration: 1)
        let selectAll = NSPredicate(format: "label IN %@", ["Select All", "全選", "全选"])
        func menu() -> XCUIElement? {
            firstReady(app.menuItems.matching(selectAll)) ?? firstReady(app.buttons.matching(selectAll))
        }
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in menu() != nil }, object: nil)], timeout: 5), .completed)
        guard let selection = menu() else { XCTFail("Native Select All must appear for the exact order field."); return }
        selection.tap(); order.typeText(XCUIKeyboardKey.delete.rawValue)
        predicate(order, "value == %@", "")
        order.typeText(desired); predicate(order, "value == %@", desired)
        tapFixed("pdfAssembly.keyboardDone")
        tapForm("pdfAssembly.prepare")
        let count = form.staticTexts["pdfAssembly.plan.count"]
        reveal(count, reading: true); XCTAssertEqual(count.label, "共 3 頁")
        for (offset, mapping) in [(a, 2), (b, 1), (a, 1)].enumerated() {
            let row = form.staticTexts["pdfAssembly.plan.page.\(offset + 1)"]
            reveal(row, reading: true)
            XCTAssertEqual(row.label, "第 \(offset + 1) 頁 ← 來源 \(mapping.0) 第 \(mapping.1) 頁")
        }
        XCTAssertFalse(form.staticTexts["pdfAssembly.result"].exists)
        tapForm("pdfAssembly.assemble")
        let result = form.staticTexts["pdfAssembly.result"]
        reveal(result, reading: true)
        let resultLabel = result.label, resultEvidence = result.value as? String ?? ""
        XCTAssertTrue(validReceipt(resultLabel, pages: 3, prefix: "已產生", limit: 20 * 1024 * 1024))
        XCTAssertNotNil(resultEvidence.range(of: "^pair=verified pages=A2,B1,A1 originals=unchanged sha256=[0-9a-f]{64}$", options: .regularExpression),
                        "Verify actual output PDF page markers, source receipt digests and unchanged synthetic originals.")
        XCTAssertFalse(form.buttons["pdfAssembly.assemble"].exists)
        tapForm("pdfAssembly.export")
        ready(filesNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["儲存", "Save", "匯出", "Export", "搬移", "移動", "Move"])).firstMatch)
        cancelNativeExport()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: filesNavigation)], timeout: 30), .completed)
        let status = form.staticTexts["pdfAssembly.export.status"]
        reveal(status, reading: true); predicate(status, "label == %@", "已取消儲存，新 PDF 仍保留。")
        reveal(result, reading: true)
        XCTAssertEqual(result.label, resultLabel); XCTAssertEqual(result.value as? String, resultEvidence)
        let export = form.buttons["pdfAssembly.export"]; reveal(export); ready(export)
        XCTAssertFalse(cancel.exists)
    }

    private func navigateToSyntheticFiles(_ role: String = "A") {
        // Known local locations only; no arbitrary provider enumeration, URLs,
        // injected selection, retapping files, or picker re-presentation.
        var used = Set<String>()
        func candidate(_ key: String) -> XCUIElement? {
            switch key {
            case "app": return namedItem(appLabels)
            case "local": return namedItem(localLabels)
            case "back": return firstReady(filesNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["瀏覽", "Browse", "位置", "Locations"])))
            case "browseTab":
                let item = firstReady(app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["瀏覽", "Browse"])))
                return item?.isSelected == false ? item : nil
            default: return firstReady(app.buttons.matching(NSPredicate(format: "label IN %@", ["瀏覽", "Browse", "位置", "Locations"])))
            }
        }
        for _ in 0..<6 {
            if exactCell(role).exists { break }
            // Scroll only inside the known local app folder, never through an
            // arbitrary provider tree. Two synthetic names are the sole target.
            if filesNavigation.staticTexts.matching(NSPredicate(format: "label IN %@", appLabels)).firstMatch.exists
                || filesNavigation.buttons["渥屋助理, 「動作」選單"].exists {
                for _ in 0..<3 {
                    if exactCell(role).exists { break }
                    guard filesList.exists else { XCTFail("Known app folder must expose Files list."); return }
                    filesList.swipeUp()
                }
                break
            }
            guard let next = ["app", "local", "back", "browseTab", "browseButton"].lazy.compactMap({ key -> (String, XCUIElement)? in
                guard !used.contains(key), let item = candidate(key) else { return nil }
                return (key, item)
            }).first else { XCTFail("Files must expose a known local route to the exact two synthetic names."); return }
            used.insert(next.0); let attempted = used; next.1.tap()
            let successors = next.0 == "app" ? [] : next.0 == "local" ? ["app"] : ["app", "local"]
            let progress = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.exactCell(role).exists || successors.contains { !attempted.contains($0) && candidate($0) != nil }
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [progress], timeout: 12), .completed,
                           "Require a real known successor; never tap an unchanged Browse route twice.")
        }
    }

    private func chooseOneNativeFile(_ role: String, index: Int) {
        navigateToSyntheticFiles(role)
        let cell = exactCell(role), stem = String(filename(role).dropLast(4))
        XCTAssertEqual(filesList.cells.matching(NSPredicate(format: "identifier == %@", stem + ", pdf")).count, 1)
        XCTAssertEqual(cell.staticTexts.matching(NSPredicate(format: "label IN %@", [filename(role), stem])).count, 1)
        ready(cell)
        let viewport = filesList.frame.intersection(app.frame)
        // Use the exact single-file cell's sole thumbnail. A filename tap
        // need not open the document in the native Files presentation.
        let images = cell.images.allElementsBoundByIndex
        XCTAssertEqual(images.count, 1)
        guard let thumbnail = images.first else { return }
        let frame = thumbnail.frame
        XCTAssertTrue(!frame.isEmpty && !frame.isInfinite && cell.frame.contains(frame)
                      && viewport.contains(frame) && !filesNavigation.frame.intersects(frame))
        thumbnail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let sourceID = "pdfAssembly.source.\(index)"
        let expectedLabel = "來源 \(index)：" + filename(role)
        // In 8c's iOS 17 run, A was accepted while a full hierarchy query
        // waited on the dismissed Files service. Restrict this transition
        // lookup to the exact source and filename; check uniqueness below.
        func receivedSource() -> XCUIElement {
            app.staticTexts.matching(NSPredicate(format: "identifier == %@ AND label == %@",
                                                 sourceID, expectedLabel)).firstMatch
        }
        func openButton() -> XCUIElement {
            filesNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["打開", "開啟", "Open"])).firstMatch
        }
        let progress = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            if receivedSource().exists { return true }
            let open = openButton()
            return open.exists && open.isEnabled && open.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [progress], timeout: 15), .completed)
        if !receivedSource().exists {
            let open = openButton()
            if open.exists && open.isEnabled && open.isHittable { open.tap() }
        }
        XCTAssertTrue(receivedSource().waitForExistence(timeout: 15))
        let received = form.staticTexts.matching(identifier: sourceID)
        XCTAssertEqual(received.count, 1)
        XCTAssertEqual(received.element.label, expectedLabel)
        XCTAssertFalse(cancel.exists)
    }

    private func exactCell(_ role: String) -> XCUIElement {
        filesList.cells.matching(NSPredicate(format: "identifier == %@", String(filename(role).dropLast(4)) + ", pdf")).firstMatch
    }
    private func namedItem(_ labels: [String]) -> XCUIElement? {
        let match = NSPredicate(format: "label IN %@", labels)
        return firstReady(app.cells.matching(match)) ?? firstReady(app.buttons.matching(match))
            ?? firstReady(app.staticTexts.matching(match))
    }
    private func firstReady(_ query: XCUIElementQuery) -> XCUIElement? {
        query.allElementsBoundByIndex.prefix(6).first { $0.exists && $0.isEnabled && $0.isHittable }
    }
    private func cancelNativeExport() {
        var visited = Set<String>()
        for attempt in 0...3 {
            if cancel.exists { ready(cancel); cancel.tap(); return }
            guard attempt < 3, let back = firstReady(filesNavigation.buttons.matching(
                NSPredicate(format: "label IN %@", localLabels + ["瀏覽", "Browse", "位置", "Locations"]))),
                  visited.insert(back.label).inserted else { XCTFail("Native exporter must expose Cancel through known local ancestors."); return }
            let label = back.label; back.tap()
            let progress = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                self.cancel.exists || !self.filesNavigation.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [progress], timeout: 12), .completed)
        }
    }
    private func tapFixed(_ id: String) {
        let button = app.buttons[id]; ready(button)
        XCTAssertTrue(!button.frame.isEmpty && app.frame.contains(button.frame)); button.tap()
    }
    private func tapForm(_ id: String) { let button = form.buttons[id]; reveal(button); ready(button); button.tap() }
    private func ready(_ element: XCUIElement, timeout: TimeInterval = 15) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate:
            NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: element)], timeout: timeout), .completed)
    }
    private func predicate(_ element: XCUIElement, _ format: String, _ value: String) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: format, value), object: element)], timeout: 15), .completed)
    }
    private func validReceipt(_ text: String, pages: Int, prefix: String, limit: Int) -> Bool {
        let lead = "\(prefix) \(pages) 頁，", tail = " 位元組"
        guard text.utf8.count <= 128, text.hasPrefix(lead), text.hasSuffix(tail) else { return false }
        let groups = text.dropFirst(lead.count).dropLast(tail.count).split(separator: ",", omittingEmptySubsequences: false)
        guard let first = groups.first, !first.isEmpty, first.first != "0",
              groups.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy({ (48...57).contains($0) }) }),
              groups.count == 1 || (first.count <= 3 && groups.dropFirst().allSatisfy({ $0.count == 3 })),
              let bytes = Int(groups.joined()) else { return false }
        return bytes > 0 && bytes <= limit
    }
    /// Cache the exact Assembly Form identity. One target snapshot per gesture
    /// avoids selecting the keyboard candidate CollectionView or querying every
    /// offscreen child. Static text needs visibility; tapped controls need full bounds.
    private func reveal(_ target: XCUIElement, reading: Bool = false) {
        var previousTargetPresent = false
        var hasSeenTarget = false
        var searchUp = true
        var previousContent: LearningScrollContent?
        var reversedAtBoundary = false
        for attempt in 0...8 {
            guard form.exists else { XCTFail("Exact Assembly Form must remain mounted."); return }
            let formFrame = form.frame
            var viewport = formFrame.intersection(app.frame)
            let title = app.navigationBars["PDF 頁面處理"]
            if title.exists {
                let bottom = viewport.maxY
                viewport.origin.y = max(viewport.minY, title.frame.maxY)
                viewport.size.height = bottom - viewport.minY
            }
            let nav = app.buttons["navigation.chat"]
            if nav.exists && nav.isHittable {
                viewport.size.height = min(viewport.maxY, nav.frame.minY) - viewport.minY
            }
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists {
                let done = app.buttons["pdfAssembly.keyboardDone"]
                let toolbar = app.toolbars.containing(.button, identifier: "pdfAssembly.keyboardDone").firstMatch
                guard done.exists else { XCTFail("Assembly keyboard accessory must exist."); return }
                viewport.size.height = min(viewport.maxY, keyboard.frame.minY, toolbar.exists ? toolbar.frame.minY : done.frame.minY) - viewport.minY
            }
            viewport = viewport.insetBy(dx: 0, dy: 4)
            let exists = target.exists
            let frame = exists ? target.frame : .zero
            if exists && learningFrameIsVisible(frame, in: viewport, visibility: reading ? .readableText : .fullyVisible) {
                if reading || target.isHittable { return }
            }
            let present = exists && !frame.isEmpty
            hasSeenTarget = hasSeenTarget || present
            var content: LearningScrollContent?
            if !present, let snapshot = try? form.snapshot() {
                var rows: [LearningScrollContent.Row] = []
                func visit(_ node: XCUIElementSnapshot) {
                    if node.elementType == .staticText, viewport.intersects(node.frame), !node.frame.isEmpty {
                        rows.append(.init(identifier: node.identifier, label: node.label, frame: node.frame))
                    }
                    for child in node.children { visit(child) }
                }
                visit(snapshot)
                if !rows.isEmpty { content = LearningScrollContent(viewport: viewport, rows: rows) }
            }
            if !present && previousTargetPresent { searchUp.toggle() }
            else if let content, let previousContent, content.isUnchanged(from: previousContent) {
                guard !reversedAtBoundary else { XCTFail("Exact Form made no progress in either direction."); return }
                searchUp.toggle(); reversedAtBoundary = true
            }
            previousContent = content
            guard attempt < 8, let drag = LearningScrollDrag.make(listFrame: formFrame, viewport: viewport,
                targetFrame: present ? frame : nil, searchUp: searchUp, maximumDistance: 120,
                visibility: reading ? .readableText : .fullyVisible, searchByPage: !hasSeenTarget) else {
                XCTFail("Exact Assembly element must become visible within bounded native scrolling."); return
            }
            let origin = form.coordinate(withNormalizedOffset: .zero)
            origin.withOffset(CGVector(dx: drag.start.x - formFrame.minX, dy: drag.start.y - formFrame.minY))
                .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: drag.end.x - formFrame.minX,
                    dy: drag.end.y - formFrame.minY)), withVelocity: .slow, thenHoldForDuration: 0.2)
            previousTargetPresent = present; searchUp = drag.end.y < drag.start.y
        }
    }
}
#endif
