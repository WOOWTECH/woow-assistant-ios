import XCTest
import CoreGraphics

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
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "memory-fixture-failure-AX"
            tree.lifetime = .keepAlways
            add(tree)
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
            setSwitch(toggle, value: "0")
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
        let content = app.textViews["memory.editor.content"]
        waitUntilHittable(content)
        content.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // A single 201-key burst previously saved only 199 characters on iOS 18.
        // Verify every input segment; do not retry or silently repair lost input.
        var entered = ""
        for count in [1, 50, 50, 50, 50] {
            let segment = String(repeating: "a", count: count)
            content.typeText(segment)
            entered += segment
            let received = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", entered), object: content)
            XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed,
                           "The editor must receive the exact validation input before Save.")
        }
        XCTAssertEqual(content.value as? String, invalid)
        tap("memory.editor.save")
        XCTAssertTrue(app.staticTexts["memory.editor.error"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["memory.editor.content"].value as? String, invalid)
        replaceEditor("memory", text: "Prefer green tea")
        tap("memory.editor.done")
        waitForAbsence(app.keyboards.firstMatch)
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
        setSwitch(enabled, value: "0")
        XCTAssertEqual(app.staticTexts["skills.state.notes-test"].label, "已停用")
        setSwitch(enabled, value: "1")
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
        XCTAssertTrue(memory("Keep until both confirmations").waitForExistence(timeout: 5),
                      "Verify the exact saved fixture before testing cancellation or deletion.")
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
        let content = app.textViews["memory.editor.content"]
        waitUntilHittable(content)
        content.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        // SE's failed clear fixture saved "Keep uil both confirmations":
        // the memory survived Cancel, but the original key burst lost "nt".
        // Verify first-key focus and every subsequent bounded chunk, without
        // retries/repair or saving an unverified fixture.
        var remaining = text[...]
        var entered = ""
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(entered.isEmpty ? 1 : 16))
            content.typeText(chunk)
            entered += chunk
            remaining = remaining.dropFirst(chunk.count)
            let received = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", entered), object: content)
            XCTAssertEqual(XCTWaiter.wait(for: [received], timeout: 5), .completed,
                           "Memory editor must receive the exact fixture text before Save.")
        }
        XCTAssertEqual(content.value as? String, text)
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
        if scroll && (id == "skills.import" || id.hasPrefix("skills.rollback.")) {
            guard revealSkillButton(button, identifier: id) else { return }
        } else if scroll { reveal(button) } else { waitUntilHittable(button) }
        button.tap()
    }

    private func revealSkillButton(_ button: XCUIElement, identifier: String,
                                   file: StaticString = #filePath, line: UInt = #line) -> Bool {
        // bd1 SE alternated eight full-list slow swipes past the import row.
        // 267 passed import, but the shared full swipe skipped rollback too.
        // Speed does not bound distance: measure the gap, drag only inside the
        // uncovered List viewport, and hold before releasing to avoid inertia.
        let list = app.collectionViews.firstMatch
        waitUntilHittable(list)
        var previousTargetWasPresent = false
        var searchUp = true
        var maximumDistance: CGFloat = 120
        for attempt in 0...8 {
            let listFrame = list.frame
            var viewport = listFrame.intersection(app.frame)
            let navigation = app.buttons["navigation.chat"]
            if navigation.exists {
                viewport.size.height = max(0, min(viewport.maxY, navigation.frame.minY) - viewport.minY)
            }
            if app.keyboards.firstMatch.exists {
                viewport.size.height = max(0, min(viewport.maxY, app.keyboards.firstMatch.frame.minY) - viewport.minY)
            }
            viewport = viewport.insetBy(dx: 0, dy: 4)
            let exists = button.exists
            let frame = exists ? button.frame : .zero
            if exists && learningFrameIsVisible(frame, in: viewport, visibility: .fullyVisible)
                && button.isHittable {
                return true
            }
            guard attempt < 8 else {
                XCTFail("\(identifier) must be fully visible above navigation/keyboard before tapping.",
                        file: file, line: line)
                return false
            }
            let targetIsPresent = exists && !frame.isEmpty
            if !targetIsPresent && previousTargetWasPresent {
                // Reverse once on losing a materialized row, then continue the
                // smaller search step until it reappears; do not oscillate.
                searchUp.toggle()
                maximumDistance = max(24, maximumDistance / 2)
            }
            guard let drag = MemoryImportScrollDrag.make(
                listFrame: listFrame, viewport: viewport,
                targetFrame: targetIsPresent ? frame : nil,
                searchUp: searchUp, maximumDistance: maximumDistance
            ) else {
                XCTFail("\(identifier) has no safe bounded scroll gesture; visibility remains required.",
                        file: file, line: line)
                return false
            }
            let origin = list.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: drag.start.x - listFrame.minX,
                                                  dy: drag.start.y - listFrame.minY))
            let end = origin.withOffset(CGVector(dx: drag.end.x - listFrame.minX,
                                                dy: drag.end.y - listFrame.minY))
            start.press(forDuration: 0.05, thenDragTo: end,
                        withVelocity: .slow, thenHoldForDuration: 0.2)
            previousTargetWasPresent = targetIsPresent
            searchUp = drag.end.y < drag.start.y
        }
        return false
    }

    private func tapFirst(prefix: String) {
        let button = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        reveal(button)
        button.tap()
    }

    private func reveal(_ element: XCUIElement) {
        revealLearningElement(element, in: app)
        waitUntilHittable(element)
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private func setSwitch(_ element: XCUIElement, value: String) {
        let native = element.switches.firstMatch
        let target = native.exists ? native : element
        waitUntilHittable(target)
        target.tap()
        let changed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["memory.error"].exists, "Memory settings could not be persisted.")
    }

    private func waitForAbsence(_ element: XCUIElement) {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 5), .completed)
    }
}

