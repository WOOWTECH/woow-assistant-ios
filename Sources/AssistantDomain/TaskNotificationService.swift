import Foundation

/// MainActor mutations are synchronous so host cancellation never waits behind an OS callback.
/// One reconciliation lane serializes OS add/remove. Every suspension rechecks current intent.
@MainActor public final class TaskNotificationService {
    public static let capacity = 32
    public static let maximumRunLifetime: TimeInterval = 1_800
    public static let maximumApprovalLifetime: TimeInterval = 180
    public static let resultLifetime: TimeInterval = 86_400
    public private(set) var enabled: Bool
    public private(set) var systemSettings = TaskNotificationSettings()
    public private(set) var requestingAuthorization = false
    public private(set) var ready = false
    public private(set) var notice: TaskNotificationNotice?
    public var onChange: (() -> Void)?
    private let client: any TaskNotificationClient
    private let persistEnabled: (Bool) -> Void
    private let now: () -> Date
    private struct Record {
        let destination: TaskNotificationDestination
        var deadline: Date
        var approvalID: UUID?
        var approvalDeadline: Date?
        var completed = false
        var payload: TaskNotificationPayload?
    }
    private var records: [TaskNotificationTicket: Record] = [:]
    private var order: [TaskNotificationTicket] = []
    private var installed: Set<String> = []
    private var worker: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var dirty = false
    private var authorizationIntent = UUID()
    private var settingsRead = UUID()

    public init(client: any TaskNotificationClient, enabled: Bool = false,
                persistEnabled: @escaping (Bool) -> Void = { _ in }, now: @escaping () -> Date = Date.init) {
        self.client = client; self.enabled = enabled; self.persistEnabled = persistEnabled; self.now = now
    }

    /// Safe on launch/foreground: never requests permission or replays previous-run events.
    public func refresh() async {
        scheduleWork()
        await readSettings()
        scheduleWork()
        await waitUntilIdle()
    }

    /// Call only from the explicit enable button. Neither refresh nor task events call this.
    public func enableFromUserGesture() async {
        guard !requestingAuthorization else { return }
        requestingAuthorization = true; notice = nil
        authorizationIntent = UUID(); let intent = authorizationIntent
        enabled = true; persistEnabled(true); onChange?()
        let observed = await readSettings()
        if enabled && authorizationIntent == intent && observed.authorization == .notDetermined {
            do { try await client.requestAuthorization() }
            catch { if authorizationIntent == intent { notice = .authorizationUnavailable } }
        }
        // A late grant never re-enables a switch that the user turned off.
        await readSettings()
        requestingAuthorization = false; onChange?(); scheduleWork()
        await waitUntilIdle()
    }

    public func disable() {
        authorizationIntent = UUID(); enabled = false; persistEnabled(false); notice = nil
        clearPayloads(); onChange?(); scheduleWork()
    }

    @discardableResult public func begin(destination: TaskNotificationDestination, deadline: Date) -> TaskNotificationTicket? {
        expire()
        let duration = deadline.timeIntervalSince(now())
        guard duration.isFinite, duration > 0, duration <= Self.maximumRunLifetime else { return nil }
        if order.count == Self.capacity { records.removeValue(forKey: order.removeFirst()) }
        let ticket = TaskNotificationTicket()
        records[ticket] = Record(destination: destination, deadline: deadline)
        order.append(ticket); scheduleWork(); armExpiry()
        return ticket
    }

    public func receive(_ event: TaskNotificationEvent, for ticket: TaskNotificationTicket) {
        expire()
        guard var record = records[ticket] else { return }
        switch event {
        case .cancelled, .expired, .failed:
            records.removeValue(forKey: ticket); order.removeAll { $0 == ticket }
        case .requiresApproval(let id, let expiresAt):
            guard !record.completed, record.approvalID == nil else { return }
            let duration = expiresAt.timeIntervalSince(now())
            guard duration.isFinite, duration > 0 else {
                receive(.expired, for: ticket); return
            }
            record.approvalDeadline = min(record.deadline, expiresAt, now().addingTimeInterval(Self.maximumApprovalLifetime))
            record.approvalID = id
            record.payload = canCreatePayload ? TaskNotificationPayload(kind: .approval, destination: record.destination) : nil
            records[ticket] = record
        case .approvalResolved(let id):
            guard !record.completed, record.approvalID == id else { return }
            record.approvalID = nil; record.approvalDeadline = nil; record.payload = nil; records[ticket] = record
        case .completed:
            guard !record.completed, record.approvalID == nil else { return }
            record.completed = true; record.deadline = now().addingTimeInterval(Self.resultLifetime)
            record.payload = canCreatePayload ? TaskNotificationPayload(kind: .completed, destination: record.destination) : nil
            records[ticket] = record
        }
        scheduleWork(); armExpiry()
    }

