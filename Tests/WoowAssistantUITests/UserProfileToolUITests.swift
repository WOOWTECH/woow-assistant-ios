import XCTest

/// Fixed model commands through ordinary Chat's real review and encrypted store.
/// The DEBUG client never writes a profile; all mutations require native UI
/// approval. This is fixture-model UI coverage, not live-model acceptance.
final class UserProfileToolUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private let receiptText = "本次對話曾儲存個人檔案；可到資料頁查看目前內容。"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            // This namespace contains only synthetic profile text and a dummy
            // model key. Never enable these attachments for live credentials.
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "profile-tool-fixture-failure-AX"
            tree.lifetime = .keepAlways; add(tree)
            let screen = XCTAttachment(screenshot: app.screenshot())
            screen.name = "profile-tool-fixture-failure-screen"
            screen.lifetime = .keepAlways; add(screen)
        }
        app.terminate()
    }

    func testApprovedChatAdditionPersistsInProfileAfterRelaunch() {
        launch(); configureModel()
        openProfile(); assertEmptyProfile(); returnToChat()
        requestReview("Remember Prefer tea", operation: "新增", before: nil, after: "Prefer tea")
        approveReview(assistantIndex: 1)
        openProfile()
        assertProfileCount(1)
        let entry = profileItem("Prefer tea")
        assertReadable(entry, equals: "Prefer tea")
        let entryID = entry.identifier
        XCTAssertTrue(entryID.hasPrefix("profile.item."))
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)

        launch(reset: false); openProfile()
        assertProfileCount(1)
        assertReadable(profileItem("Prefer tea"), equals: "Prefer tea")
        XCTAssertEqual(profileItem("Prefer tea").identifier, entryID,
                       "Relaunch must load the actual saved entry, not create a replacement.")
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
    }

    func testDeclinedChatAdditionPreservesDraftAndNeverCreatesProfileEntry() {
        launch(); configureModel()
        let prompt = "Remember Prefer quiet"
        requestReview(prompt, operation: "新增", before: nil, after: "Prefer quiet")
        tap("profileTool.decline")
        absent(app.buttons["profileTool.approve"].firstMatch)
        assertLabel(app.staticTexts["chat.error"].firstMatch,
                    "你已拒絕這次個人檔案修改；尚未儲存，訊息草稿已保留。")
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, prompt)
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].firstMatch.exists)
        ready(app.buttons["chat.send"].firstMatch)

        openProfile(); assertEmptyProfile(); returnToChat()
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, prompt,
                       "Inspecting the profile must preserve the refused request's draft.")
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        launch(reset: false); openProfile(); assertEmptyProfile()
    }

    func testReviewedReplacementOfManualEntryPersistsWithHistoryAfterRelaunch() {
        launch(); configureModel()
        openProfile(); assertEmptyProfile()
        addManualProfile("Prefer tea")
        let originalID = profileItem("Prefer tea").identifier
        returnToChat()
        requestReview("Replace Prefer tea with Prefer walks", operation: "修改",
                      before: "Prefer tea", after: "Prefer walks")
        approveReview(assistantIndex: 1)
        openProfile()
        assertProfileCount(1)
        assertReadable(profileItem("Prefer walks"), equals: "Prefer walks")
        XCTAssertFalse(profileItem("Prefer tea").exists)
        let replacementID = profileItem("Prefer walks").identifier
        XCTAssertNotEqual(replacementID, originalID)

        launch(reset: false); openProfile()
        assertProfileCount(1)
        assertReadable(profileItem("Prefer walks"), equals: "Prefer walks")
        XCTAssertEqual(profileItem("Prefer walks").identifier, replacementID)
        XCTAssertFalse(profileItem("Prefer tea").exists)
        assertSingleHistory("Prefer tea", originalIdentifier: originalID)
    }

    func testReviewedDeletionOfManualEntryPersistsWithHistoryAfterRelaunch() {
        launch(); configureModel()
        openProfile(); assertEmptyProfile()
        addManualProfile("Prefer walks")
        let originalID = profileItem("Prefer walks").identifier
        returnToChat()
        requestReview("Delete Prefer walks", operation: "刪除", before: "Prefer walks",
                      after: nil)
        approveReview(assistantIndex: 1)
        openProfile()
        assertProfileCount(0)
        assertReadable(app.staticTexts["profile.empty"].firstMatch, equals: "尚未儲存個人檔案。")
        XCTAssertFalse(profileItem("Prefer walks").exists)

        launch(reset: false); openProfile()
        assertProfileCount(0)
        assertReadable(app.staticTexts["profile.empty"].firstMatch, equals: "尚未儲存個人檔案。")
        XCTAssertFalse(profileItem("Prefer walks").exists)
        assertSingleHistory("Prefer walks", originalIdentifier: originalID)
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["uitest.banner"].firstMatch.exists)
        if !reset { assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定") }
    }

    private func configureModel() {
        navigate("settings")
        writeASCII("https://model.invalid/v1", into: app.textFields["settings.baseURL"].firstMatch)
        tap("settings.dismissKeyboard")
        writeASCII("fixture", into: app.textFields["settings.model"].firstMatch)
        tap("settings.dismissKeyboard")
        let key = app.secureTextFields["settings.apiKey"].firstMatch
        revealLearningElement(key, in: app)
        ready(key); key.tap()
        prepareLatinKeyboard()
        key.typeText("fixture-key")
        tap("settings.dismissKeyboard")
        tap("settings.save", scroll: true)
        XCTAssertTrue(app.staticTexts["settings.notice"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["settings.error"].firstMatch.exists)
        navigate("chat")
        assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定")
    }

    private func requestReview(_ prompt: String, operation: String, before: String?, after: String?) {
        let draft = app.textFields["chat.draft"].firstMatch
        writeASCII(prompt, into: draft, scroll: false)
        tap("chat.dismissKeyboard")
        XCTAssertEqual(draft.value as? String, prompt)
        tap("chat.send")
        let operationLabel = app.staticTexts["profileTool.operation"].firstMatch
        let outcome = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            operationLabel.exists || app.staticTexts["chat.error"].firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [outcome], timeout: 15), .completed)
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        assertReadable(operationLabel, equals: operation)
        assertReadable(app.staticTexts["profileTool.quote"].firstMatch, equals: prompt)
        if let before { assertReadable(app.staticTexts["profileTool.before"].firstMatch, equals: before) }
        else { XCTAssertFalse(app.staticTexts["profileTool.before"].firstMatch.exists) }
        if let after { assertReadable(app.staticTexts["profileTool.after"].firstMatch, equals: after) }
        else { XCTAssertFalse(app.staticTexts["profileTool.after"].firstMatch.exists) }
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists,
                       "A proposal cannot publish a saved receipt before approval.")
        ready(app.buttons["profileTool.approve"].firstMatch)
        ready(app.buttons["profileTool.decline"].firstMatch)
    }

    private func approveReview(assistantIndex: Int) {
        tap("profileTool.approve")
        absent(app.buttons["profileTool.approve"].firstMatch)
        assertLabel(app.staticTexts["chat.profileReceipt"].firstMatch, receiptText)
        assertLabel(app.staticTexts["chat.message.\(assistantIndex).assistant"].firstMatch, "個人檔案工具已完成。")
        assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定")
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
    }

    private func openProfile() {
        navigate("memory")
        XCTAssertFalse(app.staticTexts["memory.unavailable"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["memory.error"].firstMatch.exists)
        tap("memory.profile.open", scroll: true)
        XCTAssertTrue(app.staticTexts["profile.scope"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["profile.disabled"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["profile.unavailable"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["profile.error"].firstMatch.exists)
    }

    private func returnToChat() {
        tap("profile.close")
        absent(app.buttons["profile.close"].firstMatch)
        navigate("chat")
    }

    private func addManualProfile(_ text: String) {
        tap("profile.add", scroll: true)
        writeASCII(text, into: app.textViews["profile.editor.text"].firstMatch, chunkSize: 1)
        tap("profile.editor.done")
        tap("profile.editor.save")
        absent(app.buttons["profile.editor.save"].firstMatch)
        XCTAssertFalse(app.staticTexts["profile.error"].firstMatch.exists)
        assertReadable(profileItem(text), equals: text)
    }

    private func profileItem(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@",
                                            "profile.item.", text)).firstMatch
    }

    private func assertProfileCount(_ count: Int) {
        assertReadable(app.staticTexts["profile.count"].firstMatch, equals: "現用 \(count)／20 條")
    }

    private func assertSingleHistory(_ text: String, originalIdentifier: String) {
        let history = app.buttons["profile.history"].firstMatch
        revealLearningElement(history, in: app)
        XCTAssertEqual(history.label, "已替換或刪除的紀錄（1）")
        tapHistoryLabel(history)
        assertValue(history, "已展開")
        let identifier = originalIdentifier.replacingOccurrences(of: "profile.item.", with: "profile.history.item.")
        assertReadable(app.staticTexts[identifier].firstMatch, equals: text)
        XCTAssertFalse(profileItem(text).exists)
    }

    private func tapHistoryLabel(_ button: XCUIElement) {
        // Match the native child exposed by the 4f history failure AX. Keep a
        // single tap and all expanded-state/history assertions; efficacy still
        // requires a native rerun because the original tap was inside both frames.
        ready(button)
        XCTAssertEqual(button.value as? String, "已收合")
        let label = button.staticTexts.matching(NSPredicate(format: "label == %@", button.label)).firstMatch
        XCTAssertTrue(label.exists)
        XCTAssertTrue(label.isHittable)
        let frame = label.frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(button.frame.contains(frame) && app.frame.contains(frame))
        label.tap()
    }

    private func assertEmptyProfile() {
        assertProfileCount(0)
        assertReadable(app.staticTexts["profile.empty"].firstMatch, equals: "尚未儲存個人檔案。")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "profile.item.")).firstMatch.exists)
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
    }

    private func navigate(_ section: String) {
        let button = app.buttons["navigation.\(section)"].firstMatch
        ready(button)
        XCTAssertFalse(button.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(button.frame))
        // Existing authoring evidence: a hit-test alone did not select Memory.
        // Use the verified native button center once, then require its state.
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertValue(button, "已選取")
        XCTAssertTrue(app.staticTexts["\(section).status"].firstMatch.waitForExistence(timeout: 5))
    }

    private func writeASCII(_ text: String, into field: XCUIElement, chunkSize: Int = 16, scroll: Bool = true) {
        if scroll { revealLearningElement(field, in: app) }
        ready(field)
        if !scroll {
            // 856e8ec current AX: draft y=673.7...707.7 was fully visible
            // above navigation y=788, outside the messages ScrollView (661.7).
            // A sibling composer cannot be revealed by scrolling messages.
            XCTAssertEqual(field.identifier, "chat.draft")
            let frame = field.frame
            XCTAssertFalse(frame.isEmpty)
            XCTAssertTrue(app.frame.contains(frame))
            let navigation = app.buttons["navigation.chat"].firstMatch
            ready(navigation)
            XCTAssertLessThanOrEqual(frame.maxY, navigation.frame.minY)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { XCTAssertLessThanOrEqual(frame.maxY, keyboard.frame.minY) }
        }
        field.tap()
        prepareLatinKeyboard()
        var remaining = text[...]
        var entered = ""
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(entered.isEmpty ? 1 : chunkSize))
            field.typeText(chunk); entered += chunk; remaining = remaining.dropFirst(chunk.count)
            let actual = field.value as? String
            XCTAssertEqual(actual, entered, "Native input must match exactly; never repair or retry lost characters.")
            guard actual == entered else { return }
        }
        XCTAssertEqual(field.value as? String, text)
    }

    private func prepareLatinKeyboard() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        dismissKeyboardIntroductionIfPresented()
        let keyboard = app.keyboards.firstMatch
        func latin() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q"])).firstMatch.exists
                && keyboard.keys.matching(NSPredicate(format: "label IN %@", ["a", "A"])).firstMatch.exists
        }
        if latin() { return }
        let globe = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一個鍵盤"])).firstMatch
        ready(globe); globe.press(forDuration: 1)
        let english = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "English (US)")).firstMatch
        ready(english); english.tap()
        dismissKeyboardIntroductionIfPresented()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in latin() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
    }

    private func dismissKeyboardIntroductionIfPresented() {
        let button = app.buttons["Continue"].firstMatch
        guard button.waitForExistence(timeout: 3) else { return }
        let explanation = app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].firstMatch
        XCTAssertTrue(explanation.exists, "Only the known native keyboard introduction may be dismissed.")
        ready(button); button.tap(); absent(button)
    }

    private func assertReadable(_ element: XCUIElement, equals text: String) {
        revealLearningElement(element, in: app, visibility: .readableText)
        XCTAssertEqual(element.label, text)
    }

    private func assertLabel(_ element: XCUIElement, _ text: String) {
        let predicate = NSPredicate(format: "exists == true AND label == %@", text)
        if predicate.evaluate(with: element) { return }
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    private func assertValue(_ element: XCUIElement, _ text: String) {
        let predicate = NSPredicate(format: "value == %@", text)
        if predicate.evaluate(with: element) { return }
        let expected = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }

    private func tap(_ identifier: String, scroll: Bool = false) {
        let button = app.buttons[identifier].firstMatch
        if scroll { revealLearningElement(button, in: app) }
        ready(button); button.tap()
    }

    private func ready(_ element: XCUIElement) {
        // 4f current reached the delete case's final history checks at 239s,
        // then exceeded its unchanged 240s allowance during termination.
        // Keep the same predicate and wait; return immediately if already true.
        let predicate = NSPredicate(format: "exists == true AND hittable == true AND enabled == true")
        if predicate.evaluate(with: element) { return }
        let ready = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
    }

    private func absent(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == false")
        if predicate.evaluate(with: element) { return }
        let gone = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
