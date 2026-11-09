import Foundation

/// Caller serializes mutations and commits the new snapshot transactionally.
/// This type performs no filesystem/network/model/tool operations. Failed
/// mutations leave the value unchanged. Review is not execution authorization.
public struct SkillsState: Codable, Equatable, Sendable {
    // iOS resource policy, not an upstream Mika limit. No silent eviction.
    public static let maxInstalled = 256
    public static let maxPending = 64
    public static let maxRevisions = 512
    public private(set) var installed: [PersonalSkill] = []
    public private(set) var pending: [SkillDraft] = []
    public private(set) var revisions: [SkillRevision] = []

    public init() {}

    @discardableResult
    public mutating func importMarkdown(_ raw: String, availableToolNames: Set<String>,
                                        builtinNames: Set<String> = [], now: Date = Date(),
                                        draftID: UUID = UUID()) throws -> SkillDraft {
        try stage(raw, source: .imported, availableToolNames: availableToolNames,
                  builtinNames: builtinNames, now: now, draftID: draftID)
    }

    /// Optional hook for judged web/MCP tasks. Current plain chat has no trusted
    /// OutcomeJudge, so stays unknown; generation and user review remain app concerns.
    @discardableResult
    public mutating func proposeLearnedDraft(_ markdown: String, evidence: SkillRunEvidence,
                                            availableToolNames: Set<String>, builtinNames: Set<String> = [],
                                            now: Date = Date(), draftID: UUID = UUID()) throws -> SkillDraft {
        guard SkillLearningGate.canAutoDraft(evidence) else { throw SkillsError.insufficientEvidence }
        return try stage(markdown, source: .learned, availableToolNames: availableToolNames,
                         builtinNames: builtinNames, now: now, draftID: draftID)
    }

    private mutating func stage(_ raw: String, source: SkillSource, availableToolNames: Set<String>,
                                builtinNames: Set<String>, now: Date, draftID: UUID) throws -> SkillDraft {
        let text = try SkillDocument.importText(raw, source: source)
        let document = try SkillDocument.parse(text, availableToolNames: availableToolNames)
        guard !builtinNames.contains(document.name) else { throw SkillsError.builtinName }
        guard !pending.contains(where: { $0.name == document.name }) else { throw SkillsError.draftPending }
        guard !pending.contains(where: { $0.id == draftID }) else { throw SkillsError.duplicateID }
        guard pending.count < Self.maxPending else { throw SkillsError.capacityReached }
        let existing = installed.first { $0.name == document.name }
        let draft = SkillDraft(id: draftID, document: document, source: source,
                               replacesName: existing?.name, baseHash: existing?.fingerprint, createdAt: now)
        pending.append(draft)
        return draft
    }

    @discardableResult
    public mutating func editDraft(id: UUID, markdown: String,
                                   availableToolNames: Set<String>) throws -> SkillDraft {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { throw SkillsError.notFound }
        let original = pending[index]
        let document = try reviewedDocument(markdown, draft: original, availableToolNames: availableToolNames)
        let edited = SkillDraft(id: id, document: document, source: original.source,
                                replacesName: original.replacesName, baseHash: original.baseHash,
                                createdAt: original.createdAt)
        pending[index] = edited
        return edited
    }

    @discardableResult
    public mutating func approveDraft(id: UUID, editedMarkdown: String? = nil,
                                      availableToolNames: Set<String>, now: Date = Date()) throws -> PersonalSkill {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { throw SkillsError.notFound }
        let draft = pending[index]
        let document = try reviewedDocument(editedMarkdown ?? draft.markdown, draft: draft,
                                            availableToolNames: availableToolNames)
        let current = installed.first { $0.name == draft.name }
        guard current?.fingerprint == draft.baseHash else { throw SkillsError.changedSinceRead }
        guard current != nil || installed.count < Self.maxInstalled else { throw SkillsError.capacityReached }
        let skill = PersonalSkill(document: document, status: .trial, source: draft.source,
                                  createdAt: draft.createdAt, outcomes: [])
        try archive(name: draft.name, operation: .approve, previous: current, now: now)
        installed.removeAll { $0.name == draft.name }
        installed.append(skill)
        pending.remove(at: index)
        return skill
    }

    public mutating func rejectDraft(id: UUID, now: Date = Date()) throws {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { throw SkillsError.notFound }
        guard revisions.count < Self.maxRevisions else { throw SkillsError.capacityReached }
        let draft = pending[index]
        revisions.append(SkillRevision(id: UUID(), name: draft.name, operation: .reject,
                                       createdAt: now, previous: nil, rejectedDraft: draft))
        pending.remove(at: index)
    }

    public mutating func suspend(name: String) throws {
        guard let index = installed.firstIndex(where: { $0.name == name }) else { throw SkillsError.notFound }
        installed[index].status = .suspended
    }

