#if os(iOS) && canImport(XCTest)
import XCTest
@testable import WoowAssistant

final class BrowserPageFindIntegrationTests: XCTestCase {
    override func setUpWithError() throws { executionTimeAllowance = 120 }

    @MainActor func testNativeQueryNextPreviousCloseAndNavigation() async throws {
        let count = try await BrowserPageFindAppChecks.queryAndNavigation()
        XCTAssertGreaterThan(count, 25)
    }
    @MainActor func testAutomationOwnershipAndRetiredDocument() async throws {
        let count = try await BrowserPageFindAppChecks.ownershipAndRetirement()
        XCTAssertGreaterThan(count, 10)
    }
    @MainActor func testTabSelectionBackgroundAndCloseRevokeNativeFind() async throws {
        let count = try await BrowserPageFindAppChecks.tabsAndVisibility()
        XCTAssertGreaterThan(count, 10)
    }
}
#endif
