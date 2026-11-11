import XCTest

/// Native manual entry + production encrypted store. No seed writes, model
/// transport or network. Relaunch retains the same isolated UUID namespace.
final class UserProfileUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "profile-fixture-AX"; tree.lifetime = .keepAlways; add(tree)
            let screen = XCTAttachment(screenshot: app.screenshot())
            screen.name = "profile-fixture-screen"; screen.lifetime = .keepAlways; add(screen)
        }
        app.terminate()
    }

    func testCreateReplaceDeleteAndHistorySurviveRelaunch() {
        launch(); openProfile()
        add("Prefer quiet")
        let original = item("Prefer quiet")
        XCTAssertTrue(original.waitForExistence(timeout: 5))
        let originalID = original.identifier.replacingOccurrences(of: "profile.item.", with: "")
        tap("profile.edit." + originalID, scroll: true)
        write("Prefer central", clearing: true)
        save()
        XCTAssertTrue(item("Prefer central").waitForExistence(timeout: 5))
        XCTAssertFalse(item("Prefer quiet").exists)
        showHistory("Prefer quiet")

        launch(reset: false); openProfile()
        let replacement = item("Prefer central")
        XCTAssertTrue(replacement.waitForExistence(timeout: 5))
        let nextID = replacement.identifier.replacingOccurrences(of: "profile.item.", with: "")
        XCTAssertNotEqual(nextID, originalID, "Replacement must create a new row")
        tap("profile.delete." + nextID, scroll: true)
        XCTAssertTrue(app.staticTexts["profile.empty"].firstMatch.waitForExistence(timeout: 5))
        launch(reset: false); openProfile()
        XCTAssertTrue(app.staticTexts["profile.empty"].firstMatch.waitForExistence(timeout: 5))
        showHistory("Prefer central")
        let oldHistory = history("Prefer quiet")
        revealLearningElement(oldHistory, in: app, visibility: .readableText)
        XCTAssertTrue(oldHistory.exists, "Both superseded rows survive relaunch")
    }

    func testSensitiveTextNeverPublishes() {
        launch(); openProfile()
        add("Prefer tea")
        reject("password: dummy1234")
        launch(reset: false); openProfile()
        XCTAssertTrue(item("Prefer tea").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile.count"].firstMatch.label, "現用 1／20 條")
        XCTAssertFalse(item("password: dummy1234").exists)
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
    }

    func testMultipleSentencesNeverPublish() {
        launch(); openProfile()
        add("Prefer tea")
        reject("Two. Sentences.")
        launch(reset: false); openProfile()
        XCTAssertTrue(item("Prefer tea").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile.count"].firstMatch.label, "現用 1／20 條")
        XCTAssertFalse(item("Two. Sentences.").exists)
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
    }

    func testDuplicateAndCancelledTextNeverPublish() {
        launch(); openProfile()
        add("Prefer tea")
        reject("Prefer tea")
        tap("profile.add", scroll: true)
        write("Cancelled profile")
        tap("profile.editor.cancel")
        launch(reset: false); openProfile()
        XCTAssertTrue(item("Prefer tea").waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["profile.count"].firstMatch.label, "現用 1／20 條")
        XCTAssertFalse(item("Cancelled profile").exists)
        XCTAssertFalse(app.buttons["profile.history"].firstMatch.exists)
    }

    func testMasterSwitchAndTwiceConfirmedClearPersist() {
        launch(); openProfile()
        add("Keep this profile")
        tap("profile.close")
        let toggle = app.switches["memory.toggle.useMemory"].firstMatch
        revealLearningElement(toggle, in: app)
        let native = toggle.switches.firstMatch
        let control = native.exists ? native : toggle
        ready(control); control.tap()
        let off = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [off], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["memory.error"].firstMatch.exists)
        launch(reset: false); openProfile()
        XCTAssertTrue(app.staticTexts["profile.disabled"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(item("Keep this profile").exists, "Turning memory off preserves saved profile")
        tap("profile.close")
        tap("memory.clear", scroll: true)
        _ = advanceClearToFinalConfirmation()
        tap("memory.clear.cancel")
        absent(app.buttons["memory.clear.confirm"].firstMatch)
        tap("memory.profile.open", scroll: true)
        XCTAssertTrue(item("Keep this profile").waitForExistence(timeout: 5), "Cancel at second confirmation preserves profile")
        tap("profile.close")
        tap("memory.clear", scroll: true)
        let confirm = advanceClearToFinalConfirmation()
        confirm.tap()
        absent(app.buttons["memory.clear.confirm"].firstMatch)
        launch(reset: false); openProfile()
        XCTAssertTrue(app.staticTexts["profile.empty"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["profile.disabled"].firstMatch.exists, "Clear preserves master switch")
        XCTAssertFalse(history("Keep this profile").exists, "Clear erases history as well")
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].firstMatch.waitForExistence(timeout: 10))
    }

    private func openProfile() {
        tap("navigation.memory")
        tap("memory.profile.open", scroll: true)
        XCTAssertTrue(app.staticTexts["profile.scope"].firstMatch.waitForExistence(timeout: 5))
    }

    private func add(_ text: String) {
        tap("profile.add", scroll: true); write(text); save()
    }

    private func reject(_ text: String) {
        tap("profile.add", scroll: true)
        write(text)
        tap("profile.editor.save")
        let error = app.staticTexts["profile.editor.error"].firstMatch
        revealLearningElement(error, in: app, visibility: .readableText)
        XCTAssertTrue(error.exists)
        XCTAssertTrue(app.buttons["profile.editor.save"].firstMatch.exists, "Rejected edit must remain open")
        tap("profile.editor.cancel")
        absent(app.buttons["profile.editor.save"].firstMatch)
    }

    private func write(_ text: String, clearing: Bool = false) {
        let editor = app.textViews["profile.editor.text"].firstMatch
        ready(editor); editor.tap()
        dismissKeyboardIntroductionIfPresented()
        guard selectLatinKeyboard() else { return }
        if clearing { tap("profile.editor.clear") }
        XCTAssertEqual(editor.value as? String, "")
        var entered = ""
        for character in text {
            editor.typeText(String(character)); entered.append(character)
            // faf SE: the timed predicate expired, but its failure AX and
            // screenshot contained the exact first character.
            // typeText already waits for App idle; check its resulting value
            // directly, preserving exact per-character assertions without a
            // separate polling deadline, retries or synthesized input repairs.
            let received = editor.value as? String
            XCTAssertEqual(received, entered, "Every native character must arrive exactly before saving")
            guard received == entered else { return }
        }
        XCTAssertEqual(editor.value as? String, text)
        tap("profile.editor.done")
    }

    private func save() {
        tap("profile.editor.save")
        absent(app.buttons["profile.editor.save"].firstMatch)
        XCTAssertFalse(app.staticTexts["profile.error"].firstMatch.exists)
    }

    private func item(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "profile.item.", text)).firstMatch
    }

    private func history(_ text: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "profile.history.item.", text)).firstMatch
    }

    private func showHistory(_ text: String) {
        let button = app.buttons["profile.history"].firstMatch
        revealLearningElement(button, in: app)
        tapHistoryLabel(button)
        // Observe the post-action state within the existing readiness bound.
        // 4f read collapsed immediately after the tap; a timing cause is unproved.
        let expanded = NSPredicate(format: "value == %@", "已展開")
        if !expanded.evaluate(with: button) {
            let expectation = XCTNSPredicateExpectation(predicate: expanded, object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        }
        XCTAssertEqual(button.value as? String, "已展開")
        let row = history(text)
        revealLearningElement(row, in: app, visibility: .readableText)
        XCTAssertTrue(row.exists)
    }

    private func tapHistoryLabel(_ button: XCUIElement) {
        // 4f fixture AX exposed this native text child after a button tap left
        // history collapsed. Target the visible label once; the old tap was
        // inside both AX frames, so this does not establish a hit-area cause.
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

    private func tap(_ identifier: String, scroll: Bool = false) {
        let element = app.buttons[identifier].firstMatch
        if scroll { revealLearningElement(element, in: app) }
        ready(element); element.tap()
    }

    private func advanceClearToFinalConfirmation() -> XCUIElement {
        // 61f current: after a logged Continue tap, failure AX still showed
        // stage 1 and no confirm button. Scope the action to the presented
        // sheet, verify its actual geometry, and require stage 2 even on the
        // cancellation branch. One native tap; no input retry or extra delay.
        let stage = app.staticTexts["memory.clear.stage"].firstMatch
        XCTAssertTrue(stage.waitForExistence(timeout: 5))
        XCTAssertEqual(stage.label, "第一步：確認清除範圍")
        let viewport = app.scrollViews.containing(.staticText, identifier: "memory.clear.stage").firstMatch
        XCTAssertTrue(viewport.exists)
        let navigation = app.navigationBars["清除資料"].firstMatch
        XCTAssertTrue(navigation.exists)
        let next = viewport.buttons["memory.clear.continue"].firstMatch
        let confirm = viewport.buttons["memory.clear.confirm"].firstMatch
        XCTAssertFalse(confirm.exists, "Final confirmation must not be available at stage 1")
        ready(next)
        let frame = next.frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(app.frame.contains(frame) && viewport.frame.contains(frame))
        XCTAssertGreaterThanOrEqual(frame.minY, navigation.frame.maxY)
        XCTAssertFalse(app.keyboards.firstMatch.exists)
        next.tap()
        // Keep the existing 10-second readiness bound, then assert the actual
        // product state. Absence after cancel alone did not prove stage 2.
        ready(confirm)
        XCTAssertEqual(stage.label, "第二步：最後確認")
        XCTAssertFalse(next.exists)
        return confirm
    }

    private func ready(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == true AND hittable == true AND enabled == true")
        if predicate.evaluate(with: element) { return }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }

    private func absent(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == false")
        if predicate.evaluate(with: element) { return }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed)
    }

    // Same native English selection and exact QuickPath introduction gate as
    // BrowserLoginUITests. No simulator preference writes or input repair.
    private func selectLatinKeyboard() -> Bool {
        let keyboard = app.keyboards.firstMatch
        func latin() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q"])).firstMatch.exists
                && keyboard.keys.matching(NSPredicate(format: "label IN %@", ["a", "A"])).firstMatch.exists
        }
        if latin() { return true }
        let globe = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一個鍵盤"])).firstMatch
        ready(globe); globe.press(forDuration: 1)
        let english = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "English (US)")).firstMatch
        ready(english); english.tap()
        dismissKeyboardIntroductionIfPresented()
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in latin() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Native English keyboard must be selected before ASCII fixture entry")
        return result == .completed
    }

    private func dismissKeyboardIntroductionIfPresented() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 10))
        let button = app.buttons["Continue"].firstMatch
        guard button.waitForExistence(timeout: 3) else { return }
        let explanation = app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].firstMatch
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            explanation.exists && button.exists && button.isEnabled && button.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
        button.tap(); absent(button)
    }
}
