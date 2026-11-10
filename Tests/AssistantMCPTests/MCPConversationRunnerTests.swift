#if !MCP_SMOKE
import XCTest

final class MCPConversationRunnerTests: XCTestCase {
    func testSelectedCatalogAndExactApprovedExecution() async throws {
        let count = try await MCPConversationChecks.approvedExecutionAndCatalog()
        XCTAssertGreaterThan(count, 0)
    }
    func testDenialAndChangedArgumentsNeverBorrowConsent() async throws {
        let count = try await MCPConversationChecks.refusalAndChangedArguments()
        XCTAssertGreaterThan(count, 0)
    }
    func testStrictCommandsUnknownToolsAndSelectedResources() async throws {
        let count = try await MCPConversationChecks.strictCommandsAndSelection()
        XCTAssertGreaterThan(count, 0)
    }
    func testToolErrorsTransportFailuresAndSizeBounds() async throws {
        let count = try await MCPConversationChecks.errorsAndBounds()
        XCTAssertGreaterThan(count, 0)
    }
    func testCallBudgetsAndRepeatedOperationsStopWithoutRetry() async throws {
        let count = try await MCPConversationChecks.budgetsAndRepeatedCalls()
        XCTAssertGreaterThan(count, 0)
    }
    func testFixedModelFailureClassificationWithoutRetryOrLostEvents() async throws {
        let count = try await MCPConversationChecks.modelFailureClassification()
        XCTAssertGreaterThan(count, 0)
    }
    func testSingleBoundedCommandCorrectionPreservesSelectionApprovalAndResults() async throws {
        let count = try await MCPConversationChecks.commandCorrection()
        XCTAssertGreaterThan(count, 0)
    }
    func testCommandCorrectionCancellationAndOriginalDeadline() async throws {
        let count = try await MCPConversationChecks.correctionCancellationAndDeadline()
        XCTAssertGreaterThan(count, 0)
    }
    func testCancellationAndDeadlineFenceLateApprovalAndResults() async throws {
        let count = try await MCPConversationChecks.cancellationAndDeadline()
        XCTAssertGreaterThan(count, 0)
    }
    func testAuthorizedSingleCallTransportAndReadOnlyCompatibility() async throws {
        let count = try await MCPConversationChecks.singleCallTransportAPI()
        XCTAssertGreaterThan(count, 0)
    }
}
#endif
