import Foundation
#if DEBUG
import PDFKit

private final class DirectoryObserver: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    let target: URL
    let notified = DispatchSemaphore(value: 0)

    init(root: URL, target: URL) {
        presentedItemURL = root; self.target = target
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func presentedSubitemDidAppear(at url: URL) { observe(url) }
    func presentedSubitemDidChange(at url: URL) { observe(url) }
    private func observe(_ url: URL) {
        if url.standardizedFileURL == target.standardizedFileURL { notified.signal() }
    }
}

/// A real presenter introduces a competing creation after the seeder's initial
/// existence check, before NSFileCoordinator grants its accessor. No mocks.
private final class CompetingCreator: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    static let sentinel = Data("competing synthetic writer; must survive".utf8)

    init(_ url: URL) {
        presentedItemURL = url
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }
    func relinquishPresentedItem(toWriter writer: @escaping ((() -> Void)?) -> Void) {
        // Failure to create is detected by the caller's exact byte assertion.
        try? Self.sentinel.write(to: presentedItemURL!, options: .withoutOverwriting)
        writer(nil)
    }
}
#endif

/// Compile with the actual seeder, then run under a bounded subprocess timeout.
/// See docs/SKILL_FIXTURE_COORDINATION_EXPERIMENT.md for commands and limits.
@main
enum SkillFixtureCoordinationChecks {
    struct Failure: Error { let message: String }
    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(message: message) }
    }
    static func arguments(_ id: UUID, mode: String) -> [String] {
        ["-UITestMode", "-UITestSkillExecution", "-UITestNamespace", id.uuidString,
         "-UITestSkillFixtureWriteMode", mode]
    }

    static func main() throws {
        #if DEBUG
        var resolved = false
        let args = arguments(UUID(), mode: "coordinated")
        for invalid in [Array(args.dropLast()), arguments(UUID(), mode: "other"),
                        args + ["-UITestSkillFixtureWriteMode", "direct"]] {
            do {
                _ = try SkillExecutionUITestSupport.seedIfRequested(arguments: invalid) {
                    resolved = true; throw Failure(message: "invalid mode resolved Documents")
                }
                throw Failure(message: "invalid mode accepted")
            } catch SkillExecutionUITestSupport.Failure.invalidWriteMode { }
            try require(!resolved, "mode rejected before filesystem access")
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-coordination-check-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        for mode in ["direct", "coordinated"] {
            let id = UUID()
            let target = root.appendingPathComponent("SkillExecution-\(id.uuidString).pdf")
            let observer = DirectoryObserver(root: root, target: target)
            NSFileCoordinator.addFilePresenter(observer)
            defer { NSFileCoordinator.removeFilePresenter(observer) }
            let fixture = try SkillExecutionUITestSupport.seedIfRequested(
                arguments: arguments(id, mode: mode), documentsDirectory: { root })!
            if mode == "coordinated" {
                try require(observer.notified.wait(timeout: .now() + 3) == .success,
                            "actual directory presenter must observe coordinated creation")
            }
            let before = SkillExecutionUITestSupport.fixtureEvidence(in: root, namespace: id)
            try require(before.status == "valid", "actual bounded PDF baseline is valid")
            let pdf = PDFDocument(url: fixture.url)!
            try require(pdf.pageCount == 2, "same two-page PDF")
            for page in 0..<2 {
                let text = pdf.page(at: page)?.string ?? ""
                try require(text.contains("WOOW_SKILL_PDF_PAGE_\(page + 1)") && text.contains(id.uuidString),
                            "same actual marker and namespace text in both arms")
            }
            _ = try SkillExecutionUITestSupport.seedIfRequested(
                arguments: arguments(id, mode: mode), documentsDirectory: { root })
            let after = SkillExecutionUITestSupport.fixtureEvidence(in: root, namespace: id)
            try require(before.sha256 == after.sha256 && before.inode == after.inode,
                        "reentry preserves bytes and inode")
        }

        let collisionID = UUID()
        let collisionURL = root.appendingPathComponent("SkillExecution-\(collisionID.uuidString).pdf")
        let competitor = CompetingCreator(collisionURL)
        NSFileCoordinator.addFilePresenter(competitor)
        defer { NSFileCoordinator.removeFilePresenter(competitor) }
        var rejected = false
        do {
            _ = try SkillExecutionUITestSupport.seedIfRequested(
                arguments: arguments(collisionID, mode: "coordinated"), documentsDirectory: { root })
        } catch { rejected = true }
        try require(rejected, "competing creation must propagate the write error")
        let survivor = try Data(contentsOf: collisionURL)
        try require(survivor == CompetingCreator.sentinel, "coordination must not overwrite a competing writer")
        print("PASS strict mode gates; actual PDF text/identity in both arms; real presenter notification; competing creation refused without fallback")
        #else
        var resolved = false
        for mode in ["direct", "coordinated", "other"] {
            let fixture = try SkillExecutionUITestSupport.seedIfRequested(arguments: arguments(UUID(), mode: mode)) {
                resolved = true; throw Failure(message: "Release resolved Documents")
            }
            try require(fixture == nil && !resolved, "Release ignores all experiment modes")
        }
        print("PASS Release experiment modes perform no filesystem access")
        #endif
    }
}
