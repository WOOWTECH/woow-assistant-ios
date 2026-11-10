import XCTest

/// Real authorization, native test-notification banner and preference
/// persistence in an isolated simulator. Audible sound still needs a person.
final class NotificationUITests: XCTestCase {
    private let app = XCUIApplication()
    private let namespace = UUID().uuidString
    private var observedBannerCandidate: String?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            if let observedBannerCandidate {
                let candidate = XCTAttachment(string: observedBannerCandidate)
                candidate.name = "Observed bounded system banner candidate (diagnostic only)"
                candidate.lifetime = .keepAlways; add(candidate)
            }
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for (name, application) in [("App at failure", app), ("System at failure", springboard)] {
                let screenshot = XCTAttachment(screenshot: application.screenshot())
                screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
            }
        }
        app.terminate()
    }

    func testExplicitAuthorizationAndPreferenceSurviveRelaunchThenDisable() throws {
        launch(reset: true)
        try openSettings()
        XCTAssertEqual(app.staticTexts["notifications.enabled"].label, "已關閉")
        let before = try authorization()
        // Permission belongs to the simulator's App, not a UserDefaults suite.
        // Do not invent a private resetAuthorizationStatus raw value.
        XCTAssertTrue(["notDetermined", "authorized"].contains(before),
                      "The banner case requires full authorization; provisional or denied states are separate cases.")
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "Opening settings must not ask for permission.")
        try tap(app.buttons["notifications.enable"])

        var promptObserved = false
        if before == "notDetermined" {
            let alert = springboard.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 15), "Explicit enable must show the actual system prompt.")
            let snapshot = try alert.snapshot()
            var labels: [String] = []
            func visit(_ node: XCUIElementSnapshot) {
                labels.append(node.label)
                node.children.forEach(visit)
            }
            visit(snapshot)
            let text = labels.joined(separator: " ")
            XCTAssertTrue(text.contains("渥屋助理") || text.contains("WoowAssistant"))
            XCTAssertTrue(text.contains("通知") || text.localizedCaseInsensitiveContains("notifications"),
                          "Only this App's notification prompt may be accepted.")
            let allow = alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允許", "允许"])).firstMatch
            try tap(allow, scroll: false)
            promptObserved = true
        }
        try wait("The local preference and actual system grant must both be ready.", seconds: 15) {
            let authorization = self.app.staticTexts["notifications.authorization"].value as? String ?? "unknown"
            return self.app.staticTexts["notifications.enabled"].label == "已開啟"
                && authorization == "authorized"
        }
        let granted = try authorization()
        XCTAssertEqual(granted, "authorized")
        try assertSettingsValues()
        print("NOTIFICATION_SETTINGS enabled=1 systemPromptObserved=\(promptObserved ? 1 : 0)")

        // The explicit test action uses the production UN adapter. Require a
        // new actual system banner, not a scheduling receipt inside the App.
        XCTAssertNil(notificationBanner(in: springboard))
        try tap(app.buttons["notifications.test"])
        var observedBanner: SystemBanner?
        try wait("The system must actually display the fixed test notification.", seconds: 15) {
            observedBanner = self.notificationBanner(in: springboard)
            return observedBanner != nil
        }
        guard let banner = observedBanner else { throw Failure.readiness }
        let screenshot = XCTAttachment(screenshot: springboard.screenshot())
        screenshot.name = "Actual notification banner before opening"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let subtree = XCTAttachment(string: banner.labels.joined(separator: "\n"))
        subtree.name = "Matching system banner subtree"
        subtree.lifetime = .keepAlways
        add(subtree)
        print("NOTIFICATION_SETTINGS actualSystemBanner=1 audibleSoundVerified=0")

        // Open from a pushed Settings screen. The root must actually pop that
        // screen, not merely change the selected section underneath it.
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: banner.frame.midX, dy: banner.frame.midY)).tap()
        try wait("Opening the notification must reveal the root conversation.", seconds: 10) {
            self.app.state == .runningForeground
                && self.app.staticTexts["chat.status"].exists
                && !self.app.navigationBars["任務通知"].exists
                && self.app.buttons["navigation.chat"].value as? String == "已選取"
        }
        print("NOTIFICATION_SETTINGS actualBannerTap=1 rootChatVisible=1")

        app.terminate()
        launch(reset: false)
        try openSettings()
        XCTAssertEqual(app.staticTexts["notifications.enabled"].label, "已開啟")
        XCTAssertEqual(try authorization(), granted)
        try tap(app.buttons["notifications.refresh"])
        XCTAssertEqual(try authorization(), granted)
        try assertSettingsValues()
        try tap(app.buttons["notifications.disable"])
        try wait("Disable must persist without changing the system permission.", seconds: 10) {
            self.app.staticTexts["notifications.enabled"].label == "已關閉"
        }
        XCTAssertEqual(try authorization(), granted)

        app.terminate()
        launch(reset: false)
        try openSettings()
        XCTAssertEqual(app.staticTexts["notifications.enabled"].label, "已關閉")
        XCTAssertEqual(try authorization(), granted)
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        print("NOTIFICATION_SETTINGS relaunchEnabled=1 disablePersisted=1 systemPermissionRetained=1")
    }

    private func launch(reset: Bool) {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace]
        if reset { app.launchArguments.append("-UITestResetStorage") }
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 15))
    }

    private func openSettings() throws {
        try tap(app.buttons["navigation.settings"])
        let entry = app.buttons["settings.notifications"]
        revealLearningElement(entry, in: app)
        try tap(entry)
        XCTAssertTrue(app.staticTexts["notifications.enabled"].waitForExistence(timeout: 10))
    }

    private func authorization() throws -> String {
        let value = app.staticTexts["notifications.authorization"]
        if !value.exists { revealLearningElement(value, in: app, visibility: .readableText) }
        try wait("Actual system authorization must finish refreshing.", seconds: 10) {
            guard value.exists, let raw = value.value as? String else { return false }
            return ["notDetermined", "denied", "authorized", "provisional", "ephemeral"].contains(raw)
        }
        return value.value as? String ?? "unknown"
    }

    private func assertSettingsValues() throws {
        for identifier in ["notifications.sound", "notifications.alert"] {
            let field = app.staticTexts[identifier]
            if !field.exists { revealLearningElement(field, in: app, visibility: .readableText) }
            XCTAssertTrue(field.exists)
            XCTAssertTrue(["enabled", "disabled", "notSupported"].contains(field.value as? String ?? "unknown"),
                          "Display the actual system setting, never infer sound/alert delivery from permission alone.")
        }
    }

    private struct SystemBanner { let frame: CGRect; let labels: [String] }

    private func notificationBanner(in springboard: XCUIApplication) -> SystemBanner? {
        guard let snapshot = try? springboard.snapshot(), !snapshot.frame.isEmpty else { return nil }
        var smallest: SystemBanner?
        @discardableResult func visit(_ node: XCUIElementSnapshot) -> [String] {
            let visible = !node.frame.isEmpty && node.frame.intersects(snapshot.frame)
            var labels = visible && !node.label.isEmpty ? [node.label] : []
            for child in node.children { labels += visit(child) }
            let bounded = visible && node.elementType != .application && node.elementType != .window
                && node.frame.height < snapshot.frame.height * 0.5
            if bounded, observedBannerCandidate == nil,
               labels.contains(where: { $0.contains("通知測試") }),
               labels.contains(where: { $0.contains("這是渥屋助理的測試通知。") }) {
                // Retain the first transient candidate even if exact matching
                // fails and the OS removes the banner before tearDown runs.
                observedBannerCandidate = "frame=\(node.frame); identifier=\(node.identifier)\n"
                    + labels.prefix(20).map { String($0.prefix(500)) }.joined(separator: "\n")
            }
            // iOS 18's compact short look shows an App icon, not App-name text.
            // Match exact fields in one bounded system subtree. The subsequent
            // actual tap must open this App's root Chat to establish attribution.
            if bounded,
               hasExactField("通知測試", in: labels),
               hasExactField("這是渥屋助理的測試通知。", in: labels) {
                if smallest == nil || node.frame.width * node.frame.height
                    < smallest!.frame.width * smallest!.frame.height {
                    smallest = SystemBanner(frame: node.frame, labels: labels)
                }
            }
            return labels
        }
        visit(snapshot)
        return smallest
    }

    // AX may expose separate labels or combine fields in one announcement.
    // Match a complete field, never a substring inside unrelated body text.
    private func hasExactField(_ expected: String, in labels: [String]) -> Bool {
        labels.contains { label in
            label == expected || label.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .contains { $0.trimmingCharacters(in: .whitespacesAndNewlines) == expected }
        }
    }

    private func tap(_ element: XCUIElement, scroll: Bool = true) throws {
        if scroll && !element.isHittable { revealLearningElement(element, in: app) }
        try wait("The exact native control must be hittable.", seconds: 5) { element.isHittable }
        XCTAssertTrue(element.exists)
        XCTAssertTrue(element.isEnabled)
        XCTAssertFalse(element.frame.isEmpty)
        element.tap()
    }

    private func wait(_ message: String, seconds: TimeInterval, condition: @escaping () -> Bool) throws {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed else {
            XCTFail(message)
            throw Failure.readiness
        }
    }

    private enum Failure: Error { case readiness }
}
