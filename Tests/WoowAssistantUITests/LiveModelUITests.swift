import XCTest

// Opt-in private-runner suite: -only-testing:WoowAssistantUITests/LiveModelUITests.
// Runner-provided WOOW_LIVE_* values are forwarded in launchEnvironment only.
// Do not add screenshots, logs, or credential-bearing assertion messages to this suite.
// xctestrun/xcresult may contain launch environments; the private runner must not publish them.
final class LiveModelUITests: XCTestCase {
    private let namespace = UUID().uuidString
    private var launched = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        guard let key = ProcessInfo.processInfo.environment["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Live model credentials were not supplied by the private runner.")
        }
    }

    override func tearDownWithError() throws {
        guard launched else { return }
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveModelUITestCleanup"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["chat.status"].label, "尚未設定模型", "Isolated live credential cleanup failed.")
        app.terminate()
    }

    func testRealReplyMultiTurnContextAndDraftTabPreservation() throws {
        let app = try launchLiveApp()
        let marker = "LIVE_OK_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
        let prompt = "Remember this token for this conversation: \(marker). Reply with exactly that token and nothing else."
        enterDraft(prompt, in: app)
        for section in ["browser", "settings", "chat"] {
            navigate(to: section, in: app)
        }
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, prompt)
        app.buttons["chat.send"].tap()
        assertReply(marker, messageIndex: 1, in: app)
        enterDraft("What token did I ask you to remember? Reply with that token only.", in: app)
        app.buttons["chat.send"].tap()
        assertReply(marker, messageIndex: 3, in: app)
        XCTAssertTrue(app.staticTexts["chat.historyNotice"].label.contains("本次 App 工作階段"))
        XCTAssertFalse(app.staticTexts["uitest.banner"].exists)
    }

    func testLiveCancellationKeepsDraft() throws {
        let app = try launchLiveApp()
        let prompt = "Explain 30 practical ways to organize a small personal library, using one short sentence per item."
        enterDraft(prompt, in: app)
        app.buttons["chat.send"].tap()
        let cancel = app.buttons["chat.cancel"]
        guard cancel.waitForExistence(timeout: 2), cancel.isHittable else {
            if app.staticTexts["chat.message.1.assistant"].exists {
                throw XCTSkip("The live response completed before cancellation could be exercised.")
            }
            XCTFail("The live request did not expose a cancellation control.")
            return
        }
        cancel.tap()
        XCTAssertTrue(app.staticTexts["chat.notice"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, prompt)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
    }

    func testRealAutomaticMemorySurvivesRelaunchAndMasterSwitchBlocksRecall() throws {
        var app = try launchLiveApp()
        enterDraft("我最喜歡的顏色是琥珀色，這是我的長期喜好，請記住。簡短回覆即可。", in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["chat.message.1.assistant"].waitForExistence(timeout: 95))
        XCTAssertTrue(app.staticTexts["chat.memoryNote.0"].waitForExistence(timeout: 95),
                      "The real post-answer extraction did not publish a validated memory.")
        navigate(to: "memory", in: app)
        let remembered = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                              "memory.item.", "琥珀")).firstMatch
        XCTAssertTrue(remembered.waitForExistence(timeout: 5))
        app.terminate()
        app = try launchLiveApp() // Same isolated namespace, fresh chat history.
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
        enterDraft("我最喜歡什麼顏色？只回答顏色，使用繁體中文。", in: app)
        app.buttons["chat.send"].tap()
        let answer = app.staticTexts["chat.message.1.assistant"]
        XCTAssertTrue(answer.waitForExistence(timeout: 95))
        XCTAssertTrue(answer.label.contains("琥珀"), "Persisted memory was not used in the fresh conversation.")

        navigate(to: "memory", in: app)
        let toggle = app.switches["memory.toggle.useMemory"]
        for _ in 0..<8 where !toggle.isHittable { app.swipeUp() }
        waitUntilHittable(toggle)
        XCTAssertEqual(toggle.value as? String, "1")
        // SwiftUI can expose a row-wide switch wrapper with a nested UISwitch.
        // Target the actual control and wait for persisted state publication.
        let nativeSwitch = toggle.switches.firstMatch
        let target = nativeSwitch.exists ? nativeSwitch : toggle
        waitUntilHittable(target)
        target.tap()
        let disabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "0"), object: toggle)
        XCTAssertEqual(XCTWaiter.wait(for: [disabled], timeout: 5), .completed)
        XCTAssertFalse(app.staticTexts["memory.error"].exists, "The App reported a memory settings write error.")
        navigate(to: "chat", in: app)
        app.buttons["chat.newConversation"].tap()
        enterDraft("What is my favorite color? If no preference is provided in this conversation, reply with exactly UNKNOWN and nothing else.", in: app)
        app.buttons["chat.send"].tap()
        assertReply("UNKNOWN", messageIndex: 1, in: app)
        XCTAssertFalse(app.staticTexts["chat.learning"].exists)
        navigate(to: "memory", in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                          "memory.item.", "琥珀")).firstMatch.exists,
                      "Turning memory off must not erase stored records.")
    }

    func testRealHTTPTransportFailureKeepsDraft() throws {
        // Exercise the actual HTTP client against a reserved invalid domain with a dummy
        // credential. Never send a real key to a different service just to provoke failure.
        let app = try launchLiveApp(transportFailure: true)
        let prompt = "Keep this unsent prompt after a connection failure."
        enterDraft(prompt, in: app)
        app.buttons["chat.send"].tap()
        XCTAssertTrue(app.staticTexts["chat.error"].waitForExistence(timeout: 95))
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, prompt)
        XCTAssertTrue(app.buttons["chat.send"].isEnabled)
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
    }

    func testRealWebKitResearchUsesPublicWebsiteAndJudgesOutcome() throws {
        let app = try launchLiveApp()
        openPublicIANA(in: app)
        app.buttons["browser.research"].tap()
        let goal = app.textFields["browser.goal"].exists ? app.textFields["browser.goal"] : app.textViews["browser.goal"]
        waitUntilHittable(goal); goal.tap()
        goal.typeText("Read the currently open IANA home page and explain its three main responsibility areas in one short paragraph. Include IANA in your answer. Do not navigate unless the current page lacks the information.")
        app.buttons["browser.goal.done"].tap()
        let start = app.buttons["browser.start"]
        waitUntilHittable(start); start.tap()
        // Wait on the control that stays in the current viewport. SwiftUI Form
        // can omit the answer's accessibility row until it is scrolled into view.
        // Completion alone is never success: the answer and exact verdict below
        // remain mandatory, including if an error re-enabled the start button.
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        let completion = XCTWaiter.wait(for: [completed], timeout: 120)
        printBrowserPhase(in: app)
        XCTAssertEqual(completion, .completed, "Live website research and judging did not finish.")
        XCTAssertEqual(app.staticTexts["browser.task.status"].label, "研究已結束",
                       "Research must end successfully before looking for an answer; fixed failure category is shown above.")
        let answer = app.staticTexts["browser.answer"]
        revealLearningElement(answer, in: app, visibility: .readableText)
        XCTAssertTrue(answer.exists, "Live website research did not deliver a result.")
        XCTAssertTrue(answer.label.localizedCaseInsensitiveContains("IANA"))
        let learning = app.staticTexts["browser.learning"]
        revealLearningElement(learning, in: app)
        XCTAssertTrue(learning.exists, "The actual outcome judge did not finish.")
        XCTAssertEqual(learning.label, "已判定任務完成；未新增技能草稿。",
                       "Require judged done: partial results and failed learning also contain 完成.")
        // A one-page explanation must not fabricate five navigations to create a skill.
        XCTAssertFalse(learning.label.contains("技能草稿已加入"))
    }

    func testRealMultiPageResearchLearnsPendingSkillAndApprovalSurvivesRelaunch() throws {
        executionTimeAllowance = 300
        var app = try launchLiveApp()
        XCTAssertFalse(app.staticTexts["uitest.banner"].exists)
        openPublicIANA(in: app)
        // Each page answers a different orientation question. No fake model,
        // injected trajectory, repeated navigation or explicit skill-save request.
        // Contact is beyond the home's first 30 links; About exposes it early.
        // Leave the large Protocol Registries index last, after the other evidence.
        let sources = ["about", "contact", "domains", "numbers", "protocols"].map { "https://www.iana.org/" + $0 }
        let researchGoal = """
        Prepare a concise IANA orientation brief for a new Internet operations colleague, verifying each topic on its dedicated page, not just the home-page summary. Follow visible same-site links in this order: About, Contact us, Domains, Numbers, Protocols. On About verify who performs the IANA functions; on Contact us verify the general email contact; on Domains identify the root zone and the two special domains it operates; on Numbers explain who receives IANA's ordinary IP address allocations; on Protocols explain what its registries record and which standards organization it coordinates with. Write five short English bullets, one per topic, citing each dedicated page's full URL. The section overviews suffice: do not open individual registries, external sites, forms or unrelated pages, and do not revisit pages. Finish once those five topics are verified; report any missing evidence honestly.
        """
        app.buttons["browser.research"].tap()
        let goal = app.textFields["browser.goal"].exists ? app.textFields["browser.goal"] : app.textViews["browser.goal"]
        waitUntilHittable(goal); goal.tap(); goal.typeText(researchGoal)
        app.buttons["browser.goal.done"].tap()
        let start = app.buttons["browser.start"]
        waitUntilHittable(start); start.tap()

        // Research has a 180s product deadline; the independent judge and
        // drafter each have a 30s deadline. Never retry a failed run to get green.
        let answer = app.staticTexts["browser.answer"]
        let taskStatus = app.staticTexts["browser.task.status"]
        let delivered = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            answer.exists || (taskStatus.exists && taskStatus.label == "回答已交付，正在判定成果…") || start.isEnabled
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [delivered], timeout: 185), .completed)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 65), .completed)
        printBrowserPhase(in: app)
        XCTAssertEqual(taskStatus.label, "研究已結束",
                       "Research must end successfully before scrolling; failed/limited runs cannot pass.")
        revealLearningElement(answer, in: app, visibility: .readableText)
        XCTAssertTrue(answer.exists, "Real multi-page research must deliver an answer.")
        let answerText = answer.label
        for source in sources {
            XCTAssertTrue(answerText.contains(source), "The briefing must cite each required public source.")
        }
        let learning = app.staticTexts["browser.learning"]
        revealLearningElement(learning, in: app)
        XCTAssertEqual(learning.label, "已判定任務完成；技能草稿已加入待確認，核准後才能使用。",
                       "Require independent judged done AND a validated pending draft, not partial/unknown or a plain reply.")

        // These are exact URL labels in the App's completed-action rows, not
        // citations in the answer. Starting at /, each new page needs an actual
        // successful WKWebView navigation. Six actions = initial inspect + five
        // distinct opens, with no observation or duplicate padding of the gate.
        let reads = app.staticTexts["已完成的讀取（6）"]
        revealLearningElement(reads, in: app)
        XCTAssertTrue(reads.exists, "Require exactly the initial inspect and five successful navigations.")
        for source in ["https://www.iana.org/"] + sources {
            let observed = app.staticTexts.matching(NSPredicate(format: "label == %@", source)).firstMatch
            revealLearningElement(observed, in: app)
            XCTAssertTrue(observed.exists, "A required public page is absent from actual completed actions.")
        }
        app.buttons["browser.research.close"].tap()
        XCTAssertFalse(app.staticTexts["browser.error"].exists)
        XCTAssertTrue((app.textFields["browser.address"].value as? String) == sources.last,
                      "Research should finish on the last required public page.")

        navigate(to: "memory", in: app)
        selectLearningSegment("skills", in: app)
        XCTAssertTrue(app.staticTexts["skills.empty"].waitForExistence(timeout: 5), "Learning must not approve its own draft.")
        selectLearningSegment("pending", in: app)
        let drafts = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "skills.draft."))
        let pending = drafts.firstMatch
        revealLearningElement(pending, in: app)
        XCTAssertEqual(drafts.count, 1, "Exactly one learned draft must await explicit approval.")
        let name = String(pending.identifier.dropFirst("skills.draft.".count))
        XCTAssertFalse(name.isEmpty)
        tapLearningButton("skills.draftFullText.\(name)", in: app)
        let document = app.staticTexts["skills.document"]
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        let reviewedMarkdown = document.label
        XCTAssertFalse(reviewedMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertTrue(reviewedMarkdown.contains("\nsource: learned\n"), "Draft must originate from the real learning pipeline.")
        let provenance = reviewedMarkdown.components(separatedBy: "\n").first { $0.hasPrefix("learned_from: ") }
            .map { String($0.dropFirst("learned_from: ".count)) }
        XCTAssertNotNil(provenance.flatMap { UUID(uuidString: $0) }, "Learned draft needs a runtime run UUID.")
        app.buttons["skills.document.close"].tap()
        tapLearningButton("skills.approve.\(name)", in: app)
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["memory.error"].exists)
        selectLearningSegment("skills", in: app)
        assertLiveTrialSkill(name, in: app)
        tapLearningButton("skills.fullText.\(name)", in: app)
        XCTAssertTrue(document.waitForExistence(timeout: 5))
        // Boolean byte comparison prevents a failed assertion logging model prose.
        XCTAssertTrue(Data(document.label.utf8) == Data(reviewedMarkdown.utf8), "Approval must preserve exact reviewed Markdown and provenance.")
        app.buttons["skills.document.close"].tap()

        app.terminate()
        app = try launchLiveApp() // Same isolated vault, no fixture seeding/import.
        navigate(to: "memory", in: app)
        selectLearningSegment("skills", in: app)
        assertLiveTrialSkill(name, in: app)
        tapLearningButton("skills.fullText.\(name)", in: app)
        let persisted = app.staticTexts["skills.document"]
        XCTAssertTrue(persisted.waitForExistence(timeout: 5))
        XCTAssertTrue(Data(persisted.label.utf8) == Data(reviewedMarkdown.utf8),
                      "Encrypted relaunch must preserve the exact approved fulltext, including original run provenance.")
        app.buttons["skills.document.close"].tap()
        selectLearningSegment("pending", in: app)
        XCTAssertTrue(app.staticTexts["memory.pending.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["memory.error"].exists)
    }

    private func openPublicIANA(in app: XCUIApplication) {
        navigate(to: "browser", in: app)
        let address = app.textFields["browser.address"]
        // The first WebKit accessibility snapshot can itself take longer than
        // five seconds on a cold hosted simulator. Keep functional assertions
        // strict and record only geometry/timing, never page/configuration text.
        let addressStart = Date()
        let addressReady = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"), object: address)
        let readiness = XCTWaiter.wait(for: [addressReady], timeout: 15)
        print("Live browser address readiness seconds: \(Date().timeIntervalSince(addressStart)); exists: \(address.exists); hittable: \(address.isHittable); frame: \(address.frame)")
        XCTAssertEqual(readiness, .completed, "The real browser address must be interactable.")
        address.tap(); address.typeText("https://www.iana.org/\n")
        let loaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "頁面已載入"), object: app.staticTexts["browser.status"])
        XCTAssertEqual(XCTWaiter.wait(for: [loaded], timeout: 75), .completed)
    }

    private func selectLearningSegment(_ segment: String, in app: XCUIApplication) {
        let button = app.buttons["memory.segment.\(segment)"]
        waitUntilHittable(button); button.tap()
        XCTAssertEqual(button.value as? String, "已選取")
    }

    private func printBrowserPhase(in app: XCUIApplication) {
        // These labels are fixed App-owned state messages, never model replies,
        // observations, URLs, configuration values or underlying error strings.
        for identifier in ["browser.task.status", "browser.learning", "browser.error"] {
            let state = app.staticTexts[identifier]
            print("Live browser phase \(identifier): \(state.exists ? state.label : "not-visible")")
        }
    }

    private func tapLearningButton(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        revealLearningElement(button, in: app)
        button.tap()
    }

    private func assertLiveTrialSkill(_ name: String, in app: XCUIApplication) {
        let item = app.staticTexts["skills.item.\(name)"]
        revealLearningElement(item, in: app)
        XCTAssertTrue(item.exists)
        XCTAssertEqual(app.staticTexts["skills.state.\(name)"].label, "試用中 · 尚未驗證",
                       "The task that created a skill cannot also verify using that skill.")
        let enabled = app.switches["skills.enabled.\(name)"]
        revealLearningElement(enabled, in: app)
        XCTAssertEqual(enabled.value as? String, "1")
        XCTAssertFalse(app.staticTexts["memory.error"].exists)
    }

    private func launchLiveApp(transportFailure: Bool = false) throws -> XCUIApplication {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["WOOW_LIVE_BASE_URL"], !baseURL.isEmpty,
              let model = environment["WOOW_LIVE_MODEL"], !model.isEmpty,
              let key = environment["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            XCTFail("The private runner must provide all three live model variables.")
            throw LiveTestSetupError.missingConfiguration
        }
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-LiveModelUITest", "-LiveModelUITestNamespace", namespace]
        app.launchEnvironment = [
            "WOOW_LIVE_BASE_URL": transportFailure ? "https://unreachable.invalid/v1" : baseURL,
            "WOOW_LIVE_MODEL": transportFailure ? "unused-test-model" : model,
            "WOOW_LIVE_API_KEY": transportFailure ? "dummy-key-not-a-credential" : key
        ]
        launched = true
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        if app.staticTexts["chat.status"].label != "模型已設定" {
            navigate(to: "settings", in: app)
            // App-owned fixed category/OSStatus only, never provider data or credentials.
            let diagnosis = app.staticTexts["settings.error"].exists ? app.staticTexts["settings.error"].label : "No bootstrap diagnostic"
            XCTFail("Live bootstrap did not finish: " + diagnosis)
            throw LiveTestSetupError.missingConfiguration
        }
        XCTAssertEqual(app.staticTexts["chat.status"].label, "模型已設定", "Live bootstrap did not finish.")
        return app
    }

    private func enterDraft(_ text: String, in app: XCUIApplication) {
        let draft = app.textFields["chat.draft"]
        waitUntilHittable(draft)
        draft.tap()
        draft.typeText(text + "\n")
        waitUntilHittable(app.buttons["chat.send"])
    }

    private func navigate(to section: String, in app: XCUIApplication) {
        let button = app.buttons["navigation.\(section)"]
        waitUntilHittable(button)
        button.tap()
        XCTAssertTrue(app.staticTexts["\(section).status"].waitForExistence(timeout: 5))
    }

    private func assertReply(_ expected: String, messageIndex: Int, in app: XCUIApplication) {
        let reply = app.staticTexts["chat.message.\(messageIndex).assistant"]
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            reply.exists || app.staticTexts["chat.error"].exists
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 95), .completed)
        XCTAssertFalse(app.staticTexts["chat.error"].exists, "The live model request failed.")
        XCTAssertTrue(reply.exists)
        XCTAssertEqual(reply.label.trimmingCharacters(in: .whitespacesAndNewlines), expected)
    }

    private func waitUntilHittable(_ element: XCUIElement) {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 5), .completed)
    }

    private enum LiveTestSetupError: Error { case missingConfiguration }
}
