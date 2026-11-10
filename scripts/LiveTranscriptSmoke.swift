import AssistantModels
import AssistantSkills
import Foundation

/// Real HTTP model + production TranscriptRuntime, over fixed synthetic UTF-8
/// source data. No fixture model, fetched webpage, native picker or UI claim.
/// Usage: LiveTranscriptSmoke /absolute/path/to/MikaBundledSkills.json
/// Link AssistantModels and AssistantSkills. Simulator needs no build flag;
/// an explicit macOS-only local invocation requires swiftc -D LOCAL_PROBE.
/// Configuration comes only from WOOW_MODEL_TEST_BASE_URL / MODEL / API_KEY.
/// Never print configuration, source, generated text or arbitrary errors.
@main
struct LiveTranscriptSmoke {
    private static let formats: [TranscriptFormat] = [.summary, .chapters, .quotations, .transcript, .article]
    private static let sourceText = """
    00:00.000 社區圖書交換站在星期六上午九點開放。志工先確認書籍完整，再依兒童讀物、小說與生活知識分類。
    每位參與者可以帶來三本書，也可以不帶書就來閱讀。現場不收取費用，尚未交換的書會保留到下次活動。

    00:30.000 這次活動共有十二位居民參加，帶來二十四本書。十六本書完成交換，另外八本留在交換站。
    一位志工負責登記數量，另一位志工協助整理書架。紀錄只包含書名與數量，不登記參與者的聯絡資料。

    01:00.000 活動結束前，居民建議增加清楚的分類標籤。志工同意先製作三張標籤，下次活動再觀察是否方便尋書。
    下一次活動仍安排在星期六上午九點。交換站會繼續免費開放，讓鄰居分享已讀完而且保存良好的書。
    """

    @MainActor static func main() async {
        #if targetEnvironment(simulator)
        emit("TRANSCRIPT_PROBE mode=simulator transport=realHTTP fixedSource=1 ui=0 fetchedPage=0")
        await run()
        #elseif os(macOS) && LOCAL_PROBE
        emit("TRANSCRIPT_PROBE mode=localProbe transport=realHTTP fixedSource=1 ui=0 fetchedPage=0")
        await run()
        #else
        emit("TRANSCRIPT_PROBE status=FAIL code=unsupportedHost")
        exit(1)
        #endif
    }

