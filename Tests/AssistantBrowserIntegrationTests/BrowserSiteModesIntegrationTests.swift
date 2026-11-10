#if os(iOS) && canImport(XCTest)
import XCTest
@testable import WoowAssistant

final class BrowserSiteModesIntegrationTests: XCTestCase {
    @MainActor func testActualWorkspaceEncryptionAndWebKitSiteModes() async throws {
        let result = try await BrowserSiteModesAppChecks.run()
        XCTAssertGreaterThan(result["assertions"] as? Int ?? 0, 70)
        XCTAssertEqual(result["actual_webkit"] as? Bool, true)
    }
    // Runs in the normal hosted test process with no launch flags or HTTP.
    // Actual HTTP reload/replay proof remains in the gated Debug standalone
    // harness; native HTTP execution is pending, not silently skipped here.
    func testGETPOSTAndUnknownMethodReloadState() throws {
        XCTAssertEqual(try BrowserUserSiteModesChecks.reloadMethodEvidence(), 20)
    }
}
#endif
