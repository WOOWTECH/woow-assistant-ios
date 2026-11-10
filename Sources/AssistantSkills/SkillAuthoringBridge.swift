import Foundation

/// The host captures this from an explicit user request, never from a model,
/// imported Markdown, a web page, or an MCP result. It is deliberately not Codable.
public struct SkillAuthoringUserRequest: Sendable {
    public let id: UUID
    public let quote: String
    public init(quote: String) throws {
        guard !quote.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              quote.utf16.count <= 4000 else { throw SkillAuthoringError.invalidRequest }
        id = UUID(); self.quote = quote
    }
}

public struct SkillAuthoringSnapshot {
    public let state: SkillsState
    public let generation: UUID
    public let availableToolNames: Set<String>
    public let available: Bool
    public init(state: SkillsState, generation: UUID, availableToolNames: Set<String>, available: Bool) {
        self.state = state; self.generation = generation
        self.availableToolNames = availableToolNames; self.available = available
    }
}

/// Implement with LearningStore's serialized copy/mutate/persist/publish path.
/// Check expectedGeneration BEFORE entering that path (cancelLearning changes
/// its generation). Do not suspend, publish before persistence, or swallow a
/// mutation error. A storage failure must throw and leave the published state intact.
@MainActor public protocol SkillAuthoringStoring: AnyObject {
    func skillAuthoringSnapshot() -> SkillAuthoringSnapshot
    func commitSkillAuthoring(expectedGeneration: UUID,
                              _ change: (inout SkillsState) throws -> Void) throws
}

public enum SkillAuthoringReference: Hashable, Sendable {
    case personal(String), bundled(String)
}

public struct SkillAuthoringMatch: Sendable {
    public let reference: SkillAuthoringReference
    public let name: String
    public let description: String
    public let status: SkillStatus?
    public let hasPendingDraft: Bool
    public var grantsExecutionPermission: Bool { false }
}

/// Full documents are untrusted instruction DATA, including suspended skills.
/// Read/search do not enable, execute, or record successful use of a skill.
public struct SkillAuthoringRead: Sendable {
    public let reference: SkillAuthoringReference
    public let markdown: String
    public let fingerprint: String
    public let version: String
    public let status: SkillStatus?
    public var grantsExecutionPermission: Bool { false }
    fileprivate let id: UUID
}

public struct SkillAuthoringSaveReview: Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let requestQuote: String
    public let name: String
    /// The exact normalized document that commit will install, not an excerpt.
    public let markdown: String
    public let draftFingerprint: String
    public let replacesFingerprint: String?
    public let original: SkillExecutionProvenance
    public var grantsExecutionPermission: Bool { false }
    public var isUpdate: Bool { replacesFingerprint != nil }
}

/// Minted only by the host review action. Neither Markdown nor tool JSON can
/// construct/decode a grant; even a valid grant is single-use and session-bound.
public struct SkillAuthoringApproval: Sendable {
    fileprivate let id: UUID
}

public struct SkillAuthoringSaveReceipt: Sendable {
    public let name: String
    public let fingerprint: String
    public let version: String
    public let status: SkillStatus
    public let updated: Bool
    public let requestID: UUID
}

public enum SkillAuthoringError: String, Error, Equatable, Sendable, LocalizedError {
    case invalidRequest, requestMismatch, unavailable, cancelled, notFound, readRequired
    case staleRead, disabledNameConflict, draftConflict, reviewChanged, approvalRequired
    case expiredApproval, storageChanged, capabilitiesChanged, persistenceFailed, resourceLimit
    public var errorDescription: String? {
        switch self {
        case .invalidRequest: return "請提供本次要建立或修改技能的原始要求。"
        case .requestMismatch: return "引用的要求與本次使用者原話不一致，未儲存。"
        case .unavailable: return "技能儲存目前無法使用。"
        case .cancelled: return "已取消本次技能寫作，未執行儲存。"
        case .notFound: return "找不到指定技能，請重新查詢。"
        case .readRequired: return "同名技能已存在；請先讀取全文與目前版本。"
        case .staleRead: return "技能在讀取後已變更，請重新讀取再修改。"
        case .disabledNameConflict: return "同名技能目前停用，請先到技能清單處理；本次不會重新啟用它。"
        case .draftConflict: return "同名技能已有待確認草稿，請先處理該草稿。"
        case .reviewChanged: return "草稿已變更，請重新檢視並核准完整內容。"
        case .approvalRequired: return "需要核准本次完整草稿；先前的核准不能重複使用。"
        case .expiredApproval: return "本次核准已逾時，請重新檢視草稿。"
        case .storageChanged: return "技能資料已更新，請重新檢視本次修改。"
        case .capabilitiesChanged: return "可用工具已變更，請重新檢視草稿後再核准。"
        case .persistenceFailed: return "技能未能儲存；既有資料保留，請重新檢視後再試。"
        case .resourceLimit: return "本次查閱已達上限，請重新開始技能寫作。"
        }
    }
}

