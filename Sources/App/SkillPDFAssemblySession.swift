import AssistantSkills
import Combine
import Foundation

/// Presentation state for one user-selected set of documents. Every awaited
/// result is fenced by the selection generation; closing/replacing cancels it.
@MainActor
final class SkillPDFAssemblySession: ObservableObject {
    @Published private(set) var sources: [SkillPDFAssemblySource] = []
    @Published private(set) var receipts: [SkillPDFAssemblyReceipt] = []
    @Published private(set) var plan: SkillPDFAssemblyPlan?
    @Published private(set) var result: SkillPDFAssemblyResult?
    @Published private(set) var running = false
    @Published private(set) var status: String?
    @Published var orderText = ""
    #if DEBUG
    @Published private(set) var uiTestFixture: SkillExecutionUITestSupport.Fixture?
    @Published private(set) var uiTestPair: SkillExecutionUITestSupport.AssemblyPairFixture?
    @Published private(set) var uiTestPairOutput = "pair=none"
    private var uiTestPairPickerOrdinal = 0
    private func recordUITestPair(_ phase: String) {
        guard let pair = uiTestPair else { return }
        SkillExecutionUITestSupport.recordPairSnapshot(pair, phase: phase, ordinal: uiTestPairPickerOrdinal)
    }
    func observeUITestPairOutput() {
        guard let pair = uiTestPair, let output = result else { return }
        let digests = Dictionary(receipts.map { ($0.source.filename, $0.sha256) },
                                 uniquingKeysWith: { _, _ in "duplicate" })
        uiTestPairOutput = SkillExecutionUITestSupport.assemblyPairOutputObservation(
            output.data, receiptDigests: digests, fixture: pair)
    }
    func seedUITestIfRequested() {
        guard uiTestFixture == nil, uiTestPair == nil else { return }
        do {
            if let pair = try SkillExecutionUITestSupport.seedAssemblyPairIfRequested() { uiTestPair = pair }
            else { uiTestFixture = try SkillExecutionUITestSupport.seedIfRequested() }
        }
        catch { status = "測試 PDF 無法建立；請檢查測試命名空間與檔案設定。" }
    }
    #endif
    private var runtime: SkillPDFAssemblyRuntime?
    private var selectedFiles: [SkillExecutionSelectedFile] = []
    private var preparedOrder: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    struct PickerRequest: Equatable {
        fileprivate let id = UUID()
        fileprivate let generation: UUID
        let adding: Bool
    }
    private var pendingPicker: PickerRequest?

    var canPrepare: Bool { !sources.isEmpty && receipts.count == sources.count && !running && result == nil && pendingPicker == nil }
    var canAdd: Bool { !running && pendingPicker == nil && !sources.isEmpty && sources.count < SkillPDFAssemblyLimits.files }

    func beginPicker(adding: Bool) -> PickerRequest? {
        guard !running, pendingPicker == nil, adding ? canAdd : sources.isEmpty else { return nil }
        let request = PickerRequest(generation: generation, adding: adding)
        pendingPicker = request
        #if DEBUG
        if uiTestPair != nil {
            uiTestPairPickerOrdinal = min(uiTestPairPickerOrdinal + 1, 4)
            recordUITestPair("prePicker")
        }
        #endif
        return request
    }

    func cancelPicker(_ request: PickerRequest) {
        guard pendingPicker == request else { return }
        #if DEBUG
        recordUITestPair("cancelled")
        #endif
        pendingPicker = nil // A late completion cannot authorize selection.
    }

    func pickerFailed(_ request: PickerRequest) {
        guard pendingPicker == request, request.generation == generation else { return }
        #if DEBUG
        recordUITestPair("selectionFailure")
        #endif
        pendingPicker = nil; selectionFailed()
    }

    @discardableResult
    func finishPicker(_ request: PickerRequest, urls: [URL]) -> Bool {
        guard pendingPicker == request, request.generation == generation, !running else { return false }
        #if DEBUG
        recordUITestPair("selectionReturned")
        #endif
        pendingPicker = nil // One callback consumes this presentation, even on validation failure.
        guard urls.count == 1 else {
            status = "每次請只選取一份 PDF，再使用「加入 PDF」加入其他來源。"
            return false
        }
        do {
            let incoming = try urls.map { try SkillExecutionSelectedFile(userSelectedURL: $0) }
            let files = (request.adding ? selectedFiles : []) + incoming
            // Validate first. Cancel, invalid input and a fourth source must not
            // destroy the previous immutable result or its selected sources.
            let execution = try SkillPDFAssemblyRuntime(selectedFiles: files, catalog: BundledSkillCatalog.bundled())
            guard execution.available else { throw SkillExecutionError.unavailable }
            clear()
            runtime = execution; selectedFiles = files; sources = execution.sources
            // Reuse the original SelectedFile values so their UUIDs remain
            // stable, but revoke all old read/assembly grants and snapshots.
            status = request.adding
                ? "已加入文件；請重新核准各來源的讀取，再核對新頁序。"
                : "請逐一確認要讀取的文件。"
            return true
        } catch { report(error); return false }
    }

