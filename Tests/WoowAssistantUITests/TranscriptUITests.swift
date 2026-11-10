import Foundation
import CoreGraphics

#if TRANSCRIPT_UI_FIXTURE_CHECKS
@main enum TranscriptUIFixtureChecks {
    struct Failure: Error { let message: String }
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !value() { throw Failure(message: message) }
    }
    static func main() throws {
        let namespace = UUID()
        let local = ["app", "-UITestMode", "-UITestTranscript", "-UITestNamespace", namespace.uuidString]
        let live = ["app", "-LiveModelUITest", "-UITestTranscript", "-LiveModelUITestNamespace", namespace.uuidString]
        var touched = false
        let ignored = try TranscriptUITestSupport.seedIfRequested(arguments: ["app"]) {
            touched = true; throw Failure(message: "default accessed files")
        }
        try require(ignored == nil && !touched, "inactive fixture must not resolve Documents")
        #if DEBUG
        for invalid in [["-UITestTranscript"], local + ["-UITestMode"], local + ["-LiveModelUITest"],
                        local + ["-UITestNamespace", UUID().uuidString], local + ["-LiveModelUITestNamespace", UUID().uuidString],
                        ["-UITestTranscript", "-UITestMode", "-UITestNamespace", "../outside"],
                        live + ["-LiveModelUITestCleanup"]] {
            do {
                _ = try TranscriptUITestSupport.seedIfRequested(arguments: invalid) {
                    touched = true; throw Failure(message: "invalid gate accessed files")
                }
                throw Failure(message: "invalid gate accepted")
            } catch TranscriptUITestSupport.Failure.invalidNamespace { }
            try require(!touched, "invalid gates must fail before filesystem access")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-ui-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let fixture = try TranscriptUITestSupport.seedIfRequested(arguments: local, documentsDirectory: { root }) else {
            throw Failure(message: "fixture not created")
        }
        let bytes = try Data(contentsOf: fixture.url)
        try require(bytes.count > 8192 && bytes.count <= 65536, "actual multi-range UTF-8 source")
        try require(bytes == Data(TranscriptUITestSupport.sourceText(namespace: namespace).utf8), "exact source facts, no answers")
        try require(fixture.filename == "Transcript-\(namespace.uuidString).txt", "exact namespace basename")
        _ = try TranscriptUITestSupport.seedIfRequested(arguments: live, documentsDirectory: { root })
        try require(try Data(contentsOf: fixture.url) == bytes, "reentry/live fixture never rewrites source")
        try Data("unowned sentinel".utf8).write(to: fixture.url)
        do {
            _ = try TranscriptUITestSupport.seedIfRequested(arguments: local, documentsDirectory: { root })
            throw Failure(message: "overwrote unrelated bytes")
        } catch TranscriptUITestSupport.Failure.existingFile { }
        try require(try Data(contentsOf: fixture.url) == Data("unowned sentinel".utf8), "preserve existing unrelated content")
        let untouched = TranscriptUITestAudit()
        try require(untouched.selections == 0 && untouched.reads == 0 && untouched.modelAttempts == 0,
                    "fixture creation grants no runtime action")
        print("PASS DEBUG namespace gates, real UTF-8 source, idempotence, overwrite refusal and zero runtime audit")
        #else
        for arguments in [local, live] {
            let value = try TranscriptUITestSupport.seedIfRequested(arguments: arguments) {
                touched = true; throw Failure(message: "Release accessed files")
            }
            try require(value == nil && !touched, "Release ignores every fixture argument")
        }
        print("PASS Release fixture entry does not access files")
        #endif
        var route = TranscriptPickerRoute()
        try require(route.next { $0 == .browseTab } == .browseTab, "enter native Browse once")
        try require(!route.progress(after: .browseTab) { $0 == .browseTab }, "same control is not progress")
        try require(route.next { $0 == .browseTab } == nil, "never repeat a route control")
        try require(route.progress(after: .browseTab) { $0 == .local }, "local folder is real progress")
        let icon = CGRect(x: 20, y: 100, width: 40, height: 40)
        try require(transcriptIconIsVisible(icon, cell: CGRect(x: 10, y: 95, width: 100, height: 100),
            viewport: CGRect(x: 0, y: 80, width: 300, height: 500), navigation: CGRect(x: 0, y: 0, width: 300, height: 80)), "visible native icon")
        try require(!transcriptIconIsVisible(icon, cell: .zero, viewport: .infinite, navigation: .zero), "invalid geometry refused")
        print("PASS bounded native route and visible target geometry")
    }
}
#else
import XCTest

