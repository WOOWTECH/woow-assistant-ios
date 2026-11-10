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
    func seedUITestIfRequested() {
        guard uiTestFixture == nil else { return }
        do { uiTestFixture = try SkillExecutionUITestSupport.seedIfRequested() }
        catch { status = "測試 PDF 無法建立；請檢查測試命名空間與檔案設定。" }
    }
    #endif
    private var runtime: SkillPDFAssemblyRuntime?
    private var preparedOrder: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?

    var canPrepare: Bool { !sources.isEmpty && receipts.count == sources.count && !running && result == nil }

    func select(_ urls: [URL]) {
        clear()
        do {
            let execution = try SkillPDFAssemblyRuntime(
                selectedFiles: urls.map { try SkillExecutionSelectedFile(userSelectedURL: $0) },
                catalog: BundledSkillCatalog.bundled())
            guard execution.available else { throw SkillExecutionError.unavailable }
            runtime = execution; sources = execution.sources
            status = "請逐一確認要讀取的文件。"
        } catch { report(error) }
    }

    func selectionFailed() { status = "未能取得選取的 PDF，請重新選取。" }

    func read(_ sourceID: UUID) {
        guard let runtime, !running, receipts.allSatisfy({ $0.id != sourceID }) else { return }
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
        guard let runtime, let reviewed = plan, preparedOrder == orderText, !running, result == nil else { return }
        let token = generation
        running = true; status = nil
        task = Task {
            defer { if generation == token { running = false; task = nil } }
            do {
                let grant = try await runtime.authorizeAssembly(planID: reviewed.id)
                let output = try await runtime.assemble(grant)
                guard generation == token, plan?.id == reviewed.id, !Task.isCancelled else { return }
                result = output; status = "新 PDF 已產生，尚未儲存至檔案。"
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
        orderText = ""; status = nil; running = false
    }

    private func report(_ error: Error) {
        // Native URL/path/provider exception descriptions are not UI content.
        status = (error as? SkillExecutionError)?.errorDescription
            ?? (error as? SkillPDFAssemblyError)?.errorDescription
            ?? "文件處理未完成，原檔未修改。"
    }
}
