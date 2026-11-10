import Foundation

/// One bounded selection and one delivered output per runtime. Read approvals
/// authorize storage access; assembly approval authorizes only immutable bytes.
/// Replace/cancel this runtime when the picker selection changes or UI closes.
public actor SkillPDFAssemblyRuntime {
    public nonisolated let sources: [SkillPDFAssemblySource]
    public nonisolated let provenance: [SkillExecutionProvenance]
    public nonisolated var available: Bool { SkillPDFAssemblyNative.available }
    public var receipts: [SkillPDFAssemblyReceipt] { sources.compactMap { snapshots[$0.id]?.receipt } }
    public private(set) var preparedPlan: SkillPDFAssemblyPlan?

    private let runtimeID = UUID()
    private let selected: [UUID: SkillExecutionSelectedFile]
    private let clock: @Sendable () -> Date
    private let reader: @Sendable (SkillExecutionSelectedFile) async throws -> Data
    private let assembler: @Sendable ([SkillPDFAssemblySnapshot], [SkillPDFAssemblyPage]) async throws -> Data
    private var snapshots: [UUID: SkillPDFAssemblySnapshot] = [:]
    private var grants: [UUID: SkillPDFAssemblyApproval] = [:]
    private var activeCancel: (@Sendable () -> Void)?
    private var busy = false
    private var cancelled = false
    private var completed = false

    public init(selectedFiles: [SkillExecutionSelectedFile], catalog: BundledSkillCatalog,
                clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(selectedFiles: selectedFiles, catalog: catalog, clock: clock,
            reader: { try SkillExecutionPDF.read($0) },
            assembler: { try SkillPDFAssemblyNative.assemble($0, order: $1) })
    }

    // Internal seam for deterministic cancellation races. Production always
    // uses the actual coordinated reader and native PDFKit implementation above.
    init(selectedFiles: [SkillExecutionSelectedFile], catalog: BundledSkillCatalog,
         clock: @escaping @Sendable () -> Date = { Date() },
         reader: @escaping @Sendable (SkillExecutionSelectedFile) async throws -> Data,
         assembler: @escaping @Sendable ([SkillPDFAssemblySnapshot], [SkillPDFAssemblyPage]) async throws -> Data) throws {
        guard (1...SkillPDFAssemblyLimits.files).contains(selectedFiles.count),
              Set(selectedFiles.map(\.id)).count == selectedFiles.count,
              Set(selectedFiles.map { $0.url.standardizedFileURL }).count == selectedFiles.count else {
            throw SkillPDFAssemblyError.invalidSources
        }
        guard let entry = catalog.entry(id: "documents") else { throw SkillCatalogError.notFound }
        sources = selectedFiles.map {
            let filename = String($0.url.lastPathComponent.unicodeScalars.filter {
                !CharacterSet.controlCharacters.contains($0)
            }.map(String.init).joined().prefix(160))
            return SkillPDFAssemblySource(id: $0.id, filename: filename)
        }
        provenance = ([entry.original] + entry.assets).map(SkillExecutionProvenance.init)
        selected = Dictionary(uniqueKeysWithValues: selectedFiles.map { ($0.id, $0) })
        self.clock = clock; self.reader = reader; self.assembler = assembler
        // No filesystem/PDF inspection before a read grant is consumed.
    }

    public func authorizeRead(sourceID: UUID) throws -> SkillPDFAssemblyApproval {
        try requireIdle()
        guard available else { throw SkillExecutionError.unavailable }
        guard selected[sourceID] != nil, snapshots[sourceID] == nil else { throw SkillExecutionError.stalePlan }
        return issue(target: sourceID, assembly: false)
    }

    public func read(_ approval: SkillPDFAssemblyApproval) async throws -> SkillPDFAssemblyReceipt {
        try requireIdle()
        try consume(approval, assembly: false)
        guard let file = selected[approval.target], snapshots[approval.target] == nil,
              let source = sources.first(where: { $0.id == approval.target }) else { throw SkillExecutionError.stalePlan }
        busy = true
        let read = reader
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let bytes = try await read(file)
            try Task.checkCancellation()
            let pageCount = try SkillPDFAssemblyNative.inspect(bytes)
            return SkillPDFAssemblySnapshot(receipt: .init(source: source, pageCount: pageCount,
                byteCount: bytes.count, sha256: skillExecutionDigest(bytes)), data: bytes)
        }
        activeCancel = { operation.cancel() }
        defer { busy = false; activeCancel = nil }
        do {
            let snapshot = try await withTaskCancellationHandler(operation: { try await operation.value },
                                                                onCancel: { operation.cancel() })
            try Task.checkCancellation()
            guard !cancelled else { throw SkillExecutionError.cancelled }
            guard snapshots.values.reduce(snapshot.data.count, { $0 + $1.data.count }) <= SkillPDFAssemblyLimits.totalInputBytes else {
                throw SkillExecutionError.fileTooLarge
            }
            guard snapshots.values.reduce(snapshot.receipt.pageCount, { $0 + $1.receipt.pageCount }) <= SkillPDFAssemblyLimits.pages else {
                throw SkillExecutionError.tooManyPages
            }
            snapshots[source.id] = snapshot
            grants.removeAll(); preparedPlan = nil
            return snapshot.receipt
        } catch {
            if error is CancellationError || cancelled { cancel(); throw SkillExecutionError.cancelled }
            throw error // Consumed grant stays consumed; no retry or fallback read.
        }
    }

    /// Reuses the extraction feature's range grammar (e.g. 3,1-2,3), retaining
    /// exact order and duplicates. Calling this never reads a file again.
    public func pages(sourceID: UUID, range: String? = nil) throws -> [SkillPDFAssemblyPage] {
        try requireIdle()
        guard let snapshot = snapshots[sourceID] else { throw SkillExecutionError.approvalRequired }
        return try SkillExecutionPageRange.parse(range, pageCount: snapshot.receipt.pageCount).map {
            SkillPDFAssemblyPage(sourceID: sourceID, number: $0)
        }
    }

    /// Every edit replaces the plan and revokes its previous approval, even if
    /// the edited order is invalid. The host must show the new exact order.
    public func prepare(order: [SkillPDFAssemblyPage]) throws -> SkillPDFAssemblyPlan {
        try requireIdle()
        grants.removeAll(); preparedPlan = nil
        guard snapshots.count == sources.count else { throw SkillExecutionError.approvalRequired }
        guard !order.isEmpty else { throw SkillExecutionError.invalidPages }
        guard order.count <= SkillPDFAssemblyLimits.pages else { throw SkillExecutionError.tooManyPages }
        for page in order {
            guard let snapshot = snapshots[page.sourceID], (1...snapshot.receipt.pageCount).contains(page.number) else {
                throw SkillExecutionError.invalidPages
            }
        }
        let used = Set(order.map(\.sourceID))
        let inputs = receipts.filter { used.contains($0.id) }
        let id = UUID()
        let canonical: [String: Any] = ["id": id.uuidString, "runtime": runtimeID.uuidString,
            "inputs": inputs.map { ["id": $0.id.uuidString, "filename": $0.source.filename,
                "bytes": $0.byteCount, "pages": $0.pageCount, "sha256": $0.sha256] as [String: Any] },
            "order": order.map { ["source": $0.sourceID.uuidString, "page": $0.number] as [String: Any] },
            "engine": "Apple PDFKit", "outputByteLimit": SkillPDFAssemblyLimits.outputBytes,
            "provenance": provenance.map { [$0.repository, $0.revision, $0.path, $0.sha256] }]
        let plan = SkillPDFAssemblyPlan(id: id, inputs: inputs, order: order,
            fingerprint: skillExecutionDigest(try JSONSerialization.data(withJSONObject: canonical, options: [.sortedKeys])),
            provenance: provenance)
        preparedPlan = plan
        return plan
    }

    /// Source numbers are the one-based positions in `sources`, fixed for this
    /// runtime. Example: "1:3,1:1-2,2:1". No implied sorting or deduplication.
    public func prepare(orderText: String) throws -> SkillPDFAssemblyPlan {
        try requireIdle()
        grants.removeAll(); preparedPlan = nil
        guard !orderText.isEmpty, orderText.utf8.count <= 4096 else { throw SkillExecutionError.invalidPages }
        var order: [SkillPDFAssemblyPage] = []
        for component in orderText.split(separator: ",", omittingEmptySubsequences: false) {
            let fields = component.split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw SkillExecutionError.invalidPages }
            let source = fields[0].trimmingCharacters(in: .whitespaces)
            guard !source.isEmpty, source.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let index = Int(source), (1...sources.count).contains(index) else { throw SkillExecutionError.invalidPages }
            let range = fields[1].trimmingCharacters(in: .whitespaces)
            guard !range.isEmpty else { throw SkillExecutionError.invalidPages }
            let next = try pages(sourceID: sources[index - 1].id, range: range)
            guard order.count + next.count <= SkillPDFAssemblyLimits.pages else { throw SkillExecutionError.tooManyPages }
            order.append(contentsOf: next)
        }
        return try prepare(order: order)
    }

    public func authorizeAssembly(planID: UUID) throws -> SkillPDFAssemblyApproval {
        try requireIdle()
        guard preparedPlan?.id == planID else { throw SkillExecutionError.stalePlan }
        return issue(target: planID, assembly: true)
    }

    public func assemble(_ approval: SkillPDFAssemblyApproval) async throws -> SkillPDFAssemblyResult {
        try requireIdle()
        try consume(approval, assembly: true)
        guard let plan = preparedPlan, approval.target == plan.id else { throw SkillExecutionError.stalePlan }
        let inputs = plan.inputs.compactMap { snapshots[$0.id] }
        guard inputs.count == plan.inputs.count else { throw SkillExecutionError.stalePlan }
        busy = true
        let assemble = assembler
        let operation = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try await assemble(inputs, plan.order)
        }
        activeCancel = { operation.cancel() }
        defer { busy = false; activeCancel = nil }
        do {
            let data = try await withTaskCancellationHandler(operation: { try await operation.value },
                                                            onCancel: { operation.cancel() })
            try Task.checkCancellation()
            guard !cancelled else { throw SkillExecutionError.cancelled }
            guard data.count <= SkillPDFAssemblyLimits.outputBytes else { throw SkillPDFAssemblyError.outputTooLarge }
            let result = SkillPDFAssemblyResult(data: data, plan: plan, sha256: skillExecutionDigest(data))
            completed = true; snapshots.removeAll(); grants.removeAll()
            return result
        } catch {
            if error is CancellationError || cancelled { cancel(); throw SkillExecutionError.cancelled }
            throw error
        }
    }

    /// Terminal revocation. Native synchronous work may finish, but its bytes
    /// cannot be published. No file deletion/export side effects to undo.
    public func cancel() {
        cancelled = true; activeCancel?(); snapshots.removeAll(); grants.removeAll(); preparedPlan = nil
    }
    private func requireIdle() throws {
        guard !cancelled else { throw SkillExecutionError.cancelled }
        guard !busy else { throw SkillExecutionError.busy }
        guard !completed else { throw SkillExecutionError.stalePlan }
    }
    private func issue(target: UUID, assembly: Bool) -> SkillPDFAssemblyApproval {
        let grant = SkillPDFAssemblyApproval(id: UUID(), runtimeID: runtimeID, target: target,
            assembly: assembly, expiresAt: clock().addingTimeInterval(120))
        grants.removeAll(); grants[grant.id] = grant
        return grant
    }
    private func consume(_ approval: SkillPDFAssemblyApproval, assembly: Bool) throws {
        guard let issued = grants.removeValue(forKey: approval.id), issued.runtimeID == runtimeID,
              issued.target == approval.target, issued.assembly == assembly else { throw SkillExecutionError.approvalRequired }
        guard clock() < issued.expiresAt else { throw SkillExecutionError.expiredApproval }
    }
}