    @MainActor private static func run() async {
        // An independent process deadline also bounds a stalled system service.
        // It does not retry, invent a result, or print the in-flight request.
        let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        watchdog.schedule(deadline: .now() + 600)
        watchdog.setEventHandler { emit("TRANSCRIPT_PROBE status=FAIL code=overallDeadline"); exit(1) }
        watchdog.resume()
        defer { watchdog.cancel() }

        let catalog: BundledSkillCatalog
        let configuration: ModelConfiguration
        let key: String
        let source: TranscriptSnapshot
        do {
            guard CommandLine.arguments.count == 2 else { throw Check.catalogArgument }
            catalog = try loadCatalog(path: CommandLine.arguments[1])
            (configuration, key) = try modelConfiguration()
            guard formats.count == 5,
                  Set(formats.map(\.rawValue)) == Set(TranscriptFormat.allCases.map(\.rawValue)),
                  let url = URL(string: "https://transcript-probe.example.invalid/fixed-text") else { throw Check.invariant }
            source = try TranscriptSnapshot.fromUserApprovedWebPage(
                title: "固定文字整理驗證", text: sourceText, url: url)
            guard source.sourceKind == .approvedWebPage, source.sourceURL == url,
                  Data(source.text.utf8) == Data(sourceText.utf8), source.byteCount > 0 else { throw Check.sourceMismatch }
        } catch {
            emit("TRANSCRIPT_PROBE status=FAIL code=\(code(error)) attempted=0 expected=5")
            exit(1)
        }

        var passed = 0, totalCalls = 0
        for format in formats {
            emit("TRANSCRIPT_FORMAT format=\(format.rawValue) status=RUNNING callsLimit=6 deadlineSeconds=90")
            let start = ContinuousClock.now
            let transport = URLSessionConfiguration.ephemeral
            transport.timeoutIntervalForRequest = 90
            transport.timeoutIntervalForResource = 90
            transport.urlCache = nil
            transport.httpCookieStorage = nil
            transport.urlCredentialStorage = nil
            let session = URLSession(configuration: transport)
            let client = CountingClient(session: session)
            var runtime: TranscriptRuntime?
            var reads = 0, covered = 0, sections = 0, citations = 0
            var outcomeCode = "unknown", succeeded = false
            do {
                let current = try TranscriptRuntime(source: source, format: format, catalog: catalog,
                    limits: .init(modelCalls: 6, modelTime: .seconds(90)))
                runtime = current
                defer { current.cancel() }
                let outcome = try await boundedRun(current, client: client, configuration: configuration, key: key)
                guard case .completed(let result) = outcome else { throw Check.refused }
                let counts = await client.counts()
                try verify(result, format: format, source: source, covered: current.coveredBytes,
                           calls: counts.calls, responses: counts.responses)
                guard start.duration(to: .now) < .seconds(90) else { throw Check.formatDeadline }
                sections = result.sections.count
                citations = result.sections.reduce(0) { $0 + $1.evidence.count }
                succeeded = true; outcomeCode = "complete"; passed += 1
            } catch {
                outcomeCode = code(error)
            }
            reads = runtime?.reads.count ?? 0; covered = runtime?.coveredBytes ?? 0
            session.invalidateAndCancel()
            let counts = await client.counts()
            totalCalls += counts.calls
            let duration = start.duration(to: .now).components
            let milliseconds = duration.seconds * 1000 + duration.attoseconds / 1_000_000_000_000_000
            // The runtime enum cannot contain model-supplied text or fields.
            let reason = runtime?.lastCommandFailureReason?.rawValue ?? "none"
            let corrections = runtime?.formatCorrections ?? 0
            emit("TRANSCRIPT_FORMAT format=\(format.rawValue) status=\(succeeded ? "PASS" : "FAIL") code=\(outcomeCode) reason=\(reason) corrections=\(corrections) calls=\(counts.calls) responses=\(counts.responses) reads=\(reads) covered=\(covered) total=\(source.byteCount) sections=\(sections) citations=\(citations) elapsedMs=\(milliseconds)")
        }
        emit("TRANSCRIPT_PROBE status=\(passed == 5 ? "PASS" : "FAIL") attempted=5 passed=\(passed) failed=\(5 - passed) calls=\(totalCalls) ui=0 fetchedPage=0")
        if passed != 5 { exit(1) }
    }

    private static func loadCatalog(path: String) throws -> BundledSkillCatalog {
        do {
            guard path.hasPrefix("/") else { throw Check.catalogArgument }
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            var data = Data()
            while data.count <= 256 * 1024 {
                let next = try handle.read(upToCount: min(8192, 256 * 1024 + 1 - data.count)) ?? Data()
                if next.isEmpty { break }
                data.append(next)
            }
            return try BundledSkillCatalog.load(data: data)
        } catch let check as Check { throw check }
        catch { throw Check.catalogInvalid }
    }

