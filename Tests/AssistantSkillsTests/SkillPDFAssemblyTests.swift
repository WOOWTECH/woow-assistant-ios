#if !SKILLS_CORE_SMOKE && canImport(PDFKit)
import Foundation
import CoreGraphics
import PDFKit
#if !PDF_ASSEMBLY_STANDALONE
import XCTest
@testable import AssistantSkills
#endif

/// Actual native bytes and coordinated reads; shared by hosted XCTest and CLT.
enum SkillPDFAssemblyChecks {
    struct Failure: Error { let message: String }
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }
    static let checks = Counter()
    static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw Failure(message: message) }
        checks.add()
    }
    static func rejects<E: Error & Equatable>(_ expected: E, _ action: () async throws -> Void) async throws {
        do { try await action(); throw Failure(message: "expected rejection") }
        catch let error as E { try expect(error == expected, "exact error category") }
    }
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pdf-assembly-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    // Page 2 contains a real RGB Image XObject, not a vector rectangle or text.
    // Alternating saturated colors make blank/white rendering fail visibly.
    static let imageRGB: [UInt8] = (0..<16).flatMap { index -> [UInt8] in
        switch index % 4 {
        case 0: return [255, 0, 0]
        case 1: return [0, 255, 0]
        case 2: return [0, 0, 255]
        default: return [255, 255, 0]
        }
    }
    static func pdf(_ prefix: String = "A", count: Int = 3, catalogExtra: String = "", fractional: Bool = false) -> Data {
        let fontID = 3 + count * 2, imageID = fontID + 1
        var objects = ["<< /Type /Catalog /Pages 2 0 R \(catalogExtra) >>",
                       "<< /Type /Pages /Kids [\((0..<count).map { "\(3 + $0 * 2) 0 R" }.joined(separator: " "))] /Count \(count) >>"]
        for i in 0..<count {
            let width = 420 + i % 3 * 70, height = 320 + i % 3 * 90
            func box(_ inset: Double) -> String {
                let x = 10.125, y = 20.375, w = Double(width) + 0.1234, h = Double(height) + 0.5678
                return [x + inset, y + inset, x + w - inset, y + h - inset].map { String(format: "%.8f", $0) }.joined(separator: " ")
            }
            let bounds = fractional ?
                "/MediaBox [\(box(0))] /CropBox [\(box(10.4375))] /BleedBox [\(box(12.5625))] /TrimBox [\(box(14.6875))] /ArtBox [\(box(16.8125))]" :
                "/MediaBox [10 20 \(width + 10) \(height + 20)] /CropBox [20 30 \(width) \(height)] /BleedBox [22 32 \(width - 2) \(height - 2)] /TrimBox [24 34 \(width - 4) \(height - 4)] /ArtBox [26 36 \(width - 6) \(height - 6)]"
            let stream = i == 1 ? "q 160 0 0 120 55 70 cm /Im1 Do Q" :
                "0.2 0.4 0.8 rg 55 70 130 90 re f\nBT /F1 18 Tf 50 210 Td (\(prefix)_PAGE_\(i + 1)) Tj ET"
            objects.append("<< /Type /Page /Parent 2 0 R \(bounds) /Rotate \([0,90,270,180][i % 4]) /Resources << /Font << /F1 \(fontID) 0 R >> /XObject << /Im1 \(imageID) 0 R >> >> /Contents \(4 + i * 2) 0 R >>")
            objects.append("<< /Length \(stream.utf8.count) >>\nstream\n\(stream)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        let hex = imageRGB.map { String(format: "%02x", $0) }.joined() + ">"
        objects.append("<< /Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /ASCIIHexDecode /Length \(hex.utf8.count) >>\nstream\n\(hex)\nendstream")
        var body = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(body.utf8.count); body += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = body.utf8.count
        body += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { body += String(format: "%010d 00000 n \n", offset) }
        body += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Data(body.utf8)
    }
    static func pixels(_ page: PDFPage) throws -> Data {
        let side = 256
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let cg = page.pageRef else {
            throw Failure(message: "real raster context")
        }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.concatenate(cg.getDrawingTransform(.cropBox, rect: CGRect(x: 0, y: 0, width: side, height: side), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(cg)
        guard let data = context.data else { throw Failure(message: "raster bytes") }
        return Data(bytes: data, count: side * side * 4)
    }
    static func proveImage(_ page: PDFPage) throws {
        guard let dictionary = page.pageRef?.dictionary else { throw Failure(message: "page dictionary") }
        var resources: CGPDFDictionaryRef?, images: CGPDFDictionaryRef?, stream: CGPDFStreamRef?
        try expect(CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), "real page resources")
        try expect(CGPDFDictionaryGetDictionary(resources!, "XObject", &images), "image resource dictionary")
        try expect(CGPDFDictionaryGetStream(images!, "Im1", &stream), "actual Image XObject")
        var format = CGPDFDataFormat.raw
        guard let decoded = CGPDFStreamCopyData(stream!, &format) else { throw Failure(message: "image stream") }
        try expect(decoded as Data == Data(imageRGB), "decoded real raster samples")
        let rendered = [UInt8](try pixels(page))
        for channel in 0..<3 {
            let otherChannel = (channel + 1) % 3
            let remainingChannel = (channel + 2) % 3
            var hits = 0
            for pixel in stride(from: 0, to: rendered.count, by: 4) {
                let primary = rendered[pixel + channel]
                let other = rendered[pixel + otherChannel]
                let remaining = rendered[pixel + remainingChannel]
                if primary > 240 && other < 20 && remaining < 20 { hits += 1 }
            }
            try expect(hits > 50, "real raster has saturated RGB regions, not blank output")
        }
        try expect((page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "raster-only page has no fabricated text/OCR")
    }
    static func selected(_ url: URL) throws -> SkillExecutionSelectedFile { try .init(userSelectedURL: url) }
    static func readAll(_ runtime: SkillPDFAssemblyRuntime) async throws {
        for source in runtime.sources {
            _ = try await runtime.read(runtime.authorizeRead(sourceID: source.id))
        }
    }
    static func snapshot(_ bytes: Data, id: UUID = UUID()) throws -> SkillPDFAssemblySnapshot {
        .init(receipt: .init(source: .init(id: id, filename: "synthetic.pdf"),
            pageCount: try SkillPDFAssemblyNative.inspect(bytes), byteCount: bytes.count, sha256: skillExecutionDigest(bytes)), data: bytes)
    }

    static func nativeAssembly(_ catalog: BundledSkillCatalog) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let aURL = root.appendingPathComponent("source-a.pdf"), bURL = root.appendingPathComponent("source-b.pdf")
        let a = pdf(), b = pdf("B", count: 4)
        try a.write(to: aURL, options: .withoutOverwriting); try b.write(to: bURL, options: .withoutOverwriting)
        try proveImage(PDFDocument(data: a)!.page(at: 1)!)
        for order in ["1:2", "1:3,1:1-2", "1:3,2:2,1:2,1:1,2:4,1:3"] {
            let runtime = try SkillPDFAssemblyRuntime(selectedFiles: [selected(aURL), selected(bURL)], catalog: catalog)
            try await readAll(runtime)
            let plan = try await runtime.prepare(orderText: order)
            let expectedOrder: [(Int, Int)] = order == "1:2" ? [(0, 2)] : order == "1:3,1:1-2" ?
                [(0, 3), (0, 1), (0, 2)] : [(0, 3), (1, 2), (0, 2), (0, 1), (1, 4), (0, 3)]
            try expect(plan.order == expectedOrder.map { .init(sourceID: runtime.sources[$0.0].id, number: $0.1) },
                       "parser retains explicitly requested interleaving, source and page order")
            try expect(!plan.grantsAuthorization && plan.provenance.allSatisfy { $0.revision == BundledSkillCatalog.pinnedCommit }, "pinned instruction is not authority")
            let result = try await runtime.assemble(runtime.authorizeAssembly(planID: plan.id))
            let documents = [runtime.sources[0].id: PDFDocument(data: a)!, runtime.sources[1].id: PDFDocument(data: b)!]
            guard let output = PDFDocument(data: result.data) else { throw Failure(message: "real serialized PDF") }
            try expect(result.pageCount == plan.order.count && output.pageCount == plan.order.count, "serialized output page count")
            try expect(result.sha256 == skillExecutionDigest(result.data), "actual output digest")
            try expect(result.engine == "Apple PDFKit" && result.originalScriptSHA256 == nil, "no Python parity claim")
            try expect(plan.inputs.allSatisfy { $0.sha256 == skillExecutionDigest($0.id == runtime.sources[0].id ? a : b) }, "actual source digests")
            for (index, reference) in plan.order.enumerated() {
                let before = documents[reference.sourceID]!.page(at: reference.number - 1)!, after = output.page(at: index)!
                try expect(before.string == after.string, "exact text/order or empty raster text")
                try expect(before.rotation == after.rotation, "intrinsic page rotation")
                for box in SkillPDFAssemblyNative.boxes {
                    try expect(before.bounds(for: box).size == after.bounds(for: box).size, "exact page box dimensions")
                    try expect(SkillPDFAssemblyNative.relativeBounds(before, box) == SkillPDFAssemblyNative.relativeBounds(after, box), "media-relative page box geometry")
                }
                let expected = try pixels(before), actual = try pixels(after)
                try expect(actual == expected, "actual rendered image/vector/text pixels preserved byte-for-byte")
            }
            let retained = await runtime.receipts
            try expect(retained.isEmpty, "snapshots released after one delivered output")
            try await rejects(SkillExecutionError.stalePlan) { _ = try await runtime.authorizeAssembly(planID: plan.id) }
        }
        let unchangedA = try Data(contentsOf: aURL), unchangedB = try Data(contentsOf: bURL)
        try expect(unchangedA == a && unchangedB == b, "original bytes unchanged")
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
        try expect(remainingFiles.count == 2, "runtime never auto-writes an output")
        try await fractionalGeometry(catalog)
    }

    static func fractionalGeometry(_ catalog: BundledSkillCatalog) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("fractional.pdf"), bytes = pdf(fractional: true)
        try bytes.write(to: url, options: .withoutOverwriting)
        let source = PDFDocument(data: bytes)!
        let media = source.page(at: 1)!.bounds(for: .mediaBox)
        try expect(media.origin == CGPoint(x: 10.125, y: 20.375) && media.width == 490.1234,
                   "fixture contains requested fractional origin and width, not rounded integer coordinates")
        let runtime = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog)
        try await readAll(runtime)
        let plan = try await runtime.prepare(orderText: "1:2,1:3,1:1")
        let result = try await runtime.assemble(runtime.authorizeAssembly(planID: plan.id))
        let output = PDFDocument(data: result.data)!
        try expect(output.pageCount == 3, "actual fractional-geometry output reopens")
        for (index, number) in [2, 3, 1].enumerated() {
            let before = source.page(at: number - 1)!, after = output.page(at: index)!
            try expect(after.rotation == before.rotation && after.string == before.string, "fractional rotation and text retained")
            for box in SkillPDFAssemblyNative.boxes {
                let a = SkillPDFAssemblyNative.relativeBounds(before, box), b = SkillPDFAssemblyNative.relativeBounds(after, box)
                let delta = zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]).map { abs($0 - $1) }.max()!
                // Independent absolute measurement for this known-size fixture,
                // tighter than 4 ULP at its largest 560-point dimension.
                try expect(delta <= 2e-13, "fractional roundtrip delta is measured sub-picopoint arithmetic only")
                try expect(SkillPDFAssemblyNative.sameGeometry(a, b), "production geometry verification accepts actual fractional roundtrip")
            }
            let beforePixels = try pixels(before), afterPixels = try pixels(after)
            try expect(beforePixels == afterPixels, "fractional image/text/vector rendering matches exactly")
        }
        let original = CGRect(x: 10.125, y: 20.375, width: 490.1234, height: 410.5678)
        var within = original, beyond = original
        for _ in 0..<4 { within.size.width = within.width.nextUp }
        beyond.size.width = within.width.nextUp
        try expect(SkillPDFAssemblyNative.sameGeometry(original, within), "four representable-step boundary")
        try expect(!SkillPDFAssemblyNative.sameGeometry(original, beyond), "five representable steps rejected")
        var changed = original; changed.size.width += 0.000001
        try expect(!SkillPDFAssemblyNative.sameGeometry(original, changed), "actual dimension change rejected even at one millionth of a point")
        changed = original; changed.origin.x += 0.000001
        try expect(!SkillPDFAssemblyNative.sameGeometry(original, changed), "relative box translation rejected")
        changed = original; changed.size.width = .infinity
        try expect(!SkillPDFAssemblyNative.sameGeometry(original, changed), "infinite geometry rejected")
        changed = original; changed.origin.x = .nan
        try expect(!SkillPDFAssemblyNative.sameGeometry(original, changed), "NaN geometry rejected")
    }

    static func boundsAndRestrictions(_ catalog: BundledSkillCatalog) async throws {
        let input = try snapshot(pdf()), page = SkillPDFAssemblyPage(sourceID: input.receipt.id, number: 1)
        for order in [[], [.init(sourceID: input.receipt.id, number: 0)], [.init(sourceID: input.receipt.id, number: 4)], [.init(sourceID: UUID(), number: 1)]] as [[SkillPDFAssemblyPage]] {
            try await rejects(SkillExecutionError.invalidPages) { _ = try SkillPDFAssemblyNative.assemble([input], order: order) }
        }
        try await rejects(SkillExecutionError.tooManyPages) { _ = try SkillPDFAssemblyNative.assemble([input], order: Array(repeating: page, count: 201)) }
        let maximum = try SkillPDFAssemblyNative.assemble([input], order: Array(repeating: page, count: 200))
        try expect(PDFDocument(data: maximum)?.pageCount == 200, "actual 200-page output boundary")
        try await rejects(SkillPDFAssemblyError.invalidSources) { _ = try SkillPDFAssemblyNative.assemble([input, input], order: [page]) }
        try await rejects(SkillExecutionError.fileTooLarge) { _ = try SkillPDFAssemblyNative.inspect(Data(repeating: 0, count: SkillPDFAssemblyLimits.inputBytes + 1)) }
        try await rejects(SkillExecutionError.invalidPDF) { _ = try SkillPDFAssemblyNative.inspect(Data("bad".utf8)) }
        try await rejects(SkillExecutionError.tooManyPages) { _ = try SkillPDFAssemblyNative.inspect(pdf(count: 201)) }
        for key in ["AcroForm", "Names", "OpenAction", "AA", "Perms", "Outlines", "Collection", "StructTreeRoot", "OCProperties", "AF"] {
            try await rejects(SkillPDFAssemblyError.unsupportedDocument) { _ = try SkillPDFAssemblyNative.inspect(pdf(catalogExtra: "/\(key) << >>")) }
        }
        let protected = PDFDocument(data: pdf())!.dataRepresentation(options: [PDFDocumentWriteOption.userPasswordOption: "synthetic-user", PDFDocumentWriteOption.ownerPasswordOption: "synthetic-owner"])!
        try await rejects(SkillPDFAssemblyError.protectedPDF) { _ = try SkillPDFAssemblyNative.inspect(protected) }
        let annotated = PDFDocument(data: pdf())!
        annotated.page(at: 0)!.addAnnotation(PDFAnnotation(bounds: CGRect(x: 40, y: 50, width: 30, height: 30), forType: .text, withProperties: nil))
        let annotations = try snapshot(annotated.dataRepresentation()!)
        try await rejects(SkillPDFAssemblyError.unsupportedDocument) { _ = try SkillPDFAssemblyNative.assemble([annotations], order: [.init(sourceID: annotations.receipt.id, number: 1)]) }

        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let aURL = root.appendingPathComponent("a.pdf"), bURL = root.appendingPathComponent("b.pdf")
        try pdf(count: 101).write(to: aURL); try pdf("B", count: 100).write(to: bURL)
        let runtime = try SkillPDFAssemblyRuntime(selectedFiles: [selected(aURL), selected(bURL)], catalog: catalog)
        _ = try await runtime.read(runtime.authorizeRead(sourceID: runtime.sources[0].id))
        try await rejects(SkillExecutionError.tooManyPages) { _ = try await runtime.read(runtime.authorizeRead(sourceID: runtime.sources[1].id)) }
        let retained = await runtime.receipts
        try expect(retained.count == 1 && retained[0].pageCount == 101, "aggregate 200-input-page budget rejects second receipt")
        let s1 = try snapshot(Data(contentsOf: aURL)), s2 = try snapshot(Data(contentsOf: bURL))
        try await rejects(SkillExecutionError.tooManyPages) { _ = try SkillPDFAssemblyNative.assemble([s1, s2], order: [.init(sourceID: s1.receipt.id, number: 1)]) }
        try pdf(count: 100).write(to: aURL)
        let exactInputBound = try SkillPDFAssemblyRuntime(selectedFiles: [selected(aURL), selected(bURL)], catalog: catalog)
        try await readAll(exactInputBound)
        let exactReceipts = await exactInputBound.receipts
        try expect(exactReceipts.reduce(0, { $0 + $1.pageCount }) == 200, "exact aggregate input page boundary remains usable")
        let exactPlan = try await exactInputBound.prepare(orderText: "1:100,2:100")
        let exactOutput = try await exactInputBound.assemble(exactInputBound.authorizeAssembly(planID: exactPlan.id))
        try expect(exactOutput.pageCount == 2, "actual native assembly accepts 200 total input pages")
        try await rejects(SkillPDFAssemblyError.invalidSources) { _ = try SkillPDFAssemblyRuntime(selectedFiles: [], catalog: catalog) }
        try await rejects(SkillPDFAssemblyError.invalidSources) { _ = try SkillPDFAssemblyRuntime(selectedFiles: [selected(aURL), selected(aURL)], catalog: catalog) }
        try await rejects(SkillPDFAssemblyError.invalidSources) { _ = try SkillPDFAssemblyRuntime(selectedFiles: (0..<4).map { try selected(root.appendingPathComponent("\($0).pdf")) }, catalog: catalog) }
    }

    static func approvalAndStorage(_ catalog: BundledSkillCatalog) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("selected.pdf")
        let original = pdf(), changed = pdf("B")
        try original.write(to: url)
        let presenter = Presenter(url: url, replacement: changed)
        NSFileCoordinator.addFilePresenter(presenter)
        defer { NSFileCoordinator.removeFilePresenter(presenter) }
        let runtime = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog)
        let source = runtime.sources[0]
        try expect(presenter.saves.count == 0, "construction has not read storage")
        let fake = SkillPDFAssemblyApproval(id: UUID(), runtimeID: UUID(), target: source.id, assembly: false, expiresAt: .distantFuture)
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await runtime.read(fake) }
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await runtime.pages(sourceID: source.id) }
        let grant = try await runtime.authorizeRead(sourceID: source.id)
        try expect(presenter.saves.count == 0, "issuing approval alone does not read storage")
        let other = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog)
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await other.read(grant) }
        let receipt = try await runtime.read(grant)
        try expect(presenter.saves.count > 0 && receipt.sha256 == skillExecutionDigest(changed), "real file presenter saved bytes before actual coordinated read")
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await runtime.read(grant) }
        let readCount = presenter.saves.count
        // File no longer exists; assembling must use approved immutable bytes.
        try FileManager.default.removeItem(at: url)
        let old = try await runtime.prepare(orderText: "1:3,1:1-2,1:3")
        try expect(old.order.map(\.number) == [3, 1, 2, 3], "range parser preserves explicit order and duplicate pages")
        let obsolete = try await runtime.authorizeAssembly(planID: old.id)
        let plan = try await runtime.prepare(orderText: "1:1,1:2")
        try expect(plan.fingerprint != old.fingerprint, "changed order changes reviewed plan fingerprint")
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await runtime.assemble(obsolete) }
        let badGrant = try await runtime.authorizeAssembly(planID: plan.id)
        try await rejects(SkillExecutionError.invalidPages) { _ = try await runtime.prepare(orderText: "1:0") }
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await runtime.assemble(badGrant) }
        for invalid in ["", "0:1", "2:1", "1:", "1:3-1", "1:1,,1:2", "１:1", "1:１", "1:1:2", "1:1;script", String(repeating: "1", count: 4097)] {
            try await rejects(SkillExecutionError.invalidPages) { _ = try await runtime.prepare(orderText: invalid) }
        }
        let final = try await runtime.prepare(orderText: "1:1,1:2")
        let result = try await runtime.assemble(runtime.authorizeAssembly(planID: final.id))
        try expect(PDFDocument(data: result.data)?.page(at: 0)?.string?.contains("B_PAGE_1") == true, "output came from saved approved snapshot")
        try expect(result.plan.inputs[0].sha256 == receipt.sha256 && presenter.saves.count == readCount, "no storage reread after approval")
        try expect(!FileManager.default.fileExists(atPath: url.path), "runtime never rewrites deleted original")
    }

    final class Presenter: NSObject, NSFilePresenter, @unchecked Sendable {
        let presentedItemURL: URL?
        let presentedItemOperationQueue: OperationQueue
        let replacement: Data
        let saves = Counter()
        init(url: URL, replacement: Data) {
            presentedItemURL = url; self.replacement = replacement
            presentedItemOperationQueue = OperationQueue(); presentedItemOperationQueue.maxConcurrentOperationCount = 1
        }
        func savePresentedItemChanges(completionHandler: @escaping (Error?) -> Void) {
            saves.add()
            do { try replacement.write(to: presentedItemURL!); completionHandler(nil) }
            catch { completionHandler(error) }
        }
    }
    final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func expire() { lock.lock(); value.addTimeInterval(121); lock.unlock() }
    }
    actor Gate {
        private var begun = false, released = false
        private var waiting: CheckedContinuation<Void, Never>?
        func suspend() async {
            begun = true
            if !released { await withCheckedContinuation { waiting = $0 } }
        }
        func waitForStart() async throws {
            for _ in 0..<100 {
                if begun { return }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            throw Failure(message: "native operation did not reach cancellation gate within 10 seconds")
        }
        func release() { released = true; waiting?.resume(); waiting = nil }
    }

    static func expiryAndCancellation(_ catalog: BundledSkillCatalog) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("selected.pdf"); try pdf().write(to: url)
        let clock = Clock()
        let runtime = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog, clock: { clock.now })
        let expired = try await runtime.authorizeRead(sourceID: runtime.sources[0].id)
        clock.expire()
        try await rejects(SkillExecutionError.expiredApproval) { _ = try await runtime.read(expired) }
        try await rejects(SkillExecutionError.approvalRequired) { _ = try await runtime.read(expired) }
        try await readAll(runtime)
        let plan = try await runtime.prepare(orderText: "1:1")
        let assembly = try await runtime.authorizeAssembly(planID: plan.id)
        clock.expire()
        try await rejects(SkillExecutionError.expiredApproval) { _ = try await runtime.assemble(assembly) }
        let current = try await runtime.authorizeAssembly(planID: plan.id)
        await runtime.cancel()
        try await rejects(SkillExecutionError.cancelled) { _ = try await runtime.assemble(current) }
        let retained = await runtime.receipts, retainedPlan = await runtime.preparedPlan
        try expect(retained.isEmpty && retainedPlan == nil, "cancel revokes plan and snapshots")

        let gate = Gate()
        let reading = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog,
            reader: { file in let data = try SkillExecutionPDF.read(file); await gate.suspend(); return data },
            assembler: { try SkillPDFAssemblyNative.assemble($0, order: $1) })
        let readGrant = try await reading.authorizeRead(sourceID: reading.sources[0].id)
        let pending = Task { try await reading.read(readGrant) }
        defer { pending.cancel(); Task { await gate.release() } }
        try await gate.waitForStart()
        try await rejects(SkillExecutionError.busy) { _ = try await reading.authorizeRead(sourceID: reading.sources[0].id) }
        await reading.cancel(); await gate.release()
        try await rejects(SkillExecutionError.cancelled) { _ = try await pending.value }
        let noReceipt = await reading.receipts
        try expect(noReceipt.isEmpty, "actual late read cannot publish after revocation")
    }

    static func assemblyRaces(_ catalog: BundledSkillCatalog) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("selected.pdf"); try pdf().write(to: url)
        // The gate returns actual valid PDFKit output, so invalid bytes cannot
        // accidentally make the cancellation test pass.
        for cancelCaller in [false, true] {
            let gate = Gate(), produced = Counter()
            let runtime = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog,
                reader: { try SkillExecutionPDF.read($0) }, assembler: { inputs, order in
                    let bytes = try SkillPDFAssemblyNative.assemble(inputs, order: order)
                    produced.add(); await gate.suspend(); return bytes
                })
            try await readAll(runtime)
            let plan = try await runtime.prepare(orderText: "1:2,1:1")
            let grant = try await runtime.authorizeAssembly(planID: plan.id)
            let pending = Task { try await runtime.assemble(grant) }
            defer { pending.cancel(); Task { await gate.release() } }
            try await gate.waitForStart()
            try expect(produced.count == 1, "real native output exists before cancellation")
            try await rejects(SkillExecutionError.busy) { _ = try await runtime.prepare(orderText: "1:1") }
            try await rejects(SkillExecutionError.busy) { _ = try await runtime.assemble(grant) }
            if cancelCaller { pending.cancel() } else { await runtime.cancel() }
            await gate.release()
            try await rejects(SkillExecutionError.cancelled) { _ = try await pending.value }
            let receipts = await runtime.receipts
            try expect(receipts.isEmpty, "cancelled late native output cannot be delivered")
        }
        let gate = Gate(); await gate.release() // Positive control, release before registration.
        let accepting = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog,
            reader: { try SkillExecutionPDF.read($0) }, assembler: { inputs, order in
                let bytes = try SkillPDFAssemblyNative.assemble(inputs, order: order); await gate.suspend(); return bytes
            })
        try await readAll(accepting)
        let plan = try await accepting.prepare(orderText: "1:2,1:1")
        let accepted = try await accepting.assemble(accepting.authorizeAssembly(planID: plan.id))
        try expect(PDFDocument(data: accepted.data)?.pageCount == 2, "same real late-result adapter passes without cancellation")
        let oversized = try SkillPDFAssemblyRuntime(selectedFiles: [selected(url)], catalog: catalog,
            reader: { try SkillExecutionPDF.read($0) }, assembler: { _, _ in Data(repeating: 0, count: SkillPDFAssemblyLimits.outputBytes + 1) })
        try await readAll(oversized)
        let oversizePlan = try await oversized.prepare(orderText: "1:1")
        try await rejects(SkillPDFAssemblyError.outputTooLarge) { _ = try await oversized.assemble(oversized.authorizeAssembly(planID: oversizePlan.id)) }
    }
}

