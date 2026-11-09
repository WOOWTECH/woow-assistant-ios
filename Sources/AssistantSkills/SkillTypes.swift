import Foundation

// Behavior references: Mika 0c172724, PersonalSkills.kt, SkillImport.kt and
// SkillOutcomes.kt. This is a value-only adaptation, not a script/tool runtime.
public enum SkillStatus: String, Codable, Sendable { case pending, trial, active, suspended }
public enum SkillSource: String, Codable, Sendable { case imported, user, learned }
public enum SkillResult: String, Codable, Sendable {
    case verified, unverified, failed, unreviewed
    case verifierRejected = "verifier_rejected"
}
public enum SkillRevisionOperation: String, Codable, Sendable { case approve, reject, remove, restore }

public enum SkillsError: String, Error, Codable, Equatable, Sendable, LocalizedError {
    case invalidFrontMatter, invalidName, missingDescription, missingSection, tooLong
    case unknownTool, sensitiveContent, builtinName, draftPending, duplicateID
    case notFound, changedSinceRead, nameMismatch, notRestorable, invalidState
    case insufficientEvidence, capacityReached

    public var errorDescription: String? {
        // Fixed categories only; never echo potentially sensitive imported content.
        switch self {
        case .invalidFrontMatter: return "Skill front matter must use scalar values or inline lists."
        case .invalidName: return "Skill name must use lowercase letters, digits and hyphens."
        case .missingDescription: return "Skill description is required."
        case .missingSection: return "Skill requires all five workflow sections."
        case .tooLong: return "Skill exceeds the supported size."
        case .unknownTool: return "Skill references a tool that is not available."
        case .sensitiveContent: return "Skill contains potentially sensitive information."
        case .builtinName: return "Skill name is reserved by a built-in skill."
        case .draftPending: return "A draft for this skill is already pending."
        case .duplicateID: return "Draft identifier already exists."
        case .notFound: return "Skill or revision was not found."
        case .changedSinceRead: return "Skill changed since this version was read."
        case .nameMismatch: return "Editing a draft cannot rename its target skill."
        case .notRestorable: return "This revision has no previous installed version."
        case .invalidState: return "Skills snapshot is invalid."
        case .insufficientEvidence: return "Verified task evidence is required for learned drafts."
        case .capacityReached: return "Skills storage capacity reached; existing history was preserved."
        }
    }
}

public struct PersonalSkill: Codable, Equatable, Sendable, Identifiable {
    public let document: SkillDocument
    public internal(set) var status: SkillStatus
    public let source: SkillSource
    public let createdAt: Date
    public internal(set) var outcomes: [SkillResult]
    public var id: String { name }
    public var name: String { document.name }
    public var markdown: String { document.markdown }
    public var fingerprint: String { document.fingerprint }
    public var version: String { document.version }
    public var isEnabled: Bool { status == .trial || status == .active }
}

public struct SkillDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let document: SkillDocument
    public let source: SkillSource
    public let replacesName: String?
    public let baseHash: String?
    public let createdAt: Date
    public var name: String { document.name }
    public var markdown: String { document.markdown }
}

/// Archive records are not a fifth installed status. Rejected drafts are retained
/// for audit but cannot be restored as an approved installed version.
public struct SkillRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public let operation: SkillRevisionOperation
    public let createdAt: Date
    public let previous: PersonalSkill?
    public let rejectedDraft: SkillDraft?
    public var canRestore: Bool { previous != nil }
}

public struct SkillInstructionContext: Equatable, Sendable {
    public let text: String
    public let skillNames: [String]
    public let truncated: Bool
    /// Reference text is never permission to call tools, control apps, run scripts,
    /// access credentials, or bypass user confirmation. Enforce that outside prompts.
    public var grantsAuthorization: Bool { false }
}
