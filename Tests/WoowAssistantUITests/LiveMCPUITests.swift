import XCTest

// Only the manual live-MCP workflow injects this secret. Never attach screenshots,
// emit app debugDescription, or publish live xcresult/xctestrun files.
final class LiveMCPUITests: XCTestCase {
    private let namespace = UUID().uuidString
    private var launched = false

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 240
        guard let endpoint = ProcessInfo.processInfo.environment["WOOW_LIVE_MCP_URL"], !endpoint.isEmpty else {
            throw XCTSkip("Private MCP test configuration was not supplied.")
        }
    }

    override func tearDownWithError() throws {
        guard launched else { return }
        let app = XCUIApplication()
        app.terminate()
        app.launchArguments = ["-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage"]
        app.launchEnvironment = [:]
        app.launch()
        XCTAssertTrue(app.buttons["navigation.tools"].waitForExistence(timeout: 10))
        app.buttons["navigation.tools"].tap()
        XCTAssertTrue(app.staticTexts["mcp.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "尚未設定 MCP")
        app.terminate()
    }

    func testRealDiscoveryDisconnectAndReconnect() throws {
        let endpoint = try XCTUnwrap(ProcessInfo.processInfo.environment["WOOW_LIVE_MCP_URL"])
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(zh-Hant)", "-AppleLocale", "zh_TW",
                               "-UITestMode", "-UITestNamespace", namespace, "-UITestResetStorage", "-LiveMCPUITest"]
        app.launchEnvironment = ["WOOW_LIVE_MCP_URL": endpoint]
        launched = true
        app.launch()
        XCTAssertTrue(app.buttons["navigation.tools"].waitForExistence(timeout: 10))
        app.buttons["navigation.tools"].tap()
        XCTAssertTrue(app.staticTexts["mcp.status"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["mcp.status"].label, "端點已儲存，尚未驗證連線")
        XCTAssertFalse(app.staticTexts["mcp.testIsolation"].exists)
        for attempt in 0..<2 {
            reveal(app.buttons["mcp.connect"], in: app)
            app.buttons["mcp.connect"].tap()
            let completed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.staticTexts["mcp.status"].label == "已連線，目錄擷取完成" || app.staticTexts["mcp.error"].exists
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 95), .completed)
            XCTAssertFalse(app.staticTexts["mcp.error"].exists, "Live MCP discovery failed.")
            XCTAssertEqual(app.staticTexts["mcp.status"].label, "已連線，目錄擷取完成")
            reveal(app.staticTexts["mcp.toolCount"], in: app, upward: false)
            XCTAssertTrue(app.staticTexts["mcp.toolCount"].label.contains("個"))
            XCTAssertFalse(app.staticTexts["mcp.toolCount"].label.contains("：0 個"))
            XCTAssertTrue(app.staticTexts["mcp.resourceCount"].exists)
            if attempt == 0 {
                XCUIDevice.shared.press(.home)
                app.activate()
            } else {
                reveal(app.buttons["mcp.disconnect"], in: app)
                app.buttons["mcp.disconnect"].tap()
            }
            XCTAssertEqual(app.staticTexts["mcp.status"].label, "已中斷本機連線")
        }
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication, upward: Bool = true) {
        for _ in 0..<5 where !element.isHittable {
            if upward { app.swipeUp() } else { app.swipeDown() }
        }
        XCTAssertTrue(element.exists && element.isHittable, "MCP control was not reachable.")
    }
}
