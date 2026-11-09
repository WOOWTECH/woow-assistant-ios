import XCTest

/// Local HTML, actual WKWebView/isolated DOM executor and native approval UI.
/// No model stub is used to simulate DOM effects. No credentials or network.
final class BrowserInteractionUITests: XCTestCase {
    private var app = XCUIApplication()
    private let fixtureURL = "https://research.example.invalid/interaction"
    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "browser-interaction-local-fixture-AX"; tree.lifetime = .keepAlways; add(tree)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "browser-interaction-local-fixture"; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        app.terminate()
    }

    func testApprovedTypeSelectAndClickExecuteRealForm() {
        launchFixture()
        openControls()
        XCTAssertFalse(control("Password").exists)
        XCTAssertFalse(control("Upload excluded").exists)
        XCTAssertFalse(control("Disabled action").isEnabled)
        choose("Public note")
        let value = "Approved note"
        enter(value, into: editor)
        tap("browser.interaction.done")
        tap("browser.interaction.proposeType")
        XCTAssertEqual(app.staticTexts["browser.interaction.previewText"].label, value)
        approve()
        refresh()
        choose("Mode")
        XCTAssertFalse(app.buttons["browser.interaction.option.2"].isEnabled)
        tap("browser.interaction.option.1")
        approve()
        refresh()
        choose("Save locally")
        XCTAssertEqual(app.staticTexts["browser.interaction.previewKind"].value as? String, "click")
        approve()
        tap("browser.interaction.close")
        // Read actual page text, not the native executor's dispatch status.
        let saved = dom("SAVED Approved note advanced")
        XCTAssertTrue(saved.waitForExistence(timeout: 10))
        XCTAssertFalse(dom("NOT SAVED").exists)
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
    }

    func testRefusalAndClosingReviewDoNotTypeOrSubmit() {
        launchFixture()
        openControls()
        choose("Public note")
        enter("must never appear", into: editor)
        tap("browser.interaction.done")
        tap("browser.interaction.proposeType")
        tap("browser.interaction.reject")
        wait(app.staticTexts["browser.interaction.status"], "label == %@", "已拒絕；沒有執行動作。")
        XCTAssertFalse(app.buttons["browser.interaction.approve"].exists)
        tap("browser.interaction.close")
        XCTAssertEqual(note.value as? String, "initial")
        XCTAssertTrue(dom("NOT SAVED").exists)
        openControls()
        choose("Save locally")
        XCTAssertTrue(app.buttons["browser.interaction.approve"].exists)
        tap("browser.interaction.close")
        XCTAssertTrue(dom("NOT SAVED").exists)
        XCTAssertEqual(note.value as? String, "initial")
        openControls()
        XCTAssertFalse(app.buttons["browser.interaction.approve"].exists,
                       "Dismissing approval cannot leave a reusable grant.")
        tap("browser.interaction.close")
    }

    func testReloadInvalidatesPendingIdentityAndRequiresNewApproval() {
        launchFixture()
        openControls()
        choose("Save locally")
        XCTAssertTrue(app.buttons["browser.interaction.approve"].exists)
        tap("browser.interaction.reload")
        wait(app.buttons["browser.interaction.approve"], "exists == false")
        tap("browser.interaction.close")
        wait(app.staticTexts["browser.status"], "label == %@", "頁面已載入", timeout: 75)
        XCTAssertTrue(dom("NOT SAVED").exists)
        XCTAssertEqual(note.value as? String, "initial")
        openControls()
        XCTAssertFalse(app.buttons["browser.interaction.approve"].exists)
        choose("Save locally")
        approve()
        tap("browser.interaction.close")
        XCTAssertTrue(dom("SAVED initial basic").waitForExistence(timeout: 10),
                      "Only the new document's separately approved action may execute.")
    }

    private func launchFixture() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
                               "-UITestNamespace", UUID().uuidString, "-UITestResetStorage"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 15))
        tap("navigation.browser")
        enter(fixtureURL + "\n", into: app.textFields["browser.address"])
        wait(app.staticTexts["browser.status"], "label == %@", "頁面已載入", timeout: 75)
        XCTAssertEqual(app.textFields["browser.address"].value as? String, fixtureURL)
        XCTAssertTrue(dom("Interaction fixture").exists)
    }
    private func openControls() {
        tap("browser.interactions")
        XCTAssertTrue(app.buttons["browser.interaction.close"].waitForExistence(timeout: 5))
        wait(app.staticTexts["browser.interaction.status"], "label == %@", "控制項已更新；網頁欄位值不會傳給模型。")
        XCTAssertFalse(dom("Interaction fixture").exists, "Native modal boundary must still hide real DOM AX children.")
    }
    private func refresh() {
        tap("browser.interaction.refresh")
        wait(app.staticTexts["browser.interaction.status"], "label == %@", "控制項已更新；網頁欄位值不會傳給模型。")
    }
    private func choose(_ label: String) {
        let element = control(label)
        revealLearningElement(element, in: app)
        XCTAssertTrue(element.isEnabled)
        element.tap()
    }
    private func approve() {
        tap("browser.interaction.approve")
        wait(app.staticTexts["browser.interaction.status"], "label == %@", "已送出單次 DOM 動作；請確認網頁結果，不代表網站任務已成功。")
        XCTAssertFalse(app.staticTexts["browser.interaction.error"].exists)
        XCTAssertFalse(app.buttons["browser.interaction.approve"].exists)
    }
    private var editor: XCUIElement {
        let multiline = app.textViews["browser.interaction.text"]
        return multiline.exists ? multiline : app.textFields["browser.interaction.text"]
    }
    private var note: XCUIElement { app.webViews.textFields["Public note"].firstMatch }
    private func control(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "browser.control.", label)).firstMatch
    }
    private func dom(_ label: String) -> XCUIElement {
        app.webViews.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }
    private func tap(_ id: String) {
        let element = app.buttons[id]
        // These controls are outside the Form: bottom app navigation, the
        // browser toolbar, the sheet's navigation bar and keyboard accessory.
        // The Form helper intentionally excludes those regions from its
        // content viewport, so scrolling a Form can never reveal them.
        let fixedChrome: Set<String> = ["navigation.browser", "browser.interactions",
                                        "browser.interaction.close", "browser.interaction.done"]
        if fixedChrome.contains(id) { waitForFixedChrome(element) }
        else { revealLearningElement(element, in: app) }
        element.tap()
    }
    private func enter(_ value: String, into field: XCUIElement) {
        if field.identifier == "browser.address" { waitForFixedChrome(field) }
        else { revealLearningElement(field, in: app) }
        field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(value)
    }
    private func waitForFixedChrome(_ element: XCUIElement) {
        wait(element, "exists == true AND hittable == true AND enabled == true")
        // Do not weaken Form checks or use blind coordinates. Fixed chrome
        // must be fully inside the app window and genuinely hittable itself.
        let frame = element.frame
        XCTAssertFalse(frame.isEmpty)
        XCTAssertTrue(app.frame.contains(frame), "Fixed chrome must fit inside the app window: \(element.identifier)")
    }
    private func wait(_ element: XCUIElement, _ format: String, _ value: String? = nil, timeout: TimeInterval = 15) {
        let predicate = value.map { NSPredicate(format: format, $0) } ?? NSPredicate(format: format)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed)
    }
}
