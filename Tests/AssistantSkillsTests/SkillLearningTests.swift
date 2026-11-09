#if SKILL_LEARNING_SMOKE
import Foundation

@main
struct SkillLearningStandalone {
    static func main() async throws {
        let core = try SkillsCoreFixtures.documents() + SkillsCoreFixtures.reviewAndRevisions() +
            SkillsCoreFixtures.outcomeLifecycle() + SkillsCoreFixtures.learningGates() +
            SkillsCoreFixtures.retrievalAndContext() + SkillsCoreFixtures.capabilitiesAndBounds()
        print("PASS existing Skills core: \(core) assertions")
        let groups: [(String, () async throws -> Int)] = [
            ("actualTrajectoryAndPrivacy", SkillLearningFixtures.actualTrajectoryAndPrivacy),
            ("gatesAndNoPadding", SkillLearningFixtures.gatesAndNoPadding),
            ("untrustedAndMalformed", SkillLearningFixtures.untrustedAndMalformed),
            ("outcomeAttributionAndUpdates", SkillLearningFixtures.outcomeAttributionAndUpdates),
            ("deadlinesAndCancellation", SkillLearningFixtures.deadlinesAndCancellation),
            ("failedVerifierOutcomes", SkillLearningFixtures.failedVerifierOutcomes),
            ("inputBoundsBeforeCounting", SkillLearningFixtures.inputBoundsBeforeCounting),
            ("duplicateReferenceConflicts", SkillLearningFixtures.duplicateReferenceConflicts)
        ]
        var total = 0
        for (name, check) in groups {
            let count = try await check(); total += count
            print("PASS \(name): \(count) assertions")
        }
        print("PASS model-backed Skills fixtures: \(total) new + \(core) core = \(total + core) assertions")
    }
}
#elseif !SKILLS_CORE_SMOKE
import XCTest

final class SkillLearningTests: XCTestCase {
    func testExecutedTrajectoryAndPrivacy() async throws {
        let count = try await SkillLearningFixtures.actualTrajectoryAndPrivacy(); XCTAssertGreaterThan(count, 0)
    }
    func testMikaEligibilityAndDuplicateActions() async throws {
        let count = try await SkillLearningFixtures.gatesAndNoPadding(); XCTAssertGreaterThan(count, 0)
    }
    func testUntrustedEvidenceAndInvalidModels() async throws {
        let count = try await SkillLearningFixtures.untrustedAndMalformed(); XCTAssertGreaterThan(count, 0)
    }
    func testAtomicOutcomeAttributionAndDraftUpdates() async throws {
        let count = try await SkillLearningFixtures.outcomeAttributionAndUpdates(); XCTAssertGreaterThan(count, 0)
    }
    func testModelFailuresDeadlinesAndCancellation() async throws {
        let count = try await SkillLearningFixtures.deadlinesAndCancellation(); XCTAssertGreaterThan(count, 0)
    }
    func testFailedVerifierKeepsMikaOutcomeSemantics() async throws {
        let count = try await SkillLearningFixtures.failedVerifierOutcomes(); XCTAssertGreaterThan(count, 0)
    }
    func testInputBoundsPrecedeActionCounting() async throws {
        let count = try await SkillLearningFixtures.inputBoundsBeforeCounting(); XCTAssertGreaterThan(count, 0)
    }
    func testConflictingDuplicateReferencesAreAtomic() async throws {
        let count = try await SkillLearningFixtures.duplicateReferenceConflicts(); XCTAssertGreaterThan(count, 0)
    }
}
#endif
