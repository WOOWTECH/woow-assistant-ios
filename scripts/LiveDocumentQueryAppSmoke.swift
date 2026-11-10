import AssistantModels
import AssistantPersistence
import AssistantSkills
import CoreGraphics
import CoreText
import CryptoKit
import Foundation
import PDFKit

// Actual HTTP, PDFKit and App Session; this does not drive native iOS UI.
// Only synthetic PDF text is sent. Output is fixed categories and counts.
private enum DocumentLiveCheck: String, Error {
    case missingConfiguration, pdfCreation, extraction, source, consent, deadline
    case incomplete, answer, citations, export, preservation, budget, unknown
}

/// This probe must never open the user's learning Keychain or Application Support.
private final class DocumentProbeKeys: LearningKeyStore {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

private actor DocumentActualModel: ChatModelClient {
    private let client = HTTPChatModelClient()
    private(set) var calls = 0
    private(set) var responses = 0
    private(set) var failure = "none"
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        guard calls < 12 else { throw DocumentLiveCheck.budget }
        try Task.checkCancellation(); calls += 1
        do {
            let reply = try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
            responses += 1; return reply
        } catch {
            switch error {
            case HTTPChatModelError.httpStatus: failure = "httpRejected"
            case HTTPChatModelError.timedOut: failure = "timedOut"
            case HTTPChatModelError.transportFailure: failure = "transportFailure"
            case HTTPChatModelError.incompleteResponse: failure = "incompleteResponse"
            case is CancellationError: failure = "cancelled"
            default: failure = "modelFailure"
            }
            throw error
        }
    }
}

@main private enum LiveDocumentQueryAppSmoke {
    @MainActor static func main() async {
        let start = ContinuousClock.now
        let client = DocumentActualModel()
        var report: [String: Any] = ["schema_version": 1, "native_ios_ui": false,
            "actual_model": true, "actual_pdfkit": true, "synthetic_source_only": true]
        do {
            try await exercise(client)
            report["result"] = "PASS"; report["failure"] = "none"
        } catch {
            report["result"] = "FAIL"
            report["failure"] = (error as? DocumentLiveCheck)?.rawValue ?? "unknown"
        }
        report["model_calls"] = await client.calls
        report["model_responses"] = await client.responses
        report["model_failure"] = await client.failure
        let parts = start.duration(to: .now).components
        report["seconds"] = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
        if let bytes = try? JSONSerialization.data(withJSONObject: report, options: [.sortedKeys]),
           let text = String(data: bytes, encoding: .utf8) { print(text) }
        exit(report["result"] as? String == "PASS" ? 0 : 1)
    }

