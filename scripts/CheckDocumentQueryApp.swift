#if DOCUMENT_QUERY_APP_STANDALONE || canImport(WoowAssistant)
import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import Combine
import CoreGraphics
import CoreText
import Foundation
import PDFKit
#if !DOCUMENT_QUERY_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

// The same bodies run against actual App sources on CLT and in the hosted
// XCTest target. Only the external model and credential stores are synthetic.
private struct DocumentAppCheckFailure: Error { let label: String }
private final class DocumentCheckKeys: LearningKeyStore {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}
private final class DocumentCheckCredentials: ModelCredentialStoring {
    private var values: [String: String] = [:]
    func read(account: String) throws -> String? { values[account] }
    func insert(_ key: String, account: String) throws { values[account] = key }
    func remove(account: String) throws { values.removeValue(forKey: account) }
    func removeAll() throws { values = [:] }
}
private actor DocumentCheckGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    // Deliberately cancellation-insensitive, to deliver an actual late reply.
    func wait() async {
        await withCheckedContinuation { continuation in
            if released { continuation.resume() } else { waiters.append(continuation) }
        }
    }
    func release() {
        released = true
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}
private actor DocumentCheckModel: ChatModelClient {
    enum First: Sendable { case normal, transportFailure, refuse, malformed }
    let first: First
    let finishGate: DocumentCheckGate?
    private var gated = false
    private(set) var requests: [[ModelMessage]] = []
    private(set) var finishedResponses = 0
    private(set) var waitingForFinish = false
    init(first: First = .normal, finishGate: DocumentCheckGate? = nil) {
        self.first = first; self.finishGate = finishGate
    }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        requests.append(messages)
        if requests.count == 1 {
            switch first {
            case .transportFailure: throw URLError(.networkConnectionLost)
            case .refuse: return #"{"action":"refuse","reason":"Synthetic source needs a clearer question"}"#
            case .malformed: return "Synthetic non-JSON response"
            case .normal: break
            }
        }
        let actions = messages.filter { $0.role == "assistant" }
        if actions.isEmpty {
            return #"{"action":"search_files","query":"JASMINE_DOCUMENT_VALUE_73","limit":10}"#
        }
        guard let last = messages.last?.content, let newline = last.firstIndex(of: "\n"),
              let payload = try JSONSerialization.jsonObject(with: Data(last[last.index(after: newline)...].utf8)) as? [String: Any]
        else { throw DocumentAppCheckFailure(label: "Actual tool result required") }
        if let hits = payload["hits"] as? [[String: Any]], let hit = hits.first,
           let index = hit["pageIndex"] as? Int {
            return try Self.json(["action": "read_file", "pageIndex": index, "offset": 0, "limit": 8192])
        }
        guard let readID = payload["id"] as? String, UUID(uuidString: readID) != nil,
              let text = payload["text"] as? String, let offset = payload["offset"] as? Int,
              let range = Data(text.utf8).range(of: Data("JASMINE_DOCUMENT_VALUE_73".utf8))
        else { throw DocumentAppCheckFailure(label: "Citation must derive from actual returned read") }
        let finish = try Self.json(["action": "finish", "answer": "Synthetic answer 73",
            "citations": [["readID": readID, "offset": offset + range.lowerBound, "quote": "JASMINE_DOCUMENT_VALUE_73"]]])
        if let finishGate, !gated {
            gated = true; waitingForFinish = true
            await finishGate.wait()
        }
        finishedResponses += 1
        return finish
    }
    private static func json(_ value: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self)
    }
}