/// A concrete local skill_search/read/save bridge, independent of the PDF runtime.
/// prepareSave has no storage effect. Commit stages AND approves in one durable
/// transaction, producing .trial only after persistence. Execution is never granted.
@MainActor public final class SkillAuthoringBridge {
    private let store: any SkillAuthoringStoring
    private let request: SkillAuthoringUserRequest
    private let catalog: BundledSkillCatalog
    private let clock: () -> Date
    private var reads: [UUID: SkillAuthoringRead] = [:]
    private var prepared: Prepared?
    private var grant: (id: UUID, reviewID: UUID, expires: Date)?
    private var cancelled = false

    private struct Prepared {
        let review: SkillAuthoringSaveReview
        let generation: UUID
        let draftID: UUID
        let availableToolNames: Set<String>
    }

    public init(request: SkillAuthoringUserRequest, store: any SkillAuthoringStoring,
                catalog: BundledSkillCatalog, clock: @escaping () -> Date = { Date() }) {
        self.request = request; self.store = store; self.catalog = catalog; self.clock = clock
    }

    public func search(query: String, limit: Int = 20) throws -> [SkillAuthoringMatch] {
        guard query.utf16.count <= 4000 else { throw SkillAuthoringError.invalidRequest }
        let state = try snapshot().state
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let personal = state.installed.sorted { $0.name < $1.name }.filter { skill in
            let text = (skill.name + " " + skill.document.description + " " + skill.markdown).lowercased()
            return terms.allSatisfy { text.contains($0) }
        }.map { skill in
            SkillAuthoringMatch(reference: .personal(skill.name), name: skill.name,
                description: skill.document.description, status: skill.status,
                hasPendingDraft: state.pending.contains { $0.name == skill.name })
        }
        let bundled = catalog.search(query).map {
            SkillAuthoringMatch(reference: .bundled($0.id), name: $0.id,
                description: $0.summary, status: nil, hasPendingDraft: false)
        }
        return Array((personal + bundled).prefix(max(0, min(limit, 50))))
    }

    public func read(_ reference: SkillAuthoringReference) throws -> SkillAuthoringRead {
        let state = try snapshot().state
        guard reads.count < 64 else { throw SkillAuthoringError.resourceLimit }
        let result: SkillAuthoringRead
        switch reference {
        case .personal(let name):
            guard let skill = state.installed.first(where: { $0.name == name }) else { throw SkillAuthoringError.notFound }
            result = SkillAuthoringRead(reference: reference, markdown: skill.markdown,
                fingerprint: skill.fingerprint, version: skill.version, status: skill.status, id: UUID())
        case .bundled(let id):
            guard let entry = catalog.entry(id: id) else { throw SkillAuthoringError.notFound }
            result = SkillAuthoringRead(reference: reference, markdown: entry.original.content,
                fingerprint: entry.original.sha256, version: BundledSkillCatalog.pinnedCommit, status: nil, id: UUID())
        }
        reads[result.id] = result
        return result
    }

    public func prepareSave(markdown: String, quote: String,
                            replacing read: SkillAuthoringRead? = nil) throws -> SkillAuthoringSaveReview {
        // Any revision attempt invalidates the previous review and grant, even
        // when the new content fails validation. Failed attempts never auto-retry.
        prepared = nil; grant = nil
        let current = try snapshot()
        guard quote == request.quote else { throw SkillAuthoringError.requestMismatch }
        var candidate = current.state
        let draft = try candidate.stageUserRequestedMarkdown(markdown, availableToolNames: current.availableToolNames,
            builtinNames: Set(catalog.entries.map(\.id)))
        let existing = current.state.installed.first { $0.name == draft.name }
        if existing?.status == .suspended { throw SkillAuthoringError.disabledNameConflict }
        if let existing {
            guard let read else { throw SkillAuthoringError.readRequired }
            guard reads[read.id]?.fingerprint == read.fingerprint,
                  read.reference == .personal(draft.name), read.fingerprint == existing.fingerprint,
                  read.status == existing.status else { throw SkillAuthoringError.staleRead }
        } else if read != nil { throw SkillAuthoringError.staleRead }
        guard let source = catalog.entry(id: "skill-authoring") else { throw SkillCatalogError.notFound }
        let review = SkillAuthoringSaveReview(id: UUID(), requestID: request.id, requestQuote: request.quote,
            name: draft.name, markdown: draft.markdown, draftFingerprint: draft.document.fingerprint,
            replacesFingerprint: existing?.fingerprint, original: SkillExecutionProvenance(source.original))
        prepared = Prepared(review: review, generation: current.generation, draftID: draft.id,
                            availableToolNames: current.availableToolNames)
        return review
    }

