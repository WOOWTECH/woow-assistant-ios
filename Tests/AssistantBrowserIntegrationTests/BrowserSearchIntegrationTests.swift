#if os(iOS) && canImport(XCTest)
import XCTest

final class BrowserSearchIntegrationTests: XCTestCase {
    @MainActor func testManualSearchEncryptionAndRealWebKit() async throws {
        let result = try await BrowserSearchAppChecks.run()
        XCTAssertGreaterThan(result["assertions"] as? Int ?? 0, 115)
        XCTAssertEqual(result["actual_default_and_selected_search_actions"] as? Int, 2)
        XCTAssertEqual(result["engine_change_navigations"] as? Int, 0)
    }
}
#endif