@MainActor private final class DocumentCheckEnvironment {
    let root: URL
    let defaultsName = "io.woowtech.document-query-check." + UUID().uuidString
    let defaults: UserDefaults
    let repository: ModelSettingsRepository
    let learning: LearningStore
    let chat: ChatSession
    let model: DocumentCheckModel
    init(_ model: DocumentCheckModel = .init()) throws {
        self.model = model
        root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-document-app-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defaults = UserDefaults(suiteName: defaultsName)!
        repository = ModelSettingsRepository(defaults: defaults, credentials: DocumentCheckCredentials())
        _ = try repository.save(baseURL: "https://document-check.example.invalid/v1", model: "synthetic-document", newKey: "synthetic-not-a-key")
        learning = LearningStore(vault: EncryptedLearningFile(url: root.appendingPathComponent("learning.vault"), keys: DocumentCheckKeys()))
        guard learning.available, learning.updatePreferences({ $0.autoRemember = false }) else {
            throw DocumentAppCheckFailure(label: "Isolated real encrypted store")
        }
        chat = ChatSession(learning: learning, repository: repository, client: model)
    }
    func close() {
        defaults.removePersistentDomain(forName: defaultsName)
        try? FileManager.default.removeItem(at: root)
    }
    func savedBytes() throws -> Data { try Data(contentsOf: root.appendingPathComponent("learning.vault")) }
    func access() throws -> ModelAccess { try chat.modelAccess() }
    func source() async throws -> DocumentTextSnapshot {
        let input = root.appendingPathComponent("Synthetic.pdf")
        try Self.pdf().write(to: input, options: .withoutOverwriting)
        let catalog = try BundledSkillCatalog.bundled()
        let runtime = try SkillExecutionRuntime(selectedFile: .init(userSelectedURL: input), options: .init(pages: "2,1"), catalog: catalog)
        try DocumentQueryAppChecks.check(runtime.plan.steps.count == 2, "Actual extraction has two separate approvals")
        let first = try await runtime.authorize(stepID: runtime.plan.steps[0].id)
        guard case .selectedFileRead = try await runtime.execute(first) else {
            throw DocumentAppCheckFailure(label: "Actual selected file read")
        }
        let callsAfterRead = await model.requests.count
        try DocumentQueryAppChecks.check(callsAfterRead == 0, "File approval does not authorize a model request")
        let second = try await runtime.authorize(stepID: runtime.plan.steps[1].id)
        guard case .pdf(let result) = try await runtime.execute(second) else {
            throw DocumentAppCheckFailure(label: "Actual PDF extraction")
        }
        try DocumentQueryAppChecks.check(result.engine == "Apple PDFKit" && result.pages.map(\.number) == [2, 1], "Real PDFKit selected order")
        let snapshot = try DocumentTextSnapshot(result: result, filename: input.lastPathComponent, catalog: catalog)
        try FileManager.default.removeItem(at: input)
        try DocumentQueryAppChecks.check(!FileManager.default.fileExists(atPath: input.path), "Source PDF removed before querying")
        return snapshot
    }
    private static func pdf() throws -> Data {
        let output = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: output), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw DocumentAppCheckFailure(label: "Synthetic PDF creation")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        for value in ["ALPHA_DOCUMENT_VALUE_42", "JASMINE_DOCUMENT_VALUE_73"] {
            context.beginPDFPage(nil); context.textMatrix = .identity; context.textPosition = CGPoint(x: 30, y: 700)
            let text = NSAttributedString(string: value, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
            CTLineDraw(CTLineCreateWithAttributedString(text), context); context.endPDFPage()
        }
        context.closePDF()
        guard PDFDocument(data: output as Data)?.pageCount == 2 else { throw DocumentAppCheckFailure(label: "Real two-page PDF") }
        return output as Data
    }
}