final class TranscriptUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic Files source requires an isolated simulator.")
        #endif
        continueAfterFailure = false; executionTimeAllowance = 240
    }
    override func tearDownWithError() throws { app.terminate() }

    func testNativePickerCancellationDoesNotSelectOrRead() throws {
        let driver = try launch()
        try driver.openTranscript()
        try driver.openPicker()
        try driver.tapNativeCancel()
        try driver.assertAudit(selections: 0, reads: 0, modelAttempts: 0, results: 0)
        XCTAssertFalse(app.staticTexts["transcript.review.filename"].exists)
        XCTAssertFalse(app.staticTexts["transcript.filename"].exists)
    }

    func testNativeSelectedTextReadRefusalDoesNotReadOrSend() throws {
        let driver = try launch()
        try driver.openTranscript()
        try driver.chooseFixture()
        try driver.assertAudit(selections: 1, reads: 0, modelAttempts: 0, results: 0)
        try driver.tap("transcript.refuse", scroll: true)
        try driver.assertAudit(selections: 1, reads: 0, modelAttempts: 0, results: 0)
        XCTAssertFalse(app.staticTexts["transcript.filename"].exists)
        XCTAssertFalse(app.buttons["transcript.approveRead"].exists)
        XCTAssertFalse(app.staticTexts["transcript.result"].exists)
    }

    func testApprovedNativeTextWithoutModelCannotSendAndKeepsChatDraft() throws {
        let driver = try launch()
        let draftText = "Keep transcript draft 42"
        let draft = app.textFields["chat.draft"]
        try driver.ready(draft); draft.tap(); draft.typeText(draftText + "\n")
        XCTAssertEqual(draft.value as? String, draftText)
        try driver.openTranscript()
        try driver.chooseFixture()
        try driver.assertAudit(selections: 1, reads: 0, modelAttempts: 0, results: 0)
        try driver.approveRead()
        let source = try driver.readSourceLabel()
        XCTAssertTrue(source.contains(namespace) && source.contains("工作紀錄結尾：月底再次核對待修清單。"))
        try driver.tap("transcript.confirmDestination", scroll: true)
        let error = app.staticTexts["transcript.error"]
        try driver.show(error, readable: true)
        XCTAssertEqual(error.label, "無法取得已設定的模型服務，請先儲存模型設定。")
        let start = app.buttons["transcript.start"]
        try driver.show(start)
        XCTAssertFalse(start.isEnabled, "Reading approval must not invent configured model access.")
        try driver.assertAudit(selections: 1, reads: 1, modelAttempts: 0, results: 0)
        try driver.tap("transcript.close")
        try driver.navigate("chat")
        XCTAssertEqual(app.textFields["chat.draft"].value as? String, draftText)
        XCTAssertEqual(app.staticTexts["chat.status"].label, "尚未設定模型")
        XCTAssertFalse(app.staticTexts["chat.message.1.assistant"].exists)
    }

    private func launch() throws -> TranscriptUIDriver {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode",
            "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestTranscript"]
        app.launchEnvironment = [:]; app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["chat.status"].label, "尚未設定模型")
        return TranscriptUIDriver(app: app, namespace: namespace)
    }
}

