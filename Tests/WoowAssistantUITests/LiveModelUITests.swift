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
