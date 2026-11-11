import XCTest

/// Actual English screens after a user changes the app language. The system
/// stays zh-Hant and storage is isolated; no model, MCP or notification action
/// is authorized by these cases.
final class AppLanguagePhase2UITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private let chatDraft = "Tea draft 42"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws { app.terminate() }

    func testEnglishMCPAndNotificationsKeepUnsentChatDraft() {
        launchAndEnterDraft()
        chooseEnglishInSettings()

        tapRoot("tools")
        exactVisibleText("tools.status", "MCP and Skills")
        exactVisibleText("mcp.status", "MCP is not configured")
        exactText("mcp.testIsolation", "Isolated UI test mode: no MCP network requests.")
        exactText("mcp.endpointStatus", "No endpoint saved.")

        tapRoot("settings")
        tapContent(app.buttons["settings.notifications"])
        exactText("notifications.enabled", "Off")
        XCTAssertEqual(app.staticTexts["notifications.enabled"].value as? String, "Off")
        let authorization = app.staticTexts["notifications.authorization"]
        revealLearningElement(authorization, in: app)
        let expectedAuthorization = [
            "unknown": "Not available yet", "notDetermined": "Not requested",
            "denied": "Denied", "authorized": "Allowed",
            "provisional": "Provisionally allowed (quiet notifications)",
            "ephemeral": "Temporarily allowed"
        ]
        let rawAuthorization = authorization.value as? String ?? ""
        guard let expected = expectedAuthorization[rawAuthorization] else {
            XCTFail("The actual system authorization raw state has no localized mapping.")
            return
        }
        XCTAssertEqual(authorization.label, expected,
                       "The actual system authorization state must be rendered in English.")
        let enable = app.buttons["notifications.enable"]
        revealLearningElement(enable, in: app)
        XCTAssertEqual(enable.label, "Enable and request notification permission")
        let testNotification = app.buttons["notifications.test"]
        XCTAssertTrue(testNotification.waitForExistence(timeout: 10))
        XCTAssertFalse(testNotification.isEnabled,
                       "Changing language must not enable local notifications.")

        tapChrome(app.navigationBars["Task notifications"].buttons.firstMatch)
        tapRoot("chat")
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, chatDraft)
    }

    func testEnglishBrowserLibrarySearchAndSkillCatalogKeepUnsentChatDraft() {
        launchAndEnterDraft()
        chooseEnglishInSettings()

        tapRoot("browser")
        let searchSettings = app.buttons["browser.searchEngine.open"]
        tapChrome(searchSettings, timeout: 30) // Isolated WebKit data removal may still be finishing.
        XCTAssertTrue(app.navigationBars["Search engines"].waitForExistence(timeout: 10))
        let bing = app.buttons["browser.searchEngine.select.bing"]
        revealLearningElement(bing, in: app)
        XCTAssertEqual(bing.value as? String, "Selected")
        tapContent(app.buttons["browser.searchEngine.select.google"])
        XCTAssertEqual(app.buttons["browser.searchEngine.select.google"].value as? String, "Selected")
        let add = app.buttons["browser.searchEngine.add"]
        revealLearningElement(add, in: app)
        XCTAssertEqual(add.label, "Add and use")
        tapChrome(app.buttons["browser.searchEngine.close"])

        tapChrome(app.buttons["browser.library"])
        XCTAssertTrue(app.navigationBars["Browsing data"].waitForExistence(timeout: 10))
        let bookmarks = app.segmentedControls["browser.library.sections"].buttons["Bookmarks"]
        tapChrome(bookmarks)
        exactText("browser.bookmarks.empty", "No bookmarks yet")
        let addBookmark = app.buttons["browser.bookmarks.add"]
        XCTAssertTrue(addBookmark.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.contains(addBookmark.frame) && !addBookmark.frame.isEmpty)
        XCTAssertEqual(addBookmark.label, "Bookmark current page")
        XCTAssertFalse(addBookmark.isEnabled, "No page has been opened or approved for bookmarking.")
        tapChrome(app.buttons["browser.library.close"])

        tapRoot("memory")
        tapChrome(app.buttons["memory.segment.skills"])
        tapContent(app.buttons["skills.catalog.open"])
        exactVisibleText("catalog.status", "Mika bundled skill catalog")
        exactVisibleText("catalog.count", "Original skills: 6 · Matches: 6")
        exactText("catalog.scope", "Original text and scripts are read-only and are not executed. Import an iOS text adaptation for review, then approve it. Approval starts a trial; it does not mean original feature parity.")
        let search = app.textFields["catalog.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.contains(search.frame))
        XCTAssertTrue(search.isEnabled && search.isHittable)
        search.tap()
        prepareLatinKeyboard()
        search.typeText("ZQX987\n")
        XCTAssertEqual(search.value as? String, "ZQX987")
        exactVisibleText("catalog.count", "Original skills: 6 · Matches: 0")
        exactText("catalog.empty", "No matching skills.")
        tapChrome(app.buttons["catalog.close"])

        tapRoot("chat")
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, chatDraft)
    }

    private func launchAndEnterDraft() {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage"]
        app.launchEnvironment = [:]
        app.launch()
        let draft = app.textFields["chat.draft"]
        XCTAssertTrue(draft.waitForExistence(timeout: 10))
        XCTAssertTrue(draft.isEnabled && draft.isHittable)
        draft.tap()
        prepareLatinKeyboard()
        draft.typeText(chatDraft)
        XCTAssertEqual(draft.value as? String, chatDraft, "The actual unsent input must arrive before switching screens.")
        let done = app.buttons["chat.dismissKeyboard"]
        XCTAssertTrue(done.waitForExistence(timeout: 5) && done.isHittable)
        done.tap()
        let keyboardGone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"),
                                                     object: app.keyboards.firstMatch)
        XCTAssertEqual(XCTWaiter.wait(for: [keyboardGone], timeout: 10), .completed)
    }

    private func chooseEnglishInSettings() {
        tapRoot("settings")
        tapContent(app.buttons["settings.appearance"])
        let language = app.buttons["settings.language"]
        tapContent(language)
        let english = app.buttons["English"].firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5) && english.isHittable)
        english.tap()
        exactText("settings.language.resolved", "Current interface: English")
        let back = app.navigationBars.buttons.element(boundBy: 0)
        XCTAssertTrue(back.waitForExistence(timeout: 5) && back.isHittable)
        back.tap()
        XCTAssertTrue(app.staticTexts["settings.status"].waitForExistence(timeout: 5))
    }

    private func tapRoot(_ section: String) {
        let button = app.buttons["navigation.\(section)"]
        XCTAssertTrue(button.waitForExistence(timeout: 10) && button.isEnabled && button.isHittable)
        XCTAssertFalse(button.frame.isEmpty)
        button.tap()
    }

    private func tapContent(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        revealLearningElement(element, in: app)
        let ready = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        if !ready.evaluate(with: element) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)],
                                          timeout: timeout), .completed)
        }
        XCTAssertFalse(element.frame.isEmpty)
        element.tap()
    }

    private func tapChrome(_ element: XCUIElement, timeout: TimeInterval = 10) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let ready = NSPredicate(format: "exists == true AND enabled == true AND hittable == true")
        if !ready.evaluate(with: element) {
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: element)],
                                          timeout: timeout), .completed)
        }
        XCTAssertTrue(app.frame.contains(element.frame) && !element.frame.isEmpty)
        element.tap()
    }

    private func exactText(_ identifier: String, _ expected: String) {
        let element = app.staticTexts[identifier]
        revealLearningElement(element, in: app)
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        let exact = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [exact], timeout: 5), .completed)
    }

    private func exactVisibleText(_ identifier: String, _ expected: String) {
        let element = app.staticTexts[identifier]
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        XCTAssertTrue(app.frame.contains(element.frame) && element.isHittable)
        let exact = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [exact], timeout: 5), .completed)
    }

    private func prepareLatinKeyboard() {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        func hasLatinKeys() -> Bool {
            keyboard.keys.matching(NSPredicate(format: "label IN %@", ["q", "Q"])).firstMatch.exists
                && keyboard.keys.matching(NSPredicate(format: "label IN %@", ["a", "A"])).firstMatch.exists
        }
        let introduction = app.buttons["Continue"].firstMatch
        if introduction.exists {
            XCTAssertTrue(app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].firstMatch.exists)
            XCTAssertTrue(introduction.isHittable)
            introduction.tap()
        }
        if hasLatinKeys() { return }
        let globe = app.buttons.matching(NSPredicate(format: "label IN %@", ["Next keyboard", "下一個鍵盤"])).firstMatch
        XCTAssertTrue(globe.waitForExistence(timeout: 5) && globe.isHittable)
        globe.press(forDuration: 1)
        let english = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == %@", "English (US)")).firstMatch
        XCTAssertTrue(english.waitForExistence(timeout: 5) && english.isHittable)
        english.tap()
        if introduction.exists {
            XCTAssertTrue(introduction.isHittable)
            introduction.tap()
        }
        let latin = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in hasLatinKeys() }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [latin], timeout: 10), .completed)
    }
}
