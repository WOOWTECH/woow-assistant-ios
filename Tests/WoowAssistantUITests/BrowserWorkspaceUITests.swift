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
        // 08ebb8f iOS 17.5 read the label immediately after Save and failed;
        // its teardown AX attachment already showed this same bookmark renamed.
        // Wait for the published label, then retain the history/relaunch checks.
        let renamed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label CONTAINS %@", "My saved page"),
            object: bookmark)
        XCTAssertEqual(XCTWaiter.wait(for: [renamed], timeout: 5), .completed,
                       "The saved bookmark name must reach accessibility before continuing.")
        XCTAssertTrue(bookmark.label.contains("My saved page"))
        chooseSection("歷史"); XCTAssertEqual(history.count, 1)
        app.buttons["browser.history.clear"].tap()
        // 6d480d8 iOS 17 uses Other for this exact titled dialog; iOS 26
        // uses Sheet with duplicate nested Buttons. Retain the dialog boundary
        // and exact destructive action independently of those AX differences.
        let confirmation = app.descendants(matching: .any).matching(NSPredicate(
            format: "(elementType == %d OR elementType == %d) AND label == %@",
            XCUIElement.ElementType.sheet.rawValue, XCUIElement.ElementType.other.rawValue,
            "清除瀏覽歷史？書籤與網站登入資料會保留。")).firstMatch
        let confirmClear = confirmation.buttons.matching(NSPredicate(
            format: "identifier == %@ AND label == %@",
            "browser.history.confirmClear", "清除歷史")).firstMatch
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
    // Real UIKit find controls. No query injection, JavaScript search, model,
    // selection retry, or skip when the native panel cannot be exercised.
    func testNativePageFindQueryNextPreviousAndClose() {
        launch(reset: true, nativeFindEnglish: true); open("page-find")
        let field = openNativeFind()
        field.tap(); field.typeText("WOOW_FIND_ORCHID")
        XCTAssertEqual(field.value as? String, "WOOW_FIND_ORCHID")
        let next = app.buttons["find.nextButton"]
        let previous = app.buttons["find.previousButton"]
        waitForEnabled(next, true); waitForEnabled(previous, true)
        next.tap(); next.tap()
        let last = dom("WOOW_FIND_ORCHID third 茶香")
        let viewport = app.otherElements["browser.viewport"]
        let movedToLast = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard last.exists, viewport.exists else { return false }
            let visible = viewport.frame.intersection(self.app.frame)
            return !visible.isEmpty && !last.frame.isEmpty && visible.contains(last.frame) && last.isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedToLast], timeout: 10), .completed,
                       "Two native Next actions must reveal the third real match below the 900pt spacer.")
        let geometry = XCTAttachment(string: "viewport=\(viewport.frame) match=\(last.frame) keyboard=\(app.keyboards.firstMatch.frame)\n" + app.debugDescription)
        geometry.name = "find-third-match-visible-AX"; geometry.lifetime = .keepAlways; add(geometry)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "find-third-match-visible"; shot.lifetime = .keepAlways; add(shot)
        previous.tap()
        let movedBack = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            last.exists && viewport.exists && !viewport.frame.intersects(last.frame)
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [movedBack], timeout: 10), .completed,
                       "Previous must return to the second real match above the spacer.")
        closeNativeFind()
        let fresh = openNativeFind()
        XCTAssertNotEqual(fresh.value as? String, "WOOW_FIND_ORCHID")
        fresh.tap(); fresh.typeText("NOT_PRESENT_LITERAL")
        XCTAssertEqual(fresh.value as? String, "NOT_PRESENT_LITERAL")
        let result = app.staticTexts["find.resultLabel"]
        let noMatches = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", "0"), object: result)
        guard XCTWaiter.wait(for: [noMatches], timeout: 10) == .completed else {
            XCTFail("Native find must report zero results for the absent literal.")
            return
        }
        let first = dom("WOOW_FIND_ORCHID first 茶香")
        let address = app.textFields["browser.address"]
        let expectedURL = "https://research.example.invalid/page-find"
        func noMatchStateIsVisible() -> Bool {
            let visible = viewport.frame.intersection(app.frame)
            return result.exists && result.label == "0"
                && (fresh.value as? String) == "NOT_PRESENT_LITERAL"
                && (address.value as? String) == expectedURL
                && !app.staticTexts["browser.error"].exists
                && first.exists && !visible.isEmpty && visible.contains(first.frame) && first.isHittable
        }
        guard noMatchStateIsVisible() else {
            XCTFail("Zero results must preserve the exact query, URL, and visible first document match.")
            return
        }
        // All three native runtimes expose the arrows without a Disabled AX
        // state at zero results. Tap the real controls only if they are safely
        // visible and operable; never bypass a disabled control by coordinate.
        let keyboard = app.keyboards.firstMatch
        for arrow in [next, previous] {
            guard arrow.exists, arrow.isEnabled, arrow.isHittable,
                  app.frame.contains(arrow.frame),
                  !keyboard.exists || arrow.frame.maxY <= keyboard.frame.minY else {
                XCTFail("The native zero-result \(arrow.identifier) control is not safely tappable.")
                return
            }
            arrow.tap()
            guard noMatchStateIsVisible() else {
                XCTFail("Tapping native \(arrow.identifier) with zero results changed the query, URL, count, or visible document.")
                return
            }
        }
        closeNativeFind()
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
        XCTAssertEqual(address.value as? String, expectedURL)
    }

    func testNativePageFindClearsOnReloadAndTabSwitch() {
        launch(reset: true, nativeFindEnglish: true); open("page-find")
        let field = openNativeFind(); field.tap(); field.typeText("WOOW_FIND_ORCHID")
        XCTAssertEqual(field.value as? String, "WOOW_FIND_ORCHID")
        library()
        XCTAssertFalse(app.searchFields.firstMatch.exists)
        let firstID = tabs.firstMatch.identifier
        app.buttons["browser.tabs.new"].tap()
        XCTAssertFalse(app.buttons["browser.find"].isEnabled)
        open("workspace-two")
        library(); app.buttons[firstID].tap()
        XCTAssertTrue(dom("Find fixture").waitForExistence(timeout: 10))
        let returned = openNativeFind()
        XCTAssertNotEqual(returned.value as? String, "WOOW_FIND_ORCHID")
        returned.tap(); returned.typeText("WOOW_FIND_ORCHID")
        XCTAssertEqual(returned.value as? String, "WOOW_FIND_ORCHID")
        app.buttons["browser.reload"].tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.searchFields.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
        XCTAssertTrue(dom("Find fixture").waitForExistence(timeout: 75))
        let reloaded = openNativeFind()
        XCTAssertNotEqual(reloaded.value as? String, "WOOW_FIND_ORCHID")
        closeNativeFind()
    }

    private func openNativeFind() -> XCUIElement {
        let button = app.buttons["browser.find"]
        waitForEnabled(button, true); button.tap()
        let field = app.searchFields["find.searchField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10), "The actual UIKit find field must appear.")
        return field
    }
    private func waitForEnabled(_ element: XCUIElement, _ enabled: Bool) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == %@", NSNumber(value: enabled)), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    private func closeNativeFind() {
        let done = app.buttons["find.doneButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 5)); done.tap()
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.searchFields.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [dismissed], timeout: 10), .completed)
    }
    private var tabs: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.tabs.select.")) }
    private var history: XCUIElementQuery { app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "browser.history.open.")) }
    private func launch(reset: Bool, nativeFindEnglish: Bool = false) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", nativeFindEnglish ? "(en)" : "(zh-Hant)",
                               "-AppleLocale", nativeFindEnglish ? "en_US" : "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
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
        let title = path.hasPrefix("page-find") ? "Find fixture" : (path.hasPrefix("workspace-two") ? "Workspace second" : "Workspace first")
        XCTAssertTrue(dom(title).waitForExistence(timeout: 75))
    }
    private func library() {
        app.buttons["browser.library"].tap()
        XCTAssertTrue(app.buttons["browser.library.close"].waitForExistence(timeout: 5))
    }
    private func chooseSection(_ title: String) { app.segmentedControls["browser.library.sections"].buttons[title].tap() }
    private func dom(_ text: String) -> XCUIElement { app.webViews.staticTexts.matching(NSPredicate(format: "label == %@", text)).firstMatch }
}
