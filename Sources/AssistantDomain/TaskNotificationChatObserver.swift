import Foundation

/// The projection contains no content or tool arguments, even transiently.
public struct TaskNotificationChatSnapshot: Equatable, Sendable {
    public let entryCount: Int
    public let lastAssistantID: UUID?
    public init(entryCount: Int, lastAssistantID: UUID?) {
        self.entryCount = entryCount; self.lastAssistantID = lastAssistantID
    }
}

public enum TaskNotificationApprovalSource: Hashable { case mcp, profile, memory }

/// Observes ChatSession's actual publication order: submitting -> optional approvals ->
/// appended assistant -> submitting false. Failure/cancel never append an assistant.
/// Published callbacks must be forwarded synchronously on MainActor, without receive(on:).
@MainActor public final class TaskNotificationChatObserver {
    private let service: TaskNotificationService
    private let now: () -> Date
    private var previous: TaskNotificationChatSnapshot
    private var submitting: Bool
    private var ticket: TaskNotificationTicket?
    private var deadline: Date?
    private var approval: (source: TaskNotificationApprovalSource, id: UUID)?

    public init(service: TaskNotificationService, initial: TaskNotificationChatSnapshot,
                isSubmitting: Bool, now: @escaping () -> Date = Date.init) {
        self.service = service; previous = initial; submitting = isSubmitting; self.now = now
        // An already running task at bind time is deliberately not adopted/replayed.
    }

    public func submittingChanged(_ value: Bool) {
        guard value != submitting else { return }
        submitting = value
        if value {
            let end = now().addingTimeInterval(180)
            deadline = end; ticket = service.begin(destination: .chat, deadline: end)
        } else {
            if let ticket { service.receive(.cancelled, for: ticket) }
            ticket = nil; deadline = nil; approval = nil
        }
    }

    public func entriesChanged(_ snapshot: TaskNotificationChatSnapshot) {
        let old = previous; previous = snapshot
        // Includes newConversation, successful removeSettings and changed model settings.
        if snapshot.entryCount == 0 || snapshot.entryCount < old.entryCount {
            reset(); return
        }
        guard submitting, let ticket, snapshot.entryCount > old.entryCount,
              snapshot.lastAssistantID != nil, snapshot.lastAssistantID != old.lastAssistantID else { return }
        // Approval must already have resolved. Do not turn an impossible publication into success.
        guard approval == nil else { return }
        service.receive(.completed, for: ticket)
        self.ticket = nil; deadline = nil
    }

    public func approvalChanged(_ id: UUID?, source: TaskNotificationApprovalSource) {
        guard submitting, let ticket else { return }
        if let existing = approval, existing.source == source, existing.id != id {
            service.receive(.approvalResolved(id: existing.id), for: ticket); approval = nil
        }
        if let id, approval == nil, let deadline {
            approval = (source, id)
            service.receive(.requiresApproval(id: id, expiresAt: deadline), for: ticket)
        }
    }

    public func reset() {
        ticket = nil; deadline = nil; approval = nil
        service.clear(destination: .chat)
    }
}