    func select(_ urls: [URL]) {
        clear()
        do {
            let files = try urls.map { try SkillExecutionSelectedFile(userSelectedURL: $0) }
            let execution = try SkillPDFAssemblyRuntime(
                selectedFiles: files,
                catalog: BundledSkillCatalog.bundled())
            guard execution.available else { throw SkillExecutionError.unavailable }
            runtime = execution; selectedFiles = files; sources = execution.sources
            status = "請逐一確認要讀取的文件。"
        } catch { report(error) }
    }

    func selectionFailed() { status = "未能取得選取的 PDF，請重新選取。" }

    func read(_ sourceID: UUID) {
        guard let runtime, !running, pendingPicker == nil, receipts.allSatisfy({ $0.id != sourceID }) else { return }
        let token = generation
        running = true; status = nil
        task = Task {
            defer { if generation == token { running = false; task = nil } }
            do {
                let grant = try await runtime.authorizeRead(sourceID: sourceID)
                _ = try await runtime.read(grant)
                let loaded = await runtime.receipts
                guard generation == token, !Task.isCancelled else { return }
                receipts = loaded
                if receipts.count == sources.count {
                    orderText = sources.enumerated().compactMap { index, source in
                        guard let receipt = receipts.first(where: { $0.id == source.id }) else { return nil }
                        return "\(index + 1):1-\(receipt.pageCount)"
                    }.joined(separator: ",")
                    status = "文件已讀取；請指定新 PDF 的頁面順序。"
                } else { status = "文件已讀取；請確認其餘文件。" }
            } catch {
                guard generation == token else { return }
                report(error)
            }
        }
    }

    func invalidatePlan() {
        // No assembly grant exists while editing: grants are issued only in
        // assemble(), after the reviewed immutable plan's explicit button tap.
        guard !running, result == nil else { return }
        plan = nil; preparedOrder = nil
    }

    func prepare() {
        guard let runtime, canPrepare else { return }
        let token = generation, requested = orderText
        plan = nil; preparedOrder = nil; status = nil; running = true
        task = Task {
            defer { if generation == token { running = false; task = nil } }
            do {
                let prepared = try await runtime.prepare(orderText: requested)
                guard generation == token, !Task.isCancelled, orderText == requested else { return }
                plan = prepared; preparedOrder = requested
                status = "請核對下列頁序，再產生新的 PDF。"
            } catch {
                guard generation == token else { return }
                report(error)
            }
        }
    }

    func assemble() {
        guard let runtime, let reviewed = plan, preparedOrder == orderText, !running, pendingPicker == nil, result == nil else { return }
        let token = generation
        running = true; status = nil
        task = Task {
            defer { if generation == token { running = false; task = nil } }
            do {
                let grant = try await runtime.authorizeAssembly(planID: reviewed.id)
                let output = try await runtime.assemble(grant)
                guard generation == token, plan?.id == reviewed.id, !Task.isCancelled else { return }
                result = output; status = "新 PDF 已產生，尚未儲存至檔案。"
                #if DEBUG
                observeUITestPairOutput()
                #endif
            } catch {
                guard generation == token else { return }
                report(error)
            }
        }
    }

    func clear() {
        generation = UUID(); task?.cancel(); task = nil
        if let runtime { Task { await runtime.cancel() } }
        runtime = nil; sources = []; receipts = []; plan = nil; preparedOrder = nil; result = nil
        selectedFiles = []; pendingPicker = nil
        orderText = ""; status = nil; running = false
        #if DEBUG
        uiTestPairOutput = "pair=none"
        #endif
    }

    private func report(_ error: Error) {
        // Native URL/path/provider exception descriptions are not UI content.
        status = (error as? SkillExecutionError)?.errorDescription
            ?? (error as? SkillPDFAssemblyError)?.errorDescription
            ?? "文件處理未完成，原檔未修改。"
    }
}
