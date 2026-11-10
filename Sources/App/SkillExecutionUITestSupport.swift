import Foundation
#if DEBUG
import CoreGraphics
import CoreText
import CryptoKit
import Darwin
import PDFKit
#endif

/// No startup hook is required: SkillExecutionView calls seedIfRequested on appear.
/// DEBUG + -UITestSkillExecution + exactly one isolated local or live namespace
/// are required. Live creates the same synthetic PDF without diagnostic file
/// inventory output. Neither mode selects, reads or approves a runtime input.
/// Release/default calls return before touching the filesystem.
enum SkillExecutionUITestSupport {
    struct Fixture {
        let namespace: UUID
        let url: URL
        var filename: String { url.lastPathComponent }
    }
    enum Failure: Error { case invalidNamespace, cannotCreatePDF, existingFile, invalidWriteMode, coordinationFailed }

    static func seedIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                documentsDirectory: () throws -> URL = {
                                    try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                                appropriateFor: nil, create: true)
                                }) throws -> Fixture? {
        #if DEBUG
        guard arguments.contains("-UITestSkillExecution") else { return nil }
        let local = arguments.filter { $0 == "-UITestMode" }.count
        let live = arguments.filter { $0 == "-LiveModelUITest" }.count
        let namespaceFlag = local == 1 ? "-UITestNamespace" : "-LiveModelUITestNamespace"
        let otherNamespaceFlag = local == 1 ? "-LiveModelUITestNamespace" : "-UITestNamespace"
        let allowedLiveFlags: Set<String> = live == 1 ? ["-LiveModelUITest", "-LiveModelUITestNamespace"] : []
        guard arguments.filter({ $0 == "-UITestSkillExecution" }).count == 1,
              (local == 1 && live == 0) || (local == 0 && live == 1),
              !arguments.contains(otherNamespaceFlag),
              !arguments.contains(where: { $0.hasPrefix("-Live") && !allowedLiveFlags.contains($0) }),
              arguments.filter({ $0 == namespaceFlag }).count == 1,
              let index = arguments.firstIndex(of: namespaceFlag), arguments.indices.contains(index + 1),
              let namespace = UUID(uuidString: arguments[index + 1]) else { throw Failure.invalidNamespace }
        // Live tests exercise the real user copy option, never a picker or
        // writer experiment. Cleanup is excluded by the live flag allowlist.
        guard live == 0 || !arguments.contains(where: {
            $0.hasPrefix("-UITestPDFUIKit") || $0.hasPrefix("-UITestSkillFixtureWriteMode")
        }) else { throw Failure.invalidNamespace }
        let writeMode = try fixtureWriteMode(arguments)
        // Do not even resolve/create Documents until all fixture gates pass.
        let root = try documentsDirectory()
        let url = root.appendingPathComponent("SkillExecution-\(namespace.uuidString).pdf")
        let fixture = Fixture(namespace: namespace, url: url)
        let title = "WOOW_SKILL_PDF_FIXTURE_" + namespace.uuidString
        if FileManager.default.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? 0) <= 128 * 1024,
                  let document = PDFDocument(url: url), document.pageCount == 2,
                  document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == title else {
                throw Failure.existingFile
            }
            if live == 0 {
                recordBaseline(fixture, phase: "existing")
                recordWriteMode(fixture, mode: writeMode, phase: "existing")
            }
            return fixture // Re-entering the view never overwrites another file.
        }
        let buffer = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: buffer),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.cannotCreatePDF }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        for number in 1...2 {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: 40, y: 700)
            let marker = NSAttributedString(string: "WOOW_SKILL_PDF_PAGE_\(number)", attributes: attributes)
            CTLineDraw(CTLineCreateWithAttributedString(marker), context)
            context.textPosition = CGPoint(x: 40, y: 660)
            let scope = NSAttributedString(string: namespace.uuidString, attributes: attributes)
            CTLineDraw(CTLineCreateWithAttributedString(scope), context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let document = PDFDocument(data: buffer as Data), document.pageCount == 2 else { throw Failure.cannotCreatePDF }
        document.documentAttributes = [PDFDocumentAttribute.titleAttribute: title,
                                       PDFDocumentAttribute.authorAttribute: "Synthetic UI fixture"]
        guard let bytes = document.dataRepresentation(), bytes.count <= 128 * 1024 else { throw Failure.cannotCreatePDF }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if live == 0 { recordWriteMode(fixture, mode: writeMode, phase: "willCreate") }
        switch writeMode {
        case .direct:
            try bytes.write(to: url, options: .withoutOverwriting)
        case .coordinated:
            var coordinationError: NSError?
            var written: Result<Void, Error> = .failure(Failure.coordinationFailed)
            NSFileCoordinator().coordinate(writingItemAt: url, options: [], error: &coordinationError) { destination in
                // A moved/redirected test target is not permission to create a
                // different file. Use the accessor URL only after this check.
                guard destination.standardizedFileURL == url.standardizedFileURL else { return }
                written = Result { try bytes.write(to: destination, options: .withoutOverwriting) }
            }
            if let coordinationError { throw coordinationError }
            try written.get() // No direct-write fallback when coordination fails.
        }
        if live == 0 {
            recordBaseline(fixture, phase: "created")
            recordWriteMode(fixture, mode: writeMode, phase: "created")
        }
        return fixture
        #else
        return nil
        #endif
    }

    #if DEBUG
    // Controlled experiment only. The existing direct path remains the control;
    // neither this switch nor the fixture is available to production launches.
    private enum WriteMode: String { case direct, coordinated }

    private static func fixtureWriteMode(_ arguments: [String]) throws -> WriteMode {
        let flag = "-UITestSkillFixtureWriteMode"
        guard arguments.contains(flag) else { return .direct }
        guard arguments.filter({ $0 == flag }).count == 1,
              let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1),
              let mode = WriteMode(rawValue: arguments[index + 1]) else { throw Failure.invalidWriteMode }
        return mode
    }

    private static func recordWriteMode(_ fixture: Fixture, mode: WriteMode, phase: String) {
        print("SKILL_PDF_FIXTURE_WRITE namespace=\(fixture.namespace.uuidString) mode=\(mode.rawValue) phase=\(phase) sampledAt=\(Date().timeIntervalSince1970)")
        fflush(stdout)
    }

    /// Diagnostic only: one exact synthetic basename, no directory enumeration,
    /// links, unbounded reads, runtime selection or extraction authorization.
    struct FixtureEvidence: Codable {
        var status: String
        var sampledAt: Double = Date().timeIntervalSince1970
        var bytes: Int64?
        var device: Int32?
        var inode: UInt64?
        var modifiedSeconds: Int64?
        var modifiedNanoseconds: Int64?
        var sha256: String?
    }

    struct FixtureBaseline: Codable {
        let version: Int
        let namespace: String
        let phase: String
        let evidence: FixtureEvidence
    }

    static func fixtureEvidence(in directory: URL, namespace: UUID) -> FixtureEvidence {
        let limit = 128 * 1024
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return FixtureEvidence(status: "directoryUnavailable") }
        defer { close(parent) }
        let filename = "SkillExecution-\(namespace.uuidString).pdf"
        let fd = openat(parent, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            return FixtureEvidence(status: errno == ENOENT ? "missing" : "openRejected")
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0 else { return FixtureEvidence(status: "statFailed") }
        guard before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1 else {
            return FixtureEvidence(status: "unsafeFile")
        }
        guard before.st_size >= 0, before.st_size <= limit else { return FixtureEvidence(status: "oversized") }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        var interruptions = 0
        while data.count <= limit {
            let count = buffer.withUnsafeMutableBytes { raw in
                read(fd, raw.baseAddress, min(raw.count, limit + 1 - data.count))
            }
            if count < 0 {
                if errno == EINTR, interruptions < 8 { interruptions += 1; continue }
                return FixtureEvidence(status: "readFailed")
            }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count <= limit else { return FixtureEvidence(status: "oversized") }
        var after = stat()
        var named = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1, named.st_nlink == 1,
              named.st_dev == after.st_dev, named.st_ino == after.st_ino, named.st_size == after.st_size,
              before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, Int64(data.count) == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            return FixtureEvidence(status: "changedDuringRead")
        }
        guard let pdf = PDFDocument(data: data), pdf.pageCount == 2,
              pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "WOOW_SKILL_PDF_FIXTURE_" + namespace.uuidString,
              pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Synthetic UI fixture" else {
            return FixtureEvidence(status: "invalidFixture")
        }
        return FixtureEvidence(status: "valid", bytes: after.st_size, device: after.st_dev,
            inode: UInt64(after.st_ino), modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    private static func recordBaseline(_ fixture: Fixture, phase: String) {
        let baseline = FixtureBaseline(version: 1, namespace: fixture.namespace.uuidString, phase: phase,
            evidence: fixtureEvidence(in: fixture.url.deletingLastPathComponent(), namespace: fixture.namespace))
        // No raw paths, document contents, passwords or selected-user-file data.
        // A diagnostic failure never changes seeding/picker/test behavior.
        if let bytes = try? JSONEncoder().encode(baseline), let json = String(data: bytes, encoding: .utf8) {
            print("SKILL_PDF_FIXTURE_BASELINE " + json)
            fflush(stdout) // XCTest may terminate the App while its picker is still open.
        }
    }
    #endif
}

#if DEBUG
/// Per-view test-only evidence. Updated at real runtime dispatch/result boundaries,
/// not from expected test outcomes. Clear/cancel intentionally preserves counts.
struct SkillExecutionUITestAudit {
    var selections = 0
    var reads = 0
    var extractionAttempts = 0
    var results = 0
    var evidence: String {
        "SKILL_EXECUTION_AUDIT selections=\(selections) reads=\(reads) extractionAttempts=\(extractionAttempts) results=\(results)"
    }
}
#endif
