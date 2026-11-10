import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit

// Opt-in local App probe, not native iOS UI acceptance.
// Usage: binary --live --catalog /path/to/pinned/MikaBundledSkills.json
// Configuration comes only from the three authorized WOOW_MODEL_TEST_* fields.
// Follow-up to the preserved four-request FAIL: two distinct cases share the
// remaining EIGHT requests. Cumulative authorization is twelve; failure stops.
private enum PDFReferenceAllowance {
    static let previous = 4
    static let remaining = 8
    static let total = 12
}

// BEGIN PURE PREFIX DIAGNOSTICS — observation only, never acceptance logic.
private enum PDFReferenceOutcome: String, Encodable { case notChecked, pass, fail }
private enum PDFReferencePrefixCategory: String, Encodable {
    case notChecked, exact, leadingWhitespace, markdownWrapped, newline, tab
    case otherWhitespace, endWithoutSpace, otherSeparator, laterInAnswer
    case caseChanged, uuidChanged, tokenAltered, absent
}
private struct PDFReferencePrefixObservation: Encodable {
    var category = PDFReferencePrefixCategory.notChecked
    var answerUTF8Bytes = 0
    var exactTokenPresent = false
    var savedTokenPresent = false

    static func inspect(answer: String, expected: String, saved: String) -> Self {
        var result = Self()
        result.answerUTF8Bytes = answer.utf8.count
        result.exactTokenPresent = answer.contains(expected)
        result.savedTokenPresent = answer.contains(saved)
        if answer.hasPrefix(expected + " ") { result.category = .exact; return result }
        if let range = answer.range(of: expected) {
            let before = String(answer[..<range.lowerBound])
            if !before.isEmpty {
                let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { result.category = .leadingWhitespace }
                else if ["**", "*", "_", "__", "`", "``", "```", "#", "##", "###", ">"].contains(trimmed) {
                    result.category = .markdownWrapped
                } else { result.category = .laterInAnswer }
            } else if range.upperBound == answer.endIndex { result.category = .endWithoutSpace }
            else {
                let following = answer[range.upperBound]
                if following == "\n" || following == "\r\n" || following == "\r" { result.category = .newline }
                else if following == "\t" { result.category = .tab }
                else if following.isWhitespace { result.category = .otherWhitespace }
                else { result.category = .otherSeparator }
            }
        } else if answer.range(of: expected, options: .caseInsensitive) != nil {
            result.category = .caseChanged
        } else {
            let stem = expected.hasPrefix("SAVED_PDF_") ? "SAVED_PDF_" : "CURRENT_PDF_"
            if let stemRange = answer.range(of: stem, options: .caseInsensitive) {
                let candidate = String(answer[stemRange.upperBound...].prefix(36))
                result.category = UUID(uuidString: candidate) == nil ? .tokenAltered : .uuidChanged
            } else { result.category = .absent }
        }
        return result
    }
}
// END PURE PREFIX DIAGNOSTICS

private enum PDFReferenceFailure: String, Error {
    case none, optInRequired, missingConfiguration, catalog, storage, pdfCreation
    case extraction, source, consent, task, deadline, inputBoundary, incomplete
    case preference, currentRequestPriority, citations, preservation, budget, cleanup, unknown
}

