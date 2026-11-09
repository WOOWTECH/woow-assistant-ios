import AssistantContracts
@testable import AssistantDomain
import Foundation
import XCTest

final class RunCoordinatorTests: XCTestCase {
    func testNewRunStartsAndCompletes() async throws {
        let coordinator = RunCoordinator()
        let runID = try await coordinator.start()

        let runningPhase = await coordinator.phase(for: runID)
        XCTAssertEqual(runningPhase, .running)
        try await coordinator.transition(runID, to: .completed, summary: "Finished")

        let completedPhase = await coordinator.phase(for: runID)
        let history = await coordinator.history(for: runID)
        XCTAssertEqual(completedPhase, .completed)
        XCTAssertEqual(history.map(\.kind), [.started, .completed])
        XCTAssertEqual(history.map(\.sequence), [0, 1])
        XCTAssertEqual(history.map(\.phase), [.running, .completed])
        XCTAssertNil(history.first?.previousPhase)
        XCTAssertEqual(history.last?.previousPhase, .running)
        XCTAssertEqual(history.last?.summary, "Finished")
    }

    func testWaitingStatesResumeWithExplicitStateEventsAndMonotonicSequence() async throws {
        let coordinator = RunCoordinator()
        let runID = try await coordinator.start()
        let phases: [RunPhase] = [
            .running, .waitingForApproval, .running,
            .waitingForDeviceForeground, .running, .completed
        ]

        for phase in phases.dropFirst() {
            try await coordinator.transition(runID, to: phase, summary: phase.rawValue)
            let actual = await coordinator.phase(for: runID)
            XCTAssertEqual(actual, phase)
        }

        let history = await coordinator.history(for: runID)
        XCTAssertEqual(history.map(\.sequence), Array(phases.indices))
        XCTAssertEqual(history.map(\.kind), [
            .started, .approvalRequested, .stateChanged,
            .stateChanged, .stateChanged, .completed
        ])
        XCTAssertEqual(history.map(\.phase), phases.map { Optional($0) })
        XCTAssertEqual(history.dropFirst().map(\.previousPhase), phases.dropLast().map { Optional($0) })
        XCTAssertEqual(history.dropFirst().map(\.summary), phases.dropFirst().map(\.rawValue))
        XCTAssertEqual(Set(history.map(\.id)).count, history.count)
        XCTAssertTrue(history.allSatisfy { $0.runID == runID })
        XCTAssertFalse(history.contains { $0.kind == .messageDelta })
    }

    func testDuplicateStartCannotOverwriteAnyExistingRun() async throws {
        for phase in RunPhase.allCases where phase != .queued {
            let coordinator = RunCoordinator()
            let runID = UUID()
            let startedID = try await coordinator.start(runID: runID)
            XCTAssertEqual(startedID, runID)
            if phase != .running {
                try await coordinator.transition(runID, to: phase, summary: "Initial state")
            }
            let before = await coordinator.history(for: runID)

            await assertCoordinatorError(.alreadyRunning) {
                _ = try await coordinator.start(runID: runID)
            }

            let actual = await coordinator.phase(for: runID)
            let after = await coordinator.history(for: runID)
            XCTAssertEqual(actual, phase)
            XCTAssertEqual(after, before)
        }
    }

