import XCTest

final class BrowserSearchUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 180 }
    override func tearDownWithError() throws { app.terminate() }

    func testCustomSearchQueryAndSettingsSurviveRelaunch() {
        launch()
        let settings = app.buttons["browser.searchEngine.open"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        XCTAssertTrue(settings.label.contains("Bing"))
        tap(settings)
        XCTAssertTrue(app.buttons["browser.searchEngine.select.bing"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.buttons["browser.searchEngine.select.bing"].value as? String, "已選取")
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.searchEngine.remove.custom:")).firstMatch.exists,
                       "The fresh namespace must contain no previously saved custom engine")
        tap(app.buttons["browser.searchEngine.select.google"], scroll: true)
        XCTAssertEqual(app.buttons["browser.searchEngine.select.google"].value as? String, "已選取")
        let name = app.textFields["browser.searchEngine.name"]
        enter("Fixture Search", in: name, scroll: true)
        // Use the form's real Next action. With the name keyboard open, the
        // template is obscured; scrolling via the background browser's tab bar
        // cannot establish the presented sheet's visible input area.
        name.typeText("\n")
        let template = app.textFields["browser.searchEngine.template"]
        enter("https://research.example.invalid/search?q=%s&lang=en", in: template)
        // Submit the single-line native field to resign focus. Do not close
        // the settings sheet, patch its text, or press Add behind the keyboard.
        template.typeText("\n")
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 10), .completed)
        XCTAssertEqual(name.value as? String, "Fixture Search")
        XCTAssertEqual(template.value as? String, "https://research.example.invalid/search?q=%s&lang=en")
        let add = app.buttons["browser.searchEngine.add"]
        tap(add, scroll: true)
        tap(app.buttons["browser.searchEngine.close"])
        XCTAssertTrue(settings.label.contains("Fixture Search"))
        let address = app.textFields["browser.address"]
        enter("fixture cats & dogs/+%", in: address)
        address.typeText("\n")
        let query = app.staticTexts["browser.search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 75))
        XCTAssertTrue(query.label.contains("fixture cats & dogs/+%"))
        XCTAssertTrue((address.value as? String)?.contains("q=fixture%20cats%20%26%20dogs%2F%2B%25") == true)
        tap(app.buttons["browser.library"])
        tap(app.segmentedControls["browser.library.sections"].buttons["歷史"])
        let history = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.history.open.")).firstMatch
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        revealLearningElement(history, in: app)
        XCTAssertTrue(history.label.contains("搜尋：fixture cats & dogs/+%"))
        tap(app.buttons["browser.library.close"])
        launch()
        XCTAssertTrue(query.waitForExistence(timeout: 75))
        XCTAssertTrue(query.label.contains("fixture cats & dogs/+%"))
        XCTAssertTrue(settings.label.contains("Fixture Search"))
        tap(settings)
        let remove = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.searchEngine.remove.custom:")).firstMatch
        tap(remove, scroll: true)
        revealLearningElement(app.buttons["browser.searchEngine.select.bing"], in: app)
        XCTAssertEqual(app.buttons["browser.searchEngine.select.bing"].value as? String, "已選取")
        tap(app.buttons["browser.searchEngine.close"])
        XCTAssertTrue(settings.label.contains("Bing"))
    }

    private func launch() {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode", "-UITestNamespace", namespace]
        // This test owns a new UUID namespace. Clearing its empty WebKit store
        // adds an unrelated asynchronous reset before settings are usable. Both
        // launches keep this same isolated store to exercise actual persistence.
        app.launch()
        XCTAssertTrue(app.buttons["navigation.browser"].waitForExistence(timeout: 10))
        tap(app.buttons["navigation.browser"])
    }

    private func enter(_ text: String, in field: XCUIElement, scroll: Bool = false) {
        if scroll { revealLearningElement(field, in: app) }
        ready(field)
        assertVisibleField(field)
        field.tap()
        prepareKeyboard()
        // The real focus transition must put the entire field above the native
        // keyboard. Do not type into an offscreen or covered field.
        assertVisibleField(field)
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "Native field input must match exactly; no replacement or retyping repair")
    }

    private func assertVisibleField(_ field: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let frame = field.frame
        XCTAssertFalse(frame.isEmpty, file: file, line: line)
        XCTAssertTrue(app.frame.contains(frame), "Native input must be fully on screen", file: file, line: line)
        XCTAssertTrue(field.isHittable, "Native input must remain operable", file: file, line: line)
        let keyboard = app.keyboards.firstMatch
        if keyboard.exists {
            XCTAssertLessThanOrEqual(frame.maxY, keyboard.frame.minY,
                                     "Native input must be fully above the keyboard", file: file, line: line)
        }
        let settingsNavigation = app.navigationBars["搜尋引擎"]
        if settingsNavigation.exists {
            XCTAssertGreaterThanOrEqual(frame.minY, settingsNavigation.frame.maxY,
                                        "Native input must be below the settings navigation bar", file: file, line: line)
        }
    }

    private func tap(_ element: XCUIElement, scroll: Bool = false) {
        if scroll { revealLearningElement(element, in: app) }
        ready(element)
        XCTAssertTrue(app.frame.contains(element.frame)); XCTAssertFalse(element.frame.isEmpty)
        element.tap()
    }

    private func ready(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        if !predicate.evaluate(with: element) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 10), .completed)
        }
    }

    // Same native English-keyboard selection and exact QuickPath introduction
    // gate used by the existing archive/profile/login UI tests. App stays zh-Hant.
    private func prepareKeyboard() {
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        dismissIntroduction()
        let keyboard = app.keyboards.firstMatch
        func latin() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q"])).firstMatch.exists
                && keyboard.keys.matching(NSPredicate(format: "label IN %@", ["a", "A"])).firstMatch.exists
        }
        if latin() { return }
        let globe = app.buttons.matching(NSPredicate(
            format: "label IN %@", ["Next keyboard", "下一個鍵盤"]
        )).firstMatch
        ready(globe); globe.press(forDuration: 1)
        let english = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "English (US)")).firstMatch
        ready(english); english.tap(); dismissIntroduction()
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in latin() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, "Native Latin keys must be ready before fixture input")
    }

    private func dismissIntroduction() {
        let button = app.buttons["Continue"].firstMatch
        guard button.waitForExistence(timeout: 3) else { return }
        XCTAssertTrue(app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].firstMatch.exists)
        ready(button); button.tap()
        let gone = NSPredicate(format: "exists == false")
        if !gone.evaluate(with: button) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: gone, object: button)], timeout: 5), .completed)
        }
    }
}
