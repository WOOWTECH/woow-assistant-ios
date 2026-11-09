import XCTest

// Local fixture UI only. Unique namespaces isolate the encrypted learning vault,
// model defaults and Keychain. These tests never launch a live model or MCP request.
final class MemoryUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 180
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "memory-fixture-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        app.terminate()
    }

    func testSegmentsAndPreferencePersistence() {
        launch()
        openMemory()
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
        select("skills")
        XCTAssertTrue(app.staticTexts["skills.empty"].exists)
        select("pending")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].exists)
        reveal(app.staticTexts["memory.browserPending"])
        XCTAssertTrue(app.staticTexts["memory.browserPending"].label.contains("尚未實作"))
        select("memories")
        for name in ["useMemory", "autoRemember", "learnSkills"] {
            let toggle = app.switches["memory.toggle.\(name)"]
            reveal(toggle)
            XCTAssertEqual(toggle.value as? String, "1")
            toggle.tap()
            XCTAssertEqual(toggle.value as? String, "0")
        }
        launch(reset: false)
        openMemory()
        for name in ["useMemory", "autoRemember", "learnSkills"] {
            let toggle = app.switches["memory.toggle.\(name)"]
            reveal(toggle)
            XCTAssertEqual(toggle.value as? String, "0")
        }
        XCTAssertTrue(app.staticTexts["memory.preferenceScope"].exists)
    }

    func testMemoryValidationEditPinSearchAndDeletePersist() {
        launch()
        openMemory()
        tap("memory.add", scroll: true)
        XCTAssertFalse(app.buttons["memory.editor.save"].isEnabled)
        let invalid = String(repeating: "a", count: 201)
        enter(invalid, into: app.textViews["memory.editor.content"])
        tap("memory.editor.save")
        XCTAssertTrue(app.staticTexts["memory.editor.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["memory.editor.content"].value as? String, invalid)
        replaceEditor("memory", text: "Prefer green tea")
        reveal(app.textFields["memory.editor.keywords"])
        enter("tea", into: app.textFields["memory.editor.keywords"])
        saveMemoryEditor()
        tapFirst(prefix: "memory.pin.")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.pinned.")).firstMatch.exists)
        tapFirst(prefix: "memory.edit.")
        replaceEditor("memory", text: "Prefer jasmine tea")
        saveMemoryEditor()
        enter("tea\n", into: app.textFields["memory.search"])
        XCTAssertTrue(memory("Prefer jasmine tea").waitForExistence(timeout: 5))
        launch(reset: false)
        openMemory()
        XCTAssertTrue(memory("Prefer jasmine tea").exists)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "memory.pinned.")).firstMatch.exists)
        tapFirst(prefix: "memory.delete.")
        XCTAssertTrue(app.staticTexts["memory.empty"].waitForExistence(timeout: 5))
        launch(reset: false)
        openMemory()
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
    }

    func testProceduresRequireApprovalAndCanBeRejected() {
        launch()
        openMemory()
        addMemory("Check details before answering", procedure: true)
        XCTAssertFalse(memory("Check details before answering").exists)
        select("pending")
        XCTAssertTrue(memory("Check details before answering").exists)
        tapFirst(prefix: "memory.approve.")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        select("memories")
        XCTAssertTrue(memory("Check details before answering").exists)
        addMemory("Ask before changing a plan", procedure: true)
        select("pending")
        tapFirst(prefix: "memory.reject.")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        launch(reset: false)
        openMemory()
        XCTAssertTrue(memory("Check details before answering").exists)
        XCTAssertFalse(memory("Ask before changing a plan").exists)
    }

    func testSkillImportFailureReviewAndEnablementPersist() {
        launch()
        openMemory()
        select("skills")
        tap("skills.import", scroll: true)
        enter("not a skill document", into: app.textViews["skills.editor.markdown"])
        tap("skills.editor.save")
        XCTAssertTrue(app.staticTexts["skills.editor.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["skills.editor.markdown"].value as? String, "not a skill document")
        replaceEditor("skills", text: markdown(version: "VersionOne"))
        saveSkillEditor()
        XCTAssertTrue(app.staticTexts["skills.draft.notes-test"].exists)
        select("skills")
        XCTAssertTrue(app.staticTexts["skills.empty"].exists)
        select("pending")
        tap("skills.edit.notes-test", scroll: true)
        replaceEditor("skills", text: markdown(version: "ReviewedVersion"))
        saveSkillEditor()
        XCTAssertTrue(app.staticTexts["skills.item.notes-test"].exists)
        let enabled = app.switches["skills.enabled.notes-test"]
        reveal(enabled)
        enabled.tap()
        XCTAssertEqual(app.staticTexts["skills.state.notes-test"].label, "已停用")
        enabled.tap()
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertTrue(app.buttons["skills.share.notes-test"].exists)
        launch(reset: false)
        openMemory()
        select("skills")
        reveal(app.switches["skills.enabled.notes-test"])
        XCTAssertEqual(app.switches["skills.enabled.notes-test"].value as? String, "1")
        assertSkillText(contains: "ReviewedVersion")
    }

    func testSkillUpdateRejectionAndRollback() {
        launch()
        openMemory()
        importSkill(version: "VersionOne")
        tap("skills.approve.notes-test", scroll: true)
        importSkill(version: "RejectedVersion")
        XCTAssertTrue(app.staticTexts["skills.update.notes-test"].exists)
        tap("skills.reject.notes-test", scroll: true)
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        importSkill(version: "VersionTwo")
        tap("skills.approve.notes-test", scroll: true)
        select("skills")
        tap("skills.rollback.notes-test", scroll: true)
        assertSkillText(contains: "VersionOne")
        launch(reset: false)
        openMemory()
        select("skills")
        assertSkillText(contains: "VersionOne")
    }

    func testTwoStepClearCancellationAndModelSettingsIsolation() {
        launch()
        tap("navigation.settings")
        enter("https://model.example.invalid/v1\n", into: app.textFields["settings.baseURL"])
        reveal(app.textFields["settings.model"])
        enter("fixture-model\n", into: app.textFields["settings.model"])
        reveal(app.secureTextFields["settings.apiKey"])
        enter("fixture-only-not-a-real-key\n", into: app.secureTextFields["settings.apiKey"])
        tap("settings.save", scroll: true)
        XCTAssertTrue(app.staticTexts["settings.notice"].waitForExistence(timeout: 5))
        openMemory()
        addMemory("Keep until both confirmations")
        importSkill(version: "PendingVersion")
        tap("memory.clear", scroll: true)
        XCTAssertFalse(app.buttons["memory.clear.confirm"].exists)
        tap("memory.clear.cancel")
        tap("memory.clear", scroll: true)
        tap("memory.clear.continue")
        XCTAssertTrue(app.buttons["memory.clear.confirm"].exists)
        tap("memory.clear.cancel")
        select("memories")
        XCTAssertTrue(memory("Keep until both confirmations").exists)
        select("pending")
        XCTAssertTrue(app.staticTexts["skills.draft.notes-test"].exists)
        tap("memory.clear", scroll: true)
        tap("memory.clear.continue")
        tap("memory.clear.confirm")
        waitForAbsence(app.buttons["memory.clear.confirm"])
        select("memories")
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
        select("skills")
        XCTAssertTrue(app.staticTexts["skills.empty"].exists)
        select("pending")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].exists)
        launch(reset: false)
        XCTAssertEqual(app.staticTexts["chat.status"].label, "模型已設定")
        openMemory()
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["uitest.banner"].exists)
    }

    private func openMemory() {
        tap("navigation.memory")
        XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["memory.unavailable"].exists)
    }

    private func select(_ name: String) {
        tap("memory.segment.\(name)")
        XCTAssertEqual(app.buttons["memory.segment.\(name)"].value as? String, "已選取")
    }

    private func addMemory(_ text: String, procedure: Bool = false) {
        tap("memory.add", scroll: true)
        if procedure {
            let kind = app.segmentedControls.buttons["做法"]
            waitUntilHittable(kind)
            kind.tap()
        }
        enter(text, into: app.textViews["memory.editor.content"])
        saveMemoryEditor()
    }

    private func saveMemoryEditor() {
        tap("memory.editor.save")
        waitForAbsence(app.buttons["memory.editor.save"])
    }

    private func saveSkillEditor() {
        tap("skills.editor.save")
        waitForAbsence(app.buttons["skills.editor.save"])
    }

    private func importSkill(version: String) {
        select("skills")
        tap("skills.import", scroll: true)
        enter(markdown(version: version), into: app.textViews["skills.editor.markdown"])
        saveSkillEditor()
    }

    private func assertSkillText(contains value: String) {
        tap("skills.fullText.notes-test", scroll: true)
        let document = app.staticTexts["skills.document"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        XCTAssertTrue(document.label.contains(value))
        tap("skills.document.close")
    }

    private func markdown(version: String) -> String {
        """
        ---
        name: notes-test
        description: Organize notes.
        ---
        ## Entry
        Notes.
        ## Steps
        \(version)
        ## Pitfalls
        Missing details.
        ## Success criteria
        A summary.
        ## When to stop
        Ask the user.
        """
    }

    private func memory(_ content: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "memory.item.", content)).firstMatch
    }

    private func replaceEditor(_ prefix: String, text: String) {
        let id = prefix == "memory" ? "memory.editor.content" : "skills.editor.markdown"
        let editor = app.textViews[id]
        waitUntilHittable(editor)
        editor.tap()
        tap("\(prefix).editor.clear")
        enter(text, into: editor)
    }

    private func enter(_ text: String, into field: XCUIElement) {
        waitUntilHittable(field)
        field.tap()
        field.typeText(text)
    }

    private func tap(_ id: String, scroll: Bool = false) {
        let button = app.buttons[id]
        if scroll { reveal(button) } else { waitUntilHittable(button) }
        button.tap()
    }

    private func tapFirst(prefix: String) {
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        reveal(button)
        button.tap()
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<5 where !element.isHittable {
            if app.collectionViews.firstMatch.exists { app.collectionViews.firstMatch.swipeUp() }
            else if app.scrollViews.firstMatch.exists { app.scrollViews.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        waitUntilHittable(element)
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private func waitForAbsence(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}