    public mutating func resume(name: String) throws {
        guard let index = installed.firstIndex(where: { $0.name == name }) else { throw SkillsError.notFound }
        guard installed[index].status == .suspended else { return }
        // Evaluate retained evidence before clearing it, matching Mika restore.
        installed[index].status = installed[index].outcomes.contains(.verified) ? .active : .trial
        installed[index].outcomes = []
    }

    public mutating func remove(name: String, now: Date = Date()) throws {
        guard let index = installed.firstIndex(where: { $0.name == name }) else { throw SkillsError.notFound }
        try archive(name: name, operation: .remove, previous: installed[index], now: now)
        installed.remove(at: index)
    }

    @discardableResult
    public mutating func restoreRevision(id: UUID, expectedCurrentHash: String?,
                                         availableToolNames: Set<String>, now: Date = Date()) throws -> PersonalSkill {
        guard let revision = revisions.first(where: { $0.id == id }) else { throw SkillsError.notFound }
        guard let previous = revision.previous else { throw SkillsError.notRestorable }
        let current = installed.first { $0.name == revision.name }
        guard current?.fingerprint == expectedCurrentHash else { throw SkillsError.changedSinceRead }
        guard current != nil || installed.count < Self.maxInstalled else { throw SkillsError.capacityReached }
        _ = try SkillDocument.parse(previous.markdown, availableToolNames: availableToolNames)
        try archive(name: revision.name, operation: .restore, previous: current, now: now)
        installed.removeAll { $0.name == revision.name }
        installed.append(previous)
        return previous
    }

    public func exportMarkdown(name: String) throws -> String {
        guard let skill = installed.first(where: { $0.name == name }) else { throw SkillsError.notFound }
        return try SkillDocument.shareable(skill.markdown)
    }

    @discardableResult
    public mutating func recordOutcome(name: String, evidence: SkillRunEvidence) throws -> SkillResult? {
        guard let index = installed.firstIndex(where: { $0.name == name }) else { throw SkillsError.notFound }
        guard installed[index].isEnabled, evidence.wasRead,
              let result = SkillLearningGate.result(for: evidence) else { return nil }
        SkillOutcomeRules.record(result, on: &installed[index], followed: evidence.followed)
        return result
    }

    private func reviewedDocument(_ raw: String, draft: SkillDraft,
                                  availableToolNames: Set<String>) throws -> SkillDocument {
        let text = try SkillDocument.importText(raw, source: draft.source)
        let document = try SkillDocument.parse(text, availableToolNames: availableToolNames)
        guard document.name == draft.name else { throw SkillsError.nameMismatch }
        return document
    }

    private mutating func archive(name: String, operation: SkillRevisionOperation,
                                  previous: PersonalSkill?, now: Date) throws {
        guard revisions.count < Self.maxRevisions else { throw SkillsError.capacityReached }
        revisions.append(SkillRevision(id: UUID(), name: name, operation: operation,
                                       createdAt: now, previous: previous, rejectedDraft: nil))
    }

    private enum CodingKeys: String, CodingKey { case installed, pending, revisions }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        installed = try container.decode([PersonalSkill].self, forKey: .installed)
        pending = try container.decode([SkillDraft].self, forKey: .pending)
        revisions = try container.decode([SkillRevision].self, forKey: .revisions)
        guard installed.count <= Self.maxInstalled, pending.count <= Self.maxPending,
              revisions.count <= Self.maxRevisions,
              Set(installed.map(\.name)).count == installed.count,
              Set(pending.map(\.name)).count == pending.count,
              Set(pending.map(\.id)).count == pending.count,
              Set(revisions.map(\.id)).count == revisions.count,
              installed.allSatisfy(Self.validInstalled), pending.allSatisfy(Self.validDraft),
              revisions.allSatisfy({ revision in
                  if revision.operation == .reject {
                      return revision.previous == nil && revision.rejectedDraft.map {
                          $0.name == revision.name && Self.validDraft($0)
                      } == true
                  }
                  return revision.rejectedDraft == nil && revision.previous.map {
                      $0.name == revision.name && Self.validInstalled($0)
                  } != false
              }) else { throw SkillsError.invalidState }
    }

    private static func validInstalled(_ skill: PersonalSkill) -> Bool {
        skill.status != .pending && skill.outcomes.count <= 5 &&
        skill.document.frontMatter["source"]?.stringValue == skill.source.rawValue
    }
    private static func validDraft(_ draft: SkillDraft) -> Bool {
        guard draft.document.frontMatter["source"]?.stringValue == draft.source.rawValue else { return false }
        if let replacement = draft.replacesName, let hash = draft.baseHash {
            return replacement == draft.name && SkillDocument.matches("^[0-9a-f]{64}$", hash)
        }
        return draft.replacesName == nil && draft.baseHash == nil
    }
}