/// Shared only by the two new transcript suites. Known Files controls and
/// thumbnail geometry come from the already-observed PDF picker route. TXT
/// delivery still requires actual CI; there is no direct URL/picker fallback.
struct TranscriptUIDriver {
    enum Failure: Error { case missingControl, noNativeProgress, invalidNativeTarget, callbackMissing, invalidAudit }
    let app: XCUIApplication
    let namespace: String
    var stem: String { "Transcript-" + namespace }
    var filename: String { stem + ".txt" }
    var nativeNavigation: XCUIElement { app.navigationBars["FullDocumentManagerViewControllerNavigationBar"] }
    var nativeList: XCUIElement { app.collectionViews["File View"] }
    var nativeCancel: XCUIElement { nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["取消", "Cancel"])).firstMatch }
    private let applicationLabels = ["渥屋助理", "WoowAssistant"]
    private let localLabels = ["我的 iPhone", "我的iPhone", "在我的 iPhone 上", "On My iPhone", "我的 iPad", "On My iPad"]
    private let browseLabels = ["瀏覽", "Browse"]
    private let locationsLabels = ["位置", "Locations"]

    func ready(_ element: XCUIElement, timeout: TimeInterval = 15) throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true AND enabled == true"), object: element)
        guard XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed else {
            XCTFail("Required native control did not become ready."); throw Failure.missingControl
        }
    }
    func show(_ element: XCUIElement, readable: Bool = false) throws {
        // Called only after the native picker has actually dismissed.
        revealLearningElement(element, in: app, visibility: readable ? .readableText : .fullyVisible)
        guard element.exists else { throw Failure.missingControl }
    }
    func tap(_ id: String, scroll: Bool = false) throws {
        let button = app.buttons[id].firstMatch
        if scroll { try show(button) }
        try ready(button); button.tap()
    }
    func navigate(_ section: String) throws {
        let button = app.buttons["navigation." + section]
        try ready(button)
        guard app.frame.contains(button.frame) else { throw Failure.missingControl }
        button.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "已選取"), object: button)
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 15), .completed)
        XCTAssertTrue(app.staticTexts[section + ".status"].waitForExistence(timeout: 10))
    }
    func openTranscript() throws {
        try navigate("memory"); try tap("memory.segment.skills")
        try tap("skills.transcript.open", scroll: true)
        let fixture = app.staticTexts["transcript.uitest.fixture"]
        try show(fixture, readable: true)
        XCTAssertEqual(fixture.label, "測試文字檔已建立：" + filename)
        try assertAudit(selections: 0, reads: 0, modelAttempts: 0, results: 0)
    }
    func openPicker() throws {
        try tap("transcript.choose", scroll: true)
        try ready(nativeCancel, timeout: 45)
    }
    func tapNativeCancel() throws {
        try ready(nativeCancel); nativeCancel.tap(); try waitForNativeDismissal()
    }
    func waitForNativeDismissal() throws {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: nativeNavigation)
        guard XCTWaiter.wait(for: [gone], timeout: 30) == .completed else {
            XCTFail("Native Files must dismiss before querying or scrolling the App form."); throw Failure.callbackMissing
        }
    }
    func chooseFixture() throws {
        try openPicker()
        let cell = try navigateFiles()
        let images = cell.images.allElementsBoundByAccessibilityElement
        guard images.count == 1, let image = images.first, image.exists,
              cell.exists, cell.isEnabled, cell.isHittable, nativeList.exists, nativeNavigation.exists,
              transcriptIconIsVisible(image.frame, cell: cell.frame, viewport: nativeList.frame.intersection(app.frame), navigation: nativeNavigation.frame) else {
            XCTFail("Exact synthetic text file must expose a visible native document icon."); throw Failure.invalidNativeTarget
        }
        image.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        // Some Files presentations require one explicit Open. Do not press the
        // file or Open twice and never substitute a runtime source assignment.
        let dismissed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: nativeNavigation)
        if XCTWaiter.wait(for: [dismissed], timeout: 3) != .completed,
           let open = visible(nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", ["開啟", "Open", "完成", "Done"]))) {
            open.tap()
        }
        try waitForNativeDismissal()
        let review = app.staticTexts["transcript.review.filename"]
        try show(review, readable: true)
        guard review.exists else {
            XCTFail("Files selection must reach the real transcript importer callback."); throw Failure.callbackMissing
        }
        XCTAssertEqual(review.label, filename)
    }
    func approveRead() throws {
        try tap("transcript.approveRead", scroll: true)
        let source = app.staticTexts["transcript.filename"]
        guard source.waitForExistence(timeout: 35) else {
            XCTFail("Approved coordinated file read did not deliver a snapshot."); throw Failure.callbackMissing
        }
        XCTAssertEqual(source.label, filename)
    }
    func readSourceLabel() throws -> String {
        try tap("transcript.showSource", scroll: true)
        let source = app.staticTexts["transcript.source"]
        try show(source, readable: true)
        let text = source.label
        // Collapse immediately, while its control is still above the first
        // visible source lines. Never scroll through a 20 KiB text row.
        let collapse = app.buttons["transcript.showSource"]
        try ready(collapse); collapse.tap()
        return text
    }
    func audit() throws -> [String: Int] {
        try scrollToTop()
        let audit = app.staticTexts["transcript.uitest.audit"]
        try show(audit, readable: true)
        guard audit.label.hasPrefix("TRANSCRIPT_AUDIT ") else { throw Failure.invalidAudit }
        var values: [String: Int] = [:]
        for pair in audit.label.split(separator: " ").dropFirst() {
            let parts = pair.split(separator: "=")
            guard parts.count == 2, let value = Int(parts[1]) else { throw Failure.invalidAudit }
            values[String(parts[0])] = value
        }
        return values
    }
    func assertAudit(selections: Int, reads: Int, modelAttempts: Int, results: Int) throws {
        let values = try audit()
        XCTAssertEqual(values["selections"], selections); XCTAssertEqual(values["reads"], reads)
        XCTAssertEqual(values["modelAttempts"], modelAttempts); XCTAssertEqual(values["results"], results)
    }
    func scrollToTop() throws {
        let form = app.collectionViews["transcript.form"]
        let status = app.staticTexts["transcript.status"]
        for attempt in 0...6 {
            if status.exists && status.isHittable { return }
            guard attempt < 6, form.exists, form.isHittable else { throw Failure.missingControl }
            form.swipeDown()
        }
    }
    private var localFolder: XCUIElement {
        let title = nativeNavigation.staticTexts.matching(NSPredicate(format: "label IN %@", applicationLabels)).firstMatch
        return title.exists ? title : nativeNavigation.buttons.matching(NSPredicate(format: "label == %@", "渥屋助理, 「動作」選單")).firstMatch
    }
    private func exactFile() -> XCUIElement? {
        let cells = nativeList.cells
        for name in [filename, stem] {
            if let file = visible(cells.containing(.staticText, identifier: name)) { return file }
        }
        return visible(cells.matching(NSPredicate(format: "identifier IN %@", [stem + ", txt", filename])))
    }
    private func visible(_ query: XCUIElementQuery) -> XCUIElement? {
        // Route labels and namespace filenames identify a specific native
        // control. Resolving the entire remote collection during a folder
        // transition can outlive the predicate waiter's deadline (observed on
        // iOS 18.5). Keep a live query and ask only for its first match.
        let element = query.firstMatch
        guard element.exists, element.isHittable, element.isEnabled else { return nil }
        return element
    }
    private func item(_ labels: [String]) -> XCUIElement? {
        let predicate = NSPredicate(format: "label IN %@", labels)
        for query in [app.cells, app.buttons, app.staticTexts] {
            if let value = visible(query.matching(predicate)) { return value }
        }
        return nil
    }
    private func element(_ step: TranscriptPickerStep) -> XCUIElement? {
        switch step {
        case .file: return exactFile()
        case .application: return item(applicationLabels)
        case .local: return item(localLabels)
        case .back: return visible(nativeNavigation.buttons.matching(NSPredicate(format: "label IN %@", browseLabels + locationsLabels)))
        case .locations: return visible(app.buttons.matching(NSPredicate(format: "label IN %@", locationsLabels)))
        case .browseTab:
            let tab = visible(app.tabBars.buttons.matching(NSPredicate(format: "label IN %@", browseLabels)))
            return tab?.isSelected == false ? tab : nil
        case .browseButton:
            let button = visible(app.buttons.matching(NSPredicate(format: "label IN %@", browseLabels)))
            return button?.isSelected == false ? button : nil
        }
    }
    private func navigateFiles() throws -> XCUIElement {
        var route = TranscriptPickerRoute()
        while true {
            if localFolder.exists {
                for attempt in 0...10 {
                    if let file = exactFile() { return file }
                    guard attempt < 10, nativeList.exists, nativeList.isHittable else { break }
                    nativeList.swipeUp()
                }
                XCTFail("Known local app folder did not expose this namespace's exact text file.")
                throw Failure.invalidNativeTarget
            }
            var target: XCUIElement?
            guard let step = route.next(where: { target = element($0); return target != nil }), let target else {
                XCTFail("Native Files did not expose a known local destination."); throw Failure.noNativeProgress
            }
            if step == .file { return target }
            target.tap()
            let progressed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                localFolder.exists || route.progress(after: step) { element($0) != nil }
            }, object: nil)
            guard XCTWaiter.wait(for: [progressed], timeout: 12) == .completed else {
                XCTFail("Native Files did not progress after a single known route action."); throw Failure.noNativeProgress
            }
        }
    }
}
#endif

