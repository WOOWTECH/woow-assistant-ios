import XCTest

/// Private runner: real public search through the App's isolated WKWebView.
/// Credentials are configured normally, but this suite never authorizes research.
/// Idle research diagnostics prove that boundary, not a global HTTP call count.
/// Do not publish xcresult/xctestrun, screenshots, AX trees or candidate URLs.
final class LiveSourceDiscoveryUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private let query = "Swift Apple programming language documentation"
    private let originalRoots = ["https://example.com/", "https://example.org/", "https://example.net/"]
    private var launched = false
    private var started = Date()
    private enum Failure: Error { case configuration, readiness, budget, candidate, provider }

    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Live acceptance requires the isolated private simulator.")
        #endif
        continueAfterFailure = false
        executionTimeAllowance = 300
        started = Date()
        guard ProcessInfo.processInfo.environment["WOOW_LIVE_API_KEY"]?.isEmpty == false else {
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
        XCTAssertTrue(app.staticTexts["chat.status"].label == "尚未設定模型", "Isolated live credential cleanup failed.")
        app.terminate()
    }

    func testPublicSearchAppliesTwoDistinctOriginsWithoutStartingResearch() throws {
        try launchResearch(goal: query)
        try openDiscovery(expectedQuery: query)
        try tap("sourceDiscovery.search", scroll: true)
        let count = try waitForSearchResult()
        XCTAssertGreaterThanOrEqual(count, 2, "The actual search must return enough candidates; no fallback source is injected.")

        var selected: [SourceDiscoveryCandidateValue] = []
        for index in 0..<count {
            try checkBudget()
            let button = app.buttons["sourceDiscovery.candidate.\(index)"].firstMatch
            try show(button)
            guard let candidate = SourceDiscoveryCandidateValue(button.value as? String) else {
                XCTFail("A real candidate must expose its exact URL and selection state separately from its title.")
                throw Failure.candidate
            }
            XCTAssertFalse(candidate.selected, "Each result begins unselected.")
            guard !selected.contains(where: { $0.origin == candidate.origin }) else { continue }
            try ready(button)
            button.tap()
            try wait("The chosen actual candidate did not become selected.", timeout: 5) {
                guard let updated = SourceDiscoveryCandidateValue(button.value as? String) else { return false }
                return updated.selected && updated.url == candidate.url
            }
            selected.append(candidate)
            if selected.count == 2 { break }
        }
        guard selected.count == 2 else {
            XCTFail("The actual search did not offer two distinct origins; ordering or specific publishers are not assumed.")
            throw Failure.candidate
        }
        XCTAssertTrue(selected[0].origin != selected[1].origin)
        let selection = app.staticTexts["sourceDiscovery.selectionCount"].firstMatch
        try showFixed(selection)
        XCTAssertTrue(selection.label == "已選取 2 個網站")
        XCTAssertFalse(app.staticTexts["sourceDiscovery.error"].exists)
        try tap("sourceDiscovery.apply")
        try waitForDiscoveryDismissal()
        let applied = [selected[0].url, selected[1].url, ""]
        try assertRoots(applied)
        try assertGoal(query)
        try assertResearchIdle()
        print("SOURCE_DISCOVERY applied=2 distinctOrigins=2 researchStarted=0")

        // A reopened sheet is a new Session(query: parent goal), not a retained
        // result/selection. Closing it must not undo the already applied roots.
        try openDiscovery(expectedQuery: query)
        try assertFreshDiscovery()
        try tap("sourceDiscovery.close")
        try waitForDiscoveryDismissal()
        try assertRoots(applied)
        try assertGoal(query)
        try assertResearchIdle()
        print("SOURCE_DISCOVERY reopenedFresh=1 closePreservedRoots=1")
    }

    func testPublicSearchCancellationOrCompletionPreservesQueryUntilSheetCloses() throws {
        try launchResearch(goal: "")
        try openDiscovery(expectedQuery: "")
        try enter(query, identifier: "sourceDiscovery.query", done: "sourceDiscovery.keyboardDone")
        try tap("sourceDiscovery.search", scroll: true)
        let cancel = app.buttons["sourceDiscovery.cancel"].firstMatch
        let status = app.staticTexts["sourceDiscovery.status"].firstMatch
        try wait("The real search did not expose a running or terminal state.", timeout: 50) {
            (cancel.exists && cancel.isHittable) || self.searchIsTerminal(status)
        }
        // A fast real response can win before XCTest can tap Cancel. Never
        // demand an artificial delay, restart the request, or call that a
        // successful cancellation. Both terminal paths are reported explicitly.
        if cancel.exists && cancel.isHittable && cancel.isEnabled {
            XCTAssertTrue(app.frame.contains(cancel.frame))
            cancel.tap()
        }
        try wait("Search cancellation or completion did not reach a real terminal state.", timeout: 50) {
            self.searchIsTerminal(status)
        }
        let cancelled = status.label == "搜尋已取消，搜尋詞仍保留。"
        if cancelled {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "sourceDiscovery.candidate.")).firstMatch.exists)
            XCTAssertFalse(app.staticTexts["sourceDiscovery.selectionCount"].exists)
            XCTAssertFalse(app.staticTexts["sourceDiscovery.error"].exists)
            let lateResult = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                status.label != "搜尋已取消，搜尋詞仍保留。"
                    || self.app.buttons["sourceDiscovery.candidate.0"].exists
            }, object: nil)
            lateResult.isInverted = true
            XCTAssertTrue(XCTWaiter.wait(for: [lateResult], timeout: min(3, try remaining())) == .completed,
                          "A cancelled search must not publish a late result.")
            print("SOURCE_DISCOVERY terminal=cancelled cancellationObserved=1 candidates=0")
        } else {
            let count = try acceptedResultCount(status)
            XCTAssertFalse(app.staticTexts["sourceDiscovery.error"].exists)
            let selection = app.staticTexts["sourceDiscovery.selectionCount"].firstMatch
            try showFixed(selection)
            XCTAssertTrue(selection.label == "已選取 0 個網站")
            XCTAssertFalse(app.buttons["sourceDiscovery.apply"].isEnabled)
            print("SOURCE_DISCOVERY terminal=completed cancellationObserved=0 candidates=\(count)")
        }
        let input = try field("sourceDiscovery.query")
        try show(input)
        XCTAssertTrue(input.value as? String == query, "The same sheet must retain its actual typed query.")
        try tap("sourceDiscovery.close")
        try waitForDiscoveryDismissal()
        try assertRoots(originalRoots)
        try assertGoal("")
        try assertResearchIdle()

        // The edited search query belongs to the dismissed sheet. Reopening
        // starts with the unchanged, empty parent goal and no prior candidates.
        try openDiscovery(expectedQuery: "")
        try assertFreshDiscovery()
        try tap("sourceDiscovery.close")
        try waitForDiscoveryDismissal()
        try assertRoots(originalRoots)
        try assertResearchIdle()
        print("SOURCE_DISCOVERY queryRetainedInSheet=1 reopenedFromGoal=1 rootsUnchanged=1")
    }

    private func launchResearch(goal: String) throws {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["WOOW_LIVE_BASE_URL"], !base.isEmpty,
              let model = environment["WOOW_LIVE_MODEL"], !model.isEmpty,
              let key = environment["WOOW_LIVE_API_KEY"], !key.isEmpty else {
            XCTFail("The private runner must supply all three live model variables.")
            throw Failure.configuration
        }
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-LiveModelUITest", "-LiveModelUITestNamespace", namespace]
        app.launchEnvironment = ["WOOW_LIVE_BASE_URL": base, "WOOW_LIVE_MODEL": model, "WOOW_LIVE_API_KEY": key]
        launched = true
        app.launch()
        try wait("Private model bootstrap did not complete.", timeout: 15) { self.app.staticTexts["chat.status"].exists }
        XCTAssertTrue(app.staticTexts["chat.status"].label == "模型已設定")
        XCTAssertFalse(app.staticTexts["uitest.banner"].exists)
        try tap("navigation.browser", timeout: 15)
        try wait("The native Browser section was not selected.", timeout: 15) {
            self.app.buttons["navigation.browser"].value as? String == "已選取"
        }
        try tap("browser.multiResearch", timeout: 30)
        if !goal.isEmpty { try enter(goal, identifier: "multiResearch.goal", done: "multiResearch.keyboardDone") }
        for (index, root) in originalRoots.enumerated() {
            try enter(root, identifier: "multiResearch.rootText\(index + 1)", done: "multiResearch.keyboardDone")
        }
        try assertResearchIdle()
    }

    private func openDiscovery(expectedQuery: String) throws {
        try tap("multiResearch.discoverSources", scroll: true)
        try wait("The real source discovery sheet did not appear.", timeout: 10) {
            self.app.buttons["sourceDiscovery.close"].exists
        }
        let input = try field("sourceDiscovery.query")
        try show(input)
        XCTAssertTrue(matches(input, expectedQuery), "A new sheet must start from the unchanged parent goal.")
    }

    private func assertFreshDiscovery() throws {
        let status = app.staticTexts["sourceDiscovery.status"].firstMatch
        try show(status, readable: true)
        XCTAssertTrue(status.label == "尚未搜尋")
        XCTAssertFalse(app.buttons["sourceDiscovery.candidate.0"].exists)
        XCTAssertFalse(app.staticTexts["sourceDiscovery.selectionCount"].exists)
        XCTAssertFalse(app.buttons["sourceDiscovery.cancel"].exists)
        XCTAssertFalse(app.staticTexts["sourceDiscovery.error"].exists)
        XCTAssertFalse(app.buttons["sourceDiscovery.apply"].exists, "A fresh sheet has no result or apply footer.")
    }

    private func waitForSearchResult() throws -> Int {
        let status = app.staticTexts["sourceDiscovery.status"].firstMatch
        try wait("The real public search did not complete within its product budget.", timeout: 50) {
            self.searchIsTerminal(status)
        }
        let count = try acceptedResultCount(status)
        XCTAssertFalse(app.staticTexts["sourceDiscovery.error"].exists)
        print("SOURCE_DISCOVERY terminal=completed candidates=\(count)")
        return count
    }

    private func searchIsTerminal(_ status: XCUIElement) -> Bool {
        guard status.exists else { return false }
        let label = status.label
        return SourceDiscoveryCandidateValue.resultCount(label) != nil
            || label == "這次搜尋未完成" || label == "搜尋已取消，搜尋詞仍保留。"
    }

    private func acceptedResultCount(_ status: XCUIElement) throws -> Int {
        guard let count = SourceDiscoveryCandidateValue.resultCount(status.label) else {
            print("SOURCE_DISCOVERY terminal=search_failed")
            XCTFail("The actual provider did not deliver accepted candidates; no fixture, alternate provider or retry is used.")
            throw Failure.provider
        }
        return count
    }

    private func assertRoots(_ values: [String]) throws {
        for (index, expected) in values.enumerated() {
            let input = try field("multiResearch.rootText\(index + 1)")
            try show(input)
            XCTAssertTrue(matches(input, expected), "Root fields must equal the selected actual URLs in selection order, with an empty third root.")
        }
    }

    private func assertGoal(_ expected: String) throws {
        let input = try field("multiResearch.goal")
        try show(input)
        XCTAssertTrue(matches(input, expected), "Source discovery must not change the parent research goal.")
    }

    private func assertResearchIdle() throws {
        let status = app.staticTexts["multiResearch.status"].firstMatch
        try show(status, readable: true)
        XCTAssertTrue(status.label == "輸入問題與來源，確認後開始讀取。")
        XCTAssertTrue(status.value as? String == "phase=idle;failure=none;pages=0",
                      "Applying or closing discovery must not call the research start boundary.")
        XCTAssertFalse(app.staticTexts["multiResearch.result"].exists)
        XCTAssertFalse(app.staticTexts["multiResearch.error"].exists)
        XCTAssertFalse(app.buttons["multiResearch.cancel"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "multiResearch.receipt.")).firstMatch.exists)
    }

    private func waitForDiscoveryDismissal() throws {
        try wait("Discovery must actually dismiss before inspecting the underlying research form.", timeout: 10) {
            !self.app.buttons["sourceDiscovery.close"].exists
        }
    }

    private func field(_ identifier: String) throws -> XCUIElement {
        try checkBudget()
        // Exact ID stays stable when SwiftUI exposes a vertical TextField as a
        // TextView. Return its lazy query before revealing virtualized rows.
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func matches(_ field: XCUIElement, _ expected: String) -> Bool {
        guard let value = field.value as? String else { return false }
        return value == expected || (expected.isEmpty && value == field.placeholderValue)
    }

    private func enter(_ value: String, identifier: String, done: String) throws {
        let input = try field(identifier)
        try show(input)
        try ready(input)
        input.tap()
        // iOS 17 exposes these vertical SwiftUI fields as TextView. The failed
        // native runs stopped at a pre-typing XCUIKeyboard query; use the same
        // exact native introduction gate as other live browser input tests.
        let introduction = app.buttons["Continue"].firstMatch
        if introduction.waitForExistence(timeout: 3) {
            XCTAssertTrue(app.staticTexts["Speed up your typing by sliding your finger across the letters to compose a word."].exists,
                          "Only the known native keyboard introduction may be dismissed.")
            try ready(introduction)
            introduction.tap()
            try wait("The native keyboard introduction must dismiss before typing.", timeout: 5) {
                !introduction.exists
            }
        }
        input.typeText(value)
        XCTAssertTrue(input.value as? String == value, "The exact public input must arrive through the native keyboard.")
        try tap(done)
        try wait("The keyboard must dismiss before scrolling the form.", timeout: 5) { !self.app.keyboards.firstMatch.exists }
    }

    private func tap(_ identifier: String, scroll: Bool = false, timeout: TimeInterval = 5) throws {
        let button = app.buttons[identifier].firstMatch
        if scroll { try show(button) }
        try ready(button, timeout: timeout)
        XCTAssertTrue(app.frame.contains(button.frame), "A real visible control is required; no coordinate tap fallback is used.")
        button.tap()
    }

    private func ready(_ element: XCUIElement, timeout: TimeInterval = 5) throws {
        try wait("The native control did not become interactable.", timeout: timeout) {
            element.exists && element.isEnabled && element.isHittable
        }
    }

    private func show(_ element: XCUIElement, readable: Bool = false) throws {
        try checkBudget()
        if app.buttons["sourceDiscovery.close"].exists {
            try showInDiscoveryForm(element, readable: readable)
        } else {
            revealLearningElement(element, in: app, visibility: readable ? .readableText : .fullyVisible)
        }
        try checkBudget()
    }

    private func showFixed(_ element: XCUIElement) throws {
        // The selection count/apply footer is a real safeAreaInset sibling of
        // the Form. Never scroll the Form to try to reveal that fixed footer.
        try wait("The fixed selection footer must actually be visible.", timeout: 5) {
            guard element.exists,
                  learningFrameIsVisible(element.frame, in: self.app.frame, visibility: .fullyVisible) else { return false }
            let keyboard = self.app.keyboards.firstMatch
            return !keyboard.exists || !keyboard.frame.intersects(element.frame)
        }
    }

    private func showInDiscoveryForm(_ element: XCUIElement, readable: Bool) throws {
        let form = app.descendants(matching: .any).matching(identifier: "sourceDiscovery.form").firstMatch
        try wait("The actual discovery Form did not appear.", timeout: 5) { form.exists }
        let visibility: LearningElementVisibility = readable ? .readableText : .fullyVisible
        // Candidates are visited in increasing displayed index, with no assumed
        // publisher/order. Missing next rows are below the current viewport.
        // A materialized row above the viewport reverses via its actual frame.
        for attempt in 0...8 {
            try checkBudget()
            let formFrame = form.frame
            var viewport = formFrame.intersection(app.frame)
            let footer = app.staticTexts["sourceDiscovery.selectionCount"].firstMatch
            if footer.exists { viewport.size.height = max(0, min(viewport.maxY, footer.frame.minY - 8) - viewport.minY) }
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { viewport.size.height = max(0, min(viewport.maxY, keyboard.frame.minY) - viewport.minY) }
            viewport = viewport.insetBy(dx: 0, dy: 4)
            let frame = element.exists ? element.frame : .zero
            if learningFrameIsVisible(frame, in: viewport, visibility: visibility), readable || element.isHittable { return }
            guard attempt < 8, let drag = LearningScrollDrag.make(
                listFrame: formFrame, viewport: viewport, targetFrame: frame.isEmpty ? nil : frame,
                searchUp: true, maximumDistance: 120, visibility: visibility, searchByPage: frame.isEmpty
            ) else {
                XCTFail("The actual discovery row must be visible inside its Form, above the fixed footer/keyboard.")
                throw Failure.readiness
            }
            form.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: drag.start.x - formFrame.minX, dy: drag.start.y - formFrame.minY))
                .press(forDuration: 0.05, thenDragTo: form.coordinate(withNormalizedOffset: .zero)
                    .withOffset(CGVector(dx: drag.end.x - formFrame.minX, dy: drag.end.y - formFrame.minY)),
                       withVelocity: .slow, thenHoldForDuration: 0.2)
        }
    }

    private func wait(_ message: String, timeout: TimeInterval, until condition: @escaping () -> Bool) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: min(timeout, try remaining()))
        guard result == .completed else {
            XCTFail(message)
            throw Failure.readiness
        }
    }

    private func checkBudget() throws { _ = try remaining() }
    private func remaining() throws -> TimeInterval {
        let seconds = 285 - Date().timeIntervalSince(started)
        guard seconds > 0 else {
            XCTFail("The original 300-second case budget must retain time for private cleanup.")
            throw Failure.budget
        }
        return seconds
    }
}