#if DOCUMENT_QUERY_APP_STANDALONE
@main
#endif
private enum DocumentQueryAppChecks {
    @MainActor static var assertions = 0
    @MainActor static var groups: [String: Int] = [:]
    static let question = "What is the jasmine document value?"
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        assertions += 1
        if try !value() { throw DocumentAppCheckFailure(label: label) }
    }
    @MainActor static func until(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw DocumentAppCheckFailure(label: "Bounded App state wait") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    @MainActor static func task(_ session: DocumentQuerySession) throws -> Task<Void, Never> {
        guard let task = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value as? Task<Void, Never> else {
            throw DocumentAppCheckFailure(label: "Observe actual App query task")
        }
        return task
    }
    @MainActor static func start(_ session: DocumentQuerySession, _ env: DocumentCheckEnvironment) throws -> Task<Void, Never> {
        session.start(modelAccess: env.access)
        try check(session.running, "Explicit start enters actual App task")
        return try task(session)
    }
    @MainActor static func prepare(_ env: DocumentCheckEnvironment) async throws -> DocumentQuerySession {
        let session = DocumentQuerySession(source: try await env.source())
        session.setQuestion(question)
        session.confirmDestination(modelAccess: env.access)
        try check(session.destination == "https://document-check.example.invalid\n模型：synthetic-document", "Destination comes from actual ChatSession settings")
        return session
    }
    @MainActor static func consentAndExport() async throws {
        let env = try DocumentCheckEnvironment(); defer { env.close() }
        let bytes = try env.savedBytes()
        let session = DocumentQuerySession(source: try await env.source())
        session.setQuestion(question)
        session.start(modelAccess: env.access)
        try check(!session.running && session.error != nil && session.result == nil && session.deliveryID == nil, "No destination confirmation blocks start")
        let before = await env.model.requests.count
        try check(before == 0 && session.audit.modelCalls == 0, "No request before confirmation")
        session.confirmDestination(modelAccess: env.access)
        let confirmed = await env.model.requests.count
        try check(confirmed == 0 && !session.running && session.result == nil, "Confirming destination does not start")
        let request = try start(session, env)
        session.start(modelAccess: env.access)
        await request.value
        guard let result = session.result, let citation = result.citations.first, let delivery = session.deliveryID else {
            throw DocumentAppCheckFailure(label: "Actual verified result and delivery")
        }
        let requests = await env.model.requests
        try check(requests.count == 3 && result.modelCalls == 3, "One explicit run; duplicate start creates no request")
        try check(session.audit.modelCalls == 3 && session.audit.searches == 1 && session.audit.reads == 1 && session.audit.results == 1 && session.audit.citations == 1 && session.audit.corrections == 0, "App event counters match search read finish")
        try check(session.audit.evidence == "DOCUMENT_QUERY_AUDIT modelCalls=3 searches=1 reads=1 results=1 citations=1 corrections=0", "Fixed audit evidence represents App events")
        try check(result.question == question && result.answer == "Synthetic answer 73" && session.error == nil && session.refusal == nil, "App publishes exact question and answer")
        try check(citation.pageIndex == 1 && citation.pageNumber == 2 && citation.quote == "JASMINE_DOCUMENT_VALUE_73", "Citation retains original page and selected index")
        try check(result.reads.contains { $0.id == citation.readID && $0.text.contains(citation.quote) }, "Citation uses actual returned read ID")
        let document = try SkillExecutionTextDocument(text: result.textForExport)
        let target = env.root.appendingPathComponent("answer.txt")
        try check(!FileManager.default.fileExists(atPath: target.path), "FileDocument construction does not save")
        try document.snapshot().write(to: target, options: .atomic, originalContentsURL: nil)
        let reopened = try SkillExecutionTextDocument(fileWrapper: FileWrapper(url: target))
        try check(try Data(contentsOf: target) == Data(result.textForExport.utf8), "Actual FileDocument writes exact verified export bytes")
        try check(reopened.text == result.textForExport && reopened.text.contains(question) && reopened.text.contains(result.source.inputSHA256) && reopened.text.contains(result.source.sha256) && reopened.text.contains("第 2 頁（選取序號 1）"), "Reopened export preserves question and provenance")
        let audit = session.audit.evidence
        env.chat.modelDraft = "changed-after-finish"; env.chat.saveSettings(); session.hostChanged()
        try check(session.destination == nil && session.result?.textForExport == reopened.text && session.deliveryID == delivery && session.audit.evidence == audit, "Host change retains delivered result and audit")
        session.start(modelAccess: env.access)
        let after = await env.model.requests.count
        try check(after == 3 && session.result != nil && !session.running, "Requery after host change needs new confirmation")
        try check(try env.savedBytes() == bytes, "Document query and export do not mutate learning persistence")
    }
    @MainActor static func changedAccessBeforeStart() async throws {
        let env = try DocumentCheckEnvironment(); defer { env.close() }
        let session = try await prepare(env)
        env.chat.modelDraft = "changed-before-start"; env.chat.saveSettings()
        session.start(modelAccess: env.access)
        let calls = await env.model.requests.count
        try check(calls == 0 && !session.running && session.destination == nil && session.error != nil, "Actual settings change invalidates confirmation before request")
        try check(session.question == question && session.result == nil, "Prestart rejection retains question")
        env.chat.removeSettings(); session.confirmDestination(modelAccess: env.access)
        try check(session.destination == nil && session.error != nil, "Missing actual credentials cannot confirm destination")
    }
    @MainActor static func lateSettingsAndKeyChanges() async throws {
        for mutation in ["model", "baseURL", "key", "removed", "publisher"] {
            let gate = DocumentCheckGate()
            let env = try DocumentCheckEnvironment(.init(finishGate: gate)); defer { env.close() }
            let session = try await prepare(env), source = session.source.sha256
            var subscription: AnyCancellable?
            if mutation == "publisher" {
                subscription = env.chat.$savedSettings.dropFirst().sink { _ in session.hostChanged() }
            }
            let request = try start(session, env)
            try await until { await env.model.waitingForFinish }
            switch mutation {
            case "model", "publisher": env.chat.modelDraft = "changed-late"; env.chat.saveSettings()
            case "baseURL": env.chat.baseURLDraft = "https://changed.example.invalid/v1"; env.chat.keyDraft = "synthetic-new-key"; env.chat.saveSettings()
            case "key": env.chat.keyDraft = "synthetic-replaced-key"; env.chat.saveSettings()
            default: env.chat.removeSettings()
            }
            if mutation == "publisher" {
                try check(!session.running && session.destination == nil, "Actual settings publisher revokes destination immediately")
            }
            await gate.release(); await request.value
            try await until { await env.model.finishedResponses == 1 }
            try check(session.result == nil && session.deliveryID == nil && !session.running && session.destination == nil, "Late changed access cannot publish and revokes destination: " + mutation)
            try check(session.audit.results == 0 && session.audit.citations == 0 && session.audit.modelCalls == 3, "Rejected late result is not counted: " + mutation)
            try check(session.question == question && session.source.sha256 == source, "Late rejection retains question and snapshot: " + mutation)
            let count = await env.model.requests.count
            try check(count == 3, "Changed access does not retry: " + mutation)
            withExtendedLifetime(subscription) {}
        }
    }
    @MainActor static func cancellationAndQuestionChanges() async throws {
        for changeQuestion in [false, true] {
            let gate = DocumentCheckGate()
            let env = try DocumentCheckEnvironment(.init(finishGate: gate)); defer { env.close() }
            let session = try await prepare(env), source = session.source.sha256
            let original = try start(session, env)
            try await until { await env.model.waitingForFinish }
            if changeQuestion { session.setQuestion("A replacement jasmine question") } else { session.cancel() }
            await original.value
            try check(!session.running && session.result == nil && session.deliveryID == nil, "Cancellation ends original App task before uncooperative response")
            if changeQuestion {
                try check(session.audit.modelCalls == 0 && session.audit.reads == 0 && session.audit.results == 0, "Changed question resets audit")
            }
            let newer = try start(session, env); await newer.value
            guard let delivery = session.deliveryID, let result = session.result else {
                throw DocumentAppCheckFailure(label: "Explicit replacement run completes")
            }
            await gate.release()
            try await until { await env.model.finishedResponses == 2 }
            await original.value
            try check(session.deliveryID == delivery && session.result?.question == result.question && session.audit.results == 1, "Late old finish cannot overwrite newer delivery")
            try check(session.source.sha256 == source && session.question == (changeQuestion ? "A replacement jasmine question" : question), "Cancellation and edit retain immutable PDF source")
        }
    }
    @MainActor static func failureRefusalAndExplicitRetry() async throws {
        for first in [DocumentCheckModel.First.transportFailure, .refuse] {
            let env = try DocumentCheckEnvironment(.init(first: first)); defer { env.close() }
            let session = try await prepare(env), source = session.source.sha256
            let firstTask = try start(session, env); await firstTask.value
            let count = await env.model.requests.count
            try check(count == 1 && !session.running && session.result == nil && session.deliveryID == nil, "Failure or refusal has no implicit retry or result")
            try check(session.question == question && session.source.sha256 == source && session.destination != nil, "Retry retains source question and unchanged destination")
            try check(session.audit.modelCalls == 1 && session.audit.results == 0 && session.audit.citations == 0, "Failed or refused attempt audit counts no result")
            if first == .refuse { try check(session.refusal != nil && session.error == nil, "Refusal remains distinct from model failure") }
            else { try check(session.error != nil && session.refusal == nil, "Model failure remains distinct from refusal") }
            let retry = try start(session, env); await retry.value
            let total = await env.model.requests.count
            try check(total == 4 && session.result?.question == question && session.error == nil && session.refusal == nil, "Only explicit retry starts a fresh query")
            try check(session.audit.modelCalls == 3 && session.audit.results == 1 && session.audit.corrections == 0, "Retry audit describes current run rather than lifetime calls")
        }
    }
    @MainActor static func correctionAuditAndQuestionReset() async throws {
        let env = try DocumentCheckEnvironment(.init(first: .malformed)); defer { env.close() }
        let session = try await prepare(env)
        let request = try start(session, env); await request.value
        let count = await env.model.requests.count
        try check(count == 4 && session.result?.modelCalls == 4 && session.audit.modelCalls == 4 && session.audit.corrections == 1, "App audit includes actual correction request")
        try check(session.audit.searches == 1 && session.audit.reads == 1 && session.audit.results == 1 && session.audit.citations == 1, "Correction does not inflate tool or result counters")
        let delivery = session.deliveryID
        session.setQuestion(question)
        try check(session.deliveryID == delivery && session.audit.results == 1, "Unchanged editor text preserves result")
        session.setQuestion("New question")
        try check(session.result == nil && session.deliveryID == nil && session.audit.evidence == "DOCUMENT_QUERY_AUDIT modelCalls=0 searches=0 reads=0 results=0 citations=0 corrections=0", "Edited question clears delivery and all audit counters")
    }
    #if DOCUMENT_QUERY_APP_STANDALONE
    @MainActor static func main() async {
        do {
            let cases: [(String, () async throws -> Void)] = [
                ("consentAndExport", consentAndExport), ("changedAccessBeforeStart", changedAccessBeforeStart),
                ("lateSettingsAndKeyChanges", lateSettingsAndKeyChanges),
                ("cancellationAndQuestionChanges", cancellationAndQuestionChanges),
                ("failureRefusalAndExplicitRetry", failureRefusalAndExplicitRetry),
                ("correctionAuditAndQuestionReset", correctionAuditAndQuestionReset)]
            for (name, body) in cases {
                let before = assertions
                try await body(); groups[name] = assertions - before
            }
            let data = try JSONSerialization.data(withJSONObject: ["passed": assertions, "failed": 0, "groups": groups,
                "actual_pdfkit": true, "actual_app_sources": true, "actual_file_document": true,
                "model_network_requests": 0, "native_ios_ui": false], options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        } catch {
            let label = (error as? DocumentAppCheckFailure)?.label ?? "Unexpected offline document check failure"
            let data = try? JSONSerialization.data(withJSONObject: ["failed": 1, "failure": label, "passed": assertions, "groups": groups], options: [.sortedKeys])
            if let data { print(String(decoding: data, as: UTF8.self)) }
            exit(1)
        }
    }
    #endif
}
#if !DOCUMENT_QUERY_APP_STANDALONE
final class DocumentQueryAppIntegrationTests: XCTestCase {
    @MainActor func testConsentActualPDFQueryAuditAndFileDocumentExport() async throws { try await DocumentQueryAppChecks.consentAndExport() }
    @MainActor func testActualModelSettingsChangeBeforeStart() async throws { try await DocumentQueryAppChecks.changedAccessBeforeStart() }
    @MainActor func testLateSettingsKeyRemovalAndPublisherChanges() async throws { try await DocumentQueryAppChecks.lateSettingsAndKeyChanges() }
    @MainActor func testCancellationQuestionChangeAndLateOldResult() async throws { try await DocumentQueryAppChecks.cancellationAndQuestionChanges() }
    @MainActor func testFailureRefusalAndExplicitRetryRetainSource() async throws { try await DocumentQueryAppChecks.failureRefusalAndExplicitRetry() }
    @MainActor func testCorrectionAuditAndQuestionReset() async throws { try await DocumentQueryAppChecks.correctionAuditAndQuestionReset() }
}
#endif
#endif
