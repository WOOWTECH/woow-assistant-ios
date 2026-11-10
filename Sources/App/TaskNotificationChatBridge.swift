import Combine
import Foundation
import AssistantDomain

/// Own one bridge for the root ChatSession's lifetime. No content retained by subscribers.
@MainActor final class TaskNotificationChatBridge {
    private var subscriptions = Set<AnyCancellable>()
    private let observer: TaskNotificationChatObserver

    init(session: ChatSession, service: TaskNotificationService) {
        observer = TaskNotificationChatObserver(service: service,
            initial: Self.project(session.entries), isSubmitting: session.isSubmitting)
        session.$entries.dropFirst().map(Self.project).sink { [weak observer] in
            observer?.entriesChanged($0)
        }.store(in: &subscriptions)
        session.$isSubmitting.dropFirst().sink { [weak observer] in
            observer?.submittingChanged($0)
        }.store(in: &subscriptions)
        session.$pendingMCPApproval.dropFirst().map { $0?.id }.sink { [weak observer] in
            observer?.approvalChanged($0, source: .mcp)
        }.store(in: &subscriptions)
        session.$pendingProfileReview.dropFirst().map { $0?.id }.sink { [weak observer] in
            observer?.approvalChanged($0, source: .profile)
        }.store(in: &subscriptions)
        session.$pendingMemoryReview.dropFirst().map { $0?.id }.sink { [weak observer] in
            observer?.approvalChanged($0, source: .memory)
        }.store(in: &subscriptions)
    }

    private static func project(_ entries: [ChatEntry]) -> TaskNotificationChatSnapshot {
        TaskNotificationChatSnapshot(entryCount: entries.count, lastAssistantID: entries.last { $0.role == "assistant" }?.id)
    }
    func invalidate() { subscriptions.removeAll(); observer.reset() }
}