    public func clear(destination: TaskNotificationDestination) {
        for ticket in order where records[ticket]?.destination == destination { records.removeValue(forKey: ticket) }
        order.removeAll { records[$0] == nil }; scheduleWork(); armExpiry()
    }

    /// Explicit troubleshooting button only. A successful add is not a delivery/sound receipt.
    @discardableResult public func sendTestFromUserGesture() async -> Bool {
        guard enabled else { return false }
        let intent = authorizationIntent
        await readSettings()
        guard intent == authorizationIntent, canCreatePayload, systemSettings.authorization == .authorized,
              let ticket = begin(destination: .chat, deadline: now().addingTimeInterval(30)) else {
            scheduleWork(); return false
        }
        records[ticket]?.completed = true
        records[ticket]?.payload = TaskNotificationPayload(kind: .test, destination: .chat)
        scheduleWork(); return true
    }

    /// Call when resigning active; mirrors existing host approval cancellation, adds no background execution.
    public func invalidateApprovals() {
        for ticket in order where records[ticket]?.approvalID != nil { records.removeValue(forKey: ticket) }
        order.removeAll { records[$0] == nil }; scheduleWork(); armExpiry()
    }

    public func expire() {
        let current = now()
        let expired = order.filter { records[$0].map { min($0.deadline, $0.approvalDeadline ?? $0.deadline) <= current } ?? true }
        guard !expired.isEmpty else { return }
        for ticket in expired { records.removeValue(forKey: ticket) }
        order.removeAll { records[$0] == nil }; scheduleWork(); armExpiry()
    }

    public func mayPresent(identifier: String) -> Bool {
        expire()
        return enabled && systemSettings.authorization.allowsDelivery && desired.contains { $0.identifier == identifier }
    }

    public func dismiss(identifier: String) {
        for ticket in order where records[ticket]?.payload?.identifier == identifier { records[ticket]?.payload = nil }
        scheduleWork()
    }

    /// Useful for deterministic integration tests; does not imply OS presentation succeeded.
    public func waitUntilIdle() async { while let work = worker { await work.value } }
    public var trackedCount: Int { records.count }
    private var canCreatePayload: Bool { ready && enabled && !requestingAuthorization && systemSettings.authorization.allowsDelivery }
    private var desired: [TaskNotificationPayload] { order.compactMap { records[$0]?.payload } }

    private func clearPayloads() { for ticket in order { records[ticket]?.payload = nil } }

    @discardableResult private func readSettings() async -> TaskNotificationSettings {
        let read = UUID(); settingsRead = read
        let result = await client.settings()
        if settingsRead == read {
            systemSettings = result
            if !result.authorization.allowsDelivery { clearPayloads() }
            onChange?()
        }
        return result
    }

    private func scheduleWork() {
        dirty = true
        guard worker == nil else { return }
        worker = Task { [weak self] in await self?.reconcile() }
    }

    private func reconcile() async {
        if !ready {
            await client.removeAllOwned()
            ready = true; onChange?()
        }
        while dirty {
            dirty = false; expire()
            if !enabled { clearPayloads() }
            let wanted = Set(desired.map(\.identifier))
            let removed = installed.subtracting(wanted)
            if !removed.isEmpty {
                await client.remove(identifiers: Array(removed))
                installed.subtract(removed)
            }
            // No separate per-event Tasks: replacement/cancel always beats a stale queued add.
            for payload in desired where !installed.contains(payload.identifier) {
                await readSettings()
                expire()
                guard enabled, systemSettings.authorization.allowsDelivery,
                      desired.contains(payload) else { dirty = true; continue }
                do {
                    try await client.add(payload, sound: systemSettings.sound == .enabled)
                    installed.insert(payload.identifier)
                } catch {
                    // No raw OS error text and no automatic retry of a failed notification.
                    if desired.contains(payload) { dismiss(identifier: payload.identifier); notice = .deliveryUnavailable; onChange?() }
                }
                // add can finish after disable/resolve/expiry. Remove that request again in this lane.
                expire()
                if !enabled || !desired.contains(payload) {
                    await client.remove(identifiers: [payload.identifier]); installed.remove(payload.identifier)
                }
            }
        }
        worker = nil
    }

    private func armExpiry() {
        expiry?.cancel(); expiry = nil
        guard let date = records.values.map({ min($0.deadline, $0.approvalDeadline ?? $0.deadline) }).min() else { return }
        let interval = max(0.001, min(Self.resultLifetime, date.timeIntervalSince(now())))
        expiry = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000)) }
            catch { return }
            self?.expire(); self?.armExpiry()
        }
    }
}
