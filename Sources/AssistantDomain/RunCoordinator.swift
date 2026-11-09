import AssistantContracts
import Foundation

public enum RunCoordinatorError: Error, Equatable {
    case alreadyRunning
    case missingRun
    case invalidTransition(from: RunPhase, to: RunPhase)
}

public actor RunCoordinator {
    private var phases: [UUID: RunPhase] = [:]
    private var events: [UUID: [RunEvent]] = [:]

    public init() {}

    @discardableResult
    public func start(runID: UUID = UUID()) throws -> UUID {
        // IDs remain reserved after termination so retries cannot overwrite history.
        guard phases[runID] == nil else { throw RunCoordinatorError.alreadyRunning }
        phases[runID] = .running
        events[runID] = [
            RunEvent(runID: runID, sequence: 0, kind: .started, summary: "Run started", phase: .running)
        ]
        return runID
    }

    public func phase(for runID: UUID) -> RunPhase? {
        phases[runID]
    }

    public func history(for runID: UUID) -> [RunEvent] {
        events[runID, default: []]
    }

    public func transition(_ runID: UUID, to next: RunPhase, summary: String) throws {
        guard let current = phases[runID] else { throw RunCoordinatorError.missingRun }
        guard Self.isAllowed(current, next) else {
            throw RunCoordinatorError.invalidTransition(from: current, to: next)
        }

        phases[runID] = next
        let eventKind: RunEventKind
        switch next {
        case .completed:
            eventKind = .completed
        case .cancelled:
            eventKind = .cancelled
        case .failed:
            eventKind = .failed
        case .waitingForApproval:
            eventKind = .approvalRequested
        case .queued, .running, .waitingForDeviceForeground:
            eventKind = .stateChanged
        }
        let sequence = events[runID, default: []].count
        events[runID, default: []].append(
            RunEvent(
                runID: runID,
                sequence: sequence,
                kind: eventKind,
                summary: summary,
                previousPhase: current,
                phase: next
            )
        )
    }

    private static func isAllowed(_ current: RunPhase, _ next: RunPhase) -> Bool {
        switch (current, next) {
        case (.queued, .running),
             (.running, .waitingForApproval),
             (.running, .waitingForDeviceForeground),
             (.running, .completed),
             (.running, .cancelled),
             (.running, .failed),
             (.waitingForApproval, .running),
             (.waitingForApproval, .cancelled),
             (.waitingForApproval, .failed),
             (.waitingForDeviceForeground, .running),
             (.waitingForDeviceForeground, .cancelled),
             (.waitingForDeviceForeground, .failed):
            return true
        default:
            return false
        }
    }
}
