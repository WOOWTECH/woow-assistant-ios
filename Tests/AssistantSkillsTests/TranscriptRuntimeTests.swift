#if !SKILLS_CORE_SMOKE && !SKILL_EXECUTION_SMOKE && !SKILL_AUTHORING_SMOKE
import AssistantModels
import Foundation
@testable import AssistantSkills
#if !TRANSCRIPT_SMOKE
import XCTest
#endif

@MainActor enum TranscriptChecks {
    struct Failure: Error { let message: String }
    static let key = "transcript-fixture-not-live"
    static let caption = "WEBVTT\n\n00:01.000 --> 00:04.000\n逐字保留 café 與數字 42。\n\n"
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        if try !condition() { throw Failure(message: message) }
    }
    static func rejects(_ expected: TranscriptError, _ action: () async throws -> Void) async throws {
        do { try await action(); throw Failure(message: "Expected \(expected)") }
        catch let error as TranscriptError { try expect(error == expected, "wrong rejection: \(error), expected \(expected)") }
    }
    static func json(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    static func read(_ offset: Int, _ limit: Int = 8192) throws -> String {
        try json(["action": "tool", "name": "read_file", "arguments": ["offset": offset, "limit": limit]])
    }
    static func finish(quote: String = caption, offset: Int = 0, text: String = "依據文字內容整理。",
                       timestamp: String? = "00:01.000") throws -> String {
        var evidence: [String: Any] = ["read_offset": offset, "quote": quote]
        if let timestamp { evidence["timestamp"] = timestamp }
        let section: [String: Any] = ["title": "第一段", "text": text, "evidence": [evidence]]
        return try json(["action": "finish", "title": "文字整理", "sections": [section]])
    }
    final class TemporaryFiles {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("transcript-test-" + UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func file(_ name: String, _ data: Data) throws -> URL {
            let url = root.appendingPathComponent(name); try data.write(to: url); return url
        }
        deinit { try? FileManager.default.removeItem(at: root) }
    }
    static func snapshot(_ text: String = caption) async throws -> TranscriptSnapshot {
        let files = try TemporaryFiles(), reader = TranscriptFileAccess()
        let url = try files.file("captions.vtt", Data(text.utf8))
        let review = try reader.select(url)
        return try await reader.read(approving: review.id)
    }
    static func http(_ runtime: TranscriptRuntime, _ scenario: TranscriptHTTPFixture.Scenario,
                     references: RunReferenceContext = .empty,
                     context: @escaping @MainActor () throws -> Void = {},
                     onEvent: @escaping @MainActor (TranscriptEvent) -> Void = { _ in }) async throws -> TranscriptOutcome {
        let url = TranscriptHTTPFixture.register(scenario); defer { TranscriptHTTPFixture.remove(url) }
        let session = TranscriptHTTPFixture.session(); defer { session.invalidateAndCancel() }
        return try await runtime.run(client: HTTPChatModelClient(session: session),
            configuration: .init(baseURL: url, model: "transcript-fixture", maxOutputTokens: 8192), apiKey: key,
            references: references, validateContext: context, onEvent: onEvent)
    }
    static func completed(_ outcome: TranscriptOutcome) throws -> TranscriptResult {
        guard case .completed(let result) = outcome else { throw Failure(message: "expected verified result") }
        return result
    }

    static func approvalAndSnapshot(_ catalog: BundledSkillCatalog) async throws {
        let files = try TemporaryFiles(), reader = TranscriptFileAccess()
        let absent = files.root.appendingPathComponent("deferred.txt")
        let first = try reader.select(absent) // no read/materialization at selection
        reader.cancel()
        try await rejects(.approvalRequired) { _ = try await reader.read(approving: first.id) }
        let review = try reader.select(absent)
        try await rejects(.approvalRequired) { _ = try await reader.read(approving: UUID()) }
        try Data(caption.utf8).write(to: absent)
        let source = try await reader.read(approving: review.id)
        try expect(Data(source.text.utf8) == Data(caption.utf8), "approved real file read")
        try expect(source.sourceKind == .selectedFile && source.sourceURL == nil, "file provenance never acquires a webpage URL")
        try await rejects(.approvalRequired) { _ = try await reader.read(approving: review.id) }
        try Data("replaced".utf8).write(to: absent)
        let runtime = try TranscriptRuntime(source: source, catalog: catalog)
        let result = try completed(await http(runtime, .init([try read(0), try finish()])))
        try expect(result.source.sha256 == source.sha256 && result.source.text == caption, "only immutable approved snapshot read")
        for ext in ["txt", "srt", "vtt", "md"] {
            let selected = try reader.select(files.file("source." + ext, Data(caption.utf8)))
            _ = try await reader.read(approving: selected.id)
        }
        let bom = "\u{FEFF}原文 👩‍💻\r\n"
        let bomSource = try await snapshot(bom)
        try expect(Data(bomSource.text.utf8) == Data(bom.utf8), "BOM, CRLF and emoji bytes must not normalize")
        let bomResult = try completed(await http(TranscriptRuntime(source: bomSource, catalog: catalog),
            .init([try read(0), try finish(quote: bom, timestamp: nil)])))
        try expect(Data(bomResult.reads[0].text.utf8) == Data(bom.utf8), "tool results retain BOM bytes too")
    }

    static func fileRejections(_ catalog: BundledSkillCatalog) async throws {
        let files = try TemporaryFiles(), reader = TranscriptFileAccess()
        for (name, data, error) in [
            ("invalid.txt", Data([0xC3, 0x28]), TranscriptError.invalidEncoding),
            ("binary.md", Data([65, 0, 66]), .invalidEncoding),
            ("empty.srt", Data(" \n\t".utf8), .emptySource),
            ("large.vtt", Data(repeating: 65, count: TranscriptSnapshot.maximumBytes + 1), .tooLarge)
        ] {
            let review = try reader.select(files.file(name, data))
            try await rejects(error) { _ = try await reader.read(approving: review.id) }
        }
        let target = try files.file("actual.txt", Data(caption.utf8)), link = files.root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let symlink = try reader.select(link)
        try await rejects(.invalidSelection) { _ = try await reader.read(approving: symlink.id) }
        let directory = files.root.appendingPathComponent("folder.txt")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let folder = try reader.select(directory)
        try await rejects(.invalidSelection) { _ = try await reader.read(approving: folder.id) }
        try await rejects(.invalidSelection) { _ = try reader.select(URL(string: "https://example.invalid/source.txt")!) }
        try await rejects(.unsupportedType) { _ = try reader.select(files.root.appendingPathComponent("audio.mp3")) }
        let stale = try reader.select(target), latest = try reader.select(target)
        try await rejects(.approvalRequired) { _ = try await reader.read(approving: stale.id) }
        reader.cancel()
        try await rejects(.approvalRequired) { _ = try await reader.read(approving: latest.id) }
        // The file provider's pending save must precede validation and reading.
        for replacement in [Data(caption.utf8), nil, Data(repeating: 65, count: TranscriptSnapshot.maximumBytes + 1)] {
            let url = try files.file(UUID().uuidString + ".txt", Data("old content".utf8))
            let presenter = TranscriptPresenter(url: url, replacement: replacement)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }
            let review = try reader.select(url)
            if replacement?.count == Data(caption.utf8).count {
                let actual = try await reader.read(approving: review.id)
                try expect(actual.text == caption, "real coordinated pending save wins over stale bytes")
            } else {
                try await rejects(replacement == nil ? .invalidSelection : .tooLarge) { _ = try await reader.read(approving: review.id) }
            }
            try expect(presenter.count > 0, "actual presenter save callback reached")
        }
        for timeout in [false, true] {
            let reader = TranscriptFileAccess(readTimeout: timeout ? 0.2 : 30)
            let url = try files.file(UUID().uuidString + ".txt", Data(caption.utf8))
            let presenter = TranscriptPresenter(url: url, replacement: nil, hold: true)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { presenter.release(); NSFileCoordinator.removeFilePresenter(presenter) }
            let review = try reader.select(url)
            let request = Task { try await reader.read(approving: review.id) }
            let deadline = ContinuousClock.now + .seconds(2)
            while presenter.count == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try expect(presenter.count > 0, "held file provider actually entered")
            if !timeout { reader.cancel() }
            try await rejects(timeout ? .readTimedOut : .cancelled) { _ = try await request.value }
            presenter.release() // late callback must not publish a snapshot
            try await rejects(.approvalRequired) { _ = try await reader.read(approving: review.id) }
        }
    }

    static func httpCoverageAndFormats(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot(caption + String(repeating: "原文段落包含證據。\n", count: 440))
        let data = Data(source.text.utf8)
        var offset = 0, commands: [String] = [], expectedRanges: [Range<Int>] = []
        while true {
            commands.append(try read(offset))
            var end = min(data.count, offset + 8192)
            while end < data.count && data[end] & 0xC0 == 0x80 { end -= 1 }
            expectedRanges.append(offset..<end)
            if end == data.count { break }
            offset = end - 256
            while data[offset] & 0xC0 == 0x80 { offset += 1 }
        }
        for format in TranscriptFormat.allCases {
            let runtime = try TranscriptRuntime(source: source, format: format, catalog: catalog)
            let scenario = TranscriptHTTPFixture.Scenario(commands + [try finish(text: format == .quotations ? caption : "原文段落的整理。")])
            let result = try completed(await http(runtime, scenario))
            try expect(runtime.coveredBytes == data.count && result.reads.count == expectedRanges.count, "full overlapping UTF-8 coverage")
            try expect(result.format == format && result.sourceRevision == BundledSkillCatalog.pinnedCommit, "real requested format and pinned source")
            for (read, range) in zip(result.reads, expectedRanges) {
                try expect(read.offset == range.lowerBound && Data(read.text.utf8) == data[range], "exact source bytes per range")
            }
            for request in scenario.requests {
                try expect(request.httpMethod == "POST" && request.url?.path == "/v1/chat/completions", "actual configured HTTP endpoint")
                try expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key, "only explicit fixture credential")
            }
            let bodies = try scenario.requestBodies.map { try JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            try expect(bodies.allSatisfy { $0["model"] as? String == "transcript-fixture" && $0["max_tokens"] as? Int == 8192 }, "actual model configuration")
            let firstMessages = bodies[0]["messages"] as! [[String: String]]
            let context = try JSONSerialization.jsonObject(with: Data(firstMessages[1]["content"]!.utf8)) as! [String: Any]
            let documents = context["reference_documents"] as! [[String: String]]
            let entry = catalog.entry(id: "content-transcribe")!
            try expect(documents.map { $0["text"]! } == [entry.original.content, entry.assets[0].content], "full pinned skill and reference delivered")
            let lastMessages = bodies.last!["messages"] as! [[String: String]]
            try expect(lastMessages.contains { $0["content"]?.contains("covered_bytes") == true }, "real read results reach subsequent model requests")
            try expect(result.sections[0].evidence[0].quote == caption && result.sections[0].evidence[0].timestamp == "00:01.000", "exact citation and time retained")
        }
    }

    static func rangesAndCoverage(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        let invalid = [try read(1), try read(0, 0), try read(0, 8193), try read(Int.max),
            try json(["action": "tool", "name": "read_file", "arguments": ["offset": true, "limit": 20] as [String: Any]]),
            try json(["action": "tool", "name": "read_file", "arguments": ["offset": 0.5, "limit": 20]])]
        for command in invalid {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog)
            try await rejects(.invalidRange) { _ = try await http(runtime, .init([command])) }
            try expect(runtime.coveredBytes == 0, "invalid range must not disclose file bytes")
        }
        for commands in [[try finish()], [try read(0, 20), try finish()]] {
            try await rejects(.incompleteCoverage) { _ = try await http(TranscriptRuntime(source: source, catalog: catalog), .init(commands)) }
        }
        for commands in [[try read(0, 20), try read(21)], [try read(0, 20), try read(20)]] {
            try await rejects(.invalidRange) { _ = try await http(TranscriptRuntime(source: source, catalog: catalog), .init(commands)) }
        }
        let unicode = try await snapshot("甲乙丙\n")
        try await rejects(.invalidRange) { _ = try await http(TranscriptRuntime(source: unicode, catalog: catalog), .init([try read(0, 1)])) }
        try await rejects(.invalidRange) { _ = try await http(TranscriptRuntime(source: unicode, catalog: catalog), .init([try read(0, 3), try read(1)])) }
        let path = try json(["action": "tool", "name": "read_file", "arguments": ["offset": 0, "limit": 100, "path": "/etc/passwd"] as [String: Any]])
        try await rejects(.invalidCommand) { _ = try await http(TranscriptRuntime(source: source, catalog: catalog), .init([path, path])) }
    }

    static func exactEvidence(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        for finishCommand in [try finish(quote: "未在來源出現"), try finish(offset: 10),
                              try finish(timestamp: "00:05.000"), try finish(quote: "cafe\u{301}", timestamp: nil)] {
            try await rejects(.invalidEvidence) {
                _ = try await http(TranscriptRuntime(source: source, catalog: catalog), .init([try read(0), finishCommand]))
            }
        }
        try await rejects(.invalidEvidence) {
            _ = try await http(TranscriptRuntime(source: source, format: .quotations, catalog: catalog), .init([try read(0), try finish(text: "這是改寫")]))
        }
        let withNewlines = try completed(await http(TranscriptRuntime(source: source, catalog: catalog), .init([try read(0), try finish()])))
        try expect(Data(withNewlines.sections[0].evidence[0].quote.utf8) == Data(caption.utf8), "newlines and normalization preserved exactly")
    }

    static func refusalAndBudgets(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        let refused = try await http(TranscriptRuntime(source: source, catalog: catalog),
            .init([try json(["action": "refuse", "reason": "文字證據不足，沒有處理音訊。"])]))
        guard case .refused(let reason) = refused else { throw Failure(message: "refusal cannot become success") }
        try expect(reason.contains("證據不足"), "refusal retained")
        let limited = try TranscriptRuntime(source: source, catalog: catalog, limits: .init(modelCalls: 1))
        let scenario = TranscriptHTTPFixture.Scenario([try read(0), try finish()])
        try await rejects(.budgetExceeded) { _ = try await http(limited, scenario) }
        try expect(scenario.count == 1, "no request after model budget")
        let rejected = TranscriptHTTPFixture.Scenario([try read(0)], status: 401)
        try await rejects(.modelFailed) { _ = try await http(TranscriptRuntime(source: source, catalog: catalog), rejected) }
        try expect(rejected.count == 1, "HTTP errors do not retry")
        let invalid = TranscriptHTTPFixture.Scenario(["not JSON", "not JSON"])
        try await rejects(.invalidCommand) { _ = try await http(TranscriptRuntime(source: source, catalog: catalog), invalid) }
        try expect(invalid.count == 2, "second malformed response stops after the single format correction")
    }

    static func waitForRequest(_ scenario: TranscriptHTTPFixture.Scenario) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !scenario.ready && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        try expect(scenario.count == 1 && scenario.ready, "held real HTTP request started")
    }
    static func cancellationAndTimeout(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot()
        enum Cancellation { case runtime, timeout, parentTask }
        for cancellation in [Cancellation.runtime, .timeout, .parentTask] {
            let runtime = try TranscriptRuntime(source: source, catalog: catalog,
                limits: .init(modelTime: cancellation == .timeout ? .milliseconds(150) : .seconds(180)))
            let scenario = TranscriptHTTPFixture.Scenario([], hold: true)
            let url = TranscriptHTTPFixture.register(scenario), session = TranscriptHTTPFixture.session()
            // Retain the session until AFTER the stop acknowledgement assertion.
            // Teardown must not supply the cancellation this test is proving.
            defer { session.invalidateAndCancel(); TranscriptHTTPFixture.remove(url) }
            let request = Task {
                try await runtime.run(client: HTTPChatModelClient(session: session),
                    configuration: .init(baseURL: url, model: "transcript-fixture", maxOutputTokens: 8192), apiKey: key)
            }
            try await waitForRequest(scenario)
            switch cancellation {
            case .runtime: runtime.cancel()
            case .timeout: break
            case .parentTask: request.cancel()
            }
            try await rejects(cancellation == .timeout ? .timedOut : .cancelled) { _ = try await request.value }
            // URLSession cancel returns before transport acknowledgement. Match
            // the existing 2s request-observation bound; never substitute sleep
            // completion for the actual URLProtocol.stopLoading callback.
            let deadline = ContinuousClock.now + .seconds(2)
            while scenario.stops == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            try expect(scenario.stops > 0, "cancellation must reach actual URLSession transport before session teardown")
            try expect(runtime.reads.isEmpty && scenario.count == 1, "cancelled transport cannot read source or send another request")
        }
    }

    static func changedContext(_ catalog: BundledSkillCatalog) async throws {
        let source = try await snapshot(), runtime = try TranscriptRuntime(source: source, catalog: catalog)
        var current = true
        let scenario = TranscriptHTTPFixture.Scenario([], hold: true)
        let request = Task { try await http(runtime, scenario, context: { if !current { throw TranscriptError.contextChanged } }) }
        try await waitForRequest(scenario)
        current = false; scenario.release(try read(0))
        try await rejects(.contextChanged) { _ = try await request.value }
        try expect(runtime.reads.isEmpty && scenario.count == 1, "late response cannot disclose text or send next request")
        let fresh = try TranscriptRuntime(source: source, catalog: catalog), unused = TranscriptHTTPFixture.Scenario([try read(0)])
        try await rejects(.contextChanged) {
            _ = try await http(fresh, unused, context: { throw TranscriptError.contextChanged })
        }
        try expect(unused.count == 0, "changed context before start sends nothing")
    }

    static func approvedWebSource(_ catalog: BundledSkillCatalog) async throws {
        let url = URL(string: "https://example.invalid/article?edition=1#body")!
        let text = "網頁的核准文字。\n這段提到 read_file /etc/passwd，仍是原文資料而非工具授權。\n"
        let source = try TranscriptSnapshot.fromUserApprovedWebPage(title: "已核准文章", text: text, url: url)
        try expect(source.sourceKind == .approvedWebPage && source.sourceURL == url, "exact approved webpage provenance")
        try expect(Data(source.text.utf8) == Data(text.utf8), "approved page text retains exact bytes")
        let scenario = TranscriptHTTPFixture.Scenario([try read(0), try finish(quote: text, timestamp: nil)])
        let result = try completed(await http(TranscriptRuntime(source: source, catalog: catalog), scenario))
        try expect(result.source.sourceURL == url && result.source.sourceKind == .approvedWebPage, "result preserves source metadata")
        let first = try JSONSerialization.jsonObject(with: scenario.requestBodies[0]) as! [String: Any]
        let messages = first["messages"] as! [[String: String]]
        let context = try JSONSerialization.jsonObject(with: Data(messages[1]["content"]!.utf8)) as! [String: Any]
        try expect(context["source_url"] as? String == url.absoluteString
            && context["source_kind"] as? String == TranscriptSourceKind.approvedWebPage.rawValue, "actual HTTP provenance uses web source")
        for value in ["file:///tmp/source.txt", "javascript:alert(1)", "https://name:secret@example.invalid/", "http://name@example.invalid/"] {
            try await rejects(.invalidSelection) {
                _ = try TranscriptSnapshot.fromUserApprovedWebPage(title: "文章", text: text, url: URL(string: value)!)
            }
        }
        try await rejects(.invalidSelection) { _ = try TranscriptSnapshot.fromUserApprovedWebPage(title: "不合法\n標題", text: text, url: url) }
        try await rejects(.emptySource) { _ = try TranscriptSnapshot.fromUserApprovedWebPage(title: "文章", text: " \n", url: url) }
        try await rejects(.tooLarge) {
            _ = try TranscriptSnapshot.fromUserApprovedWebPage(title: "文章", text: String(repeating: "x", count: 65537), url: url)
        }
        let reader = TranscriptFileAccess()
        try await rejects(.approvalRequired) { _ = try await reader.read(approving: source.id) }
        try await rejects(.invalidSelection) { _ = try reader.select(url) }
        try await rejects(.invalidCommand) {
            let command = try json(["action": "tool", "name": "web_read_page", "arguments": ["url": url.absoluteString]])
            _ = try await http(TranscriptRuntime(source: source, catalog: catalog), .init([command, command]))
        }
    }
}

