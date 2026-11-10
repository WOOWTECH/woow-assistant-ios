import XCTest
import CoreGraphics

final class BrowserWorkspaceUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 240 }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription); tree.name = "workspace-fixture-AX"; tree.lifetime = .keepAlways; add(tree)
            let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "workspace-fixture"; shot.lifetime = .keepAlways; add(shot)
        }
        app.terminate()
    }
    func testTabsKeepIndependentPageStateAndRestoreSelection() {
        launch(reset: true)
        open("workspace-one")
        let note = app.webViews.textFields["Tab note"]
        XCTAssertTrue(note.waitForExistence(timeout: 10)); note.tap(); note.typeText("First note")
        app.buttons["navigation.browser"].tap()
        library()
        let firstID = tabs.firstMatch.identifier
        app.buttons["browser.tabs.new"].tap()
        open("workspace-two")
        library()
        XCTAssertEqual(tabs.count, 2)
        app.buttons[firstID].tap()
        XCTAssertTrue(app.webViews.textFields["Tab note"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.webViews.textFields["Tab note"].value as? String, "First note")
        launch(reset: false)
        XCTAssertTrue(dom("Workspace first").waitForExistence(timeout: 75))
        library()
        XCTAssertEqual(tabs.count, 2)
        let selected = tabs.matching(NSPredicate(format: "value == %@", "已選取")).firstMatch
        XCTAssertEqual(selected.identifier, firstID)
        let closeID = firstID.replacingOccurrences(of: "browser.tabs.select.", with: "browser.tabs.close.")
        app.buttons[closeID].tap()
        XCTAssertEqual(tabs.count, 1)
        app.buttons["browser.library.close"].tap()
        XCTAssertTrue(dom("Workspace second").waitForExistence(timeout: 75))
    }
    func testBookmarkRenameHistoryClearAndRelaunch() {
        launch(reset: true); open("workspace-one")
        library(); chooseSection("書籤")
        app.buttons["browser.bookmarks.add"].tap()
        let rename = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.bookmark.rename.")).firstMatch
        XCTAssertTrue(rename.waitForExistence(timeout: 5)); rename.tap()
        let input = app.alerts.textFields.firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        let originalTitle = "Workspace first"
        XCTAssertEqual(input.value as? String, originalTitle)
        // This short fixture title fits the SE alert. Place the caret after
        // it, then use real keyboard deletion. Selecting the floating edit
        // menu makes XCTest's default interruption handler cancel this alert.
        input.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        input.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: originalTitle.count))
        input.typeText("My saved page")
        XCTAssertEqual(input.value as? String, "My saved page")
        app.alerts.buttons["儲存"].tap()
        let bookmark = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.bookmark.open.")).firstMatch
        XCTAssertTrue(bookmark.label.contains("My saved page"))
        chooseSection("歷史"); XCTAssertEqual(history.count, 1)
        app.buttons["browser.history.clear"].tap()
        // iOS 26 exposes the single confirmation action as nested Buttons
        // with the same identifier, label and frame. Scope to the sheet so
        // its first match still names the exact destructive action.
        let confirmClear = app.sheets.buttons["browser.history.confirmClear"].firstMatch
        XCTAssertEqual(confirmClear.label, "清除歷史")
        confirmClear.tap()
        XCTAssertTrue(app.staticTexts["browser.history.empty"].waitForExistence(timeout: 5))
        chooseSection("書籤"); XCTAssertTrue(bookmark.label.contains("My saved page"))
        launch(reset: false)
        XCTAssertTrue(dom("Workspace first").waitForExistence(timeout: 75))
        library(); chooseSection("書籤")
        XCTAssertTrue(bookmark.waitForExistence(timeout: 5)); XCTAssertTrue(bookmark.label.contains("My saved page"))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.bookmark.delete.")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["browser.bookmarks.empty"].waitForExistence(timeout: 5))
    }
    func testManualQueryPageAndRealJavaScriptDialog() {
        launch(reset: true); open("workspace-one?q=manual#section")
        XCTAssertFalse(app.buttons["browser.research"].isEnabled)
        XCTAssertFalse(app.buttons["browser.interactions"].isEnabled)
        app.webViews.buttons["Confirm fixture"].tap()
        XCTAssertTrue(app.staticTexts["browser.dialog.message"].waitForExistence(timeout: 5))
        app.buttons["browser.dialog.cancel"].tap()
        XCTAssertTrue(dom("CANCELLED").waitForExistence(timeout: 5))
        app.webViews.buttons["Confirm fixture"].tap()
        app.buttons["browser.dialog.accept"].tap()
        XCTAssertTrue(dom("CONFIRMED").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
    }
    private var tabs: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.tabs.select.")) }
    private var history: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.history.open.")) }
    private func launch(reset: Bool) {
        app.terminate()
        app.launchArguments = ["-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.buttons["navigation.browser"].waitForExistence(timeout: 10)); app.buttons["navigation.browser"].tap()
    }
    private func open(_ path: String) {
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        if let value = field.value as? String, value.hasPrefix("https://") { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count)) }
        field.typeText("https://research.example.invalid/" + path + "\n")
        XCTAssertTrue(dom(path.hasPrefix("workspace-two") ? "Workspace second" : "Workspace first").waitForExistence(timeout: 75))
    }
    private func library() {
        app.buttons["browser.library"].tap()
        XCTAssertTrue(app.buttons["browser.library.close"].waitForExistence(timeout: 5))
    }
    private func chooseSection(_ title: String) { app.segmentedControls["browser.library.sections"].buttons[title].tap() }
    private func dom(_ text: String) -> XCUIElement { app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch }
}