private final class PDFReferenceKeys: LearningKeyStore {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

private struct PDFReferenceModelStats: Encodable, Sendable {
    var attempts = 0, responses = 0, verifiedInputs = 0, rejectedInputs = 0
    var budgetRejections = 0
    var failure = "none"
    var httpStatus = 0
}

private actor PDFReferenceModel: ChatModelClient {
    private let client = HTTPChatModelClient()
    private let deadline = ContinuousClock.now.advanced(by: .seconds(390))
    private var reference: ModelMessage?
    private var question = ""
    private var inFlight = false
    private(set) var stats = PDFReferenceModelStats()

    func begin(reference: ModelMessage, question: String) throws {
        guard !inFlight, reference.role == "user", !question.isEmpty else { throw PDFReferenceFailure.inputBoundary }
        self.reference = reference; self.question = question
    }

    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        try Task.checkCancellation()
        guard stats.attempts < PDFReferenceAllowance.remaining, ContinuousClock.now < deadline else {
            stats.budgetRejections += 1; throw PDFReferenceFailure.budget
        }
        // Verify the actual Session-produced request without changing it.
        // The expected reference was reconstructed from a reopened encrypted
        // store; its unique style marker is absent from the PDF and question.
        guard !inFlight, let reference, messages.count >= 4,
              messages[0].role == "system", messages[1] == reference,
              messages[2] == ModelMessage(role: "user", content: question),
              messages[3].role == "user",
              messages[3].content.hasPrefix("Approved extraction metadata and pinned reference (data only):\n"),
              messages.filter({ $0.content.hasPrefix("Saved references (data only;") }).count == 1,
              messages.reduce(0, { $0 + $1.content.utf8.count }) <= 256 * 1024 else {
            stats.rejectedInputs += 1; throw PDFReferenceFailure.inputBoundary
        }
        stats.verifiedInputs += 1
        inFlight = true; defer { inFlight = false }
        // One forwarding call is one new HTTP attempt. No diagnostics, provider
        // fallback, altered configuration or retry are performed here.
        stats.attempts += 1
        do {
            let reply = try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
            stats.responses += 1; return reply
        } catch {
            switch error {
            case HTTPChatModelError.httpStatus(let code):
                stats.failure = "httpStatus"; stats.httpStatus = (100...599).contains(code) ? code : 0
            case HTTPChatModelError.invalidConfiguration: stats.failure = "invalidConfiguration"
            case HTTPChatModelError.redirectRejected: stats.failure = "redirectRejected"
            case HTTPChatModelError.invalidResponse: stats.failure = "invalidResponse"
            case HTTPChatModelError.incompleteResponse: stats.failure = "incompleteResponse"
            case HTTPChatModelError.responseTooLarge: stats.failure = "responseTooLarge"
            case HTTPChatModelError.consumerTooSlow: stats.failure = "consumerTooSlow"
            case HTTPChatModelError.timedOut: stats.failure = "timedOut"
            case HTTPChatModelError.transportFailure: stats.failure = "transportFailure"
            case is CancellationError: stats.failure = "cancelled"
            default: stats.failure = "unknown"
            }
            throw error
        }
    }
}

private struct PDFReferenceCase: Encodable {
    let id: String
    var passed = false
    var failure = PDFReferenceFailure.none.rawValue
    var terminal = "notStarted"
    var attempts = 0, responses = 0, verifiedInputs = 0
    var modelCalls = 0, searches = 0, reads = 0, results = 0, citations = 0, corrections = 0
    var prefixMatched = false, exactReadLedger = false, sourceUnchanged = false
    var consentRequired = false
    var prefixOutcome = PDFReferenceOutcome.notChecked
    var ledgerOutcome = PDFReferenceOutcome.notChecked
    var sourceOutcome = PDFReferenceOutcome.notChecked
    var prefixObservation = PDFReferencePrefixObservation()
    var seconds = 0.0
}

private struct PDFReferenceReport: Encodable {
    let schemaVersion = 1
    let nativeIOSUI = false
    let syntheticSourceOnly = true
    let maximumHTTPAttempts = 12
    let previousHTTPAttempts = PDFReferenceAllowance.previous
    let maximumNewHTTPAttempts = PDFReferenceAllowance.remaining
    var cumulativeHTTPAttempts = PDFReferenceAllowance.previous
    var result = "FAIL"
    var failure = PDFReferenceFailure.none.rawValue
    var catalogVerified = false, encryptedStoreReopened = false, storageUnchanged = false
    var cleanupSucceeded = false
    var storageOutcome = PDFReferenceOutcome.notChecked
    var cases: [PDFReferenceCase] = []
    var model = PDFReferenceModelStats()
    var seconds = 0.0
}

@main private enum LiveDocumentQueryReferenceSmoke {
    @MainActor static func main() async {
        let started = ContinuousClock.now
        let client = PDFReferenceModel()
        var report = PDFReferenceReport()
        do {
            try await exercise(client, report: &report)
            guard report.cleanupSucceeded else { throw PDFReferenceFailure.cleanup }
            report.result = "PASS"
        } catch {
            report.failure = (error as? PDFReferenceFailure)?.rawValue ?? PDFReferenceFailure.unknown.rawValue
        }
        report.model = await client.stats
        report.cumulativeHTTPAttempts = PDFReferenceAllowance.previous + report.model.attempts
        report.seconds = elapsed(started)
        // Only Codable fixed fields, closed categories, counts and booleans.
        // No config, file paths, UUIDs, request/source text or model replies.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        if let bytes = try? encoder.encode(report), let text = String(data: bytes, encoding: .utf8) { print(text) }
        exit(report.result == "PASS" ? 0 : 1)
    }

