import XCTest

/// Native controls, actual ChatSession/archive/notification adapter. The explicit
/// DEBUG model fixture supplies only two bounded text deltas, never stored data.
final class ChatStreamingUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 240 }
    override func tearDownWithError() throws { app.terminate() }

    func testPartialBecomesCompletedReplyAndDurableArchive() {
        launch(); configure(); disableMemory(); enableNotifications()
        assertNotificationAttempts(0)
        compose("[fixture:stream-complete]"); tap("chat.send")
        assertLabel(app.staticTexts["chat.partialReply"].firstMatch, "串流測試：第一段")
        assertLabel(app.staticTexts["chat.partialStatus"].firstMatch, "回覆產生中・尚未完成，未保存")
        XCTAssertFalse(identifiedText("chat.message.1.assistant").exists)
        XCTAssertFalse(app.buttons["chat.archive"].firstMatch.isEnabled)
        assertNotificationAttempts(0)
        let completed = identifiedText("chat.message.1.assistant")
        wait(NSPredicate(format: "label == %@", "串流測試：第一段；完整回覆。"), on: completed, seconds: 35)
        XCTAssertEqual(completed.label, "串流測試：第一段；完整回覆。")
        XCTAssertFalse(app.staticTexts["chat.partialReply"].firstMatch.exists)
        XCTAssertFalse(app.buttons["chat.cancel"].firstMatch.exists)
        XCTAssertNotEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:stream-complete]")
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.archiveNotice"].firstMatch.exists)
        assertNotificationAttempts(1)
        launch(reset: false); tap("chat.archive")
        let saved = row("[fixture:stream-complete]"); ready(saved); saved.tap()
        assertLabel(identifiedText("archive.turn.0.assistant"), "串流測試：第一段；完整回覆。")
        print("CHAT_STREAM_UI partialObserved=1 completedPair=1 archiveRelaunch=1 completionNotificationAttempts=1")
    }

    func testCancelRetainsDraftAndPartialWithoutArchiveOrCompletionNotification() {
        launch(); configure(); disableMemory(); enableNotifications()
        assertNotificationAttempts(0)
        compose("[fixture:stream-cancel]"); tap("chat.send")
        assertLabel(app.staticTexts["chat.partialReply"].firstMatch, "串流測試：第一段")
        assertLabel(app.staticTexts["chat.partialStatus"].firstMatch, "回覆產生中・尚未完成，未保存")
        tap("chat.cancel")
        assertLabel(app.staticTexts["chat.partialStatus"].firstMatch, "已取消・部分回覆未保存")
        assertLabel(app.staticTexts["chat.partialReply"].firstMatch, "串流測試：第一段")
        XCTAssertEqual(app.textFields["chat.draft"].firstMatch.value as? String, "[fixture:stream-cancel]")
        XCTAssertFalse(identifiedText("chat.message.0.user").exists)
        XCTAssertFalse(identifiedText("chat.message.1.assistant").exists)
        assertNotificationAttempts(0)
        tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        tap("archive.close")
        assertNotificationAttempts(0)
        launch(reset: false)
        XCTAssertFalse(app.staticTexts["chat.partialReply"].firstMatch.exists, "Partials are not claimed durable")
        XCTAssertFalse(identifiedText("chat.message.1.assistant").exists)
        tap("chat.archive")
        XCTAssertTrue(app.staticTexts["archive.empty"].firstMatch.waitForExistence(timeout: 10))
        print("CHAT_STREAM_UI partialObserved=1 cancelled=1 draftRetained=1 archiveAbsentAfterRelaunch=1 completionNotificationAttempts=0")
    }

    private func disableMemory() {
        navigate("memory")
        let toggle = app.switches["memory.toggle.useMemory"].firstMatch
        revealLearningElement(toggle, in: app); ready(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        // SwiftUI can expose the labelled row as an outer Switch. Target the
        // actual native child when present, as the existing Memory drivers do.
        let native = toggle.switches.firstMatch
        let target = native.exists ? native : toggle
        ready(target)
        XCTAssertTrue(app.frame.contains(target.frame)); XCTAssertFalse(target.frame.isEmpty)
        XCTAssertTrue(toggle.frame.contains(target.frame))
        XCTAssertLessThanOrEqual(target.frame.maxY, app.buttons["navigation.chat"].firstMatch.frame.minY)
        print("CHAT_STREAM_UI memorySwitchNativeChild=\(native.exists ? 1 : 0) initialValue=1")
        target.tap()
        wait(NSPredicate(format: "value == %@", "0"), on: toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertFalse(app.staticTexts["memory.error"].firstMatch.exists)
        navigate("chat")
    }
    private func enableNotifications() {
        navigate("settings"); tap("settings.notifications", scroll: true)
        let authorization = app.staticTexts["notifications.authorization"].firstMatch
        revealLearningElement(authorization, in: app, visibility: .readableText)
        wait(NSPredicate(format: "value IN %@", ["notDetermined", "authorized"]), on: authorization)
        let before = authorization.value as? String
        XCTAssertTrue(before == "notDetermined" || before == "authorized", "No simulator permission resets")
        tap("notifications.enable", scroll: true)
        if before == "notDetermined" {
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 15))
            let text = alert.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " ")
            XCTAssertTrue(text.contains("渥屋助理") || text.contains("WoowAssistant"))
            XCTAssertTrue(text.contains("通知") || text.localizedCaseInsensitiveContains("notifications"))
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允許", "允许"])).firstMatch
            ready(allow); allow.tap()
        }
        revealLearningElement(authorization, in: app, visibility: .readableText)
        wait(NSPredicate(format: "value == %@", "authorized"), on: authorization, seconds: 15)
        let enabled = app.staticTexts["notifications.enabled"].firstMatch
        revealLearningElement(enabled, in: app, visibility: .readableText)
        assertLabel(enabled, "已開啟")
        let back = app.navigationBars["任務通知"].buttons.firstMatch; ready(back); back.tap()
        navigate("chat")
    }
    private func assertNotificationAttempts(_ expected: Int) {
        let observation = app.staticTexts["stream.fixture.notifications"].firstMatch
        wait(NSPredicate(format: "value == %@", String(expected)), on: observation)
        XCTAssertEqual(observation.value as? String, String(expected), "Actual OS adapter add attempts, not transient banner absence")
    }
    private func wait(_ predicate: NSPredicate, on element: XCUIElement, seconds: TimeInterval = 10) {
        if !element.exists || !predicate.evaluate(with: element) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: seconds), .completed)
        }
        XCTAssertTrue(element.exists)
    }
    private func launch(reset: Bool = true) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace, "-UITestChatStreaming"]
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
        // Move focus directly between visible fields. write() still requires
        // a hittable field, the native keyboard, and an exact value readback.
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
        assertLabel(identifiedText("chat.message.1.assistant"), "測試回覆：" + text)
        XCTAssertFalse(app.staticTexts["chat.error"].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["chat.archiveNotice"].firstMatch.exists)
    }
    private func row(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "archive.row.", title)).firstMatch
    }
    private func identifiedText(_ identifier: String) -> XCUIElement {
        // Selectable SwiftUI Text can be an AX Other on iOS 17 and StaticText
        // on newer runtimes. Keep the exact identifier and label assertions.
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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
        // ccfd SE AX labels this native control 下一個鍵盤 (identifier emoji).
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
