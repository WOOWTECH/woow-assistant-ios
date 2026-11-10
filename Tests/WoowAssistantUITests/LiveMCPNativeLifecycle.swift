import XCTest

/// Native lifecycle observations only. Neither .notRunning nor foreground
/// SpringBoard proves that an install/uninstall transaction has completed.
/// No launch retry, installer probe, sleep, screenshot, tree or private values.
enum LiveMCPNativeLifecycle {
    private enum Failure: Error { case appStillRunning, homeNotForeground, appNotForeground }

    static func stopAndShowHome(_ app: XCUIApplication,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        app.terminate()
        guard app.wait(for: .notRunning, timeout: 10) else {
            XCTFail("LIVE_MCP_LIFECYCLE app termination was not observed.", file: file, line: line)
            throw Failure.appStillRunning
        }
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        guard springboard.wait(for: .runningForeground, timeout: 10) else {
            XCTFail("LIVE_MCP_LIFECYCLE Home foreground was not observed.", file: file, line: line)
            throw Failure.homeNotForeground
        }
    }

    static func requireForeground(_ app: XCUIApplication,
                                  file: StaticString = #filePath, line: UInt = #line) throws {
        guard app.wait(for: .runningForeground, timeout: 10) else {
            XCTFail("LIVE_MCP_LIFECYCLE initial app foreground was not observed.", file: file, line: line)
            throw Failure.appNotForeground
        }
    }
}
