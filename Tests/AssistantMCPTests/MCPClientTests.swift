#if MCP_SMOKE
import Foundation

@main
struct MCPStandaloneSmoke {
    static func main() async throws {
        let groups: [(String, () async throws -> Int)] = [
            ("handshake", MCPClientChecks.handshake), ("catalogsAndTools", MCPClientChecks.catalogsAndTools),
            ("capabilitiesAndLimits", MCPClientChecks.capabilitiesAndLimits),
            ("parserAndErrors", MCPClientChecks.parserAndErrors),
            ("deadlinesAndCancellation", MCPClientChecks.deadlinesAndCancellation),
            ("conversationCatalog", MCPConversationChecks.approvedExecutionAndCatalog),
            ("conversationApproval", MCPConversationChecks.refusalAndChangedArguments),
            ("conversationCommands", MCPConversationChecks.strictCommandsAndSelection),
            ("conversationErrors", MCPConversationChecks.errorsAndBounds),
            ("modelFailureClassification", MCPConversationChecks.modelFailureClassification),
            ("commandCorrection", MCPConversationChecks.commandCorrection),
            ("correctionCancellation", MCPConversationChecks.correctionCancellationAndDeadline),
            ("conversationBudgets", MCPConversationChecks.budgetsAndRepeatedCalls),
            ("conversationCancellation", MCPConversationChecks.cancellationAndDeadline),
            ("authorizedTransport", MCPConversationChecks.singleCallTransportAPI)
        ]
        var count = 0
        for (name, check) in groups {
            let passed = try await check()
            count += passed
            print("PASS \(name): \(passed) checks")
        }
        print("PASS MCP: \(groups.count) groups, \(count) checks; local fixtures only")
    }
}
#else
import XCTest

final class MCPClientTests: XCTestCase {
    func testNegotiationHeadersAndStatelessSessions() async throws {
        let count = try await MCPClientChecks.handshake()
        XCTAssertGreaterThan(count, 0)
    }
    func testLargeSSECatalogAndExplicitToolAuthorization() async throws {
        let count = try await MCPClientChecks.catalogsAndTools()
        XCTAssertGreaterThan(count, 0)
    }
    func testCapabilitiesAndPaginationLimits() async throws {
        let count = try await MCPClientChecks.capabilitiesAndLimits()
        XCTAssertGreaterThan(count, 0)
    }
    func testParserBoundsAndSanitizedFailures() async throws {
        let count = try await MCPClientChecks.parserAndErrors()
        XCTAssertGreaterThan(count, 0)
    }
    func testTotalDeadlineAndCancellation() async throws {
        let count = try await MCPClientChecks.deadlinesAndCancellation()
        XCTAssertGreaterThan(count, 0)
    }
}
#endif
