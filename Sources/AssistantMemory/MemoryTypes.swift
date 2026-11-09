import Foundation
import AssistantModels

// Behavioral reference: wangzan101/Mika, commit 0c172724f3f0c96f7345262588072f6e95db1138,
// core/memory. This Swift implementation and its extraction prompt are independently written.
public enum MemoryKind: String, Codable, Sendable { case fact, preference, procedure }
public enum MemoryStatus: String, Codable, Sendable { case active, pending }
public enum MemoryNoteKind: String, Codable, Sendable { case added, updated, forgot, pending }

public struct MemoryPreferences: Codable, Equatable, Sendable {
    public var useMemory: Bool
    public var autoRemember: Bool
    public var learnSkills: Bool
    public init(useMemory: Bool = true, autoRemember: Bool = true, learnSkills: Bool = true) {
        self.useMemory = useMemory
        self.autoRemember = autoRemember
        self.learnSkills = learnSkills
    }
}

public struct MemorySource: Codable, Equatable, Sendable {
    public let type: String
    public let quote: String?
    public let conversationID: String?
    public let at: Date

    public init(type: String, quote: String? = nil, conversationID: String? = nil, at: Date) {
        self.type = type; self.quote = quote; self.conversationID = conversationID; self.at = at
    }
}

public struct MemoryItem: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let kind: MemoryKind
    public let content: String
    public let keywords: [String]
    public let source: MemorySource
    public let status: MemoryStatus
    public let pinned: Bool
    public let createdAt: Date
    public let updatedAt: Date
    public let lastUsedAt: Date?
    public let useCount: Int
    public let replaces: String?

    func changing(content: String? = nil, keywords: [String]? = nil, source: MemorySource? = nil,
                  status: MemoryStatus? = nil, pinned: Bool? = nil, updatedAt: Date? = nil,
                  lastUsedAt: Date? = nil, useCount: Int? = nil, replaces: String? = nil) -> MemoryItem {
        MemoryItem(id: id, kind: kind, content: content ?? self.content, keywords: keywords ?? self.keywords,
                   source: source ?? self.source, status: status ?? self.status, pinned: pinned ?? self.pinned,
                   createdAt: createdAt, updatedAt: updatedAt ?? self.updatedAt,
                   lastUsedAt: lastUsedAt ?? self.lastUsedAt, useCount: useCount ?? self.useCount,
                   replaces: replaces ?? self.replaces)
    }
}

public struct MemoryNote: Codable, Equatable, Sendable {
    public let kind: MemoryNoteKind
    public let memoryID: UUID
    public let undoToken: UUID?
    public let pendingID: UUID?
}

public struct MemoryContext: Sendable {
    public let message: ModelMessage?
    public let usedIDs: [UUID]
    public let revision: UUID
}

public struct MemoryExtractionInput: Sendable {
    public let utterances: [String]
    public let conversationID: String?
    public let succeeded: Bool
    public let readExternalContent: Bool

    /// Supply only the user's own statements, never quoted web/MCP/assistant output.
    public init(utterances: [String], conversationID: String? = nil, succeeded: Bool = true,
                readExternalContent: Bool = false) {
        self.utterances = utterances; self.conversationID = conversationID
        self.succeeded = succeeded; self.readExternalContent = readExternalContent
    }
}

public struct MemoryExtractionPlan: Sendable {
    public let baseRevision: UUID
    public var operationCount: Int { operations.count }
    let conversationID: String?
    let operations: [MemoryOperation]
}

enum MemoryOperation: Sendable {
    case add(MemoryKind, String, [String], String)
    case update(UUID, String, [String]?, String)
    case forget(UUID)
}

public enum MemoryError: Error, LocalizedError, Sendable, Equatable {
    case invalidContent, invalidKeywords, sensitiveContent, capacityExceeded, duplicate
    case notFound, notPending, invalidState, stalePlan, disabled
    case invalidExtraction, extractionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidContent: return "Memory must contain 1–200 UTF-16 characters."
        case .invalidKeywords: return "Memory keywords exceed their limits."
        case .sensitiveContent: return "Sensitive information cannot be stored as memory."
        case .capacityExceeded: return "Memory has reached its 500-item limit."
        case .duplicate: return "An identical memory already exists."
        case .notFound: return "The memory no longer exists."
        case .notPending: return "The memory is not awaiting approval."
        case .invalidState: return "The memory snapshot is invalid."
        case .stalePlan: return "Memory changed while extraction was running; the proposal was discarded."
        case .disabled: return "Automatic memory updates are disabled."
        case .invalidExtraction: return "The memory extraction response was invalid."
        case .extractionFailed: return "Memory extraction did not complete."
        }
    }
}
