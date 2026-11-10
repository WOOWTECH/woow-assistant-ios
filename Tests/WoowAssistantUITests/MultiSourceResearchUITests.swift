import XCTest

/// Local HTML and synthetic model only. Real field entry, WebKit, runner and
/// rendered citations; separate live tests own public HTTPS/model acceptance.
final class MultiSourceResearchUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 300 }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let image = XCTAttachment(screenshot: app.screenshot())
            image.name = "multisource-synthetic-fixture-failure"; image.lifetime = .keepAlways; add(image)
        }
        app.terminate()
    }

    func testConfirmedSourcesProduceActualQuotesAndDiscloseFixtureLimits() {
        launch()
        tap("navigation.settings")
        enter("https://model.example.invalid/v1", into: app.textFields["settings.baseURL"])
        enter("fixture-model", into: app.textFields["settings.model"])
        enter("fixture-only-not-a-real-key", into: app.secureTextFields["settings.apiKey"])
        tap("settings.save")
        XCTAssertTrue(app.staticTexts["settings.notice"].waitForExistence(timeout: 5))
        tap("navigation.browser")
        let previousAddress = app.textFields["browser.address"].value as? String
        tap("browser.multiResearch")
        fillRoots(second: "https://comparison.example.invalid/start")
        tap("multiResearch.start")
        let status = app.staticTexts["multiResearch.status"]
        revealLearningElement(status, in: app, visibility: .readableText)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "已交付部分結果；仍有來源或證據不足。"), object: status)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 180), .completed,
                       "Wait for actual isolated WebKit reads and checked model citations")
        let result = app.staticTexts["multiResearch.result"]
        revealLearningElement(result, in: app, visibility: .readableText)
        XCTAssertEqual(result.label, "部分結果", "Fixture must disclose that this is not public network/live-model acceptance")
        let count = app.staticTexts["multiResearch.citedSourceCount"]
        revealLearningElement(count, in: app, visibility: .readableText)
        XCTAssertEqual(count.label, "已引用 2 個網站")
        for (source, quote) in [("source-1", "SOURCE_ALPHA_OBSERVED"), ("source-2", "SOURCE_BETA_OBSERVED")] {
            let element = app.staticTexts["multiResearch.quote.\(source)"]
            revealLearningElement(element, in: app, visibility: .readableText)
            XCTAssertEqual(element.label, quote)
        }
        for (page, url) in [("page-1", "https://research.example.invalid/start"),
                            ("page-2", "https://comparison.example.invalid/start"),
                            ("page-3", "https://research.example.invalid/details")] {
            let receipt = app.staticTexts["multiResearch.receipt.\(page)"]
            revealLearningElement(receipt, in: app, visibility: .readableText)
            XCTAssertEqual(receipt.label, url)
        }
        tap("multiResearch.close")
        XCTAssertTrue(app.textFields["browser.address"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["browser.address"].value as? String, previousAddress, "Shared browser has not navigated to either research source")
    }

    func testDuplicateOriginsAreRejectedBeforeModelAccessOrWebKitReads() {
        launch(); tap("navigation.browser"); tap("browser.multiResearch")
        fillRoots(second: "https://research.example.invalid/details")
        tap("multiResearch.start")
        let error = app.staticTexts["multiResearch.error"]
        revealLearningElement(error, in: app, visibility: .readableText)
        XCTAssertTrue(error.waitForExistence(timeout: 5))
        XCTAssertTrue(error.label.contains("不同網站"))
        XCTAssertFalse(app.staticTexts["multiResearch.result"].exists)
        XCTAssertFalse(app.staticTexts["multiResearch.receipt.page-1"].exists)
    }

    private func launch() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
            "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestMultiSourceResearch"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
    }
    private func fillRoots(second: String) {
        enterResearchField("比較兩個合成來源的頁面標記", into: app.textViews["multiResearch.goal"].exists ? app.textViews["multiResearch.goal"] : app.textFields["multiResearch.goal"])
        enterResearchField("https://research.example.invalid/start", into: app.textFields["multiResearch.rootText1"])
        enterResearchField(second, into: app.textFields["multiResearch.rootText2"])
    }
    private func enterResearchField(_ text: String, into field: XCUIElement) {
        revealLearningElement(field, in: app)
        if field.elementType == .textView {
            // The exact iOS 17 failure left this visible editor unfocused.
            // Use the same inner-field tap as the passing BrowserLearning cases.
            XCTAssertTrue(field.isHittable)
            XCTAssertFalse(field.frame.isEmpty)
            XCTAssertTrue(app.frame.contains(field.frame))
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        } else { field.tap() }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "The exact research field must contain the entered value")
        // The multiline goal's Return key inserts a newline and leaves the
        // keyboard visible. Close it using the public toolbar before asking the
        // Form scroll helper to reveal another field (the keyboard also exposes
        // a CollectionView for its candidate bar).
        let done = app.buttons["multiResearch.keyboardDone"]
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            done.exists && done.isHittable && done.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
        XCTAssertFalse(done.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(done.frame), "Keyboard toolbar must be inside the app")
        done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            !self.app.keyboards.firstMatch.exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 5), .completed)
    }
    private func enter(_ text: String, into field: XCUIElement) {
        revealLearningElement(field, in: app)
        field.tap(); field.typeText(text + "\n")
    }
    private func tap(_ identifier: String) {
        let button = app.buttons[identifier]
        if identifier.hasPrefix("navigation.") || identifier == "multiResearch.close" || identifier == "browser.multiResearch" {
            XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
        } else { revealLearningElement(button, in: app); button.tap() }
    }
}
