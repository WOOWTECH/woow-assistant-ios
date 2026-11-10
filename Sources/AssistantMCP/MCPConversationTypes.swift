import Foundation

/// A trusted host executor, bound to the same connection as the selected catalog.
/// Calls arrive only after approval. An error/cancellation cannot promise remote
/// rollback; implementations must not automatically retry or switch connections.
public protocol MCPConversationExecuting: Sendable {
    func callAuthorizedTool(name: String, arguments: JSONValue) async throws -> JSONValue
    func readResource(uri: String) async throws -> JSONValue
}

extension MCPClient: MCPConversationExecuting {}

public enum MCPConversationAction: Codable, Equatable, Sendable {
    case callTool(name: String, arguments: JSONValue)
    case readResource(uri: String)
}

/// Value snapshot: approval returns a Bool, never replacement arguments.
/// UI must display the full action, not an abbreviated summary of its arguments.
public struct MCPConversationProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let action: MCPConversationAction

    public init(id: UUID = UUID(), action: MCPConversationAction) {
        self.id = id; self.action = action
    }
}

public struct MCPConversationStep: Equatable, Sendable {
    public let proposal: MCPConversationProposal
    /// Exact bounded server result, including content/structuredContent/isError.
    public let result: JSONValue
    public let isError: Bool
}

public enum MCPConversationEvent: Sendable, Equatable {
    case requestingModel(Int)
    /// One bounded format correction for this conversation; no operation was
    /// accepted from the invalid response. Contains no model-generated content.
    case correctingCommand
    case awaitingApproval(MCPConversationProposal)
    /// Dispatch intent, emitted before entering the executor; not proof that the
    /// server received anything. Cancellation may still prevent dispatch. Once
    /// entered, a call may reach the server without producing a completed event.
    case executing(MCPConversationProposal)
    case completed(MCPConversationStep)
}

public enum MCPConversationStopReason: String, Codable, Sendable {
    case finished, approvalDenied, modelCallLimit, toolCallLimit, repeatedCall, toolError
    case localCallLimit
}

public struct MCPConversationResult: Sendable {
    /// Present only when a valid finish command is received. Limits/refusal/tool
    /// errors never synthesize a successful model answer.
    public let answer: String?
    public let steps: [MCPConversationStep]
    public let modelCallCount: Int
    public let stopReason: MCPConversationStopReason
}

public struct MCPConversationLimits: Sendable {
    public let maximumModelCalls: Int
    /// Includes explicitly selected resource reads as well as tool calls.
    public let maximumToolCalls: Int
    public let timeout: Duration

    public init(maximumModelCalls: Int = 12, maximumToolCalls: Int = 6,
                timeout: Duration = .seconds(180)) {
        self.maximumModelCalls = maximumModelCalls
        self.maximumToolCalls = maximumToolCalls
        self.timeout = timeout
    }
}

/// Fixed categories only: never embed credentials, catalog, arguments, server
/// output or an underlying localizedDescription in a thrown error.
public enum MCPConversationError: String, Error, Sendable, Equatable, LocalizedError {
    case invalidInput, invalidCatalog, invalidLimits, invalidCommand, unknownTool, unknownResource
    case inputTooLarge, modelResponseTooLarge, outputTooLarge, invalidExecutionResult
    case modelFailed, approvalFailed, executionFailed, timedOut
    case localUnavailable, invalidLocalResult, localLeaseExpired
    /// Provider request failures are distinct from the whole-conversation deadline.
    /// HTTP status numbers, bodies and underlying error descriptions are discarded.
    case modelTimedOut, modelTransportFailed, modelHTTPRejected, modelInvalidResponse, modelIncompleteResponse
    case modelAuthenticationRejected, modelRateLimited, modelServiceUnavailable, modelRequestRejected

    public var errorDescription: String? { "MCP conversation stopped: \(rawValue)." }
}
