import Foundation
@testable import AssistantBrowser

/// Shared by XCTest and the real CLT executable on hosts without Xcode/XCTest.
enum BrowserDownloadFixtures {
    struct Failure: Error { let message: String }

    static func run() throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("browser-download-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var assertions = 0
        func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
            assertions += 1
            guard try value() else { throw Failure(message: message) }
        }
        func refuses(_ reason: BrowserDownloadError? = nil, _ operation: () throws -> Void) throws {
            assertions += 1
            do { try operation() }
            catch {
                if let reason, error as? BrowserDownloadError != reason { throw Failure(message: "Wrong failure for \(reason)") }
                return
            }
            throw Failure(message: "Unsafe operation was accepted")
        }
        func subdirectory() -> URL { root.appendingPathComponent(UUID().uuidString) }
        func completed(_ store: BrowserDownloadStore, name: String = "報告.txt", data: Data = Data("fixture-only".utf8)) throws -> BrowserDownloadItem {
            var item = BrowserDownloadItem()
            let url = try store.destination(id: item.id, suggestedFilename: name)
            item.fileName = url.lastPathComponent
            try data.write(to: url)
            return try store.finish(item)
        }

        for raw in ["../escape.txt", "../../../../secret", "..\\..\\Windows\\x", "/absolute.txt", ".", "..", "", "   ",
                    "a\u{0000}b\n.txt", "%2e%2e%2fsecret", "a\u{202e}txt.exe", "a:b?c*|\"<x>.pdf",
                    String(repeating: "繁體中文", count: 2_000) + ".pdf"] {
            let safe = BrowserDownloadPolicy.sanitizedFilename(raw)
            try expect(!safe.isEmpty && safe.utf8.count <= 120, "Filename must be nonempty and byte bounded")
            try expect(!safe.contains("/") && !safe.contains("\\") && !safe.contains("%") && !safe.hasPrefix("."), "Filename cannot be a path")
            try expect(safe == BrowserDownloadPolicy.sanitizedFilename(safe), "Sanitization is stable")
        }
        try expect(BrowserDownloadPolicy.sanitizedFilename(String(repeating: "字", count: 100) + ".pdf").hasSuffix(".pdf"), "Keep short extension")
        try expect(BrowserDownloadPolicy.sanitizedFilename(" 年度報告.pdf ") == "年度報告.pdf", "Keep readable Traditional Chinese")
        for value in ["http://example.com/a", "file:///tmp/a", "data:text/plain,x", "blob:https://example.com/id",
                      "https://user:pass@example.com/a", "https://127.0.0.1/a", "https://192.168.1.2/a",
                      "https://[::1]/a", "https://localhost/a", "https://host.local/a", "https://service.lan/a",
                      "https://service.internal/a", "https://2130706433/a", "https://0x7f000001/a", "https://intranet/a"] {
            try expect(!BrowserDownloadPolicy.allows(URL(string: value)!), "Reject unsafe download URL")
        }
        for value in ["https://example.com/a", "https://cdn.example.org/redirected?signature=FIXTURE_ONLY", "https://8.8.8.8/file"] {
            try expect(BrowserDownloadPolicy.allows(URL(string: value)!), "Accept public HTTPS")
        }
        let attachment = HTTPURLResponse(url: URL(string: "https://example.com/f")!, statusCode: 200,
                                        httpVersion: "HTTP/1.1", headerFields: ["Content-Disposition": " Attachment ; filename=x.pdf"])!
        try expect(BrowserDownloadPolicy.isAttachment(attachment), "Displayable PDFs can still be attachments")
        let limits = BrowserDownloadLimits(maximumCount: 999, maximumActive: 99, maximumFileBytes: .max, maximumTotalBytes: .max)
        try expect(limits.maximumCount == 50 && limits.maximumActive == 3, "Hard count ceilings")
        try expect(limits.maximumFileBytes == 100 * 1_024 * 1_024 && limits.maximumTotalBytes == 500 * 1_024 * 1_024, "Hard byte ceilings")

