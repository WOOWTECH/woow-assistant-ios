import XCTest

/// Private runner only: real Files import-copy, two native approvals, PDFKit,
/// configured HTTP model, verified citations and the native export cancellation.
/// The fixture creates source bytes only. Never publish xcresult/xctestrun,
/// screenshots, AX trees, launch environments or model/source text from this case.
final class LiveDocumentQueryUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private var launched = false
    private var started = Date()
    private var stem: String { "SkillExecution-" + namespace }
    private var filename: String { stem + ".pdf" }
    private var nativeNavigation: XCUIElement { app.navigationBars["FullDocumentManagerViewControllerNavigationBar"] }
    private var nativeList: XCUIElement { app.collectionViews["File View"] }
    private var nativeCancel: XCUIElement {
        nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch
    }
    private let localLabels = ["我的 iPhone", "我的iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]
    private let browseLabels = ["瀏覽", "Browse", "位置", "Locations"]
    private let appLabels = ["渥屋助理", "WoowAssistant"]
    private enum Failure: Error { case configuration, readiness, budget, route, nativeTarget, audit }

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Files source requires an isolated simulator.")
        #endif
        continueAfterFailure = false; executionTimeAllowance = 300
        started = Date()
        guard ProcessInfo.processInfo.environment["WOOW_LIVE_API_KEY"]?.isEmpty == false else {
            throw XCTSkip("Live model credentials were not supplied by the private runner.")
        }
    }

    override func tearDownWithError() throws {
        guard launched else { return }
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveModelUITestCleanup"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["chat.status"].label == "尚未設定模型", "Isolated live credential cleanup failed.")
        app.terminate()
    }

    func testRealModelAnswersFromApprovedPDFAndExportCancellationPreservesResult() throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["WOOW_LIVE_BASE_URL"], let url = URL(string: base),
              url.scheme == "https", let host = url.host,
              let model = env["WOOW_LIVE_MODEL"], !model.isEmpty,
              let key = env["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            XCTFail("The private runner must supply a valid live model configuration.")
            throw Failure.configuration
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-UITestSkillExecution"]
        app.launchEnvironment = ["WOOW_LIVE_BASE_URL": base, "WOOW_LIVE_MODEL": model, "WOOW_LIVE_API_KEY": key]
        launched = true; app.launch()
        try wait("Private model bootstrap did not complete.", timeout: 15) { self.app.staticTexts["chat.status"].exists }
        XCTAssertTrue(app.staticTexts["chat.status"].label == "模型已設定")
        XCTAssertFalse(app.staticTexts["uitest.banner"].exists)
        try tap("navigation.memory")
        try wait("Learning screen did not become ready.", timeout: 15) { self.app.staticTexts["memory.status"].exists }
        try tap("memory.segment.skills")
        try tap("skills.documents.execute", scroll: true)
        let fixture = app.staticTexts["skillExecution.uitest.fixture"].firstMatch
        try show(fixture, readable: true)
        XCTAssertTrue(fixture.label == "測試文件已建立：" + filename, "The source must belong to this isolated invocation.")
        try extractionAudit(selections: 0, reads: 0, attempts: 0, results: 0)
        try choosePDFCopy()
        phase("selected")
        try show(fixture, readable: true)
        XCTAssertTrue(fixture.value as? String == "source=user-copy mode=import allowsMultipleSelection=false")
        try extractionAudit(selections: 1, reads: 0, attempts: 0, results: 0)
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists)
        try approvePDFStep(title: "讀取選取的 PDF", nextTitle: "在裝置上擷取 PDF")
        try extractionAudit(selections: 1, reads: 1, attempts: 0, results: 0)
        XCTAssertFalse(app.staticTexts["skillExecution.result.text"].exists,
                       "Read approval must not authorize extraction.")
        try approvePDFStep(title: "在裝置上擷取 PDF", nextTitle: nil)
        let summary = app.staticTexts["skillExecution.result.summary"].firstMatch
        try show(summary, readable: true)
        XCTAssertTrue(summary.label == "共 2 頁；引擎：Apple PDFKit")
        let text = app.staticTexts["skillExecution.result.text"].firstMatch
        try show(text, readable: true)
        let extracted = text.label
        let markers = ["WOOW_SKILL_PDF_PAGE_1", "WOOW_SKILL_PDF_PAGE_2"]
        XCTAssertTrue(markers.allSatisfy { extracted.contains($0) })
        XCTAssertTrue(extracted.contains("--- page 1 ---") && extracted.contains("--- page 2 ---"))
        // PDFKit can insert line breaks in a UUID on iOS 17. Only whitespace is
        // ignored for this source-identity check; quotes below remain exact.
        let compactSource = extracted.filter { !$0.isWhitespace }
        XCTAssertTrue(compactSource.contains(namespace), "Extraction must contain the selected namespace's source identity.")
        phase("extracted")
        try tap("skillExecution.query", scroll: true)
        let sourceName = app.staticTexts["documentQuery.filename"].firstMatch
        try show(sourceName, readable: true)
        XCTAssertTrue(sourceName.label == filename)
        let question = "Search for WOOW_SKILL_PDF_PAGE_, then read the actual text of both selected PDF pages. Which original page contains WOOW_SKILL_PDF_PAGE_1 and which contains WOOW_SKILL_PDF_PAGE_2? Answer with both exact markers and their original page numbers. Provide exactly two citations in page order: quote only WOOW_SKILL_PDF_PAGE_1 from page 1, then only WOOW_SKILL_PDF_PAGE_2 from page 2. Use actual search and read tools before finishing; do not infer evidence from this question."
        let editor = app.textViews["documentQuery.question"].firstMatch
        try show(editor); try ready(editor); editor.tap()
        try wait("The query editor did not acquire the native keyboard.", timeout: 5) { self.app.keyboards.firstMatch.exists }
        phase("question_input_started")
        editor.typeText(question)
        phase("question_input_delivered")
        // In 4f26118, synthesis ended at 132.33s but post-input editor AX
        // queries delayed Done until 174.91s. Dismiss the native keyboard
        // before reading the long editor value; transmission remains blocked
        // until the same exact-value assertion and destination review pass.
        try tap("documentQuery.keyboardDone")
        try wait("The native keyboard must dismiss before form navigation.", timeout: 5) { !self.app.keyboards.firstMatch.exists }
        phase("question_keyboard_dismissed")
        XCTAssertTrue(editor.value as? String == question, "The exact question must reach the native editor.")
        phase("question_verified")
        try assertZeroQuery()
        let start = app.buttons["documentQuery.start"].firstMatch
        try show(start)
        XCTAssertFalse(start.isEnabled, "A question alone cannot authorize transmission.")
        try tap("documentQuery.confirmDestination", scroll: true)
        let destination = app.staticTexts["documentQuery.destination"].firstMatch
        try show(destination, readable: true)
        let expectedDestination = "https://" + host + (url.port.map { ":\($0)" } ?? "") + "\n模型：" + model
        XCTAssertTrue(destination.label == expectedDestination, "Only the configured destination may be approved.")
        try assertZeroQuery()
        try tap("documentQuery.start", scroll: true)
        phase("model_started")
        // A fast response need not leave the transient Cancel control visible.
        // Completion requires the actual verified result and tool audit below.
        try wait("The query did not reach a terminal state within the remaining case budget.", timeout: 185) {
            let status = self.app.staticTexts["documentQuery.status"].firstMatch
            return (start.exists && start.isEnabled && status.exists
                    && DocumentQueryUIAudit.parse(status.value as? String)?.results == 1)
                || self.app.staticTexts["documentQuery.error"].exists
                || self.app.staticTexts["documentQuery.refusal"].exists
        }
        XCTAssertFalse(app.staticTexts["documentQuery.error"].exists, "The actual query returned a failure.")
        XCTAssertFalse(app.staticTexts["documentQuery.refusal"].exists, "A refusal is not a completed answer.")
        // The result is now terminal. Read its invariant text together, taking
        // a fresh scoped snapshot after each required real scroll.
        let completed = try readableQueryText(["documentQuery.status", "documentQuery.answeredQuestion",
                                               "documentQuery.answer"] + citationIdentifiers(markers))
        let audit = try queryAudit(from: completed)
        print(audit.safeLine)
        XCTAssertTrue(audit.searches >= 1 && audit.reads >= 2 && audit.results == 1 && audit.citations == 2,
                      "Completion requires real search, two reads and exactly two validated citations.")
        XCTAssertTrue(audit.modelCalls >= 4 && audit.modelCalls <= 12 && audit.corrections <= 1)
        let answer = try XCTUnwrap(completed["documentQuery.answer"]?.label,
                                   "The completed answer must remain readable.")
        XCTAssertTrue(!answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && markers.allSatisfy { answer.contains($0) }, "The model must answer the two requested source facts.")
        XCTAssertTrue(completed["documentQuery.answeredQuestion"]?.label == question)
        try assertCitations(markers, values: completed)
        phase("verified")
        try tap("documentQuery.export", scroll: true)
        try wait("The real native exporter must appear.", timeout: 15) { self.nativeNavigation.exists }
        phase("export_presented")
        try cancelExporter()
        phase("export_cancel_tapped")
        try nativeDismissed()
        // Never reuse the pre-export readback. f49 spent 271.64–286.48s
        // separately resolving status, answer, citations and audit after the
        // real cancellation. Gather this stable phase in one bounded readback;
        // native dismissal and the exact callback text remain required.
        let retained = try readableQueryText(["documentQuery.exportStatus", "documentQuery.status",
                                              "documentQuery.answer"] + citationIdentifiers(markers))
        XCTAssertTrue(retained["documentQuery.exportStatus"]?.label == "已取消匯出，回答與引文仍保留。",
                      "Only the actual exporter cancellation callback satisfies this case.")
        phase("export_callback_verified")
        XCTAssertTrue(retained["documentQuery.answer"]?.label == answer, "Export cancellation must preserve the exact answer.")
        phase("retained_answer_verified")
        try assertCitations(markers, values: retained)
        phase("retained_citations_verified")
        XCTAssertTrue(try queryAudit(from: retained) == audit, "Export must not send another model request or replace its result.")
        phase("export_cancelled")
        try tap("documentQuery.close")
        try wait("The query sheet must close.", timeout: 10) { !self.app.buttons["documentQuery.close"].exists }
        try show(text, readable: true)
        XCTAssertTrue(text.label == extracted, "Closing the query must retain the exact original PDF extraction.")
        XCTAssertFalse(app.buttons["skillExecutionApproveStep"].exists)
        try extractionAudit(selections: 1, reads: 1, attempts: 1, results: 1)
        XCTAssertFalse(app.staticTexts["uitest.banner"].exists)
        phase("extraction_preserved")
    }

    private func phase(_ name: String) {
        // All callers supply literal stage names. No UI/source/model text.
        print("LIVE_DOCUMENT_QUERY phase=\(name) elapsedSeconds=\(Int(Date().timeIntervalSince(started)))")
    }

    private func wait(_ message: String, timeout: TimeInterval, condition: @escaping () -> Bool) throws {
        // Reserve time for namespace cleanup inside the existing 300s cap.
        try requireBudget()
        let deadline = min(started.addingTimeInterval(285), Date().addingTimeInterval(timeout))
        // AX queries are synchronous and cannot be interrupted by this local
        // polling timeout. Honor an already-ready result without querying it
        // again, but always enforce the whole-case cleanup boundary afterward.
        let initiallyReady = condition()
        try requireBudget()
        if initiallyReady { return }

        // A false initial result consumes the original timeout. Never reset it
        // or start another AX query after that local deadline has elapsed.
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { XCTFail(message); throw Failure.readiness }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard Date() < deadline else { return false }
            return condition()
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: remaining)
        try requireBudget()
        guard result == .completed else {
            XCTFail(message); throw Failure.readiness
        }
    }

    private func requireBudget() throws {
        guard Date().timeIntervalSince(started) < 285 else {
            XCTFail("The 300-second case budget is exhausted."); throw Failure.budget
        }
    }

    private func ready(_ element: XCUIElement, timeout: TimeInterval = 10) throws {
        try wait("A required native control did not become ready.", timeout: timeout) {
            element.exists && element.isEnabled && element.isHittable
        }
    }

    private func show(_ element: XCUIElement, readable: Bool = false) throws {
        revealLearningElement(element, in: app, visibility: readable ? .readableText : .fullyVisible)
        guard element.exists else { throw Failure.readiness }
    }

    private func tap(_ identifier: String, scroll: Bool = false) throws {
        let control = app.buttons[identifier].firstMatch
        if scroll { try show(control) }
        try ready(control); control.tap()
    }

    private func extractionAudit(selections: Int, reads: Int, attempts: Int, results: Int) throws {
        let audit = app.staticTexts["skillExecution.uitest.audit"].firstMatch
        try show(audit, readable: true)
        let expected = "SKILL_EXECUTION_AUDIT selections=\(selections) reads=\(reads) extractionAttempts=\(attempts) results=\(results)"
        try wait("The actual extraction audit did not match the approved operations.", timeout: 15) { audit.label == expected }
    }

    private func approvePDFStep(title: String, nextTitle: String?) throws {
        let control = app.buttons["skillExecutionApproveStep"].firstMatch
        try show(control)
        try wait("The next PDF capability must match the separate approval.", timeout: 15) {
            control.exists && control.value as? String == title && control.isEnabled && control.isHittable
        }
        control.tap()
        try wait("The approved PDF operation did not complete.", timeout: 20) {
            if let nextTitle { return control.exists && control.value as? String == nextTitle && control.isEnabled }
            return !control.exists
        }
    }

    private func queryAudit() throws -> DocumentQueryUIAudit {
        try queryAudit(from: readableQueryText(["documentQuery.status"]))
    }

    private func queryAudit(from values: [String: QueryTextValue]) throws -> DocumentQueryUIAudit {
        guard let status = values["documentQuery.status"],
              let audit = DocumentQueryUIAudit.parse(status.value) else {
            XCTFail("The fixed query audit is missing or malformed; no raw value was logged."); throw Failure.audit
        }
        return audit
    }

    private func assertZeroQuery() throws {
        XCTAssertTrue(try queryAudit() == .zero, "No search, read or model call is authorized before Start.")
        XCTAssertFalse(app.staticTexts["documentQuery.answer"].exists)
    }

    private func citationIdentifiers(_ markers: [String]) -> [String] {
        markers.indices.flatMap {
            ["documentQuery.citation.page.\($0)", "documentQuery.citation.quote.\($0)"]
        }
    }

    private func assertCitations(_ markers: [String], values: [String: QueryTextValue]) throws {
        for (index, marker) in markers.enumerated() {
            guard let page = values["documentQuery.citation.page.\(index)"],
                  let quote = values["documentQuery.citation.quote.\(index)"] else {
                XCTFail("Each citation must expose its readable page and quote."); throw Failure.readiness
            }
            XCTAssertTrue(page.label == "原 PDF 第 \(index + 1) 頁 · 選取序號 \(index + 1)", "The citation must identify its actual original page.")
            XCTAssertTrue(quote.label == marker, "The verified quotation must match the actual selected PDF marker byte for byte.")
        }
        XCTAssertFalse(app.staticTexts["documentQuery.citation.quote.2"].exists)
    }

    private struct QueryTextValue { let label: String; let value: String? }

    private func readableQueryText(_ identifiers: [String]) throws -> [String: QueryTextValue] {
        // 517d0d1 spent 280.24–304.07s repeatedly resolving the same Form,
        // keyboard and individual text attributes without a single scroll.
        // 517 logs identify this Form as a CollectionView. Container-ID
        // uniqueness remains a native assertion, not a fact proven by that log.
        // Read visible static rows together from one fresh, scoped AX snapshot.
        // This is never used for a tap or to infer Files dismissal/cancellation.
        let forms = app.collectionViews.matching(identifier: "documentQuery.form")
        let form = forms.firstMatch
        var values: [String: QueryTextValue] = [:]
        var revealed = Set<String>()
        while true {
            try requireBudget()
            guard forms.count == 1, form.isHittable, !app.keyboards.firstMatch.exists else {
                XCTFail("The readable query Form must be unique and unobscured by the keyboard.")
                throw Failure.readiness
            }
            let snapshot: XCUIElementSnapshot
            do { snapshot = try form.snapshot() }
            catch { XCTFail("The query Form snapshot could not be read."); throw Failure.readiness }
            let viewport = snapshot.frame.intersection(app.frame).insetBy(dx: 0, dy: 4)
            var pending = [snapshot], matches: [XCUIElementSnapshot] = []
            while let node = pending.popLast() {
                if identifiers.contains(node.identifier) { matches.append(node) }
                pending.append(contentsOf: node.children)
            }
            let positions = matches.map {
                DocumentQueryTextPosition(identifier: $0.identifier, frame: $0.frame,
                                          isStaticText: $0.elementType == .staticText)
            }
            guard let readable = documentQueryReadableIndices(positions, identifiers: identifiers, viewport: viewport) else {
                XCTFail("Query readback requires unique static text rows in a valid viewport.")
                throw Failure.readiness
            }
            for (identifier, index) in readable {
                let node = matches[index]
                values[identifier] = QueryTextValue(label: node.label, value: node.value as? String)
            }
            try requireBudget()
            guard let missing = identifiers.first(where: { values[$0] == nil }) else { return values }
            guard revealed.insert(missing).inserted else {
                XCTFail("The requested query text remained unreadable after bounded scrolling.")
                throw Failure.readiness
            }
            // Virtualized/offscreen rows still require actual bounded gestures.
            // Discard this snapshot after the gesture; never cache AX data
            // across native presentation, model completion or another call.
            try show(app.staticTexts[missing].firstMatch, readable: true)
        }
    }

    private func choosePDFCopy() throws {
        try tap("skillExecution.importCopy.options", scroll: true)
        let notice = app.staticTexts["skillExecution.importCopy.notice"].firstMatch
        try show(notice, readable: true)
        XCTAssertTrue(notice.label == "選檔後，系統會先建立暫存副本並占用儲存空間，不會更動原檔。App 讀取與後續擷取仍需分別核准。App 最多讀取 10 MiB；系統複製的大小不受此上限限制。")
        try tap("skillExecutionImportPDFCopy", scroll: true)
        try ready(nativeCancel, timeout: 60) // Observed cold Files presentation on SE was 48–50s.
        let file = try navigateFiles()
        let thumbnail = file.images.firstMatch
        guard file.images.count == 1, thumbnail.exists, file.exists, file.isEnabled, file.isHittable,
              nativeList.exists, nativeNavigation.exists,
              documentQueryThumbnailIsVisible(thumbnail.frame, cell: file.frame,
                  viewport: nativeList.frame.intersection(app.frame), navigation: nativeNavigation.frame) else {
            XCTFail("The exact PDF cell must expose its fully visible document thumbnail."); throw Failure.nativeTarget
        }
        thumbnail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = app.staticTexts["skillExecution.filename"].firstMatch
        let open = nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["打開", "開啟", "Open", "完成", "Done"])).firstMatch
        try wait("Files must deliver the selection or expose an actual Open confirmation.", timeout: 15) {
            selected.exists || (open.exists && open.isEnabled && open.isHittable)
        }
        if !selected.exists && open.exists && open.isEnabled && open.isHittable { open.tap() }
        try wait("The real importer callback did not deliver the selected PDF.", timeout: 15) { selected.exists }
        XCTAssertTrue(selected.label == filename)
        try nativeDismissed()
    }

    private var appFolder: XCUIElement {
        let title = nativeNavigation.staticTexts.matching(NSPredicate(format: "label IN %@", appLabels)).firstMatch
        return title.exists ? title : nativeNavigation.buttons.matching(NSPredicate(format: "label == %@", "渥屋助理, 「動作」選單")).firstMatch
    }

    private func visible(_ query: XCUIElementQuery) -> XCUIElement? {
        let element = query.firstMatch
        return element.exists && element.isEnabled && element.isHittable ? element : nil
    }

    private func exactPDF() -> XCUIElement? {
        let cells = nativeList.cells.matching(NSPredicate(format: "identifier == %@", stem + ", pdf"))
        guard let cell = visible(cells), cells.count == 1,
              cell.staticTexts.matching(NSPredicate(format: "label IN %@", [filename, stem])).count == 1 else { return nil }
        return cell
    }

    private func nativeItem(_ labels: [String]) -> XCUIElement? {
        let predicate = NSPredicate(format: "label IN %@", labels)
        for query in [nativeList.cells, app.buttons, app.staticTexts] {
            if let item = visible(query.matching(predicate)) { return item }
        }
        return nil
    }

    private func routeElement(_ step: DocumentQueryPickerStep) -> XCUIElement? {
        switch step {
        case .file: return exactPDF()
        case .application: return nativeItem(appLabels)
        case .local: return nativeItem(localLabels)
        case .back: return visible(nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", browseLabels)))
        case .locations: return visible(app.buttons.matching(NSPredicate(format: "label IN %@", ["位置", "Locations"])))
        case .browseTab:
            let tab = visible(app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", ["瀏覽", "Browse"])))
            return tab?.isSelected == false ? tab : nil
        case .browseButton:
            let button = visible(app.buttons.matching(NSPredicate(format: "label IN %@", ["瀏覽", "Browse"])))
            return button?.isSelected == false ? button : nil
        }
    }

    private func navigateFiles() throws -> XCUIElement {
        var attempted = Set<DocumentQueryPickerStep>()
        while true {
            if appFolder.exists {
                for attempt in 0...10 {
                    if let file = exactPDF() { return file }
                    guard attempt < 10, nativeList.exists, nativeList.isHittable else { break }
                    nativeList.swipeUp()
                }
                XCTFail("The known app folder did not reveal this namespace's exact PDF."); throw Failure.route
            }
            var target: XCUIElement?
            guard let step = DocumentQueryPickerStep.allCases.first(where: {
                guard !attempted.contains($0) else { return false }
                target = routeElement($0); return target != nil
            }), let target else {
                XCTFail("Files did not expose a known local route; no provider fallback is allowed."); throw Failure.route
            }
            attempted.insert(step)
            if step == .file { return target }
            target.tap()
            try wait("Files did not progress after one native route action.", timeout: 12) {
                self.appFolder.exists || step.successors.contains { !attempted.contains($0) && self.routeElement($0) != nil }
            }
        }
    }

    private func nativeDismissed() throws {
        try wait("Native Files must dismiss before any App form scrolling.", timeout: 30) { !self.nativeNavigation.exists }
    }

    private func cancelExporter() throws {
        var attempted = Set<String>()
        for attempt in 0...3 {
            if nativeCancel.exists { try ready(nativeCancel); nativeCancel.tap(); return }
            guard attempt < 3,
                  let back = visible(nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", localLabels + browseLabels))) else { break }
            let previous = back.label
            guard attempted.insert(previous).inserted else { break }
            back.tap()
            try wait("The native exporter did not leave its previous folder.", timeout: 12) {
                self.nativeCancel.exists || !self.nativeNavigation.buttons.matching(NSPredicate(format: "label == %@", previous)).firstMatch.exists
            }
        }
        XCTFail("The native exporter did not expose Cancel through its bounded local route."); throw Failure.route
    }
}

private struct DocumentQueryTextPosition {
    let identifier: String
    let frame: CGRect
    let isStaticText: Bool
}

private func documentQueryReadableIndices(_ rows: [DocumentQueryTextPosition], identifiers: [String],
                                         viewport: CGRect) -> [String: Int]? {
    guard !identifiers.isEmpty, Set(identifiers).count == identifiers.count,
          !viewport.isEmpty, !viewport.isNull, !viewport.isInfinite,
          [viewport.minX, viewport.minY, viewport.width, viewport.height].allSatisfy({ $0.isFinite }) else { return nil }
    var result: [String: Int] = [:]
    for identifier in identifiers {
        let matches = rows.indices.filter { rows[$0].identifier == identifier }
        // SwiftUI may repeat a Text identifier on its containing cell. Only
        // the expected StaticText can provide the value; wrappers cannot.
        let textMatches = matches.filter { rows[$0].isStaticText }
        guard textMatches.count <= 1 else { return nil }
        guard let index = textMatches.first else {
            guard matches.isEmpty else { return nil } // Present only with the wrong role.
            continue // Materialize the absent row via real scrolling.
        }
        let frame = rows[index].frame
        if [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }),
           learningFrameIsVisible(frame, in: viewport, visibility: .readableText) {
            result[identifier] = index
        }
    }
    return result
}

private struct DocumentQueryUIAudit: Equatable {
    let modelCalls: Int, searches: Int, reads: Int, results: Int, citations: Int, corrections: Int
    static let zero = Self(modelCalls: 0, searches: 0, reads: 0, results: 0, citations: 0, corrections: 0)
    static func parse(_ raw: String?) -> Self? {
        guard let raw, raw.utf8.count <= 256 else { return nil }
        let parts = raw.split(separator: " ")
        let names = ["modelCalls", "searches", "reads", "results", "citations", "corrections"]
        guard parts.first == "DOCUMENT_QUERY_AUDIT", parts.count == names.count + 1 else { return nil }
        var values: [Int] = []
        for (name, part) in zip(names, parts.dropFirst()) {
            let pair = part.split(separator: "=", omittingEmptySubsequences: false)
            guard pair.count == 2, pair[0] == Substring(name), !pair[1].isEmpty,
                  pair[1].utf8.allSatisfy({ (48...57).contains($0) }),
                  let value = Int(pair[1]), (0...64).contains(value) else { return nil }
            values.append(value)
        }
        return Self(modelCalls: values[0], searches: values[1], reads: values[2],
                    results: values[3], citations: values[4], corrections: values[5])
    }
    var safeLine: String {
        "LIVE_DOCUMENT_QUERY modelCalls=\(modelCalls) searches=\(searches) reads=\(reads) results=\(results) citations=\(citations) corrections=\(corrections)"
    }
}

private enum DocumentQueryPickerStep: CaseIterable {
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

private func documentQueryThumbnailIsVisible(_ image: CGRect, cell: CGRect, viewport: CGRect, navigation: CGRect) -> Bool {
    guard [image, cell, viewport, navigation].allSatisfy({ !$0.isEmpty && !$0.isNull && !$0.isInfinite }) else { return false }
    return cell.contains(image) && viewport.contains(image) && !navigation.intersects(image)
}