/// Parse explicit native metadata only. Never infer a candidate from its title,
/// assume a provider's ordering, strip a path/query, or manufacture a URL.
private struct SourceDiscoveryCandidateValue {
    let selected: Bool
    let url: String
    let origin: String

    init?(_ value: String?) {
        guard let value else { return nil }
        let parts = value.split(separator: "\n", omittingEmptySubsequences: false)
        guard parts.count == 2, ["已選取", "未選取"].contains(String(parts[0])) else { return nil }
        let exactURL = String(parts[1])
        guard !exactURL.isEmpty, exactURL.utf8.count <= 2048,
              !exactURL.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              let parsed = URLComponents(string: exactURL), parsed.scheme?.lowercased() == "https",
              parsed.user == nil, parsed.password == nil, let host = parsed.host, !host.isEmpty,
              parsed.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        selected = parts[0] == "已選取"
        url = exactURL
        origin = "https://" + host.lowercased() + ":" + String(parsed.port ?? 443)
    }

    static func resultCount(_ status: String) -> Int? {
        let prefix = "找到 ", suffix = " 個候選來源；尚未讀取網頁正文。"
        guard status.hasPrefix(prefix), status.hasSuffix(suffix) else { return nil }
        let digits = status.dropFirst(prefix.count).dropLast(suffix.count)
        guard let count = Int(digits), (1...30).contains(count), String(count) == digits else { return nil }
        return count
    }
}
