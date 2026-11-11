import XCTest

/// Native interaction with the real encrypted archive. Only model replies use
/// the existing isolated UI fixture; no archive rows are seeded by the test.
final class ConversationArchiveUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 240 }
    override func tearDownWithError() throws { app.terminate() }

    func testTwoCompletedConversationsSurviveRelaunchAndOpenExplicitly() {
        launch(); configure()
        send("Archive first"); tap("chat.newConversation")
        send("Archive second")
        launch(reset: false)
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists, "No active conversation autoload")
        tap("chat.archive")
        XCTAssertTrue(row("Archive first").waitForExistence(timeout: 10))
        XCTAssertTrue(row("Archive second").exists)
        ready(row("Archive first")); row("Archive first").tap()
        assertLabel(app.staticTexts["archive.turn.0.user"].firstMatch, "Archive first")
        assertLabel(app.staticTexts["archive.turn.0.assistant"].firstMatch, "測試回覆：Archive first")
        tap("archive.open")
        assertLabel(app.staticTexts["chat.message.0.user"].firstMatch, "Archive first")
        assertLabel(app.staticTexts["chat.message.1.assistant"].firstMatch, "測試回覆：Archive first")
        XCTAssertFalse(app.buttons["chat.cancel"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.profileReceipt"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.memoryReceipt"].firstMatch.exists)
    }

    func testChangedModelAllowsViewingButDisablesContinuation() {
        launch(); configure(); send("Archive original")
        navigate("settings")
        let model = app.textFields["settings.model"].firstMatch
        revealLearningElement(model, in: app); ready(model); model.tap(); prepareKeyboard()
        XCTAssertEqual(model.value as? String, "fixture")
        model.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 7))
        XCTAssertEqual(model.value as? String, "")
        model.typeText("different"); XCTAssertEqual(model.value as? String, "different")
        tap("settings.dismissKeyboard"); tap("settings.save", scroll: true)
        XCTAssertFalse(app.staticTexts["settings.error"].firstMatch.exists)
        navigate("chat"); tap("chat.archive")
        ready(row("Archive original")); row("Archive original").tap()
        assertLabel(app.staticTexts["archive.turn.0.assistant"].firstMatch, "測試回覆：Archive original")
        XCTAssertTrue(app.staticTexts["archive.destinationMismatch"].firstMatch.exists)
        let open = app.buttons["archive.open"].firstMatch
        XCTAssertTrue(open.exists); XCTAssertFalse(open.isEnabled)
        XCTAssertFalse(app.buttons["chat.cancel"].firstMatch.exists)
    }

    func testDeletionRemainsAbsentAfterRelaunch() {
        launch(); configure(); send("Archive delete")
        tap("chat.archive"); ready(row("Archive delete")); row("Archive delete").tap()
        tap("archive.delete"); tap("archive.delete.confirm")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(row("Archive delete").exists)
        launch(reset: false); tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(row("Archive delete").exists)
    }

    func testCancelledRunAndUnsentDraftAreNotClaimedAsSaved() {
        launch(); configure()
        compose("[fixture:wait]"); tap("chat.send")
        ready(app.buttons["chat.cancel"].firstMatch)
        XCTAssertFalse(app.buttons["chat.archive"].firstMatch.isEnabled, "History must not compete with an arriving approval sheet")
        tap("chat.cancel")
        assertLabel(app.staticTexts["chat.status"].firstMatch, "模型已設定")
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:wait]")
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists)
        tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        launch(reset: false)
        XCTAssertFalse(app.staticTexts["chat.message.0.user"].firstMatch.exists)
        XCTAssertNotEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:wait]")
        tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace]
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
    private func send(_ text: String) {
        compose(text); tap("chat.send")
        assertLabel(app.staticTexts["chat.message.1.assistant"].firstMatch, "測試回覆：" + text)
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.archiveNotice"].firstMatch.exists)
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
        let globe = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一個鍵盤"])).firstMatch
        ready(globe); globe.press(forDuration: 1)
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