#if PDF_ASSEMBLY_STANDALONE
@main struct SkillPDFAssemblyStandalone {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw SkillPDFAssemblyChecks.Failure(message: "catalog path required") }
        let catalog = try BundledSkillCatalog.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        try await SkillPDFAssemblyChecks.nativeAssembly(catalog)
        try await SkillPDFAssemblyChecks.boundsAndRestrictions(catalog)
        try await SkillPDFAssemblyChecks.approvalAndStorage(catalog)
        try await SkillPDFAssemblyChecks.expiryAndCancellation(catalog)
        try await SkillPDFAssemblyChecks.assemblyRaces(catalog)
        print("PASS PDF assembly: \(SkillPDFAssemblyChecks.checks.count) assertions; actual PDFKit, raster pixels, coordinated reads, grants and cancellation")
    }
}
#else
final class SkillPDFAssemblyTests: XCTestCase {
    func testNativeExtractReorderMergePreservesRasterTextAndGeometry() async throws { try await SkillPDFAssemblyChecks.nativeAssembly(BundledSkillCatalog.bundled()) }
    func testBoundsAndUnsupportedDocuments() async throws { try await SkillPDFAssemblyChecks.boundsAndRestrictions(BundledSkillCatalog.bundled()) }
    func testApprovalSnapshotAndActualCoordinatedStorageRead() async throws { try await SkillPDFAssemblyChecks.approvalAndStorage(BundledSkillCatalog.bundled()) }
    func testExpiryRevocationAndReadCancellation() async throws { try await SkillPDFAssemblyChecks.expiryAndCancellation(BundledSkillCatalog.bundled()) }
    func testNativeAssemblyCancellationRacesAndOutputBound() async throws { try await SkillPDFAssemblyChecks.assemblyRaces(BundledSkillCatalog.bundled()) }
}
#endif
#endif
