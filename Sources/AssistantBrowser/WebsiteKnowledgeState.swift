import Foundation

/// Native website-only adaptation informed by Mika KnowledgeStore/AppKnowledgeLearning
/// at 0c172724f3f0c96f7345262588072f6e95db1138. No Android/app knowledge is imported.
/// User approval is not a claim of trial verification. Pending lessons never inject.
/// Mutations are value-atomic; the owner persists an encrypted copy before publishing.
public struct WebsiteKnowledgeState: Codable, Equatable, Sendable {
    public static let maximumLessons = 100
    public static let maximumRevisions = 100
    public private(set) var lessons: [WebsiteLesson]
    public private(set) var revisions: [WebsiteKnowledgeRevision]
    public private(set) var revision: UUID
    public var contentHash: String {
        WebsiteLearningSafety.fingerprint([revision.uuidString] + lessons.map(\.contentHash)
            + revisions.flatMap { [$0.id.uuidString, $0.contentHash, $0.reason.rawValue,
                                   WebsiteLearningSafety.dateKey($0.archivedAt)] })
    }

    public init() { lessons = []; revisions = []; revision = UUID() }

    @discardableResult
    public mutating func addManual(text: String, evidence: WebsiteLessonEvidence, now: Date = .now) throws -> UUID {
        let item = try WebsiteLesson(text: text, evidence: evidence, source: .manual, status: .approved,
                                     task: nil, createdAt: now, updatedAt: now)
        var next = self; next.lessons.append(item); try commit(next)
        return item.id
    }

    @discardableResult
    public mutating func propose(text: String, evidence: WebsiteLessonEvidence,
                                 task: WebTaskEvidence, now: Date = .now) throws -> UUID {
        guard task.isEligible else { throw WebsiteLearningError.ineligibleTask }
        let item = try WebsiteLesson(text: text, evidence: evidence, source: .judgedTask, status: .pending,
                                     task: task, createdAt: now, updatedAt: now)
        var next = self; next.lessons.append(item); try commit(next)
        return item.id
    }

    /// A user edit stays pending if the original was pending. Explicit approval is separate.
    public mutating func edit(id: UUID, text: String, evidence: WebsiteLessonEvidence, now: Date = .now) throws {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { throw WebsiteLearningError.notFound }
        let old = lessons[index]
        guard evidence.origin == old.origin else { throw WebsiteLearningError.originMismatch }
        let edited = try WebsiteLesson(id: id, text: text, evidence: evidence, source: .manual,
                                       status: old.status, task: nil, createdAt: old.createdAt, updatedAt: now)
        var next = self; try next.archive(old, reason: .edit, now: now); next.lessons[index] = edited
        try commit(next)
    }

    public mutating func approve(id: UUID, now: Date = .now) throws {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { throw WebsiteLearningError.notFound }
        let old = lessons[index]
        guard old.status == .pending else { return }
        let approved = try WebsiteLesson(id: id, text: old.text, evidence: old.evidence, source: old.source,
                                         status: .approved, task: old.task, createdAt: old.createdAt, updatedAt: now)
        var next = self; try next.archive(old, reason: .approve, now: now); next.lessons[index] = approved
        try commit(next)
    }

    /// Recoverable deletion. clear() additionally erases ALL revision history.
    public mutating func delete(id: UUID, now: Date = .now) throws {
        guard let index = lessons.firstIndex(where: { $0.id == id }) else { throw WebsiteLearningError.notFound }
        var next = self; try next.archive(lessons[index], reason: .delete, now: now)
        next.lessons.remove(at: index); try commit(next)
    }

    /// Compare-and-restore against the ENTIRE current state (including the revision journal).
    /// Never promotes a pending historical lesson to approved.
    @discardableResult
    public mutating func restore(revisionID: UUID, expectedCurrentHash: String, now: Date = .now) throws -> UUID {
        guard expectedCurrentHash == contentHash else { throw WebsiteLearningError.staleRevision }
        guard let saved = revisions.first(where: { $0.id == revisionID }) else { throw WebsiteLearningError.notFound }
        let old = saved.lesson
        let restored = try WebsiteLesson(id: old.id, text: old.text, evidence: old.evidence, source: old.source,
                                         status: old.status, task: old.task, createdAt: old.createdAt, updatedAt: now)
        var next = self
        if let index = next.lessons.firstIndex(where: { $0.id == old.id }) {
            try next.archive(next.lessons[index], reason: .restore, now: now)
            next.lessons[index] = restored
        } else { next.lessons.append(restored) }
        try commit(next)
        return restored.id
    }

    public mutating func clear() { lessons = []; revisions = []; revision = UUID() }

    /// Returned text is UNTRUSTED reference data: inject as user/data, never system instructions.
    /// Exact origin only; no subdomain, scheme or non-default port inheritance.
    public func context(for url: URL, limit: Int = 5) throws -> [WebsiteLesson] {
        let origin = try WebsiteOrigin(url: url)
        return Array(lessons.filter { $0.origin == origin && $0.status == .approved }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
            .prefix(max(0, min(limit, 10))))
    }

    public func search(_ query: String, originURL: URL? = nil) throws -> [WebsiteLesson] {
        guard query.utf16.count <= 1000 else { throw WebsiteLearningError.invalidText }
        let origin = try originURL.map { try WebsiteOrigin(url: $0) }
        let query = WebsiteLearningSafety.normalized(query).trimmingCharacters(in: .whitespacesAndNewlines)
        return lessons.filter { (origin == nil || $0.origin == origin)
            && (query.isEmpty || $0.text.localizedCaseInsensitiveContains(query)) }
    }

    private mutating func archive(_ item: WebsiteLesson, reason: WebsiteRevisionReason, now: Date) throws {
        guard WebsiteLearningSafety.validDate(now), now >= item.updatedAt else { throw WebsiteLearningError.invalidState }
        revisions.append(WebsiteKnowledgeRevision(lesson: item, reason: reason, archivedAt: now))
        if revisions.count > Self.maximumRevisions { revisions.removeFirst(revisions.count - Self.maximumRevisions) }
    }
    private mutating func commit(_ proposed: Self) throws {
        var proposed = proposed
        proposed.revision = UUID()
        try proposed.validate()
        self = proposed
    }
    private func validate() throws {
        guard lessons.count <= Self.maximumLessons, revisions.count <= Self.maximumRevisions else {
            throw WebsiteLearningError.capacityExceeded
        }
        guard Set(lessons.map(\.id)).count == lessons.count,
              Set(revisions.map(\.id)).count == revisions.count else { throw WebsiteLearningError.invalidState }
        guard try JSONEncoder().encode(self).count <= 1_048_576 else { throw WebsiteLearningError.capacityExceeded }
    }
    private enum CodingKeys: String, CodingKey { case lessons, revisions, revision }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lessons = try c.decode([WebsiteLesson].self, forKey: .lessons)
        revisions = try c.decode([WebsiteKnowledgeRevision].self, forKey: .revisions)
        revision = try c.decode(UUID.self, forKey: .revision)
        try validate()
    }
}
