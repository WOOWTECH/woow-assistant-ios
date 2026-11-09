import Foundation

/// Executor-owned categories. Observations (inspect/find/read) can support an
/// answer but do not satisfy Mika's five-action drafting threshold. No phone or
/// command/script execution categories are provided.
public enum SkillActionKind: String, Codable, Sendable {
    case observation, navigation, interaction, tabs, transfer, writeFile
}

/// Construct ONLY after an actual executor call completes, never from a model's
/// proposed tool call or self-reported success. Results remain untrusted content.
/// Arguments are the actual executed string parameters, not generated event IDs.
public struct SkillExecutedAction: Equatable, Sendable {
    public let id: String
    public let toolName: String
    public let kind: SkillActionKind
    public let arguments: [String: String]
    public let result: String
    public let succeeded: Bool
    /// Actual page URL returned by the executor after the observation completed,
    /// never a requested URL, model argument, or URL inferred from page prose.
    public let observedURL: URL?

    public init(id: String, toolName: String, kind: SkillActionKind,
                arguments: [String: String], result: String, succeeded: Bool, observedURL: URL? = nil) {
        self.id = id; self.toolName = toolName; self.kind = kind
        self.arguments = arguments; self.result = result; self.succeeded = succeeded
        self.observedURL = observedURL
    }
}

/// A successful read of this exact installed version, captured by the executor.
/// Merely including a summary in a prompt is not proof of following the skill.
public struct SkillUsedReference: Equatable, Sendable {
    public let name: String
    public let fingerprint: String
    public let followed: Bool
    public init(name: String, fingerprint: String, followed: Bool = false) {
        self.name = name; self.fingerprint = fingerprint; self.followed = followed
    }
}

public struct SkillTaskContext: Equatable, Sendable {
    public let runID: UUID
    public let end: SkillTaskEnd
    public let failureKind: SkillFailureKind?
    public let verifierReviewed: Bool
    public let verifierPassed: Bool
    public let hasUnconfirmedClaims: Bool
    public let userInterrupted: Bool
    public let explicitSkillSave: Bool
    public let replayMatched: Bool
    public let usedSkills: [SkillUsedReference]

    public init(runID: UUID = UUID(), end: SkillTaskEnd = .succeeded,
                failureKind: SkillFailureKind? = nil, verifierReviewed: Bool = false,
                verifierPassed: Bool = false, hasUnconfirmedClaims: Bool = false,
                userInterrupted: Bool = false, explicitSkillSave: Bool = false,
                replayMatched: Bool = false, usedSkills: [SkillUsedReference] = []) {
        self.runID = runID; self.end = end; self.failureKind = failureKind
        self.verifierReviewed = verifierReviewed; self.verifierPassed = verifierPassed
        self.hasUnconfirmedClaims = hasUnconfirmedClaims; self.userInterrupted = userInterrupted
        self.explicitSkillSave = explicitSkillSave; self.replayMatched = replayMatched; self.usedSkills = usedSkills
    }

    func evidence(outcome: SkillTaskOutcome, actionCount: Int) -> SkillRunEvidence {
        SkillRunEvidence(end: end, outcome: outcome, failureKind: failureKind,
                         wasRead: !usedSkills.isEmpty, followed: usedSkills.contains { $0.followed },
                         verifierReviewed: verifierReviewed, verifierPassed: verifierPassed,
                         hasUnconfirmedClaims: hasUnconfirmedClaims, successfulActionCount: actionCount,
                         userInterrupted: userInterrupted, explicitSkillSave: explicitSkillSave, replayMatched: replayMatched)
    }
}

public struct SkillJudgmentCitation: Equatable, Sendable {
    public let actionID: String
    public let quote: String
}

/// The reason/citations are bounded, checked data, never authorization or a tool call.
public struct SkillJudgment: Equatable, Sendable {
    public let outcome: SkillTaskOutcome
    public let reason: String
    public let citations: [SkillJudgmentCitation]
    static let unknown = SkillJudgment(outcome: .unknown, reason: "", citations: [])
}

public enum SkillLearningSkipReason: String, Sendable {
    case ineligible, invalidTrajectory, unsafeEvidence, noGroundedEvidence
    case judgeUnavailable, invalidJudgment, tooFewActions, draftDisabled, draftUnavailable, invalidDraft, nameTaken
}

public struct SkillLearningAssessment: Equatable, Sendable {
    public let judgment: SkillJudgment
    public let evidence: SkillRunEvidence
    public let proposal: SkillLearningProposal?
    public let skipReason: SkillLearningSkipReason?
    public let usedSkills: [SkillUsedReference]
    let baseStateFingerprint: String
}

/// Cannot be initialized or decoded by outside callers. Applying it requires the
/// exact state snapshot used during generation; review/approval is still separate.
public struct SkillLearningProposal: Equatable, Sendable {
    public let document: SkillDocument
    public let runID: UUID
    public var markdown: String { document.markdown }
    public var name: String { document.name }
    public let replacesPendingID: UUID?
    let baseStateFingerprint: String
    let evidence: SkillRunEvidence
}
