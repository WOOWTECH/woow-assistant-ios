import XCTest

final class BrowserSiteModesUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 180 }
    override func tearDownWithError() throws { app.terminate() }

    func testManualGETChoiceReloadsAndSurvivesRelaunch() {
        launch(reset: true)
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        field.typeText("https://research.example.invalid/workspace-one\n")
        let note = app.webViews.textFields["Tab note"]
        XCTAssertTrue(note.waitForExistence(timeout: 75))
        note.tap(); note.typeText("Retain this note")
        app.buttons["navigation.browser"].tap()
        let mode = app.buttons["browser.siteMode"]
        XCTAssertTrue(mode.waitForExistence(timeout: 10)); XCTAssertEqual(mode.value as? String, "手機版")
        mode.tap(); app.buttons["browser.siteMode.desktop"].tap()
        XCTAssertEqual(mode.value as? String, "電腦版")
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", ""), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 30), .completed, "Known manual GET must reload and replace the form field")
        XCTAssertTrue(app.staticTexts["browser.siteMode.notice"].exists)
        XCTAssertTrue(app.staticTexts["browser.siteMode.notice"].label.contains("正在重新整理"))
        launch(reset: false)
        XCTAssertTrue(app.webViews.staticTexts["Workspace first"].waitForExistence(timeout: 75))
        XCTAssertEqual(mode.value as? String, "電腦版")
        mode.tap(); app.buttons["browser.siteMode.mobile"].tap()
        XCTAssertEqual(mode.value as? String, "手機版")
        launch(reset: false)
        XCTAssertTrue(app.webViews.staticTexts["Workspace first"].waitForExistence(timeout: 75))
        XCTAssertEqual(mode.value as? String, "手機版")
    }

    private func launch(reset: Bool) {
        app.terminate()
        app.launchArguments = ["-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.buttons["navigation.browser"].waitForExistence(timeout: 10))
        app.buttons["navigation.browser"].tap()
    }
}
