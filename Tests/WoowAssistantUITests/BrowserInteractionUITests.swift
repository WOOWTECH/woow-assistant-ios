import XCTest
import CoreGraphics

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
        let disabledMatches = controls(matching: "Disabled action")
        let disabled = disabledMatches.firstMatch
        // Materialize the native Form row before reading its disabled trait.
        // This fixes an offscreen assertion precondition, not a proven AX cause.
        revealDisabledRowForStateAssertion(disabled)
        XCTAssertEqual(disabledMatches.count, 1, "The disabled fixture control must match exactly one native row.")
        XCTAssertTrue(disabled.exists)
        XCTAssertFalse(disabled.isEnabled)
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
        assertInitialNote()
        XCTAssertTrue(dom("NOT SAVED").exists)
        openControls()
        choose("Save locally")
        XCTAssertTrue(app.buttons["browser.interaction.approve"].exists)
        tap("browser.interaction.close")
        XCTAssertTrue(dom("NOT SAVED").exists)
        assertInitialNote()
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
        assertInitialNote()
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
    private func assertInitialNote(file: StaticString = #filePath, line: UInt = #line) {
        // 6d480d8 iOS 17 AX exposes Public note as a sibling StaticText;
        // the input itself has no label. Identify the fixture's native WebView
        // by its app identifier (legacy/modern AX types can differ), then its
        // sole non-password input. Never select by the value being asserted
        // or fall back to the browser address/native review editor.
        let web = app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@", "browser.webView")).firstMatch
        XCTAssertTrue(web.exists, "Expected the fixture's native browser container.", file: file, line: line)
        XCTAssertTrue(web.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@", "Interaction fixture")).firstMatch.exists,
                      "The local interaction fixture must be visible after closing review.", file: file, line: line)
        let matches = web.textFields
        let count = matches.count
        XCTAssertEqual(count, 1, "Expected the unique fixture input.", file: file, line: line)
        guard count == 1 else { return }
        let input = matches.firstMatch
        let label = input.label
        XCTAssertTrue(label == "Public note" || label.hasPrefix("Public note ") ||
                      web.staticTexts.matching(NSPredicate(format: "label == %@", "Public note")).firstMatch.exists,
                      "The unique fixture input must retain its Public note label.", file: file, line: line)
        XCTAssertEqual(input.value as? String, "initial", file: file, line: line)
    }
    private func control(_ label: String) -> XCUIElement {
        controls(matching: label).firstMatch
    }
    private func controls(matching label: String) -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "browser.control.", label))
    }
    /// State inspection only: a disabled button need not be hittable. Never use
    /// this helper to authorize a tap; all actionable Form controls retain the
    /// existing full-visibility AND hittability checks in revealLearningElement.
    private func revealDisabledRowForStateAssertion(_ element: XCUIElement,
                                                    file: StaticString = #filePath, line: UInt = #line) {
        let candidates = app.collectionViews.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
        guard let form = candidates.first(where: { $0.isHittable && !$0.frame.intersection(app.frame).isEmpty }) else {
            XCTFail("A visible native Form is required to inspect the disabled row.", file: file, line: line)
            return
        }
        let navigation = app.navigationBars.firstMatch
        let keyboard = app.keyboards.firstMatch
        for attempt in 0...8 {
            var bounds = form.frame.intersection(app.frame)
            if navigation.exists, navigation.isHittable {
                let top = max(bounds.minY, navigation.frame.maxY)
                bounds = CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
            }
            if keyboard.exists {
                let bottom = min(bounds.maxY, keyboard.frame.minY)
                bounds.size.height = max(0, bottom - bounds.minY)
            }
            bounds = bounds.insetBy(dx: 0, dy: 4)
            let exists = element.exists
            let frame = exists ? element.frame : .zero
            if exists && learningFrameIsVisible(frame, in: bounds, visibility: .fullyVisible) { return }
            guard attempt < 8 else {
                print("Fixture disabled-row visibility: exists=\(exists); frame=\(frame); viewport=\(bounds)")
                XCTFail("Disabled row must be fully visible before reading isEnabled.", file: file, line: line)
                return
            }
            if exists && frame.minY < bounds.minY { form.swipeDown() }
            else { form.swipeUp() }
        }
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
        if field.elementType == .textView {
            // The iOS 17 failure screenshot/AX shows the complete native
            // multiline editor, but element.tap() left it unfocused. Use a
            // point inside that verified frame; never tap a screen coordinate
            // or bypass the keyboard and actual input-value assertions.
            XCTAssertTrue(field.isHittable)
            XCTAssertFalse(field.frame.isEmpty)
            XCTAssertTrue(app.frame.contains(field.frame))
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
        } else { field.tap() }
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        field.typeText(value)
        if field.elementType == .textView { XCTAssertEqual(field.value as? String, value) }
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
