import Foundation
import CryptoKit

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

    /// Trusted authoring bridge only: provenance comes from the captured user
    /// request, never from imported Markdown or a model-supplied source field.
    @discardableResult
    mutating func stageUserRequestedMarkdown(_ raw: String, availableToolNames: Set<String>,
                                            builtinNames: Set<String> = [], now: Date = Date(),
                                            draftID: UUID = UUID()) throws -> SkillDraft {
        try stage(raw, source: .user, availableToolNames: availableToolNames,
                  builtinNames: builtinNames, now: now, draftID: draftID)
    }

    /// Low-level compatibility hook for trusted orchestrators. Prefer applying a
    /// SkillLearningService assessment: it carries an optimistic snapshot guard.
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
        _ = try previous.document.validated(availableToolNames: availableToolNames)
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

    /// Atomic in-memory application; the caller still commits the resulting value
    /// to encrypted storage before publishing. No partial outcomes on any conflict.
    @discardableResult
    public mutating func apply(_ assessment: SkillLearningAssessment, availableToolNames: Set<String>,
                               builtinNames: Set<String> = [], now: Date = Date()) throws -> SkillDraft? {
        guard try learningFingerprint() == assessment.baseStateFingerprint else { throw SkillsError.changedSinceRead }
        let references = try validatedLearningReferences(assessment.usedSkills)
        var next = self
        for reference in references {
            try next.recordOutcome(reference: reference, evidence: assessment.evidence)
        }
        let draft: SkillDraft?
        if let proposal = assessment.proposal {
            draft = try next.apply(proposal, availableToolNames: availableToolNames, builtinNames: builtinNames, now: now)
        } else { draft = nil }
        self = next
        return draft
    }

    @discardableResult
    public mutating func apply(_ proposal: SkillLearningProposal, availableToolNames: Set<String>,
                               builtinNames: Set<String> = [], now: Date = Date()) throws -> SkillDraft {
        guard try learningFingerprint() == proposal.baseStateFingerprint else { throw SkillsError.changedSinceRead }
        guard SkillLearningGate.canAutoDraft(proposal.evidence) else { throw SkillsError.insufficientEvidence }
        let document = try SkillDocument.parse(proposal.markdown, availableToolNames: availableToolNames,
                                               trustedProvenance: proposal.runID)
        guard !builtinNames.contains(document.name) else { throw SkillsError.builtinName }
        let draft: SkillDraft
        if let id = proposal.replacesPendingID {
            guard let index = pending.firstIndex(where: { $0.id == id && $0.name == document.name }) else {
                throw SkillsError.changedSinceRead
            }
            let original = pending[index]
            draft = SkillDraft(id: id, document: document, source: .learned,
                               replacesName: original.replacesName, baseHash: original.baseHash, createdAt: now)
            pending[index] = draft
        } else {
            guard !pending.contains(where: { $0.name == document.name }) else { throw SkillsError.draftPending }
            guard pending.count < Self.maxPending else { throw SkillsError.capacityReached }
            let existing = installed.first { $0.name == document.name }
            draft = SkillDraft(id: UUID(), document: document, source: .learned,
                               replacesName: existing?.name, baseHash: existing?.fingerprint, createdAt: now)
            pending.append(draft)
        }
        return draft
    }

    @discardableResult
    public mutating func recordOutcome(reference: SkillUsedReference, evidence: SkillRunEvidence) throws -> SkillResult? {
        guard let skill = installed.first(where: { $0.name == reference.name }) else { throw SkillsError.notFound }
        guard skill.fingerprint == reference.fingerprint else { throw SkillsError.changedSinceRead }
        guard evidence.wasRead else { return nil }
        let attributed = SkillRunEvidence(end: evidence.end, outcome: evidence.outcome, failureKind: evidence.failureKind,
            wasRead: true, followed: reference.followed, verifierReviewed: evidence.verifierReviewed,
            verifierPassed: evidence.verifierPassed, hasUnconfirmedClaims: evidence.hasUnconfirmedClaims,
            successfulActionCount: evidence.successfulActionCount, userInterrupted: evidence.userInterrupted,
            explicitSkillSave: evidence.explicitSkillSave, replayMatched: evidence.replayMatched)
        return try recordOutcome(name: reference.name, evidence: attributed)
    }

    func learningFingerprint() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }

    /// Validate every version before deduplicating or recording any outcome.
    /// Identical repeated reads count once. Conflicting versions or attribution
    /// flags are rejected, so input order cannot change which evidence is used.
    func validatedLearningReferences(_ references: [SkillUsedReference]) throws -> [SkillUsedReference] {
        guard references.count <= 32 else { throw SkillsError.invalidState }
        var unique: [SkillUsedReference] = []
        var byName: [String: SkillUsedReference] = [:]
        for reference in references {
            guard let skill = installed.first(where: { $0.name == reference.name }) else { throw SkillsError.notFound }
            guard skill.fingerprint == reference.fingerprint else { throw SkillsError.changedSinceRead }
            if let previous = byName[reference.name] {
                guard previous == reference else { throw SkillsError.invalidState }
            } else {
                byName[reference.name] = reference
                unique.append(reference)
            }
        }
        return unique
    }

    private func reviewedDocument(_ raw: String, draft: SkillDraft,
                                  availableToolNames: Set<String>) throws -> SkillDocument {
        var text = try SkillDocument.importText(raw, source: draft.source)
        // Review/edit must not erase runtime provenance or accept a replacement
        // supplied in edited Markdown. Only the stored learned draft owns this ID.
        if draft.source == .learned,
           let provenance = draft.document.frontMatter["learned_from"]?.stringValue,
           UUID(uuidString: provenance) != nil {
            text = try SkillDocument.replacingField(text, key: "learned_from", value: provenance)
        }
        let document = try SkillDocument.parse(text, availableToolNames: availableToolNames,
                                               trustedProvenance: draft.source == .learned ? draft.document.localProvenance : nil)
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
