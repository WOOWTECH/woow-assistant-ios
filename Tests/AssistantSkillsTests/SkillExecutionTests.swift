#if !SKILLS_CORE_SMOKE
import Foundation
import PDFKit
#if !SKILL_EXECUTION_SMOKE
import XCTest
@testable import AssistantSkills
#endif

/// Same assertions run under XCTest on Xcode and the CLT standalone executable.
enum SkillExecutionChecks {
    struct Failure: Error { let message: String }
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(message: message) }
    }
    static func rejects(_ expected: SkillExecutionError, _ block: () async throws -> Void) async throws {
        do { try await block(); throw Failure(message: "expected \(expected.rawValue)") }
        catch let error as SkillExecutionError { try expect(error == expected, "unexpected error category") }
    }

    /// A real three-page PDF: text, empty page, text. No raster/OCR substitute.
    static func pdf() -> Data {
        let streams = ["BT /F1 18 Tf 40 700 Td (Alpha evidence) Tj ET", "", "BT /F1 18 Tf 40 700 Td (Beta evidence) Tj ET"]
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R 5 0 R 7 0 R] /Count 3 >>"]
        for (index, stream) in streams.enumerated() {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 9 0 R >> >> /Contents \(4 + index * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        objects += ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>", "<< /Title (Execution Fixture) /Author (Fixture Author) >>"]
        var body = "%PDF-1.4\n"
        var offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count)
            body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let start = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { body += String(format: "%010d 00000 n \n", offset) }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /Info 10 0 R >>\nstartxref\n\(start)\n%%EOF\n"
        return Data(body.utf8)
    }

    static func provenance(_ catalog: BundledSkillCatalog) throws {
        let reports = SkillExecutionDependencies.reports(catalog: catalog)
        try expect(reports.map(\.skillID) == BundledSkillCatalog.entryIDs, "all six source instructions reviewed")
        try expect(reports.allSatisfy { !$0.originalParity && !$0.dependencies.isEmpty }, "no false parity")
        try expect(reports.flatMap(\.provenance).count == 9, "six instructions and three supporting assets")
        let documents = reports.first { $0.skillID == "documents" }!
        try expect(documents.provenance.contains { $0.sha256 == SkillExecutionHTTPWorker.scriptSHA256 }, "exact original script hash")
        try expect(documents.provenance.allSatisfy { $0.revision == BundledSkillCatalog.pinnedCommit }, "pinned provenance")
        let query = documents.dependencies.first { $0.original == "read_file / search_files" }
        try expect(query?.status == .implementedInRuntime && query?.mapping == SkillExecutionDependencies.pdfQueryScope,
                   "PDF query is available with exact UI scope")
        try expect(SkillExecutionDependencies.pdfQueryScope.contains("本次已擷取") &&
                   SkillExecutionDependencies.pdfQueryScope.contains("不開放任意路徑、workspace"), "no arbitrary workspace claim")
        try expect(documents.dependencies.first { $0.original == "run_command + pypdf / OCR" }?.status == .excluded,
                   "query availability does not enable shell")
        try expect(documents.dependencies.first { $0.original == "--out / share_file" }?.status == .hostIntegrationRequired,
                   "user export is not a generic skill share tool")

    }

    static func nativePDF() async throws {
        let data = pdf()
        let full = try SkillExecutionPDF.extract(data, options: .init())
        try expect(full.pageCount == 3 && full.pages.map(\.number) == [1, 2, 3], "actual three-page PDF")
        try expect(full.pages[0].text == "Alpha evidence" && full.pages[2].text == "Beta evidence", "actual PDFKit text")
        try expect(full.emptyPages == [2] && !full.needsOCR, "partial empty pages are visible")
        try expect(full.text.contains("--- page 3 ---\nBeta evidence"), "page citations")
        try expect(full.originalScriptSHA256 == nil && full.engine == "Apple PDFKit", "native output does not impersonate Python")
        let selection = try SkillExecutionPDF.extract(data, options: .init(pages: "3,1-2,3"))
        try expect(selection.pages.map(\.number) == [3, 1, 2, 3], "preserve original selection order and duplicates")
        let empty = try SkillExecutionPDF.extract(data, options: .init(pages: "2"))
        try expect(empty.needsOCR && empty.emptyPages == [2], "image-only/empty text outcome")
        let info = try SkillExecutionPDF.extract(data, options: .init(metadataOnly: true))
        try expect(info.pages.isEmpty && info.metadata["title"] == "Execution Fixture", "metadata uses real PDFKit")
        for spec in ["0", "4", "3-1", "1,,2", "-1", "1-", "１", "1; rm", "99999999999999999999"] {
            try await rejects(.invalidPages) { _ = try SkillExecutionPDF.extract(data, options: .init(pages: spec)) }
        }
        try await rejects(.tooManyPages) { _ = try SkillExecutionPDFOptions(pages: "1-201") }
        let huge = try SkillExecutionPageRange.parse("1,\(Int.max)", pageCount: Int.max)
        try expect(huge == [1, Int.max], "range arithmetic does not overflow")
        try await rejects(.invalidPDF) { _ = try SkillExecutionPDF.extract(Data("bad".utf8), options: .init()) }
        let document = PDFDocument(data: data)!
        guard let locked = document.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "test-only", PDFDocumentWriteOption.ownerPasswordOption: "owner-only"]) else {
            throw Failure(message: "PDFKit encrypted fixture failed")
        }
        try await rejects(.passwordRequired) { _ = try SkillExecutionPDF.extract(locked, options: .init()) }
        try await rejects(.passwordRequired) { _ = try SkillExecutionPDF.extract(locked, options: .init(password: "wrong")) }
        let unlocked = try SkillExecutionPDF.extract(locked, options: .init(pages: "1", password: "test-only"))
        try expect(unlocked.pages[0].text == "Alpha evidence", "real encrypted PDF unlock")
    }

    static func coordinatedRead() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = pdf()
        // Same-length text keeps the real fixture's xref offsets intact.
        let changed = Data(String(decoding: original, as: UTF8.self)
            .replacingOccurrences(of: "Alpha evidence", with: "Gamma evidence").utf8)
        func withPresenter(_ replacement: Data?, _ check: (SkillExecutionSelectedFile, PendingPDFPresenter) throws -> Void) throws {
            let url = folder.appendingPathComponent(UUID().uuidString + ".pdf")
            try original.write(to: url)
            let presenter = PendingPDFPresenter(url: url, replacement: replacement)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            try check(SkillExecutionSelectedFile(userSelectedURL: url), presenter)
        }
        try withPresenter(changed) { selected, presenter in
            let snapshot = try SkillExecutionPDF.read(selected)
            try expect(presenter.saveCount > 0, "real file coordination must request pending presenter changes")
            try expect(snapshot == changed, "snapshot must include the presenter's saved bytes")
            let result = try SkillExecutionPDF.extract(snapshot, options: .init())
            try expect(result.pages[0].text == "Gamma evidence", "actual PDFKit sees coordinated content, not stale bytes")
        }
        try withPresenter(nil) { selected, presenter in
            do {
                _ = try SkillExecutionPDF.read(selected)
                throw Failure(message: "must not fall back to uncoordinated read after presenter refuses")
            } catch SkillExecutionError.invalidSelection { }
            try expect(presenter.saveCount > 0, "real presenter must receive save request before rejecting")
        }
        let oversized = Data(repeating: 0, count: SkillExecutionLimits.fileBytes + 1)
        try withPresenter(oversized) { selected, presenter in
            do {
                _ = try SkillExecutionPDF.read(selected)
                throw Failure(message: "size check must use the post-coordination item")
            } catch SkillExecutionError.fileTooLarge { }
            try expect(presenter.saveCount > 0, "oversized replacement must come from real coordination")
        }
    }

    static func authorization(_ catalog: BundledSkillCatalog) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("selected.pdf")
        let data = pdf(); try data.write(to: url)
        let selected = try SkillExecutionSelectedFile(userSelectedURL: url)
        let runtime = try SkillExecutionRuntime(selectedFile: selected, options: .init(), catalog: catalog)
        let plan = runtime.plan
        try expect(!plan.grantsAuthorization && plan.steps.allSatisfy(\.requiresAuthorization), "reference is not permission")
        let forged = SkillExecutionApproval(id: UUID(), planID: plan.id, stepID: plan.steps[0].id, expiresAt: .distantFuture)
        try await rejects(.approvalRequired) { _ = try await runtime.execute(forged) }
        try await rejects(.stalePlan) { _ = try await runtime.authorize(stepID: plan.steps[1].id) }
        let grant = try await runtime.authorize(stepID: plan.steps[0].id)
        let other = try SkillExecutionRuntime(selectedFile: selected, options: .init(), catalog: catalog)
        try await rejects(.approvalRequired) { _ = try await other.execute(grant) }
        let read = try await runtime.execute(grant)
        guard case .selectedFileRead(let size, let hash) = read else { throw Failure(message: "expected read step") }
        try expect(size == data.count && hash == skillExecutionDigest(data), "exact selected bytes")
        try await rejects(.approvalRequired) { _ = try await runtime.execute(grant) }
        // The second step uses the authorized snapshot even if the source changes.
        try Data("changed file".utf8).write(to: url)
        let extraction = try await runtime.authorize(stepID: plan.steps[1].id)
        guard case .pdf(let result) = try await runtime.execute(extraction) else { throw Failure(message: "expected PDF result") }
        try expect(result.pages[0].text == "Alpha evidence" && result.inputSHA256 == hash, "no reopen/TOCTOU after approval")
        let next = await runtime.nextStep(); try expect(next == nil, "terminal plan")
        try await rejects(.stalePlan) { _ = try await runtime.authorize(stepID: plan.steps[1].id) }

        let clock = TestClock()
        let expiring = try SkillExecutionRuntime(selectedFile: selected, options: .init(), catalog: catalog, clock: { clock.now })
        let expired = try await expiring.authorize(stepID: expiring.plan.steps[0].id)
        clock.advance()
        try await rejects(.expiredApproval) { _ = try await expiring.execute(expired) }
        try await rejects(.approvalRequired) { _ = try await expiring.execute(expired) }
        let unsupported = try SkillExecutionRuntime(selectedFile: selected, options: .init(), backend: .originalWorker, catalog: catalog)
        try expect(!unsupported.plan.steps[1].availability.available, "no fake remote endpoint")
        try data.write(to: url)
        _ = try await unsupported.execute(unsupported.authorize(stepID: unsupported.plan.steps[0].id))
        try await rejects(.unavailable) { _ = try await unsupported.authorize(stepID: unsupported.plan.steps[1].id) }
        await other.cancel()
        try await rejects(.cancelled) { _ = try await other.authorize(stepID: other.plan.steps[0].id) }
        try await rejects(.invalidSelection) { _ = try SkillExecutionSelectedFile(userSelectedURL: URL(string: "https://example.com/a.pdf")!) }
        try Data("changed file".utf8).write(to: url)
        try await rejects(.invalidPDF) { _ = try SkillExecutionPDF.read(selected) }
        try FileManager.default.removeItem(at: url)
        try await rejects(.invalidSelection) { _ = try SkillExecutionPDF.read(selected) }
        let link = folder.appendingPathComponent("link.pdf")
        try data.write(to: url)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        try await rejects(.invalidSelection) { _ = try SkillExecutionPDF.read(.init(userSelectedURL: link)) }
        try Data(repeating: 0, count: SkillExecutionLimits.fileBytes + 1).write(to: url)
        try await rejects(.fileTooLarge) { _ = try SkillExecutionPDF.read(selected) }
        var maximum = data
        maximum.append(Data(repeating: 32, count: SkillExecutionLimits.fileBytes - data.count))
        try maximum.write(to: url)
        let bounded = try SkillExecutionPDF.read(selected)
        try expect(bounded == maximum, "exactly 10 MiB is allowed without truncating the selected bytes")
        let directory = folder.appendingPathComponent("directory.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try await rejects(.invalidSelection) { _ = try SkillExecutionPDF.read(.init(userSelectedURL: directory)) }
    }

    static func cancellation(_ catalog: BundledSkillCatalog) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf().write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let worker = GateWorker()
        let runtime = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: url), options: .init(),
            backend: .originalWorker, worker: worker, catalog: catalog)
        _ = try await runtime.execute(runtime.authorize(stepID: runtime.plan.steps[0].id))
        let calls = await worker.calls; try expect(calls == 0, "read approval does not upload")
        let grant = try await runtime.authorize(stepID: runtime.plan.steps[1].id)
        let task = Task { try await runtime.execute(grant) }
        await worker.waitForStart()
        try await rejects(.busy) { _ = try await runtime.execute(grant) }
        await runtime.cancel(); await worker.release()
        try await rejects(.cancelled) { _ = try await task.value }
        let returned = await worker.responses
        try expect(returned == 1, "the adapter actually returned a late response; cancellation must discard it")
        let next = await runtime.nextStep(); try expect(next == nil, "no late result after cancellation")

        // Positive control: the same adapter response must pass runtime validation
        // without cancellation. Also force release-before-registration rather than
        // relying on a particular actor scheduler to exercise that gate ordering.
        let early = GateWorker()
        await early.release()
        let accepting = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: url), options: .init(),
            backend: .originalWorker, worker: early, catalog: catalog)
        _ = try await accepting.execute(accepting.authorize(stepID: accepting.plan.steps[0].id))
        let approved = try await accepting.authorize(stepID: accepting.plan.steps[1].id)
        guard case .pdf(let accepted) = try await accepting.execute(approved) else {
            throw Failure(message: "uncancelled adapter response must be accepted")
        }
        await early.waitForStart()
        try expect(accepted.pages.map(\.number) == [1, 2, 3] && accepted.emptyPages == [2],
                   "late-result fixture is valid, so an invalid response cannot mask cancellation")
    }

    static func remote(_ catalog: BundledSkillCatalog, endpoint: URL) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try pdf().write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let worker = try SkillExecutionHTTPWorker(endpoint: endpoint, allowLoopbackForTesting: true)
        let runtime = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: url), options: .init(pages: "3,2,1"),
            backend: .originalWorker, worker: worker, catalog: catalog)
        _ = try await runtime.execute(runtime.authorize(stepID: runtime.plan.steps[0].id))
        let approval = try await runtime.authorize(stepID: runtime.plan.steps[1].id)
        guard case .pdf(let result) = try await runtime.execute(approval) else { throw Failure(message: "worker result missing") }
        try expect(result.pages.map(\.number) == [3,2,1] && result.pages[0].text == "Beta evidence", "real HTTP original script output")
        try expect(result.emptyPages == [2] && result.originalScriptSHA256 == SkillExecutionHTTPWorker.scriptSHA256, "worker provenance and empty pages")
        try await rejects(.unavailable) { _ = try SkillExecutionHTTPWorker(endpoint: URL(string: "http://example.com/worker")!) }
        try await rejects(.unavailable) { _ = try SkillExecutionHTTPWorker(endpoint: URL(string: "https://example.com/worker?key=fixture")!) }
    }

    static func remoteValidation(endpoint: URL) async throws {
        for (path, error) in [("invalid-hash", SkillExecutionError.invalidWorkerResponse),
                              ("invalid-pages", .invalidWorkerResponse), ("redirect", .workerFailed),
                              ("oversized", .workerFailed)] {
            let url = endpoint.deletingLastPathComponent().appendingPathComponent(path)
            let worker = try SkillExecutionHTTPWorker(endpoint: url, allowLoopbackForTesting: true)
            try await rejects(error) { _ = try await worker.extract(data: pdf(), options: .init()) }
        }
        let authenticatedURL = endpoint.deletingLastPathComponent().appendingPathComponent("authenticated")
        let token = "synthetic-pdf-worker-bearer"
        let authenticated = try SkillExecutionHTTPWorker(endpoint: authenticatedURL,
            authorizationBearer: token, allowLoopbackForTesting: true)
        let result = try await authenticated.extract(data: pdf(), options: .init(pages: "1"))
        try expect(result.pages.map(\.text) == ["Alpha evidence"], "authenticated request executes actual original script")
        try expect(!authenticated.destination.contains(token), "plan destination never contains the bearer")
        for invalid in [nil, "wrong-synthetic-token"] {
            let denied = try SkillExecutionHTTPWorker(endpoint: authenticatedURL,
                authorizationBearer: invalid, allowLoopbackForTesting: true)
            try await rejects(.workerFailed) { _ = try await denied.extract(data: pdf(), options: .init()) }
        }
        for invalid in ["", "has space", "line\r\nbreak", "非ASCII", String(repeating: "a", count: 4097)] {
            try await rejects(.unavailable) { _ = try SkillExecutionHTTPWorker(endpoint: authenticatedURL,
                authorizationBearer: invalid, allowLoopbackForTesting: true) }
        }
        let redirect = try SkillExecutionHTTPWorker(endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("redirect"),
            authorizationBearer: token, allowLoopbackForTesting: true)
        try await rejects(.workerFailed) { _ = try await redirect.extract(data: pdf(), options: .init()) }
    }

    /// A real Foundation file presenter with unsaved synthetic content. The
    /// production read must coordinate with it; a direct FileHandle read fails
    /// these tests by returning stale bytes or ignoring its save refusal.
    final class PendingPDFPresenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue = {
            let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue
        }()
        private let replacement: Data?
        private let lock = NSLock()
        private var saves = 0
        var saveCount: Int { lock.lock(); defer { lock.unlock() }; return saves }
        init(url: URL, replacement: Data?) { presentedItemURL = url; self.replacement = replacement }
        func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
            lock.lock(); saves += 1; lock.unlock()
            do {
                guard let replacement, let url = presentedItemURL else { throw CocoaError(.fileWriteNoPermission) }
                try replacement.write(to: url, options: .atomic)
                completionHandler(nil)
            } catch { completionHandler(error) }
        }
    }

    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date()
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance() { lock.lock(); defer { lock.unlock() }; value = value.addingTimeInterval(121) }
    }
    actor GateWorker: SkillExecutionPDFWorker {
        nonisolated let destination = "test adapter; no network"
        var calls = 0
        var responses = 0
        private var released = false
        private var started: CheckedContinuation<Void, Never>?
        private var pending: CheckedContinuation<Void, Never>?
        func waitForStart() async {
            await withCheckedContinuation { continuation in
                if calls > 0 { continuation.resume() } else { started = continuation }
            }
        }
        func release() { released = true; pending?.resume(); pending = nil }
        func extract(data: Data, options: SkillExecutionPDFOptions) async throws -> SkillExecutionPDFResult {
            await withCheckedContinuation { continuation in
                calls += 1
                if released { continuation.resume() } else { pending = continuation }
                started?.resume(); started = nil
            }
            // This adapter tests delayed remote responses, not local extraction.
            // Both iOS 18 timeout spindumps reached PDFDocument.init here after
            // release, waiting on SpringBoard. Keep PDFKit in nativePDF(), the
            // coordinated-read checks and native UI tests; keep real Python in
            // the HTTP integration tests. Do not start it after this fake gate.
            let texts = ["Alpha evidence", "", "Beta evidence"]
            let numbers = options.metadataOnly ? [] : try SkillExecutionPageRange.parse(options.pages, pageCount: 3)
            let pages = numbers.map { SkillExecutionPDFPage(number: $0, text: texts[$0 - 1]) }
            responses += 1
            return SkillExecutionPDFResult(pageCount: 3, pages: pages, metadata: ["pages": "3"],
                emptyPages: pages.filter { $0.text.isEmpty }.map(\.number), inputSHA256: skillExecutionDigest(data),
                engine: "GateWorker test fixture", originalScriptSHA256: SkillExecutionHTTPWorker.scriptSHA256)
        }
    }
}

