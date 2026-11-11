import XCTest

/// Synthetic model/MCP transport, actual App approval and OS notification UI.
/// No authorization reset, auto-approval, background escape or fabricated banner.
final class NotificationApprovalUITests: XCTestCase {
    private let app = XCUIApplication()
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private let namespace = UUID().uuidString
    private let title = "有操作需要你核准"
    private let body = "請開啟渥屋助理查看並決定；通知不會核准操作。"
    private var stage = "launch"
    private var beforeID: UUID?
    private var afterID: UUID?
    private var navigationBefore: String?
    private var navigationAfter: String?
    private var capturedBanner: Banner?

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 300
    }

    override func tearDownWithError() throws {
        if let testRun, testRun.failureCount > 0 {
            attach("Failure stage and synthetic review IDs",
                   "stage=\(stage);before=\(beforeID?.uuidString ?? "none");after=\(afterID?.uuidString ?? "none")")
            attach("Observed notification navigation generations",
                   "before=\(navigationBefore ?? "none")\nafter=\(navigationAfter ?? "none")")
            if let capturedBanner { attachBanner(capturedBanner) }
            capture("App at approval failure", app)
            capture("System at approval failure", springboard)
        }
        app.terminate()
    }

    func testActualApprovalBannerPreservesProposalUntilExplicitNativeApproval() throws {
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
            "-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage", "-UITestMCPFixture"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.staticTexts["chat.status"].waitForExistence(timeout: 15))
        stage = "permission"
        try enableNotifications()
        try tap(app.navigationBars["任務通知"].buttons.firstMatch, scroll: false)

        stage = "fixtureConnection"
        try tap(app.buttons["navigation.tools"], scroll: false)
        try tap(app.buttons["mcp.connect"])
        try wait("The actual fixture connection must finish discovery.", seconds: 15) {
            self.app.staticTexts["mcp.status"].label == "已連線，目錄擷取完成"
        }
        try enable(app.switches["mcp.enable.fixture_echo"])
        try tap(app.buttons["navigation.chat"], scroll: false)
        // This switch is a fixed Chat header, outside the message ScrollView.
        try enable(app.switches["chat.useMCP"], scroll: false)
        XCTAssertNil(banner())
        let draft = app.textFields["chat.draft"]
        try tap(draft, scroll: false)
        draft.typeText("[fixture:mcp] hello\n")
        guard let initialNavigation = navigation() else {
            XCTFail("The fixture must expose the actual root notification navigation generation.")
            throw Failure.readiness
        }
        navigationBefore = initialNavigation.raw
        XCTAssertEqual(initialNavigation.destination, "chat")

        stage = "newApprovalAndSystemBanner"
        try tap(app.buttons["chat.send"], scroll: false)
        var original: Review?
        var shown: Banner?
        // Read both snapshots promptly. Do not spend the short banner lifetime
        // scrolling controls or collecting several independent element queries.
        try wait("A new real review and actual system approval banner must coexist.", seconds: 15) {
            if original == nil { original = self.review() }
            shown = self.banner()
            return original != nil && shown != nil
        }
        guard let original, let shown else { throw Failure.readiness }
        beforeID = original.id
        capturedBanner = shown
        stage = "actualBannerTapAndRePresentation"
        // Tap the observed short-lived banner before screenshots, attachments
        // or further assertions can consume its display lifetime.
        springboard.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: shown.frame.midX, dy: shown.frame.midY)).tap()
        attachBanner(shown)
        attach("Synthetic proposal before banner tap", original.id.uuidString)
        XCTAssertEqual(original.name, "fixture_echo")
        XCTAssertEqual(original.arguments, ["text": "hello"])
        XCTAssertFalse(original.hasAssistantResult)
        XCTAssertEqual(original.navigation.id, initialNavigation.id)
        for forbidden in ["fixture_echo", "[fixture:mcp]", "hello", original.id.uuidString] {
            XCTAssertFalse(shown.labels.joined(separator: "\n").contains(forbidden))
        }

        // No Home, activate(), reconnect, resend, or replacement review. If the
        // OS makes the scene inactive, the existing cancellation policy wins.
        var represented: Review?
        // A presented sheet can retain the environment value from its initial
        // presentation. Verify the pending review here; verify the root-owned
        // route generation after the sheet closes below.
        try wait("The same pending UUID must remain available after the actual banner tap.", seconds: 10) {
            represented = self.review()
            self.navigationAfter = represented?.navigation.raw
            return self.app.state == .runningForeground && represented?.id == original.id
                && represented?.navigation.destination == "chat"
        }
        guard let represented else { throw Failure.readiness }
        afterID = represented.id
        XCTAssertEqual(represented.id, original.id)
        XCTAssertEqual(represented.name, "fixture_echo")
        XCTAssertEqual(represented.arguments, ["text": "hello"])
        XCTAssertFalse(represented.hasAssistantResult)
        XCTAssertEqual(represented.navigation.destination, "chat")
        XCTAssertTrue(app.buttons["mcp.approval.decline"].isHittable)
        XCTAssertTrue(app.buttons["mcp.approval.approve"].isHittable)
        capture("Same pending approval after actual banner tap", app)
        attach("Synthetic proposal after banner tap", represented.id.uuidString)

        stage = "oneExplicitNativeApproval"
        try tap(app.buttons["mcp.approval.approve"], scroll: false)
        let answer = app.staticTexts["chat.message.1.assistant"]
        XCTAssertTrue(answer.waitForExistence(timeout: 15))
        // The same in-process server connection counts every actual tool call.
        // There was exactly one user approval and there must be one call total.
        XCTAssertEqual(answer.label, "FIXTURE_CALL_1: hello")
        XCTAssertFalse(app.buttons["mcp.approval.approve"].exists)
        XCTAssertFalse(app.staticTexts["chat.error"].exists)
        let audit = app.staticTexts["chat.mcpActivity"].value as? String ?? ""
        XCTAssertTrue(audit.components(separatedBy: ";").contains("attempts=1"))
        XCTAssertTrue(audit.components(separatedBy: ";").contains("results=1"))
        XCTAssertTrue(audit.components(separatedBy: ";").contains("failure=none"))
        XCTAssertEqual(app.state, .runningForeground)
        XCTAssertEqual(app.buttons["navigation.chat"].value as? String, "已選取")
        stage = "retainedRootNavigationGeneration"
        // Only the root owns this generation. The notification-open callback
        // must have changed it; explicit approval itself does not route.
        try wait("Root Chat must retain the actual notification-open generation.", seconds: 5) {
            guard let current = self.navigation() else { return false }
            self.navigationAfter = current.raw
            return current.id != initialNavigation.id && current.destination == "chat"
        }
        attach("Observed notification navigation generations",
               "before=\(navigationBefore ?? "none")\nafter=\(navigationAfter ?? "none")")
        try wait("The resolved approval banner must disappear.", seconds: 5) { self.banner() == nil }
        attach("Final fixed execution counters", audit)
        print("NOTIFICATION_APPROVAL actualSystemBanner=1 defaultOpenObserved=1 destination=chat sameProposalUUID=1 explicitApprovals=1 calls=1 audibleSoundVerified=0")

        stage = "disable"
        try openSettings()
        try tap(app.buttons["notifications.disable"])
        XCTAssertEqual(app.staticTexts["notifications.enabled"].label, "已關閉")
        stage = "complete"
    }

    private func enableNotifications() throws {
        try openSettings()
        XCTAssertEqual(app.staticTexts["notifications.enabled"].label, "已關閉")
        let field = app.staticTexts["notifications.authorization"]
        if !field.exists { revealLearningElement(field, in: app, visibility: .readableText) }
        try wait("Read the actual authorization before the explicit enable gesture.", seconds: 10) {
            ["notDetermined", "authorized", "denied", "provisional", "ephemeral"].contains(field.value as? String ?? "")
        }
        let before = field.value as? String ?? "unknown"
        XCTAssertTrue(["notDetermined", "authorized"].contains(before))
        XCTAssertFalse(springboard.alerts.firstMatch.exists)
        try tap(app.buttons["notifications.enable"])
        if before == "notDetermined" {
            let alert = springboard.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 15))
            let snapshot = try alert.snapshot()
            let text = labels(in: snapshot).joined(separator: " ")
            XCTAssertTrue(text.contains("渥屋助理") || text.contains("WoowAssistant"))
            XCTAssertTrue(text.contains("通知") || text.localizedCaseInsensitiveContains("notifications"))
            try tap(alert.buttons.matching(NSPredicate(format: "label IN %@", ["Allow", "允許", "允许"])).firstMatch,
                    scroll: false)
        }
        try wait("Explicit opt-in and full system authorization are required.", seconds: 15) {
            self.app.staticTexts["notifications.enabled"].label == "已開啟"
                && field.value as? String == "authorized"
        }
        print("NOTIFICATION_APPROVAL authorizationBefore=\(before) authorizationAfter=authorized")
    }

    private func openSettings() throws {
        try tap(app.buttons["navigation.settings"], scroll: false)
        try tap(app.buttons["settings.notifications"])
        XCTAssertTrue(app.staticTexts["notifications.enabled"].waitForExistence(timeout: 10))
    }

    private struct Review {
        let id: UUID
        let name: String
        let arguments: [String: String]
        let hasAssistantResult: Bool
        let navigation: Navigation
    }

    private struct Navigation { let id: UUID; let destination: String; let raw: String }

    private func navigation() -> Navigation? {
        let field = app.staticTexts["notifications.routeObservation"]
        guard field.exists, let raw = field.value as? String else { return nil }
        return parseNavigation(raw)
    }

    private func parseNavigation(_ raw: String) -> Navigation? {
        let parts = raw.components(separatedBy: ";")
        guard parts.count == 2, parts[0].hasPrefix("generation="), parts[1].hasPrefix("destination="),
              let id = UUID(uuidString: String(parts[0].dropFirst("generation=".count))) else { return nil }
        return Navigation(id: id, destination: String(parts[1].dropFirst("destination=".count)), raw: raw)
    }

    private func review() -> Review? {
        guard let snapshot = try? app.snapshot(),
              let name = node("mcp.approval.name", in: snapshot),
              let raw = name.value as? String, let id = UUID(uuidString: raw),
              let arguments = node("mcp.approval.arguments", in: snapshot),
              let parsed = try? JSONSerialization.jsonObject(with: Data(arguments.label.utf8)) as? [String: String],
              let route = node("mcp.approval.routeObservation", in: snapshot)?.value as? String,
              let navigation = parseNavigation(route),
              node("mcp.approval.approve", in: snapshot) != nil,
              node("mcp.approval.decline", in: snapshot) != nil else { return nil }
        return Review(id: id, name: name.label, arguments: parsed,
                      hasAssistantResult: node("chat.message.1.assistant", in: snapshot) != nil,
                      navigation: navigation)
    }

    private func node(_ identifier: String, in snapshot: XCUIElementSnapshot) -> XCUIElementSnapshot? {
        if snapshot.identifier == identifier { return snapshot }
        for child in snapshot.children { if let match = node(identifier, in: child) { return match } }
        return nil
    }

    private struct Banner { let frame: CGRect; let labels: [String] }

    private func banner() -> Banner? {
        guard let snapshot = try? springboard.snapshot(), !snapshot.frame.isEmpty else { return nil }
        var smallest: Banner?
        @discardableResult func visit(_ node: XCUIElementSnapshot) -> [String] {
            let visible = !node.frame.isEmpty && node.frame.intersects(snapshot.frame)
            var text = visible && !node.label.isEmpty ? [node.label] : []
            for child in node.children { text += visit(child) }
            let fields = text.flatMap { $0.components(separatedBy: CharacterSet(charactersIn: ",\n")) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if visible, node.elementType != .application, node.elementType != .window,
               node.frame.height < snapshot.frame.height * 0.5,
               fields.contains(title), fields.contains(body),
               smallest == nil || node.frame.width * node.frame.height < smallest!.frame.width * smallest!.frame.height {
                smallest = Banner(frame: node.frame, labels: text)
            }
            return text
        }
        visit(snapshot)
        return smallest
    }

    private func labels(in snapshot: XCUIElementSnapshot) -> [String] {
        [snapshot.label] + snapshot.children.flatMap { labels(in: $0) }
    }

    private func enable(_ toggle: XCUIElement, scroll: Bool = true) throws {
        if scroll { revealLearningElement(toggle, in: app) }
        else { XCTAssertTrue(toggle.waitForExistence(timeout: 5)) }
        if toggle.value as? String != "1" {
            // Match the existing MCP UI fixture setup: reveal a catalog row
            // once, then tap its real switch; fixed Chat headers need no scroll.
            try tap(toggle.switches.firstMatch.exists ? toggle.switches.firstMatch : toggle, scroll: false)
        }
        try wait("Enable the exact selected fixture capability.", seconds: 5) { toggle.value as? String == "1" }
    }

    private func tap(_ element: XCUIElement, scroll: Bool = true) throws {
        // A Form row can report hittable while below the visible content area.
        // Always enforce the existing viewport check for scrollable controls.
        if scroll { revealLearningElement(element, in: app) }
        try wait("The native control must be hittable and enabled.", seconds: 5) { element.isHittable && element.isEnabled }
        element.tap()
    }

    private func wait(_ message: String, seconds: TimeInterval, condition: @escaping () -> Bool) throws {
        if condition() { return }
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        guard XCTWaiter.wait(for: [expectation], timeout: seconds) == .completed else {
            XCTFail("\(stage): \(message)"); throw Failure.readiness
        }
    }

    private func capture(_ name: String, _ application: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: application.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func attach(_ name: String, _ value: String) {
        let attachment = XCTAttachment(string: value)
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func attachBanner(_ banner: Banner) {
        attach("Actual bounded approval banner subtree captured before tap",
               "frame=\(banner.frame)\n" + banner.labels.joined(separator: "\n"))
    }

    private enum Failure: Error { case readiness }
}
