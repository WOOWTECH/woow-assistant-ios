import Foundation
@testable import AssistantDomain
#if !TASK_NOTIFICATIONS_STANDALONE
import XCTest
#endif

@MainActor final class TaskNotificationGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async { if !released { await withCheckedContinuation { waiters.append($0) } } }
    func release() { released = true; let waiting = waiters; waiters = []; waiting.forEach { $0.resume() } }
}

@MainActor final class TaskNotificationFakeCenter: TaskNotificationClient {
    var value = TaskNotificationSettings(authorization: .authorized, sound: .enabled, alert: .enabled)
    var grant = true
    var failAuthorization = false
    var failAdd = false
    var permissionGate: TaskNotificationGate?
    var addGate: TaskNotificationGate?
    var settingsGate: TaskNotificationGate?
    var permissionCalls = 0
    var addCalls = 0
    var settingsCalls = 0
    var clearCalls = 0
    var pending: [String: TaskNotificationPayload] = [:]
    var delivered: [String: TaskNotificationPayload] = [:]
    var additions: [(payload: TaskNotificationPayload, sound: Bool)] = []
    enum Failure: Error { case synthetic }
    func settings() async -> TaskNotificationSettings {
        settingsCalls += 1
        let result = value
        if let gate = settingsGate { settingsGate = nil; await gate.wait() }
        return result
    }
    func requestAuthorization() async throws {
        permissionCalls += 1
        if let gate = permissionGate { await gate.wait() }
        if failAuthorization { throw Failure.synthetic }
        value = TaskNotificationSettings(authorization: grant ? .authorized : .denied, sound: grant ? .enabled : .disabled, alert: grant ? .enabled : .disabled)
    }
    func add(_ payload: TaskNotificationPayload, sound: Bool) async throws {
        addCalls += 1
        if let gate = addGate { await gate.wait() }
        if failAdd { throw Failure.synthetic }
        additions.append((payload, sound)); pending[payload.identifier] = payload
    }
    func remove(identifiers: [String]) async {
        for identifier in identifiers { pending.removeValue(forKey: identifier); delivered.removeValue(forKey: identifier) }
    }
    func removeAllOwned() async {
        clearCalls += 1
        await remove(identifiers: Array(Set(pending.keys).union(delivered.keys)).filter { $0.hasPrefix(TaskNotificationPayload.identifierPrefix) })
    }
    func deliver() { delivered.merge(pending) { _, next in next }; pending = [:] }
}