    @MainActor private static func exercise(_ client: DocumentActualModel) async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["WOOW_MODEL_TEST_BASE_URL"], let url = URL(string: base), url.scheme == "https",
              let model = env["WOOW_MODEL_TEST_MODEL"], !model.isEmpty,
              let key = env["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty else { throw DocumentLiveCheck.missingConfiguration }
        let access = ModelAccess(client: client, configuration: .init(baseURL: url, model: model, maxOutputTokens: 2048), key: key)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-document-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let input = root.appendingPathComponent("Synthetic-Document.pdf"), bytes = try pdf()
        try bytes.write(to: input, options: .withoutOverwriting)
        let catalog = try BundledSkillCatalog.bundled()
        let extraction = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: input), options: .init(), catalog: catalog)
        let steps = extraction.plan.steps
        guard steps.count == 2 else { throw DocumentLiveCheck.extraction }
        let readApproval = try await extraction.authorize(stepID: steps[0].id)
        guard case .selectedFileRead = try await extraction.execute(readApproval) else { throw DocumentLiveCheck.extraction }
        let extractionApproval = try await extraction.authorize(stepID: steps[1].id)
        guard case .pdf(let extracted) = try await extraction.execute(extractionApproval), extracted.pages.count == 2,
              extracted.engine == "Apple PDFKit", extracted.originalScriptSHA256 == nil else { throw DocumentLiveCheck.extraction }
        let expectedHash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        guard extracted.inputSHA256 == expectedHash else { throw DocumentLiveCheck.source }
        let snapshot = try DocumentTextSnapshot(result: extracted, filename: input.lastPathComponent, catalog: catalog)
        // Querying/exporting must use the completed snapshot, never reopen PDF.
        try FileManager.default.removeItem(at: input)
        let learning = LearningStore(vault: EncryptedLearningFile(
            url: root.appendingPathComponent("probe-learning.vault"), keys: DocumentProbeKeys()))
        guard learning.available else { throw DocumentLiveCheck.consent }
        let session = DocumentQuerySession(source: snapshot, learning: learning)
        session.setQuestion("Search for WOOW_DOCUMENT_QUERY_PAGE. Read BOTH selected pages before finishing. Answer exactly DOCUMENT_QUERY_OK_42_73. Provide exactly two citations, quoting WOOW_DOCUMENT_QUERY_PAGE_1_VALUE_42 from original page 1 and WOOW_DOCUMENT_QUERY_PAGE_2_VALUE_73 from original page 2, using each actual returned read ID and byte offset. Do not invent evidence.")
        session.start(modelAccess: { access })
        guard !session.running, session.result == nil, session.error != nil, await client.calls == 0 else { throw DocumentLiveCheck.consent }
        session.confirmDestination(modelAccess: { access })
        guard session.destination != nil, session.result == nil, session.audit.modelCalls == 0, await client.calls == 0 else {
            throw DocumentLiveCheck.consent
        }
        session.start(modelAccess: { access })
        let deadline = ContinuousClock.now.advanced(by: .seconds(190))
        while session.running {
            guard ContinuousClock.now < deadline else { session.cancel(); throw DocumentLiveCheck.deadline }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        guard let result = session.result, session.error == nil, session.refusal == nil,
              let delivery = session.deliveryID, session.audit.results == 1,
              session.audit.searches >= 1, session.audit.reads >= 2 else { throw DocumentLiveCheck.incomplete }
        guard result.answer == "DOCUMENT_QUERY_OK_42_73" else { throw DocumentLiveCheck.answer }
        guard result.citations.count == 2, Set(result.citations.map(\.pageNumber)) == [1, 2],
              result.source.sha256 == snapshot.sha256 else { throw DocumentLiveCheck.citations }
        for citation in result.citations {
            guard citation.pageIndex == citation.pageNumber,
                  citation.quote == "WOOW_DOCUMENT_QUERY_PAGE_\(citation.pageNumber)_VALUE_\(citation.pageNumber == 1 ? 42 : 73)",
                  let read = result.reads.first(where: { $0.id == citation.readID }),
                  read.pageIndex == citation.pageIndex,
                  Data(read.text.utf8).range(of: Data(citation.quote.utf8)) != nil else { throw DocumentLiveCheck.citations }
        }
        let document = try SkillExecutionTextDocument(text: result.textForExport)
        let output = root.appendingPathComponent("answer.txt")
        try document.snapshot().write(to: output, options: .atomic, originalContentsURL: nil)
        let reopened = try SkillExecutionTextDocument(fileWrapper: FileWrapper(url: output))
        guard reopened.text == result.textForExport,
              reopened.text.contains(expectedHash), reopened.text.contains("DOCUMENT_QUERY_OK_42_73"),
              !FileManager.default.fileExists(atPath: input.path) else { throw DocumentLiveCheck.export }
        let calls = await client.calls
        session.hostChanged()
        guard session.destination == nil, session.deliveryID == delivery, session.result?.answer == result.answer,
              session.source.sha256 == snapshot.sha256, !session.running, await client.calls == calls else {
            throw DocumentLiveCheck.preservation
        }
        let responses = await client.responses
        guard calls == responses, calls == result.modelCalls, (4...12).contains(calls) else { throw DocumentLiveCheck.budget }
    }

    private static func pdf() throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw DocumentLiveCheck.pdfCreation }
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for number in 1...2 {
            context.beginPDFPage(nil); context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: 700)
            let text = NSAttributedString(string: "WOOW_DOCUMENT_QUERY_PAGE_\(number)_VALUE_\(number == 1 ? 42 : 73)",
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            CTLineDraw(CTLineCreateWithAttributedString(text), context); context.endPDFPage()
        }
        context.closePDF()
        guard PDFDocument(data: output as Data)?.pageCount == 2 else { throw DocumentLiveCheck.pdfCreation }
        return output as Data
    }
}