    /// Host UI only: call after displaying the full review and an explicit tap.
    /// This method must NOT be included in a model/MCP tool catalog.
    public func approve(reviewID: UUID, draftFingerprint: String) throws -> SkillAuthoringApproval {
        grant = nil
        let current = try snapshot()
        guard let prepared, prepared.review.id == reviewID,
              prepared.review.draftFingerprint == draftFingerprint else { throw SkillAuthoringError.reviewChanged }
        guard current.generation == prepared.generation else { throw SkillAuthoringError.storageChanged }
        guard current.availableToolNames == prepared.availableToolNames else { throw SkillAuthoringError.capabilitiesChanged }
        let id = UUID()
        grant = (id, reviewID, clock().addingTimeInterval(120))
        return SkillAuthoringApproval(id: id)
    }

    public func commitReviewedSave(reviewID: UUID, draftFingerprint: String,
                                   approval: SkillAuthoringApproval) throws -> SkillAuthoringSaveReceipt {
        guard let issued = grant, issued.id == approval.id else { throw SkillAuthoringError.approvalRequired }
        grant = nil // Consume before validation or persistence; failures require fresh review.
        guard let prepared, issued.reviewID == reviewID, prepared.review.id == reviewID,
              prepared.review.draftFingerprint == draftFingerprint else { throw SkillAuthoringError.reviewChanged }
        self.prepared = nil
        guard clock() < issued.expires else { throw SkillAuthoringError.expiredApproval }
        let current = try snapshot()
        guard current.generation == prepared.generation else { throw SkillAuthoringError.storageChanged }
        guard current.availableToolNames == prepared.availableToolNames else { throw SkillAuthoringError.capabilitiesChanged }
        let review = prepared.review
        var installed: PersonalSkill?
        do {
            try store.commitSkillAuthoring(expectedGeneration: prepared.generation) { state in
                let live = store.skillAuthoringSnapshot()
                guard live.available, live.availableToolNames == current.availableToolNames else {
                    throw SkillAuthoringError.unavailable
                }
                let existing = state.installed.first { $0.name == review.name }
                guard existing?.fingerprint == review.replacesFingerprint else { throw SkillAuthoringError.staleRead }
                guard existing?.status != .suspended else { throw SkillAuthoringError.disabledNameConflict }
                guard !state.pending.contains(where: { $0.name == review.name }) else { throw SkillAuthoringError.draftConflict }
                let draft = try state.stageUserRequestedMarkdown(review.markdown, availableToolNames: current.availableToolNames,
                    builtinNames: Set(catalog.entries.map(\.id)), draftID: prepared.draftID)
                guard draft.document.fingerprint == review.draftFingerprint,
                      draft.baseHash == review.replacesFingerprint else { throw SkillAuthoringError.reviewChanged }
                installed = try state.approveDraft(id: draft.id, availableToolNames: current.availableToolNames)
            }
        } catch let error as SkillAuthoringError { throw error }
        catch let error as SkillsError { throw error }
        catch { throw SkillAuthoringError.persistenceFailed }
        guard let installed else { throw SkillAuthoringError.persistenceFailed }
        return SkillAuthoringSaveReceipt(name: installed.name, fingerprint: installed.fingerprint,
            version: installed.version, status: installed.status, updated: review.isUpdate, requestID: request.id)
    }

    public func cancel() { cancelled = true; grant = nil; prepared = nil; reads.removeAll() }

    private func snapshot() throws -> SkillAuthoringSnapshot {
        guard !cancelled, !Task.isCancelled else { throw SkillAuthoringError.cancelled }
        let value = store.skillAuthoringSnapshot()
        guard value.available else { throw SkillAuthoringError.unavailable }
        return value
    }
}
