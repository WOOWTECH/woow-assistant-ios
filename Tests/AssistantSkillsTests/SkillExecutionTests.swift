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
        let next = await runtime.nextStep(); try expect(next == nil, "no late result after cancellation")
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
        private var started: CheckedContinuation<Void, Never>?
        private var pending: CheckedContinuation<Void, Never>?
        func waitForStart() async { if calls == 0 { await withCheckedContinuation { started = $0 } } }
        func release() { pending?.resume(); pending = nil }
        func extract(data: Data, options: SkillExecutionPDFOptions) async throws -> SkillExecutionPDFResult {
            calls += 1
            await withCheckedContinuation { pending = $0; started?.resume(); started = nil }
            return try SkillExecutionPDF.extract(data, options: options)
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
    func testSelectedFileAndSingleUseAuthorization() async throws { try await SkillExecutionChecks.authorization(BundledSkillCatalog.bundled()) }
    func testCancellationAndUploadGating() async throws { try await SkillExecutionChecks.cancellation(BundledSkillCatalog.bundled()) }
}
#endif
#endif