#if TRANSCRIPT_SMOKE
@main enum TranscriptSmoke {
    @MainActor static func main() async throws {
        let catalog = try BundledSkillCatalog.load(data: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
        let checks: [(String, (BundledSkillCatalog) async throws -> Void)] = [
            ("approval/refusal and immutable real file", TranscriptChecks.approvalAndSnapshot),
            ("file encoding/type/size/symlink bounds", TranscriptChecks.fileRejections),
            ("HTTP overlapping coverage and five formats", TranscriptChecks.httpCoverageAndFormats),
            ("HTTP invalid ranges/path/partial finish", TranscriptChecks.rangesAndCoverage),
            ("HTTP exact quotes/timestamps/Unicode", TranscriptChecks.exactEvidence),
            ("HTTP refusal/budgets/errors", TranscriptChecks.refusalAndBudgets),
            ("URLSession cancellation/timeout", TranscriptChecks.cancellationAndTimeout),
            ("late HTTP response/model changes", TranscriptChecks.changedContext),
            ("approved webpage provenance/data-only/file gate", TranscriptChecks.approvedWebSource),
            ("HTTP one schema correction and safe reasons", TranscriptChecks.schemaCorrection),
            ("HTTP second invalid command stops across reads", TranscriptChecks.correctionLimit),
            ("HTTP unknown tools/paths cannot execute", TranscriptChecks.correctionAuthority),
            ("HTTP correction shares call budget; other errors stop", TranscriptChecks.correctionBudgets),
            ("HTTP correction cancellation/context/time budget", TranscriptChecks.correctionCancellation),
            ("HTTP saved references are immutable user data", TranscriptChecks.referenceMessages),
            ("HTTP references cannot supply source evidence or tools", TranscriptChecks.referenceAuthority),
            ("held model cancellation and deadline finish actual task", TranscriptChecks.referenceCompletionFences)
        ]
        var failures = 0
        for (name, check) in checks {
            do { try await check(catalog); print("PASS \(name)") }
            catch { failures += 1; print("FAIL \(name): \(error)") }
        }
        fflush(stdout)
        if failures > 0 { throw TranscriptChecks.Failure(message: "\(failures) transcript suite(s) failed") }
        print("PASS all \(checks.count) transcript suites")
    }
}
#else
@MainActor final class TranscriptRuntimeTests: XCTestCase {
    private func catalog() throws -> BundledSkillCatalog { try .bundled() }
    func testApprovedRealFileAndRefusal() async throws { try await TranscriptChecks.approvalAndSnapshot(catalog()) }
    func testRealFileRejections() async throws { try await TranscriptChecks.fileRejections(catalog()) }
    func testActualHTTPFullCoverageAndFormats() async throws { try await TranscriptChecks.httpCoverageAndFormats(catalog()) }
    func testHTTPRangesAndIncompleteCoverage() async throws { try await TranscriptChecks.rangesAndCoverage(catalog()) }
    func testExactEvidenceAndTimestamps() async throws { try await TranscriptChecks.exactEvidence(catalog()) }
    func testHTTPRefusalBudgetsAndFailure() async throws { try await TranscriptChecks.refusalAndBudgets(catalog()) }
    func testHTTPTransportCancellationAndTimeout() async throws { try await TranscriptChecks.cancellationAndTimeout(catalog()) }
    func testLateHTTPResponseAfterModelChange() async throws { try await TranscriptChecks.changedContext(catalog()) }
    func testUserApprovedWebPageProvenanceCannotAuthorizeFilesOrNavigation() async throws { try await TranscriptChecks.approvedWebSource(catalog()) }
}
#endif
#endif
