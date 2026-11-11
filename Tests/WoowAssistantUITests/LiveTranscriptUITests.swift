import XCTest

/// Private-runner only. The native Files source is synthetic, but the model
/// requests use the configured real endpoint and actual credentials. No reply,
/// read result, runtime completion, file selection or approval is preseeded.
/// Do not publish xcresult/xctestrun, launch environments or add attachments.
final class LiveTranscriptUITests: XCTestCase {
    private let namespace = UUID().uuidString
    private let app = XCUIApplication()
    private var launched = false

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Files source requires an isolated simulator.")
        #endif
        continueAfterFailure = false; executionTimeAllowance = 300
        guard let key = ProcessInfo.processInfo.environment["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            throw XCTSkip("Live model credentials were not supplied by the private runner.")
        }
    }

    override func tearDownWithError() throws {
        guard launched else { return }
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-LiveModelUITest", "-LiveModelUITestNamespace", namespace, "-LiveModelUITestCleanup"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["chat.status"].label, "尚未設定模型", "Isolated live credential cleanup failed.")
        app.terminate()
    }

    func testRealModelReadsEntireNativeTextAndReturnsVerifiedSourceQuotes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let baseURL = environment["WOOW_LIVE_BASE_URL"], !baseURL.isEmpty,
              let model = environment["WOOW_LIVE_MODEL"], !model.isEmpty,
              let key = environment["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            XCTFail("The private runner must provide all three live model variables.")
            throw SetupFailure.missingConfiguration
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-LiveModelUITest",
            "-LiveModelUITestNamespace", namespace, "-UITestTranscript"]
        app.launchEnvironment = ["WOOW_LIVE_BASE_URL": baseURL, "WOOW_LIVE_MODEL": model, "WOOW_LIVE_API_KEY": key]
        launched = true; app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["chat.status"].label, "模型已設定", "Private live bootstrap must succeed.")
        XCTAssertFalse(app.staticTexts["uitest.banner"].exists)
        let driver = TranscriptUIDriver(app: app, namespace: namespace)
        try driver.openTranscript()
        try driver.chooseFixture()
        try driver.assertAudit(selections: 1, reads: 0, modelAttempts: 0, results: 0)
        try driver.approveRead()
        let source = try driver.readSourceLabel()
        XCTAssertTrue(source.contains(namespace) && source.contains("工作紀錄結尾：月底再次核對待修清單。"),
                      "The source must be this namespace's actual selected text, including its last paragraph.")
        XCTAssertTrue(source.utf8.count > 8192, "This case must require more than one model read_file range.")
        try driver.assertAudit(selections: 1, reads: 1, modelAttempts: 0, results: 0)
        try driver.tap("transcript.confirmDestination", scroll: true)
        let destination = app.staticTexts["transcript.destination"]
        try driver.show(destination, readable: true)
        // Boolean comparisons avoid logging the endpoint/model through XCTAssertEqual.
        let url = try XCTUnwrap(URL(string: baseURL))
        let host = try XCTUnwrap(url.host)
        let expectedDestination = "https://" + host + (url.port.map { ":\($0)" } ?? "") + "\n模型：" + model
        XCTAssertTrue(destination.label == expectedDestination, "Only the configured destination may be approved.")
        XCTAssertFalse(app.staticTexts["transcript.result"].exists)
        try driver.tap("transcript.start", scroll: true)
        // The start control remains near the current viewport while results are
        // still virtualized below. Require terminal product status and evidence
        // after it re-enables; re-enablement on failure never counts as success.
        let start = app.buttons["transcript.start"]
        XCTAssertTrue(app.buttons["transcript.cancel"].waitForExistence(timeout: 10))
        XCTAssertFalse(start.isEnabled)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: start)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 185), .completed)
        let audit = try driver.audit()
        recordSafeDiagnostic(audit: audit)
        XCTAssertEqual(audit["selections"], 1); XCTAssertEqual(audit["reads"], 1); XCTAssertEqual(audit["results"], 1)
        XCTAssertTrue((audit["rangeReads"] ?? 0) >= 2)
        XCTAssertTrue((audit["modelAttempts"] ?? 0) >= 3)
        XCTAssertEqual(audit["covered"], source.utf8.count)
        XCTAssertEqual(audit["total"], source.utf8.count)
        XCTAssertFalse(app.staticTexts["transcript.error"].exists)
        XCTAssertFalse(app.staticTexts["transcript.refusal"].exists)
        let title = app.staticTexts["transcript.result"]
        try driver.show(title, readable: true)
        XCTAssertTrue(!title.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let summary = app.staticTexts["transcript.section.0"]
        try driver.show(summary, readable: true)
        XCTAssertTrue(!summary.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        let evidence = app.staticTexts["transcript.evidence.0.0"]
        try driver.show(evidence, readable: true)
        let quote = Data(evidence.label.utf8)
        XCTAssertTrue(!quote.isEmpty && Data(source.utf8).range(of: quote) != nil,
                      "A real model citation must match the actual selected UTF-8 text byte for byte.")
        // Returning to Learning must not reveal an auto-created memory/skill.
        try driver.tap("transcript.close")
        try driver.show(app.staticTexts["skills.empty"], readable: true)
        try driver.tap("memory.segment.pending")
        try driver.show(app.staticTexts["memory.pending.empty"], readable: true)
    }

    /// Never print status/refusal/error prose, AX trees or model replies. These
    /// allowlists also reject accidental future additions of arbitrary values.
    private func recordSafeDiagnostic(audit: [String: Int]) {
        let element = app.staticTexts["transcript.diagnostic"]
        let tokens = element.exists ? element.label.split(separator: " ").map(String.init) : []
        let terminals: Set<String> = ["idle", "reading", "running", "completed", "refused", "unknownFailure",
            "invalidSelection", "unsupportedType", "tooLarge", "invalidEncoding", "emptySource", "approvalRequired",
            "cancelled", "readTimedOut", "invalidCommand", "invalidRange", "incompleteCoverage", "invalidEvidence",
            "budgetExceeded", "modelFailed", "timedOut", "contextChanged"]
        let reasons: Set<String> = ["none", "syntax", "size", "fields", "action", "tool", "arguments"]
        if tokens.count == 4, tokens[0] == "TRANSCRIPT_DIAGNOSTIC",
           terminals.map({ "terminal=" + $0 }).contains(tokens[1]),
           reasons.map({ "reason=" + $0 }).contains(tokens[2]),
           ["corrections=0", "corrections=1"].contains(tokens[3]) {
            print(tokens.joined(separator: " "))
        } else { print("TRANSCRIPT_DIAGNOSTIC unavailable") }
        let names = ["selections", "reads", "modelAttempts", "rangeReads", "covered", "total", "results"]
        guard names.allSatisfy({ audit[$0].map { (0...65536).contains($0) } == true }) else {
            print("TRANSCRIPT_AUDIT unavailable"); return
        }
        print("TRANSCRIPT_AUDIT " + names.map { "\($0)=\(audit[$0]!)" }.joined(separator: " "))
    }
    private enum SetupFailure: Error { case missingConfiguration }
}
