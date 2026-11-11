import XCTest

/// DEBUG fixture creates only a real PDF and a closed model transport. Selection,
/// independent grants, destination approval, archive and cancellation are native.
final class ChatPDFAttachmentUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private var stem: String { "SkillExecution-" + namespace }
    private var filename: String { stem + ".pdf" }
    private var nativeList: XCUIElement { app.collectionViews["File View"].firstMatch }
    private var nativeNavigation: XCUIElement { app.navigationBars["FullDocumentManagerViewControllerNavigationBar"].firstMatch }
    private var nativeCancel: XCUIElement { nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["Cancel", "取消"])).firstMatch }
    private let appLabels = ["渥屋助理", "WoowAssistant"]
    private let localLabels = ["On My iPhone", "我的 iPhone", "在我的 iPhone 上"]
    private let browseLabels = ["瀏覽", "Browse", "位置", "Locations"]
    private enum Failure: Error { case nativeTarget, route, readiness }
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 240 }
    override func tearDownWithError() throws { app.terminate() }

    func testNativePDFApprovalsCitationsArchiveRelaunchOpenAndDelete() throws {
        launch(); configure(); compose("[fixture:chat-pdf]")
        try choosePDF(); phase("awaitingRead"); requests(0)
        XCTAssertFalse(app.staticTexts["chat.pdf.extracted"].firstMatch.exists)
        tap("chat.pdf.approveRead", scroll: true); phase("awaitingExtraction"); requests(0)
        XCTAssertFalse(app.staticTexts["chat.pdf.extracted"].firstMatch.exists)
        tap("chat.pdf.approveExtract", scroll: true); phase("ready"); requests(0)
        let extracted = app.staticTexts["chat.pdf.extracted"].firstMatch
        revealLearningElement(extracted, in: app, visibility: .readableText)
        XCTAssertTrue(extracted.label.hasPrefix("已擷取 2 頁，"))
        tap("chat.pdf.done"); XCTAssertFalse(app.buttons["chat.send"].firstMatch.isEnabled)
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:chat-pdf]")
        tap("chat.pdf.open")
        let notice = app.staticTexts["chat.pdf.transmissionNotice"].firstMatch
        revealLearningElement(notice, in: app, visibility: .readableText)
        XCTAssertEqual(notice.label, "問題、檔名、讀取片段與已啟用的個人檔案、相關記憶及適用技能會傳給此模型服務。保存資料只作背景，不是文件證據或操作授權。")
        tap("chat.pdf.confirmDestination", scroll: true); tap("chat.pdf.done")
        tap("chat.send")
        assertLabel(app.staticTexts["chat.message.1.assistant"].firstMatch, "PDF 問答已完成：WOOW_SKILL_PDF_PAGE_2")
        requests(3)
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.archiveNotice"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.pdf.card"].firstMatch.exists)
        XCTAssertFalse(app.buttons["chat.cancel"].firstMatch.exists)
        launch(reset: false); requests(0)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
        tap("chat.archive"); let saved = row("[fixture:chat-pdf]"); ready(saved); saved.tap()
        assertLabel(app.staticTexts["archive.turn.0.assistant"].firstMatch, "PDF 問答已完成：WOOW_SKILL_PDF_PAGE_2")
        tap("archive.turn.0.pdf", scroll: true)
        let citation = app.staticTexts["archive.turn.0.pdf.citation.0"].firstMatch
        revealLearningElement(citation, in: app, visibility: .readableText)
        XCTAssertEqual(citation.label, "WOOW_SKILL_PDF_PAGE_2")
        tap("archive.turn.0.pdf.pages", scroll: true)
        let text = app.staticTexts["archive.turn.0.pdf.page.1"].firstMatch
        revealLearningElement(text, in: app, visibility: .readableText)
        XCTAssertTrue(text.label.contains("WOOW_SKILL_PDF_PAGE_2"))
        XCTAssertTrue(text.label.filter { !$0.isWhitespace }.contains(namespace))
        tap("archive.open"); requests(0)
        assertLabel(app.staticTexts["chat.message.1.assistant"].firstMatch, "PDF 問答已完成：WOOW_SKILL_PDF_PAGE_2")
        XCTAssertFalse(app.staticTexts["chat.pdf.card"].firstMatch.exists, "Restored evidence never restores an active grant")
        tap("chat.archive"); let again = row("[fixture:chat-pdf]"); ready(again); again.tap()
        tap("archive.delete"); tap("archive.delete.confirm")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        launch(reset: false); tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        print("CHAT_PDF_UI nativeSelection=1 separateGrants=2 modelRequestEvents=3 citations=1 archiveRelaunch=1 explicitOpen=1 deleteRelaunchAbsent=1")
    }

    func testReadApprovalThenRemoveNeverExtractsOrSubmitsAndRetainsDraft() throws {
        launch(); configure(); compose("[fixture:chat-pdf]")
        try choosePDF(); phase("awaitingRead"); requests(0)
        tap("chat.pdf.approveRead", scroll: true); phase("awaitingExtraction")
        XCTAssertFalse(app.staticTexts["chat.pdf.extracted"].firstMatch.exists)
        tap("chat.pdf.remove", scroll: true)
        XCTAssertTrue(app.buttons["chat.pdf.select"].firstMatch.waitForExistence(timeout: 10))
        tap("chat.pdf.done"); requests(0)
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:chat-pdf]")
        XCTAssertFalse(app.staticTexts["chat.pdf.card"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists)
        tap("chat.archive"); XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        launch(reset: false); tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        print("CHAT_PDF_UI nativeSelection=1 readGrant=1 extractionGrant=0 modelRequestEvents=0 draftRetained=1 archiveAbsent=1")
    }

    func testCancelActualQueryKeepsQuestionAndSourceWithoutCompletedArchive() throws {
        launch(); configure(); compose("[fixture:chat-pdf-cancel]")
        try choosePDF(); tap("chat.pdf.approveRead", scroll: true); phase("awaitingExtraction")
        tap("chat.pdf.approveExtract", scroll: true); phase("ready")
        tap("chat.pdf.confirmDestination", scroll: true); tap("chat.pdf.done"); tap("chat.send")
        requests(1); tap("chat.cancel")
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:chat-pdf-cancel]")
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["chat.pdf.card"].firstMatch.exists)
        tap("chat.pdf.open"); phase("ready")
        let confirm = app.buttons["chat.pdf.confirmDestination"].firstMatch
        revealLearningElement(confirm, in: app); ready(confirm)
        XCTAssertFalse(app.staticTexts["chat.pdf.destination"].firstMatch.exists)
        tap("chat.pdf.done"); tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        launch(reset: false); requests(0)
        XCTAssertFalse(app.staticTexts["chat.pdf.card"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
        tap("chat.archive"); XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        print("CHAT_PDF_UI cancelled=1 modelRequestEvents=1 sourceRetained=1 draftRetained=1 archiveAbsentAfterRelaunch=1")
    }

    private func phase(_ expected: String) {
        let status = app.staticTexts["chat.pdf.phase"].firstMatch
        revealLearningElement(status, in: app, visibility: .readableText)
        wait(NSPredicate(format: "value == %@", expected), on: status)
        XCTAssertEqual(status.value as? String, expected)
    }
    private func requests(_ expected: Int) {
        let value = app.staticTexts["chat.pdf.requestEvents"].firstMatch
        wait(NSPredicate(format: "value == %@", String(expected)), on: value)
        XCTAssertEqual(value.value as? String, String(expected), "Runtime request events, not all HTTP calls")
    }
    private func wait(_ reason: String, timeout: TimeInterval, condition: @escaping () -> Bool) throws {
        if !condition() {
            let result = XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)], timeout: timeout)
            guard result == .completed else { XCTFail(reason); throw Failure.readiness }
        }
        XCTAssertTrue(condition(), reason)
    }
    private func choosePDF() throws {
        tap("chat.pdf.open")
        let fixture = app.staticTexts["chat.pdf.fixtureFilename"].firstMatch
        revealLearningElement(fixture, in: app, visibility: .readableText); assertLabel(fixture, filename)
        tap("chat.pdf.select", scroll: true)
        wait(NSPredicate(format: "hittable == true"), on: nativeCancel, seconds: 60)
        let file = try navigateFiles(), thumbnail = file.images.firstMatch
        guard file.images.count == 1, thumbnail.exists, file.exists, file.isEnabled, file.isHittable,
              nativeList.exists, nativeNavigation.exists,
              chatPDFThumbnailIsVisible(thumbnail.frame, cell: file.frame,
                  viewport: nativeList.frame.intersection(app.frame), navigation: nativeNavigation.frame) else {
            XCTFail("Exact native PDF thumbnail must be fully visible"); throw Failure.nativeTarget
        }
        thumbnail.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = app.staticTexts["chat.pdf.filename"].firstMatch
        let open = nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["打開", "開啟", "Open", "完成", "Done"])).firstMatch
        try wait("Native Files must deliver this selection or an explicit Open control", timeout: 15) {
            selected.exists || (open.exists && open.isEnabled && open.isHittable)
        }
        if !selected.exists && open.exists && open.isEnabled && open.isHittable { open.tap() }
        try wait("Actual importer callback did not deliver this PDF", timeout: 15) { selected.exists }
        XCTAssertEqual(selected.label, filename); try nativeDismissed()
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

    private func routeElement(_ step: ChatPDFPickerStep) -> XCUIElement? {
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
        var attempted = Set<ChatPDFPickerStep>()
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
            guard let step = ChatPDFPickerStep.allCases.first(where: {
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

    private func wait(_ predicate: NSPredicate, on element: XCUIElement, seconds: TimeInterval = 10) {
        if !predicate.evaluate(with: element) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: seconds), .completed)
        }
        XCTAssertTrue(element.exists)
    }
    private func launch(reset: Bool = true) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace, "-UITestChatPDF"]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["uitest.banner"].firstMatch.exists)
        assertLabel(app.staticTexts["chat.historyNotice"].firstMatch,
                    "已完成的問答會加密保存在此裝置；未完成任務與未送出的草稿不會保存。")
        if !reset { assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定") }
    }
    private func configure() {
        navigate("settings")
        write("https://model.invalid/v1", field: app.textFields["settings.baseURL"].firstMatch, scroll: true)
        tap("settings.dismissKeyboard")
        write("fixture", field: app.textFields["settings.model"].firstMatch, scroll: true)
        tap("settings.dismissKeyboard")
        let key = app.secureTextFields["settings.apiKey"].firstMatch
        revealLearningElement(key, in: app); ready(key); key.tap(); prepareKeyboard(); key.typeText("fixture-key")
        tap("settings.dismissKeyboard"); tap("settings.save", scroll: true)
        XCTAssertTrue(app.staticTexts["settings.notice"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["settings.error"].firstMatch.exists)
        navigate("chat"); assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定")
    }
    private func compose(_ text: String) {
        let draft = app.textFields["chat.draft"].firstMatch
        write(text, field: draft, scroll: false); tap("chat.dismissKeyboard")
        XCTAssertEqual(draft.value as? String, text)
    }
    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "archive.row.", title)).firstMatch
    }
    private func navigate(_ section: String) {
        let button = app.buttons["navigation." + section].firstMatch
        ready(button); XCTAssertTrue(app.frame.contains(button.frame))
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let predicate = NSPredicate(format: "value == %@", "已選取")
        if !predicate.evaluate(with: button) { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: button)], timeout: 10), .completed) }
        XCTAssertTrue(app.staticTexts[section + ".status"].firstMatch.waitForExistence(timeout: 5))
    }
    private func write(_ text: String, field: XCUIElement, scroll: Bool) {
        if scroll { revealLearningElement(field, in: app) }
        ready(field)
        if !scroll {
            XCTAssertTrue(app.frame.contains(field.frame)); XCTAssertFalse(field.frame.isEmpty)
            XCTAssertLessThanOrEqual(field.frame.maxY, app.buttons["navigation.chat"].firstMatch.frame.minY)
        }
        field.tap(); prepareKeyboard()
        var entered = "", remaining = text[...]
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(entered.isEmpty ? 1 : 16))
            field.typeText(chunk); entered += chunk; remaining = remaining.dropFirst(chunk.count)
            XCTAssertEqual(field.value as? String, entered, "Native text must be exact without repair or retry")
            guard field.value as? String == entered else { return }
        }
    }
    private func prepareKeyboard() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5)); dismissIntroduction()
        let keyboard = app.keyboards.firstMatch
        func latin() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q"])).firstMatch.exists
                && keyboard.keys.matching(NSPredicate(format: "label IN %@", ["a", "A"])).firstMatch.exists
        }
        if latin() { return }
        let globe = app.buttons["Next keyboard"].firstMatch; ready(globe); globe.press(forDuration: 1)
        let english = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "English (US)")).firstMatch
        ready(english); english.tap(); dismissIntroduction()
        if !latin() { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in latin() }, object: nil)], timeout: 10), .completed) }
    }
    private func dismissIntroduction() {
        let button = app.buttons["Continue"].firstMatch
        guard button.waitForExistence(timeout: 3) else { return }
        XCTAssertTrue(app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].firstMatch.exists)
        ready(button); button.tap()
        let absent = NSPredicate(format: "exists == false")
        if !absent.evaluate(with: button) { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: absent, object: button)], timeout: 5), .completed) }
    }
    private func tap(_ id: String, scroll: Bool = false) {
        let button = app.buttons[id].firstMatch
        if scroll { revealLearningElement(button, in: app) }
        ready(button); XCTAssertTrue(app.frame.contains(button.frame)); button.tap()
    }
    private func ready(_ element: XCUIElement) {
        let hittable = NSPredicate(format: "hittable == true")
        if !hittable.evaluate(with: element) { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: hittable, object: element)], timeout: 10), .completed) }
        XCTAssertTrue(element.exists); XCTAssertTrue(element.isEnabled)
    }
    private func assertLabel(_ element: XCUIElement, _ value: String) {
        let predicate = NSPredicate(format: "exists == true AND label == %@", value)
        if !predicate.evaluate(with: element) { XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 15), .completed) }
        XCTAssertEqual(element.label, value)
    }
}

private enum ChatPDFPickerStep: CaseIterable {
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

private func chatPDFThumbnailIsVisible(_ image: CGRect, cell: CGRect, viewport: CGRect, navigation: CGRect) -> Bool {
    guard [image, cell, viewport, navigation].allSatisfy({ !$0.isEmpty && !$0.isNull && !$0.isInfinite }) else { return false }
    return cell.contains(image) && viewport.contains(image) && !navigation.intersects(image)
}