#if SKILL_EXECUTION_SMOKE
@main
struct SkillExecutionStandalone {
    static func main() async throws {
        let args = ProcessInfo.processInfo.arguments
        guard args.count >= 2 else { throw SkillExecutionChecks.Failure(message: "catalog resource path required") }
        let catalog = try BundledSkillCatalog.load(data: Data(contentsOf: URL(fileURLWithPath: args[1])))
        try SkillExecutionChecks.provenance(catalog); print("PASS six-skill provenance and dependency mapping")
        try await SkillExecutionChecks.nativePDF(); print("PASS actual PDFKit text, metadata, pages, encryption and invalid inputs")
        try await SkillExecutionChecks.coordinatedRead(); print("PASS real file presenter save, refusal and post-coordination byte limit")
        try await SkillExecutionChecks.authorization(catalog); print("PASS per-step approval, replay, expiry, selection and byte snapshot")
        try await SkillExecutionChecks.cancellation(catalog); print("PASS upload gating, concurrency and cancellation")
        if args.count >= 3 {
            try await SkillExecutionChecks.remote(catalog, endpoint: URL(string: args[2])!)
            print("PASS Swift HTTP -> pinned original Python script integration")
        }
        if args.count == 4 && args[3] == "--test-protocol-rejections" {
            try await SkillExecutionChecks.remoteValidation(endpoint: URL(string: args[2])!)
            print("PASS real HTTP redirect, provenance, page and size rejection")
        }
    }
}
#else
final class SkillExecutionTests: XCTestCase {
    func testPinnedProvenanceAndDependencies() throws { try SkillExecutionChecks.provenance(BundledSkillCatalog.bundled()) }
    func testRealPDFKitExtraction() async throws { try await SkillExecutionChecks.nativePDF() }
    func testCoordinatedSelectedFileRead() async throws { try await SkillExecutionChecks.coordinatedRead() }
    func testSelectedFileAndSingleUseAuthorization() async throws { try await SkillExecutionChecks.authorization(BundledSkillCatalog.bundled()) }
    func testCancellationAndUploadGating() async throws { try await SkillExecutionChecks.cancellation(BundledSkillCatalog.bundled()) }
}
#endif
#endif
