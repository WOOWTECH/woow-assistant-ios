import XCTest

/// Real manual UI and encrypted LearningStore. No model, MCP, network, seeded
/// skill, direct save hook or approval bypass. Relaunch uses the same UUID vault.
final class SkillAuthoringUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString
    private let fixtureSkillName = "authoring-notes"
    private let request = "Save this notes workflow as a skill after I review it."

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "skill-authoring-fixture-AX"; tree.lifetime = .keepAlways; add(tree)
            let screen = XCTAttachment(screenshot: app.screenshot())
            screen.name = "skill-authoring-fixture-screen"; screen.lifetime = .keepAlways; add(screen)
        }
        app.terminate()
    }

    func testReviewedCreatePersistsAfterRelaunch() {
        launch()
        openAuthoring()
        begin()
        search("skill-authoring")
        tap("authoring.match.bundled.skill-authoring", scroll: true)
        let source = app.staticTexts["authoring.read.full"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("skill_save"))
        XCTAssertTrue(source.label.contains("## 怎样算办成"))
        XCTAssertFalse(app.buttons["authoring.edit.read"].exists)
        tap("authoring.lookup")
        tap("authoring.new")
        writeMarkdown(markdown("CreatedMarker"))
        prepare(marker: "CreatedMarker")
        XCTAssertEqual(app.staticTexts["authoring.review.request"].label, request)
        XCTAssertFalse(app.staticTexts["authoring.saved.status"].exists)
        tap("authoring.approve")
        assertSaved(updated: false)
        assertPersisted(marker: "CreatedMarker")
    }

    func testCancelledReviewLeavesNoSkillOrPendingDraft() {
        launch()
        openAuthoring()
        begin()
        tap("authoring.new")
        writeMarkdown(markdown("CancelledMarker"))
        prepare(marker: "CancelledMarker")
        tap("authoring.close")
        XCTAssertTrue(app.buttons["catalog.skill-authoring.open"].waitForExistence(timeout: 5))
        assertEmptyAfterRelaunch()
    }

    func testPersonalReadAndReviewedUpdatePersistAfterRelaunch() {
        launch()
        openAuthoring()
        begin()
        tap("authoring.new")
        writeMarkdown(markdown("OriginalMarker"))
        prepare(marker: "OriginalMarker")
        tap("authoring.approve")
        assertSaved(updated: false)
        launch(reset: false)
        openAuthoring()
        begin()
        search(fixtureSkillName)
        tap("authoring.match.personal." + fixtureSkillName, scroll: true)
        let source = app.staticTexts["authoring.read.full"]
        XCTAssertTrue(source.waitForExistence(timeout: 5))
        XCTAssertTrue(source.label.contains("OriginalMarker"))
        tap("authoring.edit.read")
        writeMarkdown(markdown("UpdatedMarker"))
        prepare(marker: "UpdatedMarker")
        tap("authoring.approve")
        assertSaved(updated: true)
        assertPersisted(marker: "UpdatedMarker", absent: "OriginalMarker")
    }

    func testInvalidToolDraftCannotApproveOrPublishSuccess() {
        launch()
        openAuthoring()
        begin()
        tap("authoring.new")
        writeMarkdown(markdown("Use `run_command` without approval."))
        tap("authoring.prepare")
        let failure = app.staticTexts["authoring.error"]
        XCTAssertTrue(failure.waitForExistence(timeout: 5))
        XCTAssertTrue(failure.label.contains("尚未提供的工具"))
        XCTAssertFalse(app.buttons["authoring.approve"].exists)
        XCTAssertFalse(app.staticTexts["authoring.saved.status"].exists)
        XCTAssertTrue((app.textViews["authoring.markdown"].value as? String ?? "").contains("run_command"))
        tap("authoring.close")
        assertEmptyAfterRelaunch()
    }

    private func launch(reset: Bool = true) {
        app.terminate(); app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["uitest.banner"].exists)
    }

    private func openSkills() {
        let navigation = app.buttons["navigation.memory"]
        let ready = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"), object: navigation)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed)
        XCTAssertFalse(navigation.frame.isEmpty)
        XCTAssertTrue(app.frame.contains(navigation.frame))
        // 5d current's recording and AX stayed on Chat after element.tap().
        // Target the actual button's visible center once, then require selection.
        navigation.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let deadline = Date().addingTimeInterval(10)
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "已選取"), object: navigation)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 10), .completed)
        XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: max(0, deadline.timeIntervalSinceNow)))
        XCTAssertFalse(app.staticTexts["memory.unavailable"].exists)
        tap("memory.segment.skills")
    }

    private func openAuthoring() {
        openSkills()
        tap("skills.catalog.open", scroll: true)
        let field = app.textFields["catalog.search"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("skill-authoring\n")
        tap("catalog.entry.skill-authoring", scroll: true)
        tap("catalog.skill-authoring.open", scroll: true)
        XCTAssertTrue(app.staticTexts["authoring.intro"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["authoring.begin"].isEnabled)
    }

    private func begin() {
        let field = app.textViews["authoring.request"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(request)
        XCTAssertEqual(field.value as? String, request)
        tap("authoring.keyboard.done")
        tap("authoring.begin")
        XCTAssertTrue(app.textFields["authoring.search"].waitForExistence(timeout: 5))
    }

    private func search(_ text: String) {
        let field = app.textFields["authoring.search"]
        field.tap(); field.typeText(text + "\n")
        XCTAssertEqual(field.value as? String, text)
    }

    private func writeMarkdown(_ text: String) {
        let editor = app.textViews["authoring.markdown"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue(editor.isHittable)
        editor.tap()
        tap("authoring.keyboard.clear")
        XCTAssertEqual(editor.value as? String, "")
        // 5d SE kept keyboard focus after Clear, but the full-document key burst
        // lost "na" and moved "m" to the end. Observe each native input chunk;
        // never retry/repair text or proceed to review with a different document.
        var remaining = text[...]
        var entered = ""
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(entered.isEmpty ? 1 : 16))
            editor.typeText(chunk)
            entered += chunk
            remaining = remaining.dropFirst(chunk.count)
            XCTAssertEqual(editor.value as? String, entered,
                           "Every native input chunk must preserve the exact accumulated document.")
        }
        XCTAssertEqual(editor.value as? String, text, "The exact full document must arrive before review.")
        tap("authoring.keyboard.done")
    }

    private func prepare(marker: String) {
        tap("authoring.prepare")
        let full = app.staticTexts["authoring.review.full"]
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        XCTAssertTrue(full.label.contains(marker))
        XCTAssertTrue(full.label.contains("## When to stop"))
        XCTAssertTrue(app.staticTexts["authoring.review.state"].label.contains("尚未儲存"))
        XCTAssertFalse(app.staticTexts["authoring.error"].exists)
    }

    private func assertSaved(updated: Bool) {
        let status = app.staticTexts["authoring.saved.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.label, updated ? "已更新個人技能 · 試用中" : "已新增個人技能 · 試用中")
        XCTAssertEqual(app.staticTexts["authoring.saved.name"].label, fixtureSkillName)
        XCTAssertFalse(app.buttons["authoring.approve"].exists, "A successful grant cannot be replayed.")
        XCTAssertFalse(app.staticTexts["authoring.error"].exists)
    }

    private func assertPersisted(marker: String, absent: String? = nil) {
        launch(reset: false)
        openSkills()
        let status = app.staticTexts["skills.state." + fixtureSkillName]
        revealLearningElement(status, in: app)
        XCTAssertEqual(status.label, "試用中 · 尚未驗證")
        tap("skills.fullText." + fixtureSkillName, scroll: true)
        let text = app.staticTexts["skills.document"]
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        XCTAssertTrue(text.label.contains(marker))
        if let absent { XCTAssertFalse(text.label.contains(absent)) }
        tap("skills.document.close")
        tap("memory.segment.pending")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
    }

    private func assertEmptyAfterRelaunch() {
        launch(reset: false)
        openSkills()
        XCTAssertTrue(app.staticTexts["skills.empty"].waitForExistence(timeout: 5))
        tap("memory.segment.pending")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
    }

    private func tap(_ identifier: String, scroll: Bool = false) {
        let button = app.buttons[identifier].firstMatch
        if scroll { revealLearningElement(button, in: app) }
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 10), .completed, identifier)
        button.tap()
    }

    private func markdown(_ detail: String) -> String {
        """
        ---
        name: \(fixtureSkillName)
        description: Organize notes.
        ---
        ## Entry
        User notes.
        ## Steps
        \(detail)
        ## Pitfalls
        Missing context.
        ## Success criteria
        A faithful summary.
        ## When to stop
        Ask if unclear.
        """
    }
}
