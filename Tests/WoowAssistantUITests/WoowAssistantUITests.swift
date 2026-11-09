import XCTest

final class WoowAssistantUITests: XCTestCase {
    private let sections = ["chat", "browser", "tools", "memory", "settings"]

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testEverySectionIsReachableOnIPhone() {
        let app = launchApp()

        // Visit in both directions so a page cannot trap the user away from navigation.
        for section in sections + Array(sections.reversed()) {
            openSection(section, in: app)
            for destination in sections {
                let button = app.buttons["navigation.\(destination)"]
                waitUntilHittable(button)
                XCTAssertEqual(button.value as? String, destination == section ? "已選取" : "未選取")
            }
        }
    }

    func testSendIsDisabledAndRetainsTypedDraft() {
        let app = launchApp()
        let send = app.buttons["chat.send"]
        XCTAssertTrue(send.waitForExistence(timeout: 5))
        XCTAssertFalse(send.isEnabled)
        XCTAssertTrue(app.staticTexts["chat.explanation"].label.contains("尚未連接模型"))

        let draft = app.textFields["chat.draft"]
        waitUntilHittable(draft)
        draft.tap()
        draft.typeText("Keep this draft 42")
        assertDraft("Keep this draft 42", in: app)
        XCTAssertFalse(send.isEnabled, "Typing must not enable an unimplemented send operation.")

        // Return is Done, not an alternate route that silently sends or clears text.
        draft.typeText("\n")
        let keyboardHidden = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: app.keyboards.firstMatch
        )
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardHidden], timeout: 5), .completed)
        assertDraft("Keep this draft 42", in: app)
        XCTAssertTrue(send.exists)
        XCTAssertFalse(send.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(send.frame))
        // A physical tap at the disabled control must not erase or submit the draft.
        send.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        assertDraft("Keep this draft 42", in: app)
        XCTAssertFalse(send.isEnabled)
    }

    func testDraftSurvivesEverySectionAndKeyboardNavigation() {
        let app = launchApp()
        let draft = app.textFields["chat.draft"]
        waitUntilHittable(draft)
        draft.tap()
        draft.typeText("Draft survives navigation 73")

        // The first switch intentionally happens with the iPhone keyboard still visible.
        for section in sections.dropFirst() {
            openSection(section, in: app)
            openSection("chat", in: app)
            assertDraft("Draft survives navigation 73", in: app)
            XCTAssertFalse(app.buttons["chat.send"].isEnabled)
        }
    }

    func testBrowserAndToolsHonestlyReportUnimplementedFeatures() {
        let app = launchApp()
        openSection("browser", in: app)
        XCTAssertEqual(app.staticTexts["browser.status"].label, "瀏覽器尚未實作")
        XCTAssertTrue(app.staticTexts["browser.explanation"].label.contains("尚未載入網頁"))
        XCTAssertTrue(app.staticTexts["browser.explanation"].label.contains("未進行網站連線驗證"))
        XCTAssertFalse(app.staticTexts["公開 HTTPS 頁面已通過第一層安全政策"].exists)
        XCTAssertEqual(app.webViews.count, 0)

        openSection("tools", in: app)
        XCTAssertEqual(app.staticTexts["tools.status"].label, "Skills 與 MCP尚未實作")
        XCTAssertTrue(app.staticTexts["tools.explanation"].label.contains("未連接 MCP 伺服器"))
        XCTAssertTrue(app.staticTexts["tools.explanation"].label.contains("沒有可呼叫的工具"))
    }

    func testPhoneControlIsExcludedFromEverySection() {
        let app = launchApp()
        let excludedLabels = ["手機操作", "手機控制", "App 操作", "螢幕錄影", "無障礙控制", "ADB", "USB helper"]
        let navigation = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "navigation."))

        for section in sections {
            openSection(section, in: app)
            XCTAssertEqual(navigation.count, sections.count)
            for label in excludedLabels {
                let excluded = app.descendants(matching: .any)
                    .matching(NSPredicate(format: "label CONTAINS[c] %@", label))
                XCTAssertEqual(excluded.count, 0, "Excluded phone-control UI found in \(section): \(label)")
            }
        }
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW"]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        return app
    }

    private func openSection(_ section: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons["navigation.\(section)"]
        waitUntilHittable(button, file: file, line: line)
        button.tap()
        XCTAssertTrue(app.staticTexts["\(section).status"].waitForExistence(timeout: 5), file: file, line: line)
    }

    private func waitUntilHittable(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed, file: file, line: line)
    }

    private func assertDraft(_ expected: String, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let field = app.textFields["chat.draft"]
        XCTAssertTrue(field.waitForExistence(timeout: 5), file: file, line: line)
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: field)
        XCTAssertEqual(XCTWaiter.wait(for: [matches], timeout: 5), .completed, file: file, line: line)
    }
}