        let path = subdirectory()
        let store = try BrowserDownloadStore(directory: path, limits: .init())
        var first = BrowserDownloadItem()
        let firstDestination = try store.destination(id: first.id, suggestedFilename: "../../報告.txt")
        first.fileName = firstDestination.lastPathComponent
        try expect(!fm.fileExists(atPath: firstDestination.path), "WebKit destination does not exist yet")
        try expect(fm.fileExists(atPath: firstDestination.deletingLastPathComponent().path), "WebKit destination parent exists")
        try expect(firstDestination.path.hasPrefix(path.path + "/Partial/"), "Destination stays in sandbox")
        try Data("original fixture".utf8).write(to: firstDestination)
        first = try store.finish(first)
        try expect(first.status == .completed && first.receivedBytes == 16, "Finish verifies disk bytes")
        let second = try completed(store, name: "../../報告.txt")
        let firstURL = try store.fileURL(id: first.id), secondURL = try store.fileURL(id: second.id)
        try expect(first.fileName == second.fileName && firstURL != secondURL, "Same filename has unique destination")
        try expect(try String(contentsOf: firstURL) == "original fixture", "A second transfer cannot overwrite the first")
        let persisted = try Data(contentsOf: path.appendingPathComponent("completed.json"))
        let json = String(decoding: persisted, as: UTF8.self)
        try expect(persisted.count <= limits.maximumMetadataBytes && !json.contains("http") && !json.contains("Cookie"), "Bound metadata without URLs or credentials")
        let reopened = try BrowserDownloadStore(directory: path, limits: .init())
        try expect(reopened.completed.count == 2 && reopened.completed.contains(first), "Completed metadata round trips")
        try refuses(.confirmationRequired) { try reopened.delete(id: first.id, confirmed: false) }
        try expect(fm.fileExists(atPath: firstURL.path), "Unconfirmed deletion preserves file")
        try reopened.delete(id: first.id, confirmed: true)
        try expect(!fm.fileExists(atPath: firstURL.path) && fm.fileExists(atPath: secondURL.path), "Confirmed deletion removes only selected file")
        try expect(try BrowserDownloadStore(directory: path, limits: .init()).completed.map(\.id) == [second.id], "Deletion persists")

        let staleID = UUID()
        let stale = try reopened.destination(id: staleID, suggestedFilename: "partial.bin")
        try Data([1, 2, 3]).write(to: stale)
        let unrelated = path.appendingPathComponent("Partial/keep-unrelated")
        try Data([9]).write(to: unrelated)
        let orphan = path.appendingPathComponent("Files/" + UUID().uuidString)
        try fm.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data([4]).write(to: orphan.appendingPathComponent("orphan"))
        _ = try BrowserDownloadStore(directory: path, limits: .init())
        try expect(!fm.fileExists(atPath: stale.path) && !fm.fileExists(atPath: orphan.path), "Startup cleans partials and pre-manifest crash orphans")
        try expect(fm.fileExists(atPath: unrelated.path) && fm.fileExists(atPath: secondURL.path), "Cleanup preserves unrelated/completed files")

        let tiny = try BrowserDownloadStore(directory: subdirectory(), limits: .init(maximumCount: 1, maximumFileBytes: 4, maximumTotalBytes: 5))
        var oversized = BrowserDownloadItem()
        let largeFile = try tiny.destination(id: oversized.id, suggestedFilename: "too-large")
        oversized.fileName = largeFile.lastPathComponent
        try Data(repeating: 1, count: 5).write(to: largeFile)
        try refuses(.tooLarge) { _ = try tiny.finish(oversized) }
        try refuses(.tooMany) { _ = try tiny.destination(id: UUID(), suggestedFilename: "second") }
        try tiny.discardPartial(id: oversized.id)
        try expect(!fm.fileExists(atPath: largeFile.path), "Cancelling removes actual partial")
        _ = try completed(tiny, data: Data([1, 2, 3, 4]))
        try refuses(.tooMany) { _ = try tiny.destination(id: UUID(), suggestedFilename: "at-capacity") }
        let totalLimited = try BrowserDownloadStore(directory: subdirectory(), limits: .init(maximumFileBytes: 4, maximumTotalBytes: 5))
        _ = try completed(totalLimited, data: Data([1, 2, 3]))
        try refuses(.tooLarge) { _ = try completed(totalLimited, data: Data([4, 5, 6])) }
        try expect(totalLimited.completed.count == 1, "Total quota cannot evict completed data")