private enum TranscriptPickerStep: CaseIterable {
    case file, application, local, back, locations, browseTab, browseButton
    var successors: [Self] {
        switch self {
        case .file: return []
        case .application: return [.file]
        case .local: return [.file, .application]
        case .locations: return [.file, .application, .local]
        case .back, .browseTab, .browseButton: return [.file, .application, .local, .locations]
        }
    }
}
private struct TranscriptPickerRoute {
    private var attempted = Set<TranscriptPickerStep>()
    mutating func next(where available: (TranscriptPickerStep) -> Bool) -> TranscriptPickerStep? {
        for step in TranscriptPickerStep.allCases where !attempted.contains(step) && available(step) {
            attempted.insert(step); return step
        }
        return nil
    }
    func progress(after step: TranscriptPickerStep, where available: (TranscriptPickerStep) -> Bool) -> Bool {
        step.successors.contains { !attempted.contains($0) && available($0) }
    }
}
private func transcriptIconIsVisible(_ icon: CGRect, cell: CGRect, viewport: CGRect, navigation: CGRect) -> Bool {
    guard [icon, cell, viewport, navigation].allSatisfy({ !$0.isEmpty && !$0.isNull && !$0.isInfinite }) else { return false }
    return cell.contains(icon) && viewport.contains(icon) && !navigation.intersects(icon)
}
