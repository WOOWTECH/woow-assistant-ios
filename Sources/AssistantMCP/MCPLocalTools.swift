import Foundation

/// Host-owned actions, never entries in the remote MCP catalog. A remote
/// call_tool with the same name still addresses the selected remote server.
public enum MCPLocalAction: String, Sendable {
    case profileEdit = "profile_edit"
    case memorySearch = "memory_search"
    case memorySave = "memory_save"
    case memoryEdit = "memory_edit"

    public var isMutation: Bool { self != .memorySearch }
}

/// Immutable data, not authorization. The host grounds it against the actual
/// current utterance captured before the run, never a catalog/result/history.
public struct MCPLocalProposal: Identifiable, Sendable {
    public let id: UUID
    public let action: MCPLocalAction
    /// Exact original JSON bytes, including nested duplicate keys. Do not
    /// decode/re-encode before the profile/memory argument validator sees them.
    public let argumentsJSON: String

    init(action: MCPLocalAction, argumentsJSON: String) {
        id = UUID(); self.action = action; self.argumentsJSON = argumentsJSON
    }
}

/// Only the trusted host may supply these results, after its real search or
/// successful encrypted commit. Never return a committed receipt on write error.
public enum MCPLocalOutcome: Sendable {
    case searchResult(json: String)
    case committedReceipt(json: String)
    case declined
}

public typealias MCPLocalHandler = @Sendable (MCPLocalProposal, MCPLocalLease) async throws -> MCPLocalOutcome

/// Liveness only, never user consent. After native approval, the host MUST call
/// check(), recheck its request/review IDs, master switch, generation and revision,
/// then persist synchronously without another await. The host owns dismissal and
/// resumption of its pending approval continuation when the run ends.
/// A receipt already durably committed must survive a later timeout/disconnect.
public struct MCPLocalLease: Sendable {
    private let deadline: ContinuousClock.Instant
    private let isRunFinished: @Sendable () -> Bool
    private let state = MCPLocalLeaseState()

    init(deadline: ContinuousClock.Instant, isRunFinished: @escaping @Sendable () -> Bool) {
        self.deadline = deadline; self.isRunFinished = isRunFinished
    }

    public func check() throws {
        try Task.checkCancellation()
        guard ContinuousClock.now < deadline else { throw MCPConversationError.timedOut }
        guard !isRunFinished() else { throw CancellationError() }
        guard state.isActive else { throw MCPConversationError.localLeaseExpired }
    }

    // Retained copies expire as soon as this one callback returns or throws,
    // even if remote steps continue within the same conversation.
    func invalidate() { state.invalidate() }
}

private final class MCPLocalLeaseState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = true
    var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    func invalidate() { lock.lock(); active = false; lock.unlock() }
}