    func testConcurrentDuplicateStartsAcceptExactlyOne() async throws {
        let coordinator = RunCoordinator()
        let runID = UUID()
        let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    do {
                        try await coordinator.start(runID: runID)
                        return true
                    } catch RunCoordinatorError.alreadyRunning {
                        return false
                    }
                }
            }
            var successes = 0
            for try await started in group where started {
                successes += 1
            }
            return successes
        }

        let history = await coordinator.history(for: runID)
        let phase = await coordinator.phase(for: runID)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(phase, .running)
        XCTAssertEqual(history.map(\.sequence), [0])
        XCTAssertEqual(history.map(\.kind), [.started])
    }

    func testMissingRunRejectsTransitionsWithoutCreatingHistory() async {
        let coordinator = RunCoordinator()
        let runID = UUID()

        for phase in RunPhase.allCases {
            await assertCoordinatorError(.missingRun) {
                try await coordinator.transition(runID, to: phase, summary: "Unknown run")
            }
        }

        let phase = await coordinator.phase(for: runID)
        let history = await coordinator.history(for: runID)
        XCTAssertNil(phase)
        XCTAssertTrue(history.isEmpty)
    }

    func testCancellationWorksFromRunningAndEachWaitingState() async throws {
        for phase in activePhases {
            let coordinator = RunCoordinator()
            let runID = try await coordinator.start()
            if phase != .running {
                try await coordinator.transition(runID, to: phase, summary: "Waiting")
            }
            try await coordinator.transition(runID, to: .cancelled, summary: "User cancelled")

            let actual = await coordinator.phase(for: runID)
            let history = await coordinator.history(for: runID)
            XCTAssertEqual(actual, .cancelled)
            XCTAssertEqual(history.last?.kind, .cancelled)
            XCTAssertEqual(history.last?.previousPhase, phase)
            XCTAssertEqual(history.last?.phase, .cancelled)
            XCTAssertEqual(history.last?.summary, "User cancelled")
            XCTAssertEqual(history.map(\.sequence), Array(history.indices))
        }
    }

    func testFailureWorksFromRunningAndEachWaitingState() async throws {
        for phase in activePhases {
            let coordinator = RunCoordinator()
            let runID = try await coordinator.start()
            if phase != .running {
                try await coordinator.transition(runID, to: phase, summary: "Waiting")
            }
            try await coordinator.transition(runID, to: .failed, summary: "Execution unavailable")

            let actual = await coordinator.phase(for: runID)
            let history = await coordinator.history(for: runID)
            XCTAssertEqual(actual, .failed)
            XCTAssertEqual(history.last?.kind, .failed)
            XCTAssertEqual(history.last?.previousPhase, phase)
            XCTAssertEqual(history.last?.phase, .failed)
        }
    }

    func testEveryTerminalStateRejectsEveryFurtherTransition() async throws {
        for terminal in [RunPhase.completed, .cancelled, .failed] {
            let coordinator = RunCoordinator()
            let runID = try await coordinator.start()
            try await coordinator.transition(runID, to: terminal, summary: "Terminal")

            for next in RunPhase.allCases {
                await assertRejectedTransition(coordinator, runID: runID, from: terminal, to: next)
            }
        }
    }

    func testWaitingMustResumeBeforeCompletingOrChangingWaitingReason() async throws {
        for phase in [RunPhase.waitingForApproval, .waitingForDeviceForeground] {
            let coordinator = RunCoordinator()
            let runID = try await coordinator.start()
            try await coordinator.transition(runID, to: phase, summary: "Waiting")
            let other: RunPhase = phase == .waitingForApproval
                ? .waitingForDeviceForeground : .waitingForApproval

            for next in [RunPhase.completed, other] {
                await assertRejectedTransition(coordinator, runID: runID, from: phase, to: next)
            }

            try await coordinator.transition(runID, to: .running, summary: "Resumed")
            try await coordinator.transition(runID, to: .completed, summary: "Finished")
            let history = await coordinator.history(for: runID)
            XCTAssertEqual(history.map(\.sequence), [0, 1, 2, 3])
        }
    }

    func testActiveStatesRejectSelfTransitionsAndRequeuing() async throws {
        for phase in activePhases {
            let coordinator = RunCoordinator()
            let runID = try await coordinator.start()
            if phase != .running {
                try await coordinator.transition(runID, to: phase, summary: "Waiting")
            }

            for next in [phase, .queued] {
                await assertRejectedTransition(coordinator, runID: runID, from: phase, to: next)
            }
        }
    }

    func testConcurrentTerminalTransitionsAcceptExactlyOne() async throws {
        let coordinator = RunCoordinator()
        let runID = try await coordinator.start()
        let successes = try await withThrowingTaskGroup(of: Bool.self) { group in
            for terminal in [RunPhase.completed, .cancelled, .failed] {
                group.addTask {
                    do {
                        try await coordinator.transition(runID, to: terminal, summary: terminal.rawValue)
                        return true
                    } catch RunCoordinatorError.invalidTransition {
                        return false
                    }
                }
            }
            var successes = 0
            for try await accepted in group where accepted {
                successes += 1
            }
            return successes
        }

        let phase = await coordinator.phase(for: runID)
        let history = await coordinator.history(for: runID)
        XCTAssertEqual(successes, 1)
        XCTAssertEqual(history.map(\.sequence), [0, 1])
        XCTAssertEqual(history.last?.previousPhase, .running)
        XCTAssertEqual(history.last?.phase, phase)
        XCTAssertTrue([RunPhase.completed, .cancelled, .failed].contains { $0 == phase })
    }

    func testRunsKeepIndependentStateAndSequences() async throws {
        let coordinator = RunCoordinator()
        let first = try await coordinator.start()
        let second = try await coordinator.start()
        try await coordinator.transition(first, to: .cancelled, summary: "Cancelled first")
        let firstHistory = await coordinator.history(for: first)
        try await coordinator.transition(second, to: .waitingForApproval, summary: "Waiting second")
        try await coordinator.transition(second, to: .running, summary: "Resumed second")
        try await coordinator.transition(second, to: .completed, summary: "Finished second")

        let finalFirstHistory = await coordinator.history(for: first)
        let secondHistory = await coordinator.history(for: second)
        let firstPhase = await coordinator.phase(for: first)
        let secondPhase = await coordinator.phase(for: second)
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(firstPhase, .cancelled)
        XCTAssertEqual(secondPhase, .completed)
        XCTAssertEqual(finalFirstHistory, firstHistory)
        XCTAssertEqual(firstHistory.map(\.sequence), [0, 1])
        XCTAssertEqual(secondHistory.map(\.sequence), [0, 1, 2, 3])
        XCTAssertTrue(firstHistory.allSatisfy { $0.runID == first })
        XCTAssertTrue(secondHistory.allSatisfy { $0.runID == second })
    }

    func testStateChangedEventCodableRoundTrip() throws {
        let event = RunEvent(
            runID: UUID(),
            sequence: 7,
            kind: .stateChanged,
            summary: "Back in foreground",
            previousPhase: .waitingForDeviceForeground,
            phase: .running,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(RunEvent.self, from: data)

        XCTAssertEqual(decoded, event)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["kind"] as? String, "stateChanged")
        XCTAssertEqual(object["previousPhase"] as? String, "waitingForDeviceForeground")
        XCTAssertEqual(object["phase"] as? String, "running")
    }

    func testLegacyEventWithoutStateMetadataStillDecodes() throws {
        let data = Data("""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "runID": "00000000-0000-0000-0000-000000000002",
            "sequence": 0,
            "kind": "started",
            "summary": "Run started",
            "createdAt": 0
        }
        """.utf8)
        let event = try JSONDecoder().decode(RunEvent.self, from: data)

        XCTAssertEqual(event.kind, .started)
        XCTAssertEqual(event.sequence, 0)
        XCTAssertNil(event.previousPhase)
        XCTAssertNil(event.phase)
    }

    private var activePhases: [RunPhase] {
        [.running, .waitingForApproval, .waitingForDeviceForeground]
    }

    private func assertRejectedTransition(
        _ coordinator: RunCoordinator,
        runID: UUID,
        from current: RunPhase,
        to next: RunPhase,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let before = await coordinator.history(for: runID)

        await assertCoordinatorError(.invalidTransition(from: current, to: next), file: file, line: line) {
            try await coordinator.transition(runID, to: next, summary: "Rejected")
        }

        let actual = await coordinator.phase(for: runID)
        let after = await coordinator.history(for: runID)
        XCTAssertEqual(actual, current, file: file, line: line)
        XCTAssertEqual(after, before, file: file, line: line)
    }
}

private func assertCoordinatorError(
    _ expected: RunCoordinatorError,
    file: StaticString = #filePath,
    line: UInt = #line,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        XCTFail("Expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? RunCoordinatorError, expected, file: file, line: line)
    }
}
