import Foundation

public enum SkillTaskEnd: String, Codable, Sendable { case succeeded, failed, cancelled }
public enum SkillTaskOutcome: String, Codable, Sendable { case done, partial, notPossible, unknown }
public enum SkillFailureKind: String, Codable, Sendable {
    case gaveUp, stepLimit, tokenLimit, model, environment, protection, interrupted, verifierRejected
}

/// Supplied by trusted orchestration, never decoded from model output or skill text.
/// Mika attributes use to a successful skill_read, not proof of following every step.
/// Here that distinction is explicit: wasRead and followed. Only trusted task
/// orchestration/OutcomeJudge may supply .done; HTTP 200 or raw model claims must
/// stay .unknown. Like Mika, a separate final verifier is not mandatory.
public struct SkillRunEvidence: Equatable, Sendable {
    public let end: SkillTaskEnd
    public let outcome: SkillTaskOutcome
    public let failureKind: SkillFailureKind?
    public let wasRead: Bool
    public let followed: Bool
    public let verifierReviewed: Bool
    public let verifierPassed: Bool
    public let hasUnconfirmedClaims: Bool
    public let successfulActionCount: Int
    public let userInterrupted: Bool
    public let explicitSkillSave: Bool
    public let replayMatched: Bool

    public init(end: SkillTaskEnd = .succeeded, outcome: SkillTaskOutcome = .unknown,
                failureKind: SkillFailureKind? = nil, wasRead: Bool = false, followed: Bool = false,
                verifierReviewed: Bool = false,
                verifierPassed: Bool = false, hasUnconfirmedClaims: Bool = false,
                successfulActionCount: Int = 0, userInterrupted: Bool = false,
                explicitSkillSave: Bool = false, replayMatched: Bool = false) {
        self.end = end; self.outcome = outcome; self.failureKind = failureKind
        self.wasRead = wasRead; self.followed = followed
        self.verifierReviewed = verifierReviewed; self.verifierPassed = verifierPassed
        self.hasUnconfirmedClaims = hasUnconfirmedClaims; self.successfulActionCount = successfulActionCount
        self.userInterrupted = userInterrupted; self.explicitSkillSave = explicitSkillSave
        self.replayMatched = replayMatched
    }
}

public enum SkillLearningGate {
    /// Pure lifecycle gate. SkillLearningService derives these fields from an
    /// executed trajectory and an independent model-backed outcome judgment.
    public static func canAutoDraft(_ evidence: SkillRunEvidence) -> Bool {
        evidence.end == .succeeded && evidence.outcome == .done &&
        !evidence.hasUnconfirmedClaims && (!evidence.verifierReviewed || evidence.verifierPassed) &&
        evidence.successfulActionCount >= 5 && !evidence.wasRead && !evidence.followed &&
        !evidence.userInterrupted && !evidence.explicitSkillSave && !evidence.replayMatched
    }

    public static func result(for evidence: SkillRunEvidence) -> SkillResult? {
        switch evidence.end {
        case .cancelled: return nil
        case .failed:
            switch evidence.failureKind {
            case .verifierRejected: return .verifierRejected
            // Mika 0c172724 includes TokenLimit; older WOOW 48dd3b94 does not.
            case .gaveUp, .stepLimit, .tokenLimit: return .failed
            default: return .unreviewed
            }
        case .succeeded:
            if evidence.outcome == .partial || evidence.outcome == .notPossible { return .failed }
            if evidence.hasUnconfirmedClaims { return .verifierRejected }
            if evidence.outcome == .unknown { return .unreviewed }
            if evidence.verifierReviewed && !evidence.verifierPassed { return .unverified }
            return .verified
        }
    }
}

enum SkillOutcomeRules {
    static func record(_ result: SkillResult, on skill: inout PersonalSkill, followed: Bool) {
        skill.outcomes = Array((skill.outcomes + [result]).suffix(5))
        if skill.status == .trial {
            if result == .verified { skill.status = .active }
            else if result == .failed || result == .verifierRejected { skill.status = .suspended }
        } else if skill.status == .active {
            let window = skill.outcomes.filter { $0 != .unreviewed }.suffix(3)
            if (followed && result == .verifierRejected) || window.filter({ $0 != .verified }).count >= 2 {
                skill.status = .suspended
            }
        }
    }
}
