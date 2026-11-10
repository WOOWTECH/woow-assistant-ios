// Standalone macOS App-logic acceptance. Compile with the exact App Session,
// View (FileDocument), and actual AssistantSkills/AssistantModels modules.
// Put MikaBundledSkills.json in the executable's .app/Contents/Resources;
// do not substitute a catalog loader, reader, assembler, or model Session.
import AppKit
import AssistantSkills
import Combine
import CoreText
import CryptoKit
import Foundation
import PDFKit

@main
enum SkillPDFAssemblyAppChecks {
    struct Failure: Error { let message: String }
    @MainActor static var checks: [[String: Any]] = []
    @MainActor static func expect(_ condition: Bool, _ name: String) throws {
        checks.append(["name": name, "passed": condition])
        guard condition else { throw Failure(message: name) }
    }

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            let watchdog = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard !Task.isCancelled else { return }
                emit(failure: "bounded App-logic check timed out"); exit(2)
            }
            do { try await run(); watchdog.cancel(); emit(failure: nil); exit(0) }
            catch {
                watchdog.cancel()
                emit(failure: (error as? Failure)?.message ?? "synthetic PDF App check failed")
                exit(1)
            }
        }
        app.run()
    }

    @MainActor static func emit(failure: String?) {
        var report: [String: Any] = [
            "checks": checks, "passed": checks.filter { $0["passed"] as? Bool == true }.count,
            "total": checks.count, "platform": "macOS App logic with actual PDFKit and FileWrapper",
            "bundle_loader": "BundledSkillCatalog.bundled()", "uses_stubs": false,
            "native_picker_or_exporter_UI_test": false,
            "cancellation": "actual held NSFileCoordinator read plus queued prepare/assembly tasks",
            "task_observation": "read-only reflection of App task handles; awaited before assertions"
        ]
        if let failure { report["failure"] = failure }
        let bytes = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: bytes, as: UTF8.self))
        fflush(stdout)
    }

    // Await the actual Task even after clear() drops its reference. This reads
    // App state only; no private OS API, modified Session, or sleep-as-completion.
    @MainActor static func pending(_ session: SkillPDFAssemblySession) throws -> Task<Void, Never> {
        guard let value = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value,
              let optional = value as? Optional<Task<Void, Never>>, let task = optional else {
            throw Failure(message: "actual Session task handle unavailable")
        }
        return task
    }

    @MainActor static func drain(_ session: SkillPDFAssemblySession) async throws {
        let task = try pending(session)
        await task.value
        try expect(!session.running, "completed task clears running")
    }

    @MainActor static func loaded(_ files: [URL]) async throws -> SkillPDFAssemblySession {
        let session = SkillPDFAssemblySession()
        session.select(files)
        try expect(session.sources.count == files.count, "selection creates exact source count")
        for source in session.sources { session.read(source.id); try await drain(session) }
        try expect(session.canPrepare, "all separately approved sources become reviewable")
        return session
    }

    static func pdf(_ markers: [String]) throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 500, height: 400)
        guard let consumer = CGDataConsumer(data: data), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw Failure(message: "synthetic PDF context unavailable")
        }
        for marker in markers {
            context.beginPDFPage(nil)
            context.textPosition = CGPoint(x: 40, y: 200)
            let attributed = NSAttributedString(string: marker, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            ])
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    static func pageTexts(_ bytes: Data) throws -> [String] {
        guard let document = PDFDocument(data: bytes) else { throw Failure(message: "real PDF readback failed") }
        return (0..<document.pageCount).map {
            (document.page(at: $0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @MainActor static func run() async throws {
        let catalog = try BundledSkillCatalog.bundled()
        try expect(catalog.entries.count == 6 && catalog.entry(id: "documents") != nil,
                   "actual app-bundled pinned six-skill catalog loads")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("assembly-app-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("synthetic-A.pdf"), second = folder.appendingPathComponent("synthetic-B.pdf")
        let a = ["ASSEMBLY_A_PAGE_1", "ASSEMBLY_A_PAGE_2", "ASSEMBLY_A_PAGE_3"]
        let b = ["ASSEMBLY_B_PAGE_1", "ASSEMBLY_B_PAGE_2"]
        let aData = try pdf(a), bData = try pdf(b)
        try aData.write(to: first, options: .withoutOverwriting)
        try bData.write(to: second, options: .withoutOverwriting)
        try expect(try pageTexts(aData) == a && pageTexts(bData) == b, "both actual input PDFs contain exact markers")

        let session = SkillPDFAssemblySession()
        session.select([first, second])
        try expect(session.sources.count == 2 && session.receipts.isEmpty && session.plan == nil && session.result == nil,
                   "selection alone publishes no reads or result")
        session.prepare(); session.assemble()
        try expect(!session.running && !session.canPrepare && session.plan == nil && session.result == nil,
                   "no review or assembly before per-file approvals")
        let ids = session.sources.map(\.id)
        session.read(ids[0]); try await drain(session)
        try expect(session.receipts.map(\.id) == [ids[0]] && !session.canPrepare, "first approval reads only its source")
        session.read(ids[0])
        try expect(!session.running && session.receipts.count == 1, "duplicate read does not start another task")
        session.read(ids[1]); try await drain(session)
        try expect(session.receipts.map(\.id) == ids && session.receipts.map(\.pageCount) == [3, 2], "both real read receipts retain selection order")
        try expect(session.orderText == "1:1-3,2:1-2", "default order derives from actual page counts")
        session.orderText = "2:2,1:3,2:1,1:1,1:3"
        session.prepare(); try await drain(session)
        guard let plan = session.plan else { throw Failure(message: "reviewed plan missing") }
        try expect(plan.order.map(\.number) == [2, 3, 1, 1, 3]
                   && plan.order.map(\.sourceID) == [ids[1], ids[0], ids[1], ids[0], ids[0]], "review preserves requested source order and duplicates")
        try expect(!plan.grantsAuthorization && session.result == nil, "review alone does not assemble")
        session.orderText = "1:1" // Deliberately no SwiftUI onChange/invalidatePlan.
        session.assemble()
        try expect(!session.running && session.result == nil && session.plan?.id == plan.id,
                   "preparedOrder rejects edited raw text before onChange")
        session.orderText = "2:2,1:3,2:1,1:1,1:3"
        session.assemble(); try await drain(session)
        guard let result = session.result else { throw Failure(message: "approved assembly produced no result") }
        let expected = [b[1], a[2], b[0], a[0], a[2]]
        try expect(result.plan.id == plan.id && result.pageCount == 5, "result belongs to exactly reviewed plan")
        try expect(try pageTexts(result.data) == expected, "actual assembled PDF exact text order and repeated page")
        try expect(result.sha256 == SHA256.hash(data: result.data).map { String(format: "%02x", $0) }.joined(), "result digest matches actual delivered bytes")
        try expect(session.status == "新 PDF 已產生，尚未儲存至檔案。", "assembly does not claim export success")
        session.assemble()
        try expect(!session.running && session.result?.data == result.data, "completed assembly cannot execute again")

        var mutable = result.data
        let document = try SkillPDFAssemblyDocument(data: mutable)
        mutable[0] = 0
        session.clear()
        try expect(session.result == nil && document.data == result.data, "export snapshot survives Session clear and caller data mutation")
        let destination = folder.appendingPathComponent("synthetic-export.pdf")
        let wrapper = document.snapshot()
        try expect(wrapper.isRegularFile && wrapper.regularFileContents == result.data, "actual FileDocument snapshot contains exact immutable PDF")
        try wrapper.write(to: destination, options: .atomic, originalContentsURL: nil)
        let reopened = try FileWrapper(url: destination, options: .immediate)
        guard let saved = reopened.regularFileContents else { throw Failure(message: "export readback missing bytes") }
        try expect(saved == result.data && pageTexts(saved) == expected, "actual FileWrapper disk write and PDFKit page readback")
        do { _ = try SkillPDFAssemblyDocument(data: Data("invalid".utf8)); throw Failure(message: "invalid export accepted") }
        catch is CocoaError { try expect(true, "non-PDF export snapshot rejected") }

        try await checkReadFence(file: first, replacement: second, replace: false)
        try await checkReadFence(file: first, replacement: second, replace: true)

        let edit = try await loaded([first, second])
        edit.prepare(); let preparing = try pending(edit)
        edit.orderText = "2:1" // Change before Task publishes, without onChange.
        await preparing.value
        try expect(edit.plan == nil && !edit.running && edit.result == nil, "late prepare cannot publish review for changed order")
        edit.prepare(); try await drain(edit)
        try expect(edit.plan?.order.count == 1, "new order can be explicitly reviewed")
        edit.invalidatePlan()
        try expect(edit.plan == nil && edit.result == nil, "explicit editor invalidation removes review")
        edit.prepare(); let cancelledPrepare = try pending(edit); edit.clear(); await cancelledPrepare.value
        try expect(edit.plan == nil && edit.status == nil && !edit.running, "cleared queued prepare does not republish")

        let cancelled = try await loaded([first, second])
        cancelled.prepare(); try await drain(cancelled)
        cancelled.assemble(); let assembling = try pending(cancelled)
        cancelled.clear(); await assembling.value
        try expect(cancelled.result == nil && cancelled.plan == nil && cancelled.sources.isEmpty
                   && cancelled.status == nil && !cancelled.running, "cleared queued assembly cannot publish snapshot or completion")

        let replaced = try await loaded([first, second])
        replaced.prepare(); try await drain(replaced)
        let previousIDs = Set(replaced.sources.map(\.id))
        replaced.select([second]); replaced.assemble()
        try expect(replaced.sources.count == 1 && previousIDs.isDisjoint(with: replaced.sources.map(\.id))
                   && replaced.receipts.isEmpty && replaced.plan == nil && replaced.result == nil && !replaced.running,
                   "replacement selection revokes previous read receipts and plan")
        replaced.select([])
        try expect(replaced.sources.isEmpty && replaced.result == nil && replaced.status != nil, "invalid replacement publishes failure without old success")
        replaced.select([folder.appendingPathComponent("synthetic-missing.pdf")])
        guard let missingID = replaced.sources.first?.id else { throw Failure(message: "missing path must remain unread until approval") }
        replaced.read(missingID); try await drain(replaced)
        try expect(replaced.receipts.isEmpty && replaced.result == nil && replaced.status != nil
                   && !(replaced.status ?? "").contains(folder.path), "actual read failure publishes no receipt or sensitive path")
        replaced.clear()
        try expect(try Data(contentsOf: first) == aData && Data(contentsOf: second) == bData, "all App operations preserve both original PDFs byte-for-byte")
    }

    @MainActor static func checkReadFence(file: URL, replacement: URL, replace: Bool) async throws {
        let presenter = HeldPresenter(url: file)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
        let session = SkillPDFAssemblySession()
        session.select([file])
        guard let id = session.sources.first?.id else { throw Failure(message: "fence selection unavailable") }
        session.read(id); let reading = try pending(session)
        let deadline = ProcessInfo.processInfo.systemUptime + 10
        while !presenter.started && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        try expect(presenter.started && session.running, "actual coordinated read reached held presenter")
        var publishedOldReceipt = false
        let observation = session.$receipts.sink { if $0.contains(where: { $0.id == id }) { publishedOldReceipt = true } }
        defer { observation.cancel() }
        if replace { session.select([replacement]) } else { session.clear() }
        let status = session.status, newIDs = session.sources.map(\.id)
        presenter.release(); await reading.value
        try expect(!publishedOldReceipt && session.receipts.isEmpty && session.result == nil,
                   replace ? "replaced in-flight real read never publishes old snapshot" : "cleared in-flight real read never publishes snapshot")
        try expect(session.status == status && session.sources.map(\.id) == newIDs && !session.running,
                   "late read task leaves new generation state untouched")
        if replace {
            session.read(newIDs[0]); try await drain(session)
            try expect(session.receipts.map(\.id) == newIDs && session.receipts[0].pageCount == 2,
                       "replacement remains usable through its own actual approval")
        }
        session.clear()
    }

    // A real external Foundation presenter, never a substituted runtime reader.
    // Always released on error/cleanup; the App read is truly pending here.
    final class HeldPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue = {
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
        }()
        private let lock = NSLock()
        private var callback: ((Error?) -> Void)?
        private var entered = false
        private var released = false
        var started: Bool { lock.lock(); defer { lock.unlock() }; return entered }
        init(url: URL) { presentedItemURL = url }
        func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
            lock.lock(); entered = true
            if released { lock.unlock(); completionHandler(nil) }
            else { callback = completionHandler; lock.unlock() }
        }
        func release() {
            lock.lock(); released = true; let pending = callback; callback = nil; lock.unlock()
            pending?(nil)
        }
    }
}