    @MainActor private static func exercise(_ client: PDFReferenceModel, report: inout PDFReferenceReport) async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 3, args[0] == "--live", args[1] == "--catalog" else {
            throw PDFReferenceFailure.optInRequired
        }
        let catalog: BundledSkillCatalog
        do {
            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: args[2]))
            defer { try? handle.close() }
            let bytes = try handle.read(upToCount: 1_048_577) ?? Data()
            guard bytes.count <= 1_048_576 else { throw PDFReferenceFailure.catalog }
            catalog = try BundledSkillCatalog.load(data: bytes)
        } catch { throw PDFReferenceFailure.catalog }
        report.catalogVerified = true
        let env = ProcessInfo.processInfo.environment
        guard let base = env["WOOW_MODEL_TEST_BASE_URL"], let url = URL(string: base),
              url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
              let model = env["WOOW_MODEL_TEST_MODEL"], !model.isEmpty,
              let key = env["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty else {
            throw PDFReferenceFailure.missingConfiguration
        }
        let access = ModelAccess(client: client, configuration: .init(baseURL: url, model: model, maxOutputTokens: 2048), key: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-pdf-reference-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try FileManager.default.removeItem(at: root); report.cleanupSucceeded = true }
            catch { report.cleanupSucceeded = false }
        }
        let savedPrefix = "SAVED_PDF_" + UUID().uuidString
        let currentPrefix = "CURRENT_PDF_" + UUID().uuidString
        let preference = "I prefer PDF answers to begin with the exact prefix '\(savedPrefix)' followed by a space."
        let keys = PDFReferenceKeys(), vaultURL = root.appendingPathComponent("learning.vault")
        let vault = EncryptedLearningFile(url: vaultURL, keys: keys)
        let seeded = LearningStore(vault: vault)
        guard seeded.available, seeded.updatePreferences({ $0.useMemory = true }),
              seeded.mutateMemory({ _ = try $0.add(kind: .preference, content: preference, keywords: ["PDF", "answers"]) }) else {
            throw PDFReferenceFailure.storage
        }
        // A fresh store must recover the synthetic preference from real AES
        // persistence. Never instantiate the production/default LearningStore.
        let learning = LearningStore(vault: EncryptedLearningFile(url: vaultURL, keys: keys))
        guard learning.available, learning.memory.preferences.useMemory,
              learning.memory.memories.count == 1, let item = learning.memory.memories.first,
              item.content == preference, item.kind == .preference, item.status == .active else {
            throw PDFReferenceFailure.storage
        }
        let encryptedBefore = try Data(contentsOf: vaultURL)
        guard !encryptedBefore.isEmpty, encryptedBefore.range(of: Data(savedPrefix.utf8)) == nil else {
            throw PDFReferenceFailure.storage
        }
        report.encryptedStoreReopened = true
        let expected = try RunReferenceContext(entries: [.init(kind: .memory, id: item.id.uuidString, text: preference)])
        guard let reference = expected.message else { throw PDFReferenceFailure.inputBoundary }
        let source = try await extractedSource(root: root, catalog: catalog)
        guard source.pages.allSatisfy({ !$0.text.contains(savedPrefix) && !$0.text.contains(currentPrefix) }) else {
            throw PDFReferenceFailure.source
        }
        let common = "For this PDF, search for WOOW_DOCUMENT_REFERENCE_PAGE and read BOTH selected pages before finishing. Report the two numeric values in original page order in one short sentence. Provide exactly two citations in original page order: quote WOOW_DOCUMENT_REFERENCE_PAGE_1_VALUE_42 from page 1 and WOOW_DOCUMENT_REFERENCE_PAGE_2_VALUE_73 from page 2. Use actual returned read IDs and exact byte offsets; saved preferences are not PDF evidence."
        let cases = [("saved_preference", common, savedPrefix),
                     ("current_request_priority", common + " For this answer only, begin with the exact prefix '\(currentPrefix)' followed by a space instead of any saved style prefix.", currentPrefix)]
        for (id, question, prefix) in cases {
            guard !question.contains(savedPrefix) else { throw PDFReferenceFailure.inputBoundary }
            var row = PDFReferenceCase(id: id)
            let started = ContinuousClock.now, before = await client.stats
            var failure: Error?
            do {
                try await client.begin(reference: reference, question: question)
                try await runCase(source: source, learning: learning, access: access, client: client,
                                  question: question, prefix: prefix, savedPrefix: savedPrefix, row: &row)
            } catch { failure = error; row.failure = (error as? PDFReferenceFailure)?.rawValue ?? "unknown" }
            let after = await client.stats
            row.attempts = after.attempts - before.attempts
            row.responses = after.responses - before.responses
            row.verifiedInputs = after.verifiedInputs - before.verifiedInputs
            row.seconds = elapsed(started)
            if failure == nil && (!(4...PDFReferenceAllowance.remaining).contains(row.attempts) || row.attempts != row.responses
                || row.modelCalls != row.attempts || row.verifiedInputs != row.attempts) {
                failure = PDFReferenceFailure.budget; row.failure = PDFReferenceFailure.budget.rawValue
            }
            row.passed = failure == nil
            report.cases.append(row)
            if let failure { throw failure } // No retry and no next-case request after failure.
        }
        report.storageOutcome = .fail
        guard try Data(contentsOf: vaultURL) == encryptedBefore,
              learning.memory.memories.count == 1, learning.memory.memories.first?.content == preference else {
            throw PDFReferenceFailure.preservation
        }
        report.storageUnchanged = true
        report.storageOutcome = .pass
    }

    @MainActor private static func runCase(source: DocumentTextSnapshot, learning: LearningStore,
        access: ModelAccess, client: PDFReferenceModel, question: String, prefix: String,
        savedPrefix: String, row: inout PDFReferenceCase) async throws {
        let session = DocumentQuerySession(source: source, learning: learning)
        defer { session.cancel(notice: false) }
        let before = await client.stats.attempts
        session.setQuestion(question)
        session.start(modelAccess: { access })
        guard !session.running, session.error != nil, session.result == nil, await client.stats.attempts == before else {
            throw PDFReferenceFailure.consent
        }
        session.confirmDestination(modelAccess: { access })
        guard session.destination != nil, session.result == nil, session.audit.modelCalls == 0,
              await client.stats.attempts == before else { throw PDFReferenceFailure.consent }
        row.consentRequired = true
        session.start(modelAccess: { access })
        #if DEBUG
        let completion = session.capturedRunCompletion
        #else
        let completion = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value as? Task<Void, Never>
        #endif
        guard let completion else { throw PDFReferenceFailure.task }
        var deadlineReached = false
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 185_000_000_000) } catch { return }
            deadlineReached = true; session.cancel(notice: false)
        }
        await completion.value // Observe the actual App task, not a counter/yield proxy.
        watchdog.cancel()
        row.modelCalls = session.audit.modelCalls; row.searches = session.audit.searches
        row.reads = session.audit.reads; row.results = session.audit.results
        row.citations = session.audit.citations; row.corrections = session.audit.corrections
        row.terminal = terminal(session)
        guard !deadlineReached else { throw PDFReferenceFailure.deadline }
        guard let result = session.result, session.error == nil, session.refusal == nil, !session.running,
              session.audit.results == 1, session.audit.searches >= 1, session.audit.reads >= 2,
              session.audit.corrections <= 1 else { throw PDFReferenceFailure.incomplete }
        row.prefixObservation = .inspect(answer: result.answer, expected: prefix, saved: savedPrefix)
        row.prefixMatched = result.answer.hasPrefix(prefix + " ")
            && (prefix == savedPrefix || !result.answer.contains(savedPrefix))
        row.prefixOutcome = row.prefixMatched ? .pass : .fail
        guard row.prefixMatched else {
            throw prefix == savedPrefix ? PDFReferenceFailure.preference : PDFReferenceFailure.currentRequestPriority
        }
        guard result.answer.contains("42"), result.answer.contains("73") else { throw PDFReferenceFailure.source }
        row.ledgerOutcome = .fail
        guard result.source.sha256 == source.sha256, result.question == question,
              result.citations.count == 2, result.citations.map(\.pageNumber) == [1, 2] else { throw PDFReferenceFailure.citations }
        for read in result.reads {
            guard (1...source.pages.count).contains(read.pageIndex) else { throw PDFReferenceFailure.citations }
            let page = source.pages[read.pageIndex - 1], bytes = Data(page.text.utf8)
            guard read.pageNumber == page.pageNumber, read.sourceSHA256 == source.sha256,
                  read.offset >= 0, read.offset <= bytes.count, read.length >= 0, read.length <= bytes.count - read.offset,
                  bytes.subdata(in: read.offset..<(read.offset + read.length)) == Data(read.text.utf8) else {
                throw PDFReferenceFailure.citations
            }
        }
        for citation in result.citations {
            guard let read = result.reads.first(where: { $0.id == citation.readID }),
                  citation.pageIndex == read.pageIndex, citation.pageNumber == read.pageNumber,
                  citation.sourceSHA256 == source.sha256,
                  citation.quote == marker(citation.pageNumber), citation.offset >= read.offset else {
                throw PDFReferenceFailure.citations
            }
            let bytes = Data(read.text.utf8), offset = citation.offset - read.offset, quote = Data(citation.quote.utf8)
            guard offset <= bytes.count, quote.count <= bytes.count - offset,
                  bytes.subdata(in: offset..<(offset + quote.count)) == quote else { throw PDFReferenceFailure.citations }
        }
        row.exactReadLedger = true
        row.ledgerOutcome = .pass
        row.sourceUnchanged = session.source.sha256 == source.sha256
        row.sourceOutcome = row.sourceUnchanged ? .pass : .fail
        guard row.sourceUnchanged else { throw PDFReferenceFailure.preservation }
    }

    @MainActor private static func terminal(_ session: DocumentQuerySession) -> String {
        if session.result != nil { return "completed" }
        if session.refusal != nil { return "refused" }
        for error: DocumentQueryError in [.invalidSource, .emptySource, .sourceTooLarge, .invalidQuestion, .invalidLimits,
            .invalidRange, .invalidSearch, .invalidEvidence, .invalidCommand, .budgetExceeded, .outputTooLarge,
            .cancelled, .timedOut, .contextChanged, .modelFailed] {
            if session.error == error.errorDescription { return error.rawValue }
        }
        return "incomplete"
    }

    @MainActor private static func extractedSource(root: URL, catalog: BundledSkillCatalog) async throws -> DocumentTextSnapshot {
        let bytes = try pdf(), url = root.appendingPathComponent("Synthetic-Reference.pdf")
        try bytes.write(to: url, options: .withoutOverwriting)
        let runtime = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: url), options: .init(), catalog: catalog)
        guard runtime.plan.steps.count == 2 else { throw PDFReferenceFailure.extraction }
        let read = try await runtime.authorize(stepID: runtime.plan.steps[0].id)
        guard case .selectedFileRead = try await runtime.execute(read) else { throw PDFReferenceFailure.extraction }
        let extract = try await runtime.authorize(stepID: runtime.plan.steps[1].id)
        guard case .pdf(let result) = try await runtime.execute(extract), result.pages.count == 2,
              result.engine == "Apple PDFKit", result.originalScriptSHA256 == nil,
              result.inputSHA256 == SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() else {
            throw PDFReferenceFailure.extraction
        }
        let snapshot = try DocumentTextSnapshot(result: result, filename: url.lastPathComponent, catalog: catalog)
        try FileManager.default.removeItem(at: url) // Later queries can only use the approved snapshot.
        guard !FileManager.default.fileExists(atPath: url.path) else { throw PDFReferenceFailure.source }
        return snapshot
    }

    private static func marker(_ page: Int) -> String {
        "WOOW_DOCUMENT_REFERENCE_PAGE_\(page)_VALUE_\(page == 1 ? 42 : 73)"
    }

    private static func pdf() throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw PDFReferenceFailure.pdfCreation
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for page in 1...2 {
            context.beginPDFPage(nil); context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: 700)
            let line = NSAttributedString(string: marker(page), attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            CTLineDraw(CTLineCreateWithAttributedString(line), context); context.endPDFPage()
        }
        context.closePDF()
        guard PDFDocument(data: output as Data)?.pageCount == 2 else { throw PDFReferenceFailure.pdfCreation }
        return output as Data
    }

    private static func elapsed(_ start: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: .now).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