    private static func modelConfiguration() throws -> (ModelConfiguration, String) {
        let environment = ProcessInfo.processInfo.environment
        guard let base = environment["WOOW_MODEL_TEST_BASE_URL"],
              let parts = URLComponents(string: base), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true, let url = parts.url,
              let model = environment["WOOW_MODEL_TEST_MODEL"],
              !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = environment["WOOW_MODEL_TEST_API_KEY"],
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              ![base, model, key].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw Check.configuration
        }
        return (.init(baseURL: url, model: model, maxOutputTokens: 4096), key)
    }

    @MainActor private static func boundedRun(_ runtime: TranscriptRuntime, client: CountingClient,
                                              configuration: ModelConfiguration, key: String) async throws -> TranscriptOutcome {
        let operation = Task { try await runtime.run(client: client, configuration: configuration, apiKey: key) }
        defer { operation.cancel() }
        return try await withThrowingTaskGroup(of: TranscriptOutcome.self) { group in
            group.addTask {
                try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            }
            group.addTask { try await Task.sleep(for: .seconds(90)); throw Check.formatDeadline }
            defer { group.cancelAll() }
            guard let outcome = try await group.next() else { throw Check.cancelled }
            try Task.checkCancellation()
            return outcome
        }
    }

    private static func verify(_ result: TranscriptResult, format: TranscriptFormat, source: TranscriptSnapshot,
                               covered: Int, calls: Int, responses: Int) throws {
        guard result.format == format else { throw Check.formatMismatch }
        guard result.source.id == source.id, result.source.sha256 == source.sha256,
              Data(result.source.text.utf8) == Data(source.text.utf8),
              result.sourceRevision == BundledSkillCatalog.pinnedCommit else { throw Check.sourceMismatch }
        guard (2...6).contains(calls), result.modelCalls == calls, responses == calls else { throw Check.callCount }
        let bytes = Data(source.text.utf8)
        var observed = 0
        guard !result.reads.isEmpty, covered == bytes.count else { throw Check.coverage }
        for read in result.reads {
            guard read.offset >= 0, read.offset <= observed, read.length > 0,
                  read.length <= 8192, read.end <= bytes.count,
                  Data(read.text.utf8) == bytes.subdata(in: read.offset..<read.end) else { throw Check.coverage }
            if observed > 0, read.end > observed, read.offset >= observed { throw Check.coverage }
            observed = max(observed, read.end)
        }
        guard observed == bytes.count else { throw Check.coverage }
        guard !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !result.sections.isEmpty else { throw Check.emptyResult }
        for section in result.sections {
            guard !section.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !section.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !section.evidence.isEmpty else { throw Check.emptyResult }
            for evidence in section.evidence {
                let quote = Data(evidence.quote.utf8)
                guard !quote.isEmpty, evidence.offset >= 0, evidence.offset <= bytes.count,
                      quote.count <= bytes.count - evidence.offset else { throw Check.quoteMismatch }
                let end = evidence.offset + quote.count
                guard bytes.subdata(in: evidence.offset..<end) == quote,
                      result.reads.contains(where: { $0.offset <= evidence.offset && $0.end >= end }) else { throw Check.quoteMismatch }
                if let timestamp = evidence.timestamp, quote.range(of: Data(timestamp.utf8)) == nil { throw Check.quoteMismatch }
            }
            if format == .quotations,
               !section.evidence.contains(where: { Data($0.quote.utf8) == Data(section.text.utf8) }) { throw Check.formatMismatch }
        }
    }

    private enum Check: String, Error {
        case catalogArgument, catalogInvalid, configuration, invariant, sourceMismatch
        case refused, formatMismatch, callCount, coverage, emptyResult, quoteMismatch
        case formatDeadline, cancelled
    }

    private static func code(_ error: Error) -> String {
        if let check = error as? Check { return check.rawValue }
        if let runtime = error as? TranscriptError { return runtime.rawValue }
        if error is CancellationError { return Check.cancelled.rawValue }
        return "unknown"
    }

    private static func emit(_ fixedStatus: String) { print(fixedStatus); fflush(stdout) }

    private actor CountingClient: ChatModelClient {
        private let client: HTTPChatModelClient
        private var calls = 0, responses = 0
        init(session: URLSession) { client = HTTPChatModelClient(session: session) }
        func counts() -> (calls: Int, responses: Int) { (calls, responses) }
        func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
            guard calls < 6 else { throw Check.callCount }
            try Task.checkCancellation()
            calls += 1
            let result = try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
            responses += 1
            return result
        }
    }
}
