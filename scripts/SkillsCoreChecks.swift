// Run from the repository root (no network, filesystem fixtures or credentials):
// swiftc -D SKILLS_CORE_SMOKE -parse-as-library Sources/AssistantSkills/*.swift \
//   Tests/AssistantSkillsTests/*.swift scripts/SkillsCoreChecks.swift -o /tmp/woow-skills-core-checks
// /tmp/woow-skills-core-checks
#if SKILLS_CORE_SMOKE
import Foundation

@main
struct SkillsCoreStandaloneChecks {
    static func main() throws {
        let groups: [(String, () throws -> Int)] = [
            ("documents", SkillsCoreFixtures.documents),
            ("reviewAndRevisions", SkillsCoreFixtures.reviewAndRevisions),
            ("outcomeLifecycle", SkillsCoreFixtures.outcomeLifecycle),
            ("learningGates", SkillsCoreFixtures.learningGates),
            ("retrievalAndContext", SkillsCoreFixtures.retrievalAndContext),
            ("capabilitiesAndBounds", SkillsCoreFixtures.capabilitiesAndBounds)
        ]
        var total = 0
        for (name, operation) in groups {
            let count = try operation(); total += count
            print("PASS \(name): \(count) assertions")
        }
        print("PASS Skills core: \(groups.count) groups, \(total) assertions")
    }
}
#endif