@MainActor enum TaskNotificationChecks {
    struct Failure: Error { let check: String }
    static var assertions = 0
    static func expect(_ value: @autoclosure () -> Bool, _ check: String) throws {
        guard value() else { throw Failure(check: check) }; assertions += 1
    }
    static func until(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while !condition() {
            guard Date() < deadline else { throw Failure(check: "bounded async state reached") }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
    }
    static func begin(_ service: TaskNotificationService, now: Date = Date()) throws -> TaskNotificationTicket {
        guard let ticket = service.begin(destination: .chat, deadline: now.addingTimeInterval(180)) else { throw Failure(check: "valid ticket") }
        return ticket
    }
    static func active(_ center: TaskNotificationFakeCenter) async -> TaskNotificationService {
        let service = TaskNotificationService(client: center, enabled: true)
        await service.refresh(); return service
    }

    static func defaultOffAndPermission() async throws {
        let center = TaskNotificationFakeCenter()
        center.value = TaskNotificationSettings(authorization: .notDetermined)
        var saved: [Bool] = []
        let service = TaskNotificationService(client: center, persistEnabled: { saved.append($0) })
        await service.refresh()
        try expect(!service.enabled && center.permissionCalls == 0, "launch is off and never prompts")
        let ticket = try begin(service); service.receive(.completed, for: ticket)
        await service.waitUntilIdle()
        try expect(center.addCalls == 0 && center.permissionCalls == 0, "events cannot enable or prompt")
        await service.enableFromUserGesture()
        try expect(service.enabled && center.permissionCalls == 1 && saved == [true], "explicit click prompts and persists")
        try expect(center.addCalls == 0, "enabling never replays off-period completion")
        await service.refresh(); await service.enableFromUserGesture()
        try expect(center.permissionCalls == 1, "authorized never prompts again")
        let next = try begin(service); service.receive(.completed, for: next)
        await service.waitUntilIdle()
        try expect(center.pending.count == 1 && center.additions[0].sound, "new completion has system-enabled sound")
        service.disable(); await service.waitUntilIdle()
        try expect(!service.enabled && center.pending.isEmpty && saved.last == false, "disable persists and removes")
    }

    static func permissionAndSettingsRaces() async throws {
        let center = TaskNotificationFakeCenter()
        center.value = TaskNotificationSettings(authorization: .notDetermined)
        let gate = TaskNotificationGate(); center.permissionGate = gate
        let service = TaskNotificationService(client: center)
        await service.refresh()
        let enable = Task { await service.enableFromUserGesture() }
        try await until { center.permissionCalls == 1 }
        await service.enableFromUserGesture()
        try expect(center.permissionCalls == 1, "double tap coalesces permission")
        service.disable(); gate.release(); await enable.value
        try expect(!service.enabled && service.systemSettings.authorization == .authorized, "late grant does not undo opt-out")
        try expect(center.pending.isEmpty, "late grant emits no notifications")

        let settingsGate = TaskNotificationGate(); center.settingsGate = settingsGate
        let stale = Task { await service.refresh() }
        let reads = center.settingsCalls; try await until { center.settingsCalls > reads }
        center.value = TaskNotificationSettings(authorization: .denied)
        await service.refresh(); settingsGate.release(); await stale.value
        try expect(service.systemSettings.authorization == .denied, "older settings callback cannot overwrite newer denial")
        await service.enableFromUserGesture()
        try expect(center.permissionCalls == 1 && service.systemSettings.authorization == .denied, "denied click does not re-prompt")

        center.value = TaskNotificationSettings(authorization: .notDetermined); center.failAuthorization = true
        await service.enableFromUserGesture()
        try expect(service.notice == .authorizationUnavailable, "permission failure has fixed safe notice")
        service.disable(); await service.waitUntilIdle()
    }

    static func enableRefreshOverlap() async throws {
        let center = TaskNotificationFakeCenter()
        center.value = TaskNotificationSettings(authorization: .notDetermined)
        let first = TaskNotificationGate(); center.settingsGate = first
        let service = TaskNotificationService(client: center)
        let enable = Task { await service.enableFromUserGesture() }
        try await until { center.settingsCalls == 1 }
        let second = TaskNotificationGate(); center.settingsGate = second
        let refresh = Task { await service.refresh() }
        try await until { center.settingsCalls == 2 }
        first.release(); await enable.value
        second.release(); await refresh.value
        try expect(center.permissionCalls == 1, "overlapping refresh cannot swallow explicit permission request")
        try expect(service.systemSettings.authorization == .authorized, "stale refresh cannot overwrite granted status")
        service.disable(); await service.waitUntilIdle()
    }

    static func transitionsAndExpiry() async throws {
        let center = TaskNotificationFakeCenter()
        var clock = Date(timeIntervalSince1970: 1_000)
        let service = TaskNotificationService(client: center, enabled: true, now: { clock })
        await service.refresh()
        let ticket = try begin(service, now: clock); let approval = UUID()
        service.receive(.requiresApproval(id: approval, expiresAt: clock.addingTimeInterval(20)), for: ticket)
        await service.waitUntilIdle()
        try expect(center.pending.values.first?.kind == .approval, "approval emitted")
        service.receive(.requiresApproval(id: approval, expiresAt: clock.addingTimeInterval(20)), for: ticket)
        service.receive(.completed, for: ticket); await service.waitUntilIdle()
        try expect(center.addCalls == 1, "duplicate approval and impossible completion suppressed")
        center.deliver(); service.receive(.approvalResolved(id: UUID()), for: ticket)
        await service.waitUntilIdle()
        try expect(center.delivered.count == 1, "stale resolution cannot clear current approval")
        service.receive(.approvalResolved(id: approval), for: ticket); await service.waitUntilIdle()
        try expect(center.delivered.isEmpty && center.pending.isEmpty, "resolution clears pending and delivered")
        clock = clock.addingTimeInterval(21)
        service.receive(.completed, for: ticket); await service.waitUntilIdle()
        try expect(center.pending.values.first?.kind == .completed, "resolved short approval deadline does not shorten original run")
        service.receive(.completed, for: ticket); await service.waitUntilIdle()
        try expect(center.addCalls == 2, "completion de-duplicated")
        center.deliver(); clock = clock.addingTimeInterval(TaskNotificationService.resultLifetime)
        service.expire(); await service.waitUntilIdle()
        try expect(center.delivered.isEmpty && service.trackedCount == 0, "result retention bounded")

        for terminal in [TaskNotificationEvent.cancelled, .expired, .failed] {
            let task = try begin(service, now: clock)
            service.receive(.requiresApproval(id: UUID(), expiresAt: clock.addingTimeInterval(1)), for: task)
            await service.waitUntilIdle(); center.deliver()
            service.receive(terminal, for: task); service.receive(.completed, for: task)
            await service.waitUntilIdle()
            try expect(center.pending.isEmpty && center.delivered.isEmpty, "terminal revokes and rejects late completion")
        }
        let expired = try begin(service, now: clock)
        service.receive(.requiresApproval(id: UUID(), expiresAt: clock.addingTimeInterval(1)), for: expired)
        await service.waitUntilIdle(); clock = clock.addingTimeInterval(1); service.expire(); await service.waitUntilIdle()
        try expect(center.pending.isEmpty, "approval expires at exact boundary")
        let background = try begin(service, now: clock)
        service.receive(.requiresApproval(id: UUID(), expiresAt: clock.addingTimeInterval(10)), for: background)
        await service.waitUntilIdle(); center.deliver(); service.invalidateApprovals(); await service.waitUntilIdle()
        try expect(center.delivered.isEmpty, "leaving foreground revokes approval notifications")
        service.disable(); await service.waitUntilIdle()
    }

    static func inFlightAddCancellation() async throws {
        for mode in 0..<4 {
            let center = TaskNotificationFakeCenter(); let service = await active(center)
            let gate = TaskNotificationGate(); center.addGate = gate
            let ticket = try begin(service); let approval = UUID()
            service.receive(.requiresApproval(id: approval, expiresAt: Date().addingTimeInterval(60)), for: ticket)
            try await until { center.addCalls == 1 }
            switch mode {
            case 0: service.disable()
            case 1: service.receive(.cancelled, for: ticket)
            case 2: service.receive(.approvalResolved(id: approval), for: ticket)
            default: center.value = TaskNotificationSettings(authorization: .denied)
                let refresh = Task { await service.refresh() }
                try await until { service.systemSettings.authorization == .denied }
                gate.release(); await refresh.value
            }
            gate.release(); await service.waitUntilIdle()
            try expect(center.pending.isEmpty && center.delivered.isEmpty, "late OS add cleaned after invalidation")
            try expect(center.permissionCalls == 0, "reconciliation cannot request permission")
            service.disable(); await service.waitUntilIdle()
        }
    }

    static func boundsRelaunchAndRevocation() async throws {
        let center = TaskNotificationFakeCenter(); let service = await active(center)
        var tickets: [TaskNotificationTicket] = []
        for _ in 0..<70 {
            let ticket = try begin(service); tickets.append(ticket); service.receive(.completed, for: ticket)
            await service.waitUntilIdle()
            try expect(service.trackedCount <= 32 && center.pending.count <= 32, "run and notification capacity")
        }
        let count = center.addCalls
        service.receive(.completed, for: tickets[0]); await service.waitUntilIdle()
        try expect(center.addCalls == count, "evicted token cannot resurrect")
        for date in [Date.distantPast, Date.distantFuture, Date(timeIntervalSince1970: .nan), Date().addingTimeInterval(1_801)] {
            try expect(service.begin(destination: .browser, deadline: date) == nil, "invalid lifetime rejected")
        }
        center.deliver()
        let unrelated = TaskNotificationPayload(kind: .completed, destination: .chat)
        center.pending["another-feature"] = unrelated
        let relaunched = TaskNotificationService(client: center, enabled: true)
        await relaunched.refresh()
        try expect(center.delivered.isEmpty && center.pending.count == 1, "relaunch removes owned stale work and preserves unrelated")
        try expect(relaunched.trackedCount == 0 && center.permissionCalls == 0, "relaunch restores only preference")
        let ticket = try begin(relaunched); center.value = TaskNotificationSettings(authorization: .denied)
        relaunched.receive(.completed, for: ticket); await relaunched.waitUntilIdle()
        try expect(center.addCalls == count, "recheck before add observes revoked authorization")
        center.value = TaskNotificationSettings(authorization: .authorized, sound: .disabled, alert: .disabled)
        await relaunched.refresh()
        try expect(center.addCalls == count, "restored permission does not replay dropped event")
        let silent = try begin(relaunched); relaunched.receive(.completed, for: silent); await relaunched.waitUntilIdle()
        try expect(center.additions.last?.sound == false, "current disabled sound respected")
        center.failAdd = true
        let failed = try begin(relaunched); relaunched.receive(.completed, for: failed); await relaunched.waitUntilIdle()
        let attempts = center.addCalls; await relaunched.refresh()
        try expect(relaunched.notice == .deliveryUnavailable && center.addCalls == attempts, "add failure safe and not retried")
        service.disable(); relaunched.disable(); await service.waitUntilIdle(); await relaunched.waitUntilIdle()
    }

    static func observerLifecycle() async throws {
        let center = TaskNotificationFakeCenter(); let service = await active(center)
        let existing = UUID()
        let observer = TaskNotificationChatObserver(service: service,
            initial: .init(entryCount: 2, lastAssistantID: existing), isSubmitting: false)
        observer.entriesChanged(.init(entryCount: 2, lastAssistantID: existing)); await service.waitUntilIdle()
        try expect(center.addCalls == 0, "binding and unchanged history never replay")
        observer.submittingChanged(true)
        observer.entriesChanged(.init(entryCount: 3, lastAssistantID: existing)); await service.waitUntilIdle()
        try expect(center.addCalls == 0, "user append not completion")
        let answer = UUID()
        observer.entriesChanged(.init(entryCount: 4, lastAssistantID: answer)); observer.submittingChanged(false)
        await service.waitUntilIdle()
        try expect(center.pending.count == 1, "actual success publication order emits once")
        observer.entriesChanged(.init(entryCount: 4, lastAssistantID: answer)); await service.waitUntilIdle()
        try expect(center.addCalls == 1, "repeated snapshot suppressed")
        observer.entriesChanged(.init(entryCount: 0, lastAssistantID: nil)); await service.waitUntilIdle()
        try expect(center.pending.isEmpty, "new conversation/model removal clears")
        for source in [TaskNotificationApprovalSource.mcp, .profile, .memory] {
            observer.submittingChanged(true); let id = UUID()
            observer.approvalChanged(id, source: source); await service.waitUntilIdle()
            try expect(center.pending.values.first?.kind == .approval, "each actual approval source supported")
            observer.approvalChanged(nil, source: source); await service.waitUntilIdle()
            try expect(center.pending.isEmpty, "resolution immediately revokes")
            observer.submittingChanged(false)
        }
        observer.submittingChanged(true); observer.submittingChanged(false)
        let attempts = center.addCalls
        observer.entriesChanged(.init(entryCount: 2, lastAssistantID: UUID())); await service.waitUntilIdle()
        try expect(center.addCalls == attempts, "late answer after cancel cannot notify")
        let rebound = TaskNotificationChatObserver(service: service,
            initial: .init(entryCount: 0, lastAssistantID: nil), isSubmitting: true)
        rebound.entriesChanged(.init(entryCount: 2, lastAssistantID: UUID())); rebound.submittingChanged(false)
        await service.waitUntilIdle()
        try expect(center.addCalls == attempts, "binding during run does not replay that run")
        observer.reset(); service.disable(); await service.waitUntilIdle()
    }

    static func testButtonAndRoutes() async throws {
        let center = TaskNotificationFakeCenter()
        var clock = Date(timeIntervalSince1970: 2_000)
        let service = TaskNotificationService(client: center, now: { clock })
        await service.refresh()
        let off = await service.sendTestFromUserGesture()
        try expect(!off && center.addCalls == 0, "test button cannot bypass default off")
        await service.enableFromUserGesture()
        let accepted = await service.sendTestFromUserGesture(); await service.waitUntilIdle()
        try expect(accepted && center.pending.count == 1, "test uses common scheduling lane")
        let payload = center.additions.last!.payload
        try expect(payload.title == "通知測試" && payload.body == "這是渥屋助理的測試通知。", "test fixed copy")
        try expect(service.mayPresent(identifier: payload.identifier), "explicit valid test may present foreground")
        center.deliver(); clock = clock.addingTimeInterval(30); service.expire(); await service.waitUntilIdle()
        try expect(center.delivered.isEmpty && !service.mayPresent(identifier: payload.identifier), "test expires at 30 seconds")
        for kind in [TaskNotificationKind.completed, .approval, .test] {
            for destination in [TaskNotificationDestination.chat, .browser] {
                let value = TaskNotificationPayload(kind: kind, destination: destination)
                try expect(TaskNotificationPayload.destination(for: value.identifier) == destination, "only enum destination recovered")
                try expect(value.identifier.count < 100 && !value.body.contains(value.identifier), "bounded opaque identifier, fixed copy")
            }
        }
        for identifier in ["", "approve", payload.identifier + ".approve", payload.identifier.lowercased(),
                           "woow.task.v1.chat.approval.secret", "woow.task.v1.settings.test." + UUID().uuidString,
                           String(repeating: "A", count: 10_000)] {
            try expect(TaskNotificationPayload.destination(for: identifier) == nil, "malformed routing rejected")
        }
        center.value = TaskNotificationSettings(authorization: .provisional)
        let quiet = await service.sendTestFromUserGesture()
        try expect(!quiet && center.permissionCalls == 0, "test requires full authorization without prompting")
        service.disable(); await service.waitUntilIdle()
    }
}
