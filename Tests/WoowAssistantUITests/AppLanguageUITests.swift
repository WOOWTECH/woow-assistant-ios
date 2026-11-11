import XCTest

/// Actual settings UI acceptance. Never sets defaults/bindings or overrides a
/// product DEBUG locale. Each case owns fresh storage; model requests stay off.
final class AppLanguageUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    override func setUpWithError() throws { continueAfterFailure = false; executionTimeAllowance = 240 }
    override func tearDownWithError() throws { app.terminate() }

    func testExplicitEnglishPersistsAndPreservesAppearancePermissionAndDraft() {
        launch(systemLanguages: "(zh-Hant)")
        choose("selfConfiguration.appearance", option: "深色")
        let permission = app.switches["selfConfiguration.permission"]
        revealLearningElement(permission, in: app)
        XCTAssertEqual(permission.value as? String, "0")
        let native = permission.switches.firstMatch
        (native.exists ? native : permission).tap()
        let draft = app.textViews["selfConfiguration.request"]
        revealLearningElement(draft, in: app); draft.tap(); draft.typeText("保留 Tea")
        app.buttons["selfConfiguration.keyboard.done"].tap()
        choose("settings.language", option: "English")
        exactLabel("settings.language.resolved", "Current interface: English")
        exactLabel("selfConfiguration.appliedAppearance", "Currently displayed: Dark")
        revealLearningElement(permission, in: app)
        XCTAssertEqual(permission.value as? String, "1")
        revealLearningElement(draft, in: app)
        XCTAssertEqual(draft.value as? String, "保留 Tea")
        exactLabel("selfConfiguration.status", "No appearance change has been requested.")
        app.terminate(); launch(systemLanguages: "(zh-Hant)")
        exactLabel("settings.language.resolved", "Current interface: English")
        exactLabel("selfConfiguration.appliedAppearance", "Currently displayed: Dark")
        revealLearningElement(permission, in: app)
        XCTAssertEqual(permission.value as? String, "1")
    }

    func testSimplifiedChineseAndSystemFollowActualPreferredLanguages() {
        launch(systemLanguages: "(en)")
        exactLabel("selfConfiguration.status", "No appearance change has been requested.")
        choose("settings.language", option: "简体中文")
        exactLabel("settings.language.resolved", "当前界面：简体中文")
        exactLabel("selfConfiguration.status", "尚未提出外观调整请求。")
        app.terminate(); launch(systemLanguages: "(zh-Hant)")
        exactLabel("selfConfiguration.status", "尚未提出外观调整请求。")
        choose("settings.language", option: "跟随系统")
        exactLabel("settings.language.resolved", "目前介面：繁體中文")
        exactLabel("selfConfiguration.status", "尚未提出外觀調整要求。")
    }

    func testUnsupportedSystemLanguageUsesTraditionalChineseFallback() {
        launch(systemLanguages: "(fr-FR)")
        exactLabel("selfConfiguration.status", "尚未提出外觀調整要求。")
        exactLabel("settings.language.resolved", "目前介面：繁體中文")
        let permission = app.switches["selfConfiguration.permission"]
        revealLearningElement(permission, in: app)
        XCTAssertEqual(permission.value as? String, "0")
        XCTAssertFalse(app.buttons["selfConfiguration.start"].exists)
    }

    private func launch(systemLanguages: String) {
        app.launchArguments = ["-AppleLanguages", systemLanguages, "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        app.launchEnvironment = [:]; app.launch()
        let settings = app.buttons["navigation.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let appearance = app.buttons["settings.appearance"]
        revealLearningElement(appearance, in: app); appearance.tap()
    }

    private func choose(_ identifier: String, option: String) {
        let picker = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        revealLearningElement(picker, in: app); picker.tap()
        let button = app.buttons[option].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5)); button.tap()
    }

    private func exactLabel(_ identifier: String, _ expected: String) {
        let element = app.staticTexts[identifier]
        revealLearningElement(element, in: app)
        let match = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", expected), object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [match], timeout: 5), .completed)
    }
}
