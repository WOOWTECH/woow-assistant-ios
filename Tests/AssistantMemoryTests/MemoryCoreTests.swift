import XCTest

final class MemoryCoreTests: XCTestCase {
    func testMutationsUndoAndSerialization() throws { XCTAssertGreaterThan(try MemoryChecks.mutations(), 0) }
    func testSensitiveExclusionAndNoAutomaticEviction() throws { XCTAssertGreaterThan(try MemoryChecks.sensitiveAndCapacity(), 0) }
    func testAutoAndRelevantRetrievalBudgets() throws { XCTAssertGreaterThan(try MemoryChecks.retrieval(), 0) }
    func testGroundingRevisionAndAtomicApplication() throws { XCTAssertGreaterThan(try MemoryChecks.extraction(), 0) }
    func testSeparateModelCallGatesAndCancellation() async throws {
        let count = try await MemoryChecks.modelBoundary()
        XCTAssertGreaterThan(count, 0)
    }
}
