import XCTest
import CoreGraphics

/// Fixture transport and local HTML only; the WKWebView, research runner, review
/// UI and encrypted persistence are real. Never launch a live model or use a key
/// from the environment. Each test owns an isolated defaults/Keychain namespace.
final class BrowserLearningUITests: XCTestCase {
    private var app = XCUIApplication()
    private let namespace = UUID().uuidString
    private let fixtureURL = "https://research.example.invalid/start"
    private let goal = "Read alpha, beta, gamma, delta and epsilon; summarize WOOW_WEB_GUIDE with sources."

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "browser-learning-fixture-failure"
            attachment.lifetime = .keepAlways
            add(attachment)
            // This suite launches only local HTML and dummy model settings.
            // Preserve the actual AX child tree on failure, not live page data.
            let accessibility = XCTAttachment(string: app.debugDescription)
            accessibility.name = "browser-learning-fixture-ax-tree"
            accessibility.lifetime = .keepAlways
            add(accessibility)
        }
        app.terminate()
    }

    func testWebsiteResearchCreatesPendingSkillAndManualApprovalSurvivesRelaunch() {
        launch()
        configureModel()
        openFixture()
        waitFor(fixtureHeading, predicate: "exists == true")
        enterGoal()
        // The modal sheet owns accessibility focus, but the real WKWebView
        // remains mounted and must still execute all five navigations below.
        // Assert the real DOM child is hidden, not that its WebView container
        // vanishes: iOS 18 still exposed that root in the previous fixture run.
        waitFor(fixtureHeading, predicate: "exists == false")
        let start = app.buttons["browser.start"]
        XCTAssertTrue(start.isEnabled)
        start.tap()
        // Re-enabled only after research AND the separate learning pipeline end.
        // Errors also re-enable it, so require an answer, a learning result and a
        // persisted pending draft below; the button alone is never success.
        waitFor(start, predicate: "exists == true AND enabled == true", timeout: 45)
        let answer = app.staticTexts["browser.answer"]
        reveal(answer)
        XCTAssertEqual(answer.label, "WOOW_WEB_GUIDE: five sections reviewed.")
        let learning = app.staticTexts["browser.learning"]
        // SE's AX row extends 3.5pt below the screen even though both lines of
        // text are visible. Read the full static label; this never taps the row.
        revealLearningElement(learning, in: app, visibility: .readableText)
        XCTAssertEqual(learning.label, "已判定任務完成；技能草稿已加入待確認，核准後才能使用。")
        XCTAssertFalse(fixtureHeading.exists, "Background DOM content must stay outside the modal accessibility tree.")
        tap("browser.research.close")
        waitFor(fixtureHeading, predicate: "exists == true")
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
        XCTAssertEqual(app.textFields["browser.address"].value as? String,
                       "https://research.example.invalid/epsilon")

        openMemory()
        select("skills")
        XCTAssertTrue(app.staticTexts["skills.empty"].waitForExistence(timeout: 5),
                      "Learning must not install or approve its own draft.")
        select("pending")
        let draft = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "skills.draft.")).firstMatch
        reveal(draft)
        let name = String(draft.identifier.dropFirst("skills.draft.".count))
        XCTAssertEqual(name, "website-research")
        XCTAssertFalse(app.staticTexts["skills.item.\(name)"].exists)
        tap("skills.draftFullText.\(name)", scroll: true)
        let document = app.staticTexts["skills.document"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        let reviewedMarkdown = document.label
        XCTAssertFalse(reviewedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        tap("skills.document.close")
        tap("skills.approve.\(name)", scroll: true)
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["memory.error"].exists)
        select("skills")
        assertTrialSkill(name)

        launch(reset: false)
        waitForLabel(app.staticTexts["chat.status"], "模型已設定")
        openMemory()
        select("skills")
        assertTrialSkill(name)
        tap("skills.fullText.\(name)", scroll: true)
        let persistedDocument = app.staticTexts["skills.document"]
        XCTAssertTrue(persistedDocument.waitForExistence(timeout: 5))
        XCTAssertEqual(persistedDocument.label, reviewedMarkdown,
                       "The reviewed skill must survive encrypted persistence unchanged.")
        tap("skills.document.close")
        select("pending")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))

        // Website knowledge and routes are separate persisted records. The
        // website lesson still needs its own approval; approving a skill must
        // not silently approve the website evidence too.
        openWebsites(expectedCounts: "1／1")
        let lesson = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "website.lesson.", "WOOW_WEB_GUIDE")).firstMatch
        reveal(lesson)
        let lessonID = String(lesson.identifier.dropFirst("website.lesson.".count))
        let approve = app.buttons["website.approve.\(lessonID)"]
        reveal(approve)
        XCTAssertTrue(approve.isEnabled)
        let route = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "website.route.")).firstMatch
        reveal(route)
        XCTAssertEqual(route.label, goal)
        let routeID = String(route.identifier.dropFirst("website.route.".count))
        reveal(app.staticTexts["6 步 · research.example.invalid"])
        XCTAssertFalse(app.staticTexts["website.error"].exists)

        // This app was relaunched above: replay must mount the real WKWebView
        // from Memory, not depend on a browser left visible by the first run.
        let replay = app.buttons["website.replay.\(routeID)"]
        let websites = app.collectionViews["website.manager"]
        XCTAssertTrue(replay.waitForExistence(timeout: 5))
        // SE's recording showed the button below the screen while eight short
        // drags starting in website.search left the list at its initial offset.
        // Use one normal list swipe, then keep the full-visibility tap check.
        if !websites.frame.intersection(app.frame).insetBy(dx: 4, dy: 4).contains(replay.frame) {
            websites.swipeUp(velocity: .slow)
        }
        tap("website.replay.\(routeID)", scroll: true)
        let confirmations = app.alerts.buttons.matching(NSPredicate(format: "label == %@", "開啟並逐步核對"))
        XCTAssertTrue(confirmations.firstMatch.waitForExistence(timeout: 5))
        // iOS 26 can expose both a wrapper and its nested action; tap the leaf.
        guard let confirmation = confirmations.allElementsBoundByIndex.last else {
            XCTFail("The persisted route requires explicit replay confirmation.")
            return
        }
        waitFor(confirmation, predicate: "exists == true AND hittable == true")
        confirmation.tap()
        waitFor(app.buttons["navigation.browser"], predicate: "exists == true AND value == '已選取'")
        // A fresh app needed 57.481s merely to launch WebContent on hosted CI.
        // Keep all per-step URL/quote and judged-result assertions below.
        waitForLabel(app.staticTexts["browser.status"], "路線重走已結束", timeout: 105)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
        tap("browser.research")
        XCTAssertTrue(app.buttons["browser.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(goalField.value as? String, goal)
        let replayAnswer = app.staticTexts["browser.answer"]
        reveal(replayAnswer)
        XCTAssertEqual(replayAnswer.label, "WOOW_WEB_GUIDE: five sections reviewed.")
        let replayLearning = app.staticTexts["browser.learning"]
        revealLearningElement(replayLearning, in: app, visibility: .readableText)
        XCTAssertEqual(replayLearning.label, "路線核對與成果判定完成；未重複產生技能。")
        tap("browser.research.close")
    }

    func testUnconfiguredBrowserRetainsGoalAndManualWebsiteKnowledgeSurvivesRelaunch() {
        launch()
        openFixture()
        enterGoal()
        XCTAssertFalse(app.buttons["browser.start"].isEnabled)
        XCTAssertFalse(app.staticTexts["browser.answer"].exists)
        XCTAssertFalse(app.staticTexts["browser.learning"].exists)
        tap("browser.research.close")
        tap("navigation.chat")
        waitForLabel(app.staticTexts["chat.status"], "尚未設定模型")
        tap("navigation.browser")
        waitForLabel(app.staticTexts["browser.status"], "頁面已載入")
        XCTAssertEqual(app.textFields["browser.address"].value as? String, fixtureURL)
        tap("browser.research")
        XCTAssertTrue(app.buttons["browser.start"].waitForExistence(timeout: 5))
        XCTAssertEqual(goalField.value as? String, goal)
        XCTAssertFalse(app.buttons["browser.start"].isEnabled)
        XCTAssertFalse(app.buttons["browser.task.cancel"].exists)
        XCTAssertFalse(app.staticTexts["browser.answer"].exists)
        XCTAssertFalse(app.staticTexts["browser.learning"].exists)
        tap("browser.research.close")

        // Manual, sourced website knowledge does not require a model/key and
        // must not invent a multi-step route or a personal memory.
        openMemory()
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
        openWebsites(expectedCounts: "0／0")
        let save = app.buttons["website.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        let note = "Use the guide links to review each section."
        enter(note + "\n", into: app.textFields["website.note"])
        waitFor(app.keyboards.firstMatch, predicate: "exists == false")
        tap("website.save", scroll: true)
        waitFor(save, predicate: "exists == true AND enabled == false")
        XCTAssertFalse(app.staticTexts["website.error"].exists)
        tap("website.close")
        waitFor(app.buttons["website.close"], predicate: "exists == false")
        openWebsites(expectedCounts: "1／0")
        let lesson = app.staticTexts.matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label == %@", "website.lesson.", note)).firstMatch
        reveal(lesson)
        let lessonIdentifier = lesson.identifier
        let lessonID = String(lessonIdentifier.dropFirst("website.lesson.".count))
        XCTAssertFalse(app.buttons["website.approve.\(lessonID)"].exists)
        reveal(app.staticTexts["website.routes.empty"])

        launch(reset: false)
        waitForLabel(app.staticTexts["chat.status"], "尚未設定模型")
        openMemory()
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
        openWebsites(expectedCounts: "1／0")
        let persistedLesson = app.staticTexts[lessonIdentifier]
        reveal(persistedLesson)
        XCTAssertEqual(persistedLesson.label, note)
        reveal(app.staticTexts["已核准"])
        let persistedEvidence = app.staticTexts.matching(NSPredicate(
            format: "label BEGINSWITH %@ AND label CONTAINS %@", "來源：", "WOOW_WEB_GUIDE")).firstMatch
        reveal(persistedEvidence)
        XCTAssertFalse(app.buttons["website.approve.\(lessonID)"].exists)
        // The page is session-only, but its reviewed note and evidence persist.
        XCTAssertFalse(app.textFields["website.note"].exists)
        reveal(app.staticTexts["website.routes.empty"])
        XCTAssertFalse(app.staticTexts["website.error"].exists)
    }

    func testRemovingModelSettingsCancelsResearchAndPreservesGoalWithoutLearning() {
        launch()
        configureModel()
        openFixture()
        let waitingGoal = "[fixture:wait] Review WOOW_WEB_GUIDE before answering."
        enterGoal(waitingGoal)
        XCTAssertTrue(app.buttons["browser.start"].isEnabled)
        tap("browser.start")
        waitForLabel(app.staticTexts["browser.task.status"], "正在研究網站…")
        XCTAssertTrue(app.buttons["browser.task.cancel"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["browser.start"].isEnabled)
        // A source URL appears only after the real WK inspection was recorded.
        // The fixture then waits cancellably; do not wait for its 60-second delay.
        XCTAssertTrue(app.staticTexts[fixtureURL].waitForExistence(timeout: 10))
        tap("browser.research.close")
        tap("navigation.settings")
        tap("settings.remove", scroll: true)
        waitForLabel(app.staticTexts["settings.keyStatus"], "尚未儲存金鑰。")
        XCTAssertTrue(app.staticTexts["settings.notice"].label.contains("已移除"))
        XCTAssertFalse(app.staticTexts["settings.error"].exists)

        let stopped = "已停止；已取得的內容與草稿保留"
        tap("navigation.browser")
        waitForLabel(app.staticTexts["browser.status"], stopped)
        XCTAssertFalse(app.buttons["browser.cancel"].exists)
        XCTAssertEqual(app.textFields["browser.address"].value as? String, fixtureURL)
        tap("browser.research")
        waitForLabel(app.staticTexts["browser.task.status"], stopped)
        XCTAssertEqual(goalField.value as? String, waitingGoal)
        XCTAssertTrue(goalField.isEnabled)
        XCTAssertFalse(app.buttons["browser.start"].isEnabled)
        XCTAssertFalse(app.buttons["browser.task.cancel"].exists)
        XCTAssertFalse(app.staticTexts["browser.answer"].exists)
        XCTAssertFalse(app.staticTexts["browser.learning"].exists)
        tap("browser.research.close")

        openMemory()
        XCTAssertTrue(app.staticTexts["memory.empty"].exists)
        select("skills")
        XCTAssertTrue(app.staticTexts["skills.empty"].waitForExistence(timeout: 5))
        select("pending")
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        let websites = app.buttons["memory.websites"]
        reveal(websites)
        XCTAssertEqual(websites.label, "網站知識與路線（0／0）")
        XCTAssertFalse(app.staticTexts["memory.error"].exists)

        // Recheck after navigation gives cancellation completion a chance to
        // publish; neither a stale reply nor a learning result may appear.
        tap("navigation.browser")
        waitForLabel(app.staticTexts["browser.status"], stopped)
        tap("browser.research")
        waitForLabel(app.staticTexts["browser.task.status"], stopped)
        XCTAssertEqual(goalField.value as? String, waitingGoal)
        XCTAssertFalse(app.buttons["browser.start"].isEnabled)
        XCTAssertFalse(app.staticTexts["browser.answer"].exists)
        XCTAssertFalse(app.staticTexts["browser.learning"].exists)
        tap("browser.research.close")
    }

    private func launch(reset: Bool = true) {
        app.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["uitest.banner"].exists)
    }

    private func configureModel() {
        tap("navigation.settings")
        enter("https://model.example.invalid/v1\n", into: app.textFields["settings.baseURL"])
        let model = app.textFields["settings.model"]
        reveal(model)
        enter("fixture-model\n", into: model)
        let key = app.secureTextFields["settings.apiKey"]
        reveal(key)
        enter("fixture-only-not-a-real-key\n", into: key)
        tap("settings.save", scroll: true)
        XCTAssertTrue(app.staticTexts["settings.notice"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["settings.error"].exists)
    }

    private func openFixture() {
        tap("navigation.browser")
        // iOS 26's failed transition snapshot contained no AX children; the
        // failure screenshot and final AX both showed this exact initial state.
        // Use XCTest's existence polling before reading the label, with the
        // same five-second bound as the previous compound predicate.
        let initialStatus = app.staticTexts["browser.status"]
        XCTAssertTrue(initialStatus.waitForExistence(timeout: 5))
        XCTAssertEqual(initialStatus.label, "輸入網址開始瀏覽")
        XCTAssertFalse(app.buttons["browser.research"].isEnabled)
        // DEBUG startup removes website data asynchronously. The failed Large
        // event-dispatch snapshot showed this field present but Disabled.
        // Wait for that reset to finish before the single tap and submission.
        let address = app.textFields["browser.address"]
        waitFor(address, predicate: "exists == true AND enabled == true AND hittable == true", timeout: 30)
        // Return submits the address exactly once through BrowserView.onSubmit.
        enter(fixtureURL + "\n", into: address)
        // Recorded iOS 18 WebContent startup alone took 57.481s. This remains
        // a bounded wait for real page readiness, not a fixed sleep or a retry.
        waitForLabel(app.staticTexts["browser.status"], "頁面已載入", timeout: 75)
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["browser.research"].isEnabled)
    }

    // Every real fixture page, including /start and /epsilon, has this h1.
    // Scope to WebKit descendants so a native sheet label cannot satisfy it.
    private var fixtureHeading: XCUIElement {
        app.webViews.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Website guide")).firstMatch
    }

    private var goalField: XCUIElement {
        // SwiftUI's multiline TextField is a TextView on some iOS versions.
        let textView = app.textViews["browser.goal"]
        return textView.exists ? textView : app.textFields["browser.goal"]
    }

    private func enterGoal(_ value: String? = nil) {
        let text = value ?? goal
        tap("browser.research")
        XCTAssertTrue(app.buttons["browser.start"].waitForExistence(timeout: 5))
        enter(text, into: goalField)
        tap("browser.goal.done")
        // SE 74's video shows dismissal at 53.280s, before the 54.12s
        // predicate check; its exists query retried until the waiter expired.
        // Retain five seconds and the exact goal check below. Never tap Done
        // again. Xcode's API introduction alone is not iOS 17 runtime proof;
        // keep that runtime on established XCTest polling of a fresh query.
        if #available(iOS 18.0, *) {
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        } else {
            let keyboardAbsent = XCTNSPredicateExpectation(
                predicate: NSPredicate { [self] _, _ in app.keyboards.count == 0 }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [keyboardAbsent], timeout: 5), .completed)
        }
        reveal(app.buttons["browser.start"])
        XCTAssertEqual(goalField.value as? String, text)
    }

    private func openMemory() {
        tap("navigation.memory")
        XCTAssertTrue(app.staticTexts["memory.status"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["memory.unavailable"].exists)
    }

    private func openWebsites(expectedCounts: String) {
        let websites = app.buttons["memory.websites"]
        reveal(websites)
        XCTAssertEqual(websites.label, "網站知識與路線（\(expectedCounts)）")
        websites.tap()
        XCTAssertTrue(app.buttons["website.close"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["website.error"].exists)
    }

    private func select(_ segment: String) {
        tap("memory.segment.\(segment)")
        XCTAssertEqual(app.buttons["memory.segment.\(segment)"].value as? String, "已選取")
    }

    private func assertTrialSkill(_ name: String) {
        let item = app.staticTexts["skills.item.\(name)"]
        reveal(item)
        waitForLabel(app.staticTexts["skills.state.\(name)"], "試用中 · 尚未驗證")
        let enabled = app.switches["skills.enabled.\(name)"]
        reveal(enabled)
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertFalse(app.staticTexts["memory.error"].exists)
    }

    private func enter(_ text: String, into field: XCUIElement) {
        // SE's website.note lookup failed to resolve the TextField visible in
        // the recording and final AX. Use native existence polling
        // before asking for hittability, within the same five-second budget.
        let deadline = Date().addingTimeInterval(5)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        if !field.isHittable {
            waitFor(field, predicate: "hittable == true", timeout: max(0, deadline.timeIntervalSinceNow))
        }
        if field.elementType == .textView {
            // iOS 17 AX/screenshot confirms an unobscured multiline goal
            // editor, but element.tap() did not focus it. Target the visible
            // text area within the actual element, then require the keyboard.
            reveal(field)
            XCTAssertTrue(field.isHittable)
            XCTAssertFalse(field.frame.isEmpty)
            XCTAssertTrue(app.frame.contains(field.frame))
            field.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.5)).tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        } else { field.tap() }
        field.typeText(text)
        if field.elementType == .textView { XCTAssertEqual(field.value as? String, text) }
    }

    private func tap(_ identifier: String, scroll: Bool = false,
                     file: StaticString = #filePath, line: UInt = #line) {
        let button = app.buttons[identifier]
        if scroll { reveal(button) }
        else {
            // SE 74's initial settings button was visible throughout, but the
            // compound predicate produced only an unresolved AX query chain.
            // Native existence polling avoids that nested exists retry. Share
            // the original five-second budget with the hittability check.
            let deadline = Date().addingTimeInterval(5)
            XCTAssertTrue(button.waitForExistence(timeout: 5), file: file, line: line)
            if !button.isHittable {
                waitFor(button, predicate: "hittable == true",
                        timeout: max(0, deadline.timeIntervalSinceNow), file: file, line: line)
            }
        }
        button.tap()
    }

    private func reveal(_ element: XCUIElement) {
        revealLearningElement(element, in: app)
    }

    private func waitFor(_ element: XCUIElement, predicate: String, timeout: TimeInterval = 5,
                         file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, file: file, line: line)
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String, timeout: TimeInterval = 5,
                              file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND label == %@", label), object: element)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        if result != .completed, element.exists, element.identifier == "browser.status" {
            // AX debugDescription truncates the load counters. Capture the
            // native diagnostic value before assertion reporting/teardown can
            // take another snapshot after the delayed document finally loads.
            let attachment = XCTAttachment(string: "label=\(element.label)\nload=\(element.value as? String ?? "unavailable")")
            attachment.name = "browser-load-at-wait-deadline"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, file: file, line: line)
    }
}