/// Pure geometry so the measured SE failure can be checked without a simulator.
/// Coordinates are used only for a List-relative scroll, never to tap a control.
private struct MemoryImportScrollDrag {
    let start: CGPoint
    let end: CGPoint

    static func make(listFrame: CGRect, viewport: CGRect, targetFrame: CGRect?,
                     searchUp: Bool, maximumDistance: CGFloat) -> Self? {
        guard valid(listFrame), valid(viewport), listFrame.contains(viewport),
              viewport.width >= 48, maximumDistance.isFinite, maximumDistance > 0 else { return nil }
        let limit = min(maximumDistance, viewport.height * 0.3)
        guard limit >= 16 else { return nil }
        let up: Bool
        let distance: CGFloat
        if let targetFrame {
            guard valid(targetFrame), targetFrame.height <= viewport.height,
                  targetFrame.minX >= viewport.minX, targetFrame.maxX <= viewport.maxX else { return nil }
            if targetFrame.maxY > viewport.maxY {
                up = true
                distance = min(limit, max(24, targetFrame.maxY - viewport.maxY + 12))
            } else if targetFrame.minY < viewport.minY {
                up = false
                distance = min(limit, max(24, viewport.minY - targetFrame.minY + 12))
            } else {
                // Already in the viewport: scrolling cannot establish why a
                // control is not hittable, so never substitute a coordinate tap.
                return nil
            }
        } else {
            up = searchUp
            distance = limit
        }
        let displacement = up ? distance : -distance
        let start = CGPoint(x: viewport.midX, y: viewport.midY + displacement / 2)
        let end = CGPoint(x: viewport.midX, y: viewport.midY - displacement / 2)
        guard viewport.contains(start), viewport.contains(end) else { return nil }
        return Self(start: start, end: end)
    }

    private static func valid(_ frame: CGRect) -> Bool {
        !frame.isNull && !frame.isInfinite && frame.width > 0 && frame.height > 0
            && [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy { $0.isFinite }
    }
}
