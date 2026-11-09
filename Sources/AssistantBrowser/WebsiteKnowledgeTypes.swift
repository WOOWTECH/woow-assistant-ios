import Foundation

/// Only a small caller-selected quote is retained, not the full page or form contents.
/// The quote proves source attribution, not that an arbitrary paraphrase is true.
public struct WebsiteLessonEvidence: Codable, Equatable, Sendable {
    public let sourceURL: URL
    public let quote: String
    public let pageDigest: String
    public let capturedAt: Date
    public var origin: WebsiteOrigin { try! WebsiteOrigin(url: sourceURL) }

    /// Supply an actual successful public-page observation, never model-generated text.
    public init(snapshot: PageSnapshot, quote: String) throws {
        let safeQuote = try WebsiteLearningSafety.text(quote, max: 512)
        guard safeQuote.utf16.count >= 2, snapshot.visibleText.utf16.count <= 2_000_000,
              WebsiteLearningSafety.normalized(snapshot.visibleText).contains(safeQuote),
              WebsiteLearningSafety.validDate(snapshot.capturedAt) else {
            throw WebsiteLearningError.invalidEvidence
        }
        sourceURL = try WebsiteLearningSafety.publicURL(snapshot.url)
        self.quote = safeQuote
        pageDigest = WebsiteLearningSafety.digest(WebsiteLearningSafety.normalized(snapshot.visibleText))
        capturedAt = snapshot.capturedAt
    }

    private enum CodingKeys: String, CodingKey { case sourceURL, quote, pageDigest, capturedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sourceURL = try WebsiteLearningSafety.publicURL(c.decode(URL.self, forKey: .sourceURL))
        quote = try WebsiteLearningSafety.text(c.decode(String.self, forKey: .quote), max: 512)
        pageDigest = try c.decode(String.self, forKey: .pageDigest)
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        guard quote.utf16.count >= 2, WebsiteLearningSafety.validHash(pageDigest),
              WebsiteLearningSafety.validDate(capturedAt) else { throw WebsiteLearningError.invalidEvidence }
    }

    var hashFields: [String] { [sourceURL.absoluteString, quote, pageDigest, WebsiteLearningSafety.dateKey(capturedAt)] }
}

public enum WebTaskOutcome: String, Codable, Sendable { case succeeded, partial, failed, cancelled, unknown }

/// The runtime/judge supplies this AFTER the answer and verification. A saved plan is
/// not execution evidence, and a model's self-declared success is not confirmation.
public struct WebTaskEvidence: Codable, Equatable, Sendable {
    public let outcome: WebTaskOutcome
    public let confirmed: Bool
    public let summary: String
    public let completedAt: Date
    public var isEligible: Bool { outcome == .succeeded && confirmed }

    public init(outcome: WebTaskOutcome, confirmed: Bool, summary: String, completedAt: Date = .now) throws {
        self.outcome = outcome; self.confirmed = confirmed
        self.summary = try WebsiteLearningSafety.text(summary, max: 512)
        guard WebsiteLearningSafety.validDate(completedAt) else { throw WebsiteLearningError.invalidEvidence }
        self.completedAt = completedAt
    }
    private enum CodingKeys: String, CodingKey { case outcome, confirmed, summary, completedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(outcome: c.decode(WebTaskOutcome.self, forKey: .outcome),
                      confirmed: c.decode(Bool.self, forKey: .confirmed),
                      summary: c.decode(String.self, forKey: .summary),
                      completedAt: c.decode(Date.self, forKey: .completedAt))
    }
    var hashFields: [String] { [outcome.rawValue, String(confirmed), summary, WebsiteLearningSafety.dateKey(completedAt)] }
}

public enum WebsiteLessonStatus: String, Codable, Sendable { case pending, approved }
public enum WebsiteLessonSource: String, Codable, Sendable { case manual, judgedTask }

public struct WebsiteLesson: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let text: String
    public let evidence: WebsiteLessonEvidence
    public let source: WebsiteLessonSource
    public let status: WebsiteLessonStatus
    public let task: WebTaskEvidence?
    public let createdAt: Date
    public let updatedAt: Date
    public var origin: WebsiteOrigin { evidence.origin }
    public var contentHash: String {
        WebsiteLearningSafety.fingerprint([id.uuidString, text, source.rawValue, status.rawValue,
            WebsiteLearningSafety.dateKey(createdAt), WebsiteLearningSafety.dateKey(updatedAt)]
            + evidence.hashFields + (task?.hashFields ?? []))
    }

    init(id: UUID = UUID(), text: String, evidence: WebsiteLessonEvidence, source: WebsiteLessonSource,
         status: WebsiteLessonStatus, task: WebTaskEvidence?, createdAt: Date, updatedAt: Date) throws {
        self.id = id; self.text = try WebsiteLearningSafety.text(text, max: 1500)
        self.evidence = evidence; self.source = source; self.status = status; self.task = task
        self.createdAt = createdAt; self.updatedAt = updatedAt
        guard WebsiteLearningSafety.validDate(createdAt), WebsiteLearningSafety.validDate(updatedAt),
              createdAt <= updatedAt, evidence.capturedAt <= updatedAt else { throw WebsiteLearningError.invalidState }
        if source == .judgedTask {
            guard let task = task, task.isEligible, evidence.capturedAt <= task.completedAt,
                  task.completedAt <= updatedAt else { throw WebsiteLearningError.ineligibleTask }
        } else if task != nil { throw WebsiteLearningError.invalidState }
    }
    private enum CodingKeys: String, CodingKey { case id, text, evidence, source, status, task, createdAt, updatedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: c.decode(UUID.self, forKey: .id), text: c.decode(String.self, forKey: .text),
                      evidence: c.decode(WebsiteLessonEvidence.self, forKey: .evidence),
                      source: c.decode(WebsiteLessonSource.self, forKey: .source),
                      status: c.decode(WebsiteLessonStatus.self, forKey: .status),
                      task: c.decodeIfPresent(WebTaskEvidence.self, forKey: .task),
                      createdAt: c.decode(Date.self, forKey: .createdAt), updatedAt: c.decode(Date.self, forKey: .updatedAt))
    }
}

public enum WebsiteRevisionReason: String, Codable, Sendable { case edit, approve, delete, restore }
public struct WebsiteKnowledgeRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let lesson: WebsiteLesson
    public let reason: WebsiteRevisionReason
    public let archivedAt: Date
    public var contentHash: String { lesson.contentHash }

    init(lesson: WebsiteLesson, reason: WebsiteRevisionReason, archivedAt: Date) {
        id = UUID(); self.lesson = lesson; self.reason = reason; self.archivedAt = archivedAt
    }
    private enum CodingKeys: String, CodingKey { case id, lesson, reason, archivedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); lesson = try c.decode(WebsiteLesson.self, forKey: .lesson)
        reason = try c.decode(WebsiteRevisionReason.self, forKey: .reason)
        archivedAt = try c.decode(Date.self, forKey: .archivedAt)
        guard WebsiteLearningSafety.validDate(archivedAt), archivedAt >= lesson.updatedAt else {
            throw WebsiteLearningError.invalidState
        }
    }
}
