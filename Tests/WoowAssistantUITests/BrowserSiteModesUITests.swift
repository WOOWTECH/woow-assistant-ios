import XCTest
import CoreGraphics

final class BrowserSiteModesUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 180 }
    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "site-mode-failure-AX"; tree.lifetime = .keepAlways; add(tree)
            let shot = XCTAttachment(screenshot: app.screenshot())
            shot.name = "site-mode-failure"; shot.lifetime = .keepAlways; add(shot)
        }
        app.terminate()
    }

    func testManualGETChoiceReloadsAndSurvivesRelaunch() throws {
        launch(reset: true)
        let field = app.textFields["browser.address"]
        XCTAssertTrue(field.waitForExistence(timeout: 10)); field.tap()
        field.typeText("https://research.example.invalid/workspace-one\n")
        let note = app.webViews.textFields["Tab note"]
        XCTAssertTrue(note.waitForExistence(timeout: 75))
        note.tap(); note.typeText("Retain this note")
        XCTAssertEqual(note.value as? String, "Retain this note")
        try dismissWebKeyboard()
        // The iOS 17 failure has an identified Menu wrapper around a separate
        // native Button. Its outer AX Button exists but has no hittable point.
        let mode = siteMode
        try chooseMode("desktop", from: "手機版")
        try waitForMode("電腦版")
        XCTAssertEqual(mode.value as? String, "電腦版")
        let reloaded = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND value == %@", ""), object: note)
        XCTAssertEqual(XCTWaiter.wait(for: [reloaded], timeout: 30), .completed, "Known manual GET must reload and replace the form field")
        XCTAssertTrue(app.staticTexts["browser.siteMode.notice"].exists)
        XCTAssertTrue(app.staticTexts["browser.siteMode.notice"].label.contains("正在重新整理"))
        XCTAssertEqual(field.value as? String, "https://research.example.invalid/workspace-one")
        launch(reset: false)
        XCTAssertTrue(app.webViews.staticTexts["Workspace first"].waitForExistence(timeout: 75))
        try waitForMode("電腦版")
        XCTAssertEqual(mode.value as? String, "電腦版")
        XCTAssertEqual(field.value as? String, "https://research.example.invalid/workspace-one")
        try chooseMode("mobile", from: "電腦版")
        try waitForMode("手機版")
        XCTAssertEqual(mode.value as? String, "手機版")
        launch(reset: false)
        XCTAssertTrue(app.webViews.staticTexts["Workspace first"].waitForExistence(timeout: 75))
        try waitForMode("手機版")
        XCTAssertEqual(mode.value as? String, "手機版")
        XCTAssertEqual(field.value as? String, "https://research.example.invalid/workspace-one")
    }

    private var siteMode: XCUIElement {
        app.navigationBars.descendants(matching: .any).matching(identifier: "browser.siteMode").firstMatch
    }

    private func dismissWebKeyboard() throws {
        // The captured failure includes this real WebKit input-accessory Done
        // button. A tap on an already-selected app tab does not resign focus.
        let done = app.toolbars.buttons.matching(NSPredicate(format: "label IN %@", ["Done", "完成"])).firstMatch
        if app.keyboards.firstMatch.exists || done.exists {
            try wait("WebKit keyboard Done must be visible and hittable") { self.canTap(done) }
            done.tap()
        }
        try wait("WebKit keyboard and input accessory must actually close") {
            !self.app.keyboards.firstMatch.exists && !done.exists
        }
    }

    private func waitForMode(_ expected: String) throws {
        try wait("Loaded manual document must expose the saved site mode: " + expected) {
            let mode = self.siteMode
            return mode.exists && mode.isEnabled && self.onScreen(mode) && mode.value as? String == expected
                && self.siteModeControl() != nil
        }
    }

    private func chooseMode(_ choice: String, from expected: String) throws {
        try waitForMode(expected)
        XCTAssertEqual(siteMode.value as? String, expected)
        // A Menu's outer AX Button cannot perform scroll-to-visible on iOS 17
        // and SE. Tap its visible, hittable native wrapper once when the leaf
        // button has no AX hit point; the next assertion proves the real menu
        // opened before any preference changes.
        let control = try XCTUnwrap(siteModeControl(), "Exactly one native site-mode control must remain visible and hittable")
        if control.elementType == .button {
            control.tap()
        } else {
            let navigation = app.navigationBars.firstMatch
            let center = CGPoint(x: control.frame.midX, y: control.frame.midY)
            let otherControls = ["browser.find", "browser.multiResearch", "browser.transcript"]
                .map { navigation.descendants(matching: .any).matching(identifier: $0).firstMatch }
            XCTAssertTrue(control.isHittable && navigation.exists && navigation.frame.contains(control.frame)
                && navigation.frame.contains(center) && app.frame.contains(center)
                && !app.keyboards.firstMatch.exists
                && otherControls.allSatisfy { !$0.exists || !$0.frame.contains(center) },
                "The native Menu hit point must be fully inside the unobscured navigation bar")
            control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let item = app.buttons["browser.siteMode." + choice]
        try wait("Requested site-mode menu item must be visible and hittable") { self.canTap(item) }
        let opened = XCTAttachment(string: app.debugDescription)
        opened.name = "site-mode-native-menu-AX"; opened.lifetime = .keepAlways; add(opened)
        let openedShot = XCTAttachment(screenshot: app.screenshot())
        openedShot.name = "site-mode-native-menu"; openedShot.lifetime = .keepAlways; add(openedShot)
        item.tap()
    }

    private func siteModeControl() -> XCUIElement? {
        let anchor = siteMode
        guard anchor.exists, anchor.isEnabled, onScreen(anchor), !app.keyboards.firstMatch.exists else { return nil }
        let descendants = anchor.descendants(matching: .button).allElementsBoundByAccessibilityElement
        let leaves = descendants.filter { $0.descendants(matching: .button).count == 0 }
        let candidates = descendants.isEmpty && anchor.elementType == .button ? [anchor] : leaves
        let hittable = candidates.filter { canTap($0) && anchor.frame.contains($0.frame) }
        if hittable.count == 1 { return hittable[0] }
        // The native Menu wrapper is the only on-screen target when older AX
        // exposes its nested Button without an independent hit point.
        let navigation = app.navigationBars.firstMatch
        guard hittable.isEmpty, anchor.elementType == .other, canTap(anchor),
              navigation.exists, navigation.frame.contains(anchor.frame) else { return nil }
        return anchor
    }

    private func onScreen(_ element: XCUIElement) -> Bool {
        guard element.exists else { return false }
        let frame = element.frame
        return !frame.isEmpty && !frame.isNull && !frame.isInfinite && app.frame.contains(frame)
    }

    private func canTap(_ element: XCUIElement) -> Bool {
        element.exists && element.isEnabled && element.isHittable && onScreen(element)
    }

    private func wait(_ message: String, until condition: @escaping () -> Bool) throws {
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        let result = XCTWaiter.wait(for: [ready], timeout: 10)
        XCTAssertEqual(result, .completed, message)
        guard result == .completed else { throw DriverNotReady() }
    }
    private struct DriverNotReady: Error {}

    private func launch(reset: Bool) {
        app.terminate()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW", "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launch()
        XCTAssertTrue(app.buttons["navigation.browser"].waitForExistence(timeout: 10))
        app.buttons["navigation.browser"].tap()
    }
}