        // A link attack must neither publish nor share data outside the download root.
        let outside = root.appendingPathComponent("outside-secret-fixture")
        try Data("fixture only".utf8).write(to: outside)
        let links = try BrowserDownloadStore(directory: subdirectory(), limits: .init())
        var symlinkItem = BrowserDownloadItem()
        let symlink = try links.destination(id: symlinkItem.id, suggestedFilename: "link")
        symlinkItem.fileName = symlink.lastPathComponent
        try fm.createSymbolicLink(at: symlink, withDestinationURL: outside)
        try refuses(.invalidFile) { _ = try links.finish(symlinkItem) }
        try links.discardPartial(id: symlinkItem.id)
        try expect(fm.fileExists(atPath: outside.path), "Cleanup cannot follow a file symlink")
        let linkFolder = links.directory.appendingPathComponent("Partial/" + UUID().uuidString)
        try fm.createSymbolicLink(at: linkFolder, withDestinationURL: root)
        _ = try BrowserDownloadStore(directory: links.directory, limits: .init())
        try expect(fm.fileExists(atPath: outside.path), "Cleanup cannot traverse a directory symlink")
        let linkComplete = try completed(links)
        let linkCompleteURL = try links.fileURL(id: linkComplete.id)
        try fm.removeItem(at: linkCompleteURL)
        try fm.createSymbolicLink(at: linkCompleteURL, withDestinationURL: outside)
        try refuses(.invalidFile) { _ = try links.fileURL(id: linkComplete.id) }
        try refuses(.invalidMetadata) { _ = try BrowserDownloadStore(directory: links.directory, limits: .init()) }

        // Persistence failure must never claim completion or leave a published file.
        let broken = try BrowserDownloadStore(directory: subdirectory(), limits: .init())
        try fm.createDirectory(at: broken.directory.appendingPathComponent("completed.json"), withIntermediateDirectories: true)
        try refuses { _ = try completed(broken) }
        try expect(broken.completed.isEmpty, "Failed manifest write does not publish")
        try expect(try fm.contentsOfDirectory(atPath: broken.directory.appendingPathComponent("Files").path).isEmpty, "Failed manifest write rolls back file")

        for badManifest in [Data("invalid JSON".utf8), Data(repeating: 65, count: 65_537),
                            Data("{\"version\":2,\"items\":[]}".utf8)] {
            let corrupt = try BrowserDownloadStore(directory: subdirectory(), limits: .init())
            let item = try completed(corrupt)
            let file = try corrupt.fileURL(id: item.id)
            try badManifest.write(to: corrupt.directory.appendingPathComponent("completed.json"))
            try refuses(.invalidMetadata) { _ = try BrowserDownloadStore(directory: corrupt.directory, limits: .init()) }
            try expect(fm.fileExists(atPath: file.path), "Corrupt metadata never destroys completed user files")
        }
        let malicious = try BrowserDownloadStore(directory: subdirectory(), limits: .init())
        _ = try completed(malicious)
        let metadataURL = malicious.directory.appendingPathComponent("completed.json")
        var dictionary = try JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as! [String: Any]
        var records = dictionary["items"] as! [[String: Any]]
        records[0]["fileName"] = "../../outside-secret-fixture"
        dictionary["items"] = records
        try JSONSerialization.data(withJSONObject: dictionary).write(to: metadataURL)
        try refuses(.invalidMetadata) { _ = try BrowserDownloadStore(directory: malicious.directory, limits: .init()) }
        try expect(fm.fileExists(atPath: outside.path), "Manifest path traversal cannot touch outside file")

        let missing = try BrowserDownloadStore(directory: subdirectory(), limits: .init())
        let missingItem = try completed(missing)
        try fm.removeItem(at: missing.fileURL(id: missingItem.id))
        try expect(try BrowserDownloadStore(directory: missing.directory, limits: .init()).completed.isEmpty, "Missing files pruned on launch")
        var unknown = BrowserDownloadItem()
        unknown.receivedBytes = 100
        try expect(unknown.fractionCompleted == nil, "Unknown total is indeterminate")
        unknown.totalBytes = 10
        try expect(unknown.fractionCompleted == 1, "Progress display never exceeds 100 percent")
        return assertions
    }
}

#if BROWSER_DOWNLOAD_SMOKE
@main enum BrowserDownloadSmoke {
    static func main() throws { print("Browser downloads: \(try BrowserDownloadFixtures.run()) filesystem/policy assertions passed") }
}
#elseif canImport(XCTest)
import XCTest
final class BrowserDownloadTests: XCTestCase {
    func testRealFilesPersistenceBoundsAndPolicies() throws { XCTAssertGreaterThan(try BrowserDownloadFixtures.run(), 95) }
}
#endif
