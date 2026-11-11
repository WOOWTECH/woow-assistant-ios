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
        // The two-source fixture has its own Assembly-only entry. Never turn
        // this flag into a single-file/Live fixture or touch Documents first.
        guard !arguments.contains(where: { $0.hasPrefix("-UITestSkillAssemblyPair") }) else {
            throw Failure.invalidNamespace
        }
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
            $0.hasPrefix("-UITestPDFUIKit") || $0.hasPrefix("-UITestPDFAssembly")
                || $0.hasPrefix("-UITestSkillFixtureWriteMode")
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
    struct AssemblyPairFixture {
        struct Source {
            let role: String
            let url: URL
            let sha256: String
            var filename: String { url.lastPathComponent }
        }
        struct CreationProof {
            let mode: String
            let coordinationAttempts: Int
            let accessorCalls: Int
            let createdFiles: Int
            let existingFiles: Int
            var accessibilityValue: String {
                "creation=\(mode) coordinationAttempts=\(coordinationAttempts) accessorCalls=\(accessorCalls) createdFiles=\(createdFiles) existingFiles=\(existingFiles)"
            }
        }
        let namespace: UUID
        let sources: [Source]
        let creationProof: CreationProof
    }

    /// Creates two real PDFs only for the isolated, non-Live Assembly case.
    /// Creation never supplies picker URLs, read grants or a runtime result.
    static func seedAssemblyPairIfRequested(arguments: [String] = ProcessInfo.processInfo.arguments,
                                           directoryCoordinator: NSFileCoordinator? = nil,
                                           documentsDirectory: () throws -> URL = {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
    }) throws -> AssemblyPairFixture? {
        let flag = "-UITestSkillAssemblyPair"
        let experiment = "-UITestSkillAssemblyPairDirectoryCoordinatedCreation"
        guard arguments.contains(where: { $0.hasPrefix(flag) }) else { return nil }
        let coordinated = arguments.contains(experiment)
        guard arguments.filter({ $0 == flag }).count == 1,
              arguments.filter({ $0 == experiment }).count <= 1,
              !arguments.contains(where: { $0.hasPrefix(flag) && $0 != flag && $0 != experiment }),
              arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestSkillExecution" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              !arguments.contains(where: {
                  $0.hasPrefix("-Live") || $0.hasPrefix("-UITestPDF") || $0.hasPrefix("-UITestSkillFixtureWriteMode")
              }),
              let position = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(position + 1),
              let namespace = UUID(uuidString: arguments[position + 1]),
              namespace.uuidString == arguments[position + 1] else { throw Failure.invalidNamespace }
        let directory = try documentsDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if coordinated {
            return try seedDirectoryCoordinatedAssemblyPair(in: directory, namespace: namespace,
                                                            coordinator: directoryCoordinator ?? NSFileCoordinator())
        }
        var sources: [AssemblyPairFixture.Source] = []
        var createdFiles = 0
        for role in ["A", "B"] {
            let url = directory.appendingPathComponent("SkillAssembly-\(role)-\(namespace.uuidString).pdf")
            let existed = FileManager.default.fileExists(atPath: url.path)
            if !existed {
                let data = try assemblyPairPDFBytes(role: role, namespace: namespace)
                try data.write(to: url, options: .withoutOverwriting)
                createdFiles += 1
            }
            let bytes = try validatedAssemblyPairBytes(url, role: role, namespace: namespace)
            sources.append(.init(role: role, url: url, sha256: pairDigest(bytes)))
            recordPairSnapshot(in: directory, namespace: namespace, role: role,
                               phase: existed ? "existing" : "created", ordinal: 0)
        }
        guard Set(sources.map(\.sha256)).count == 2 else { throw Failure.existingFile }
        return AssemblyPairFixture(namespace: namespace, sources: sources, creationProof: .init(
            mode: "direct", coordinationAttempts: 0, accessorCalls: 0,
            createdFiles: createdFiles, existingFiles: 2 - createdFiles))
    }

    private static func assemblyPairPDFBytes(role: String, namespace: UUID) throws -> Data {
        let title = "WOOW_ASSEMBLY_\(role)_\(namespace.uuidString)"
        let buffer = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: buffer),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else { throw Failure.cannotCreatePDF }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        for page in 1...2 {
            context.beginPDFPage(nil); context.textMatrix = .identity
            context.textPosition = CGPoint(x: 40, y: 700)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: "WOOW_ASSEMBLY_\(role)_PAGE_\(page)", attributes: attributes)), context)
            context.textPosition = CGPoint(x: 40, y: 660)
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(
                string: namespace.uuidString, attributes: attributes)), context)
            context.endPDFPage()
        }
        context.closePDF()
        guard let pdf = PDFDocument(data: buffer as Data) else { throw Failure.cannotCreatePDF }
        pdf.documentAttributes = [PDFDocumentAttribute.titleAttribute: title,
                                  PDFDocumentAttribute.authorAttribute: "Synthetic UI fixture"]
        guard let data = pdf.dataRepresentation(), data.count <= 128 * 1024 else { throw Failure.cannotCreatePDF }
        return data
    }

    private static func validatedAssemblyPairBytes(_ url: URL, role: String, namespace: UUID) throws -> Data {
        let title = "WOOW_ASSEMBLY_\(role)_\(namespace.uuidString)"
        let bytes = try assemblyPairBytes(url)
        guard bytes.starts(with: Data("%PDF-".utf8)),
              let pdf = PDFDocument(data: bytes), pdf.pageCount == 2,
              pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == title,
              pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Synthetic UI fixture",
              (1...2).allSatisfy({ assemblyPairPage(pdf.page(at: $0 - 1), matches: role, number: $0, namespace: namespace) }) else {
            throw Failure.existingFile
        }
        return bytes
    }

    /// Single directory-content write experiment. Prepared immutable PDF bytes,
    /// exact source names, picker behavior and read consent are unchanged.
    /// No retries, alternate URL, per-file coordination or direct fallback.
    private static func seedDirectoryCoordinatedAssemblyPair(in directory: URL, namespace: UUID,
                                                              coordinator: NSFileCoordinator) throws -> AssemblyPairFixture {
        let identity = try assemblyPairDirectoryIdentity(directory)
        var prepared: [(role: String, url: URL, bytes: Data, existed: Bool)] = []
        for role in ["A", "B"] {
            let url = directory.appendingPathComponent("SkillAssembly-\(role)-\(namespace.uuidString).pdf")
            let existed = FileManager.default.fileExists(atPath: url.path)
            let bytes = try existed ? validatedAssemblyPairBytes(url, role: role, namespace: namespace)
                                    : assemblyPairPDFBytes(role: role, namespace: namespace)
            prepared.append((role, url, bytes, existed))
        }
        let existingFiles = prepared.filter(\.existed).count
        var createdFiles = 0, accessorCalls = 0
        var completed = false
        func record(_ phase: String) {
            print("SKILL_PDF_PAIR_CREATION namespace=\(namespace.uuidString) mode=directoryCoordinated phase=\(phase) coordinationAttempts=1 accessorCalls=\(accessorCalls) createdFiles=\(createdFiles) existingFiles=\(existingFiles)")
            fflush(stdout)
        }
        record("willCoordinate")
        defer { if !completed { record("failed") } }
        var coordinationError: NSError?
        var written: Result<Void, Error> = .failure(Failure.coordinationFailed)
        coordinator.coordinate(writingItemAt: directory, options: [], error: &coordinationError) { destination in
            accessorCalls += 1
            written = Result {
                guard accessorCalls == 1 else { throw Failure.coordinationFailed }
                try validateAssemblyPairDirectory(destination, expected: directory, identity: identity)
                for item in prepared {
                    if !item.existed {
                        try item.bytes.write(to: item.url, options: .withoutOverwriting)
                        createdFiles += 1
                    }
                    // Compare the actual persisted payload to the immutable
                    // pre-coordination bytes, including existing-file races.
                    guard try validatedAssemblyPairBytes(item.url, role: item.role, namespace: namespace) == item.bytes else {
                        throw Failure.existingFile
                    }
                }
                try validateAssemblyPairDirectory(destination, expected: directory, identity: identity)
            }
        }
        if coordinationError != nil { throw Failure.coordinationFailed }
        try written.get()
        try validateAssemblyPairDirectory(directory, expected: directory, identity: identity)
        var sources: [AssemblyPairFixture.Source] = []
        for item in prepared {
            let bytes = try validatedAssemblyPairBytes(item.url, role: item.role, namespace: namespace)
            guard bytes == item.bytes else { throw Failure.existingFile }
            sources.append(.init(role: item.role, url: item.url, sha256: pairDigest(bytes)))
            recordPairSnapshot(in: directory, namespace: namespace, role: item.role,
                               phase: item.existed ? "existing" : "created", ordinal: 0)
        }
        guard Set(sources.map(\.sha256)).count == 2 else { throw Failure.existingFile }
        completed = true
        record("completed")
        return AssemblyPairFixture(namespace: namespace, sources: sources, creationProof: .init(
            mode: "directoryCoordinated", coordinationAttempts: 1, accessorCalls: accessorCalls,
            createdFiles: createdFiles, existingFiles: existingFiles))
    }

    static func assemblyPairDirectoryIdentity(_ directory: URL) throws -> (device: Int32, inode: UInt64) {
        guard directory.isFileURL else { throw Failure.coordinationFailed }
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw Failure.coordinationFailed }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw Failure.coordinationFailed }
        return (info.st_dev, UInt64(info.st_ino))
    }

    static func validateAssemblyPairDirectory(_ destination: URL, expected: URL,
                                              identity: (device: Int32, inode: UInt64)) throws {
        guard destination.isFileURL, destination.standardizedFileURL == expected.standardizedFileURL,
              try assemblyPairDirectoryIdentity(destination) == identity else { throw Failure.coordinationFailed }
    }

    /// Reads only the two exact fixture paths created above, with a small bound.
    /// O_NOFOLLOW + descriptor/name identity reject replacement, links and FIFOs.
    private static func assemblyPairBytes(_ url: URL) throws -> Data {
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { throw Failure.existingFile }
        defer { close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.existingFile }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_nlink == 1,
              before.st_size > 0, before.st_size <= 128 * 1024 else { throw Failure.existingFile }
        var bytes = Data(count: Int(before.st_size))
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        var after = stat(), named = stat()
        guard count == bytes.count, fstat(fd, &after) == 0,
              fstatat(parent, url.lastPathComponent, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_mode & S_IFMT == S_IFREG, named.st_nlink == 1, after.st_nlink == 1,
              named.st_ino == after.st_ino, named.st_dev == after.st_dev, named.st_size == after.st_size,
              before.st_ino == after.st_ino, before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw Failure.existingFile }
        return bytes
    }

    private static func pairDigest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private static func assemblyPairPage(_ page: PDFPage?, matches role: String, number: Int, namespace: UUID) -> Bool {
        guard let text = page?.string, text.utf8.count <= 512 else { return false }
        // Actual iOS17 PDFKit can insert ASCII layout whitespace within a UUID.
        // Retain every other character, marker, source role and page number.
        let compact = text.unicodeScalars.filter { ![9, 10, 13, 32].contains($0.value) }.map(String.init).joined()
        return compact == "WOOW_ASSEMBLY_\(role)_PAGE_\(number)" + namespace.uuidString
    }

    /// Observes real receipt hashes and actual output bytes, without modifying
    /// the plan, grants or result. No selected user URL is read here.
    static func assemblyPairOutputObservation(_ bytes: Data, receiptDigests: [String: String],
                                              fixture: AssemblyPairFixture) -> String {
        guard fixture.sources.count == 2, receiptDigests.count == 2,
              fixture.sources.allSatisfy({ receiptDigests[$0.filename] == $0.sha256 }),
              bytes.count <= 20 * 1024 * 1024, bytes.starts(with: Data("%PDF-".utf8)),
              let pdf = PDFDocument(data: bytes), pdf.pageCount == 3,
              assemblyPairPage(pdf.page(at: 0), matches: "A", number: 2, namespace: fixture.namespace),
              assemblyPairPage(pdf.page(at: 1), matches: "B", number: 1, namespace: fixture.namespace),
              assemblyPairPage(pdf.page(at: 2), matches: "A", number: 1, namespace: fixture.namespace),
              fixture.sources.allSatisfy({ source in
                  guard let original = try? assemblyPairBytes(source.url) else { return false }
                  return pairDigest(original) == source.sha256
              }) else { return "pair=failed" }
        return "pair=verified pages=A2,B1,A1 originals=unchanged sha256=" + pairDigest(bytes)
    }

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
        var role: String? = nil
        var ordinal: Int? = nil
        var location: FixtureLocation? = nil
    }

    struct FixtureLocation: Codable {
        let urlSHA256: String
        var parentDevice: Int32?
        var parentInode: UInt64?
    }

    static func pairFixtureSample(in directory: URL, namespace: UUID, role: String)
        -> (FixtureEvidence, FixtureLocation?) {
        guard ["A", "B"].contains(role) else { return (FixtureEvidence(status: "invalidFixture"), nil) }
        let url = directory.appendingPathComponent("SkillAssembly-\(role)-\(namespace.uuidString).pdf")
        var location = FixtureLocation(urlSHA256: pairDigest(Data(url.standardizedFileURL.path.utf8)))
        var parentIdentity: stat?
        let evidence = fixtureEvidence(in: directory, namespace: namespace, role: role, parentIdentity: &parentIdentity)
        if let value = parentIdentity {
            location.parentDevice = value.st_dev; location.parentInode = UInt64(value.st_ino)
        }
        return (evidence, location)
    }

    /// Strictly synthetic pair only; never follows a selected document URL.
    /// These snapshots observe the original files without supplying picker URLs
    /// or changing selection/grants. No timer, retry, coordination or write.
    static func recordPairSnapshot(_ fixture: AssemblyPairFixture, phase: String, ordinal: Int) {
        guard ["prePicker", "selectionReturned", "selectionFailure", "cancelled"].contains(phase),
              (1...3).contains(ordinal), fixture.sources.count == 2 else { return }
        for source in fixture.sources {
            guard ["A", "B"].contains(source.role),
                  source.filename == "SkillAssembly-\(source.role)-\(fixture.namespace.uuidString).pdf" else { return }
        }
        for source in fixture.sources {
            recordPairSnapshot(in: source.url.deletingLastPathComponent(), namespace: fixture.namespace,
                               role: source.role, phase: phase, ordinal: ordinal)
        }
    }

    private static func recordPairSnapshot(in directory: URL, namespace: UUID, role: String,
                                           phase: String, ordinal: Int) {
        let (evidence, location) = pairFixtureSample(in: directory, namespace: namespace, role: role)
        let baseline = FixtureBaseline(version: 2, namespace: namespace.uuidString, phase: phase,
            evidence: evidence, role: role, ordinal: ordinal, location: location)
        if let bytes = try? JSONEncoder().encode(baseline), let json = String(data: bytes, encoding: .utf8) {
            print("SKILL_PDF_ASSEMBLY_FIXTURE_BASELINE " + json)
            fflush(stdout)
        }
    }

    static func pairFixtureEvidence(in directory: URL, namespace: UUID, role: String) -> FixtureEvidence {
        pairFixtureSample(in: directory, namespace: namespace, role: role).0
    }

    static func fixtureEvidence(in directory: URL, namespace: UUID) -> FixtureEvidence {
        var parentIdentity: stat?
        return fixtureEvidence(in: directory, namespace: namespace, role: nil, parentIdentity: &parentIdentity)
    }

    private static func fixtureEvidence(in directory: URL, namespace: UUID, role: String?,
                                        parentIdentity: inout stat?) -> FixtureEvidence {
        let limit = 128 * 1024
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return FixtureEvidence(status: "directoryUnavailable") }
        defer { close(parent) }
        var openedParent = stat()
        guard fstat(parent, &openedParent) == 0 else { return FixtureEvidence(status: "statFailed") }
        parentIdentity = openedParent
        let filename = role.map { "SkillAssembly-\($0)-\(namespace.uuidString).pdf" }
            ?? "SkillExecution-\(namespace.uuidString).pdf"
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
        var namedParent = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, filename, &named, AT_SYMLINK_NOFOLLOW) == 0,
              lstat(directory.path, &namedParent) == 0, namedParent.st_mode & S_IFMT == S_IFDIR,
              namedParent.st_dev == openedParent.st_dev, namedParent.st_ino == openedParent.st_ino,
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
        let title = role.map { "WOOW_ASSEMBLY_\($0)_\(namespace.uuidString)" }
            ?? "WOOW_SKILL_PDF_FIXTURE_" + namespace.uuidString
        guard let pdf = PDFDocument(data: data), pdf.pageCount == 2,
              pdf.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == title,
              pdf.documentAttributes?[PDFDocumentAttribute.authorAttribute] as? String == "Synthetic UI fixture" else {
            return FixtureEvidence(status: "invalidFixture")
        }
        if let role, !(1...2).allSatisfy({ assemblyPairPage(pdf.page(at: $0 - 1), matches: role, number: $0, namespace: namespace) }) {
            return FixtureEvidence(status: "invalidFixture")
        }
        return FixtureEvidence(status: "valid", bytes: after.st_size, device: after.st_dev,
            inode: UInt64(after.st_ino), modifiedSeconds: Int64(after.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(after.st_mtimespec.tv_nsec),
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    struct ReadPickerSnapshot: Encodable {
        let version = 1
        let namespace: String
        let phase: String
        let ordinal: Int
        let evidence: FixtureEvidence
        let location: FixtureLocation
        let returnedURLRelation: String
    }

    /// Observe only the seeded source. Returned user URLs are compared in memory,
    /// never opened, resolved, hashed or printed by this diagnostic.
    static func readPickerSnapshot(_ fixture: Fixture, phase: String, ordinal: Int,
                                   returnedURLs: [URL]? = nil,
                                   arguments: [String] = ProcessInfo.processInfo.arguments) -> ReadPickerSnapshot? {
        guard arguments.filter({ $0 == "-UITestMode" }).count == 1,
              arguments.filter({ $0 == "-UITestSkillExecution" }).count == 1,
              arguments.filter({ $0 == "-UITestNamespace" }).count == 1,
              !arguments.contains(where: { $0.hasPrefix("-Live") || $0.hasPrefix("-UITestSkillAssemblyPair") }),
              let index = arguments.firstIndex(of: "-UITestNamespace"), arguments.indices.contains(index + 1),
              arguments[index + 1] == fixture.namespace.uuidString,
              fixture.url.isFileURL,
              fixture.filename == "SkillExecution-\(fixture.namespace.uuidString).pdf",
              ["prePicker", "selectionReturned", "selectionFailure", "cancelled"].contains(phase),
              (1...3).contains(ordinal) else { return nil }
        let source = fixture.url.standardizedFileURL
        var parent: stat?
        let evidence = fixtureEvidence(in: source.deletingLastPathComponent(), namespace: fixture.namespace,
                                       role: nil, parentIdentity: &parent)
        let location = FixtureLocation(urlSHA256: pairDigest(Data(source.path.utf8)),
                                       parentDevice: parent?.st_dev, parentInode: parent.map { UInt64($0.st_ino) })
        let relation: String
        if let urls = returnedURLs {
            if urls.count != 1 { relation = urls.isEmpty ? "empty" : "multiple" }
            else if !urls[0].isFileURL { relation = "nonFile" }
            else if urls[0].standardizedFileURL == source { relation = "exactSource" }
            else if urls[0].lastPathComponent == fixture.filename { relation = "sameBasenameOtherLocation" }
            else { relation = "other" }
        } else { relation = "notReturned" }
        return ReadPickerSnapshot(namespace: fixture.namespace.uuidString, phase: phase, ordinal: ordinal,
                                  evidence: evidence, location: location, returnedURLRelation: relation)
    }

    static func recordReadPickerSnapshot(_ fixture: Fixture, phase: String, ordinal: Int,
                                         returnedURLs: [URL]? = nil) {
        guard let sample = readPickerSnapshot(fixture, phase: phase, ordinal: ordinal, returnedURLs: returnedURLs),
              let bytes = try? JSONEncoder().encode(sample), let json = String(data: bytes, encoding: .utf8) else { return }
        // Separate schema; the existing baseline/post-test inventory is unchanged.
        print("SKILL_PDF_READ_PICKER_IDENTITY " + json)
        fflush(stdout)
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
