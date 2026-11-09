import Foundation

public enum MessageRole: String, Codable, Sendable, CaseIterable {
    case user
    case assistant
    case tool
}

public struct ConversationMessage: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let conversationID: UUID
    public let role: MessageRole
    public let text: String
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        conversationID: UUID,
        role: MessageRole,
        text: String,
        createdAt: Date = .now
    ) {
        self.id = id
        self.conversationID = conversationID
        self.role = role
        self.text = text
        self.createdAt = createdAt
    }
}

public enum RunPhase: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waitingForApproval
    case waitingForDeviceForeground
    case completed
    case cancelled
    case failed
}

public enum RunEventKind: String, Codable, Sendable, CaseIterable {
    case started
    case stateChanged
    case messageDelta
    case toolRequested
    case approvalRequested
    case completed
    case cancelled
    case failed
}

public struct RunEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let sequence: Int
    public let kind: RunEventKind
    public let summary: String
    /// State metadata is absent on older events and events that do not change state.
    public let previousPhase: RunPhase?
    public let phase: RunPhase?
    public let createdAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        sequence: Int,
        kind: RunEventKind,
        summary: String,
        previousPhase: RunPhase? = nil,
        phase: RunPhase? = nil,
        createdAt: Date = .now
    ) {
        self.id = id
        self.runID = runID
        self.sequence = sequence
        self.kind = kind
        self.summary = summary
        self.previousPhase = previousPhase
        self.phase = phase
        self.createdAt = createdAt
    }
}

public enum ApprovalRisk: String, Codable, Sendable, CaseIterable {
    case localRead
    case publicRead
    case privateRead
    case sandboxedDraft
    case externalWrite
    case destructiveOrPayment
}

public struct ApprovalRequest: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let runID: UUID
    public let toolCallID: String
    public let risk: ApprovalRisk
    public let summary: String
    public let expiresAt: Date

    public init(
        id: UUID = UUID(),
        runID: UUID,
        toolCallID: String,
        risk: ApprovalRisk,
        summary: String,
        expiresAt: Date
    ) {
        self.id = id
        self.runID = runID
        self.toolCallID = toolCallID
        self.risk = risk
        self.summary = summary
        self.expiresAt = expiresAt
    }
}
