#if os(iOS) && canImport(XCTest)
import XCTest

final class BrowserDownloadedPDFIntegrationTests: XCTestCase {
    override func setUpWithError() throws { executionTimeAllowance = 120 }
    @MainActor func testRealWKDownloadTwoApprovalsAndPDFKit() async throws {
        let count = try await BrowserDownloadedPDFAppChecks.realDownloadAndApprovals()
        XCTAssertGreaterThan(count, 20)
    }
    @MainActor func testInvalidSelectionsReplacementAndBounds() async throws {
        let count = try await BrowserDownloadedPDFAppChecks.invalidSourcesAndLimits()
        XCTAssertGreaterThan(count, 7)
    }
    @MainActor func testDeletionCancellationAndHeldReadReplacement() async throws {
        let count = try await BrowserDownloadedPDFAppChecks.deletionAndHeldRead()
        XCTAssertGreaterThan(count, 6)
    }
    @MainActor func testExplicitWorkerApprovalAndLateReplyRevocation() async throws {
        let count = try await BrowserDownloadedPDFAppChecks.lateWorkerAndDisclosure()
        XCTAssertGreaterThan(count, 6)
    }
}
#endif
