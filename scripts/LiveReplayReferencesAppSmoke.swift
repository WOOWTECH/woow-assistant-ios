import AppKit
import AssistantBrowser
import AssistantMemory
import AssistantModels
import AssistantPersistence
import AssistantSkills
import CryptoKit
import Foundation
import WebKit

// Opt-in host harness. The production BrowserSession, route execution, capture,
// judge, URL policy and deadlines are compiled unchanged from a verified snapshot.
private enum ReplayLiveFailure: String, Error, Codable {
    case none, configuration, sources, deadline, inputBoundary, modelBudget
    case modelFailure, incomplete, preference, currentPriority, judgment, storage, unknown
}
private struct ReplayHTTPFailure: Codable {
    enum Kind: String, Codable {
        case invalidConfiguration, redirectRejected, httpStatus, invalidResponse
        case incompleteResponse, responseTooLarge, consumerTooSlow, timedOut, transportFailure
    }
    let kind: Kind
    let statusCode: Int
    init(_ error: HTTPChatModelError) {
        var status = 0
        switch error {
        case .invalidConfiguration: kind = .invalidConfiguration
        case .redirectRejected: kind = .redirectRejected
        case .httpStatus(let value): kind = .httpStatus; status = (100...599).contains(value) ? value : 0
        case .invalidResponse: kind = .invalidResponse
        case .incompleteResponse: kind = .incompleteResponse
        case .responseTooLarge: kind = .responseTooLarge
        case .consumerTooSlow: kind = .consumerTooSlow
        case .timedOut: kind = .timedOut
        case .transportFailure: kind = .transportFailure
        }
        statusCode = status
    }
}
private struct ReplayPageProof: Codable {
    let index: Int
    let url: String // Exact allowlisted public URL only.
    let textSHA256: String
    let quoteSHA256: String
    let textCharacters: Int
    let capturedAt: Double
}
private struct ReplayLiveCaseReport: Codable {
    let id: String
    var passed = false
    var failure: ReplayLiveFailure = .none
    var clientAttempts = 0
    var clientResponses = 0
    var modelErrors: [ReplayHTTPFailure] = []
    var answerInputVerified = false
    var judgeLedgerVerified = false
    var expectedPrefixMatched = false
    var startsWithSavedPrefix = false
    var startsWithCurrentPrefix = false
    var observedURLStringsMentioned = 0 // Literal presence, NOT citation correctness.
    var answerSHA256: String?
    var routeSuccessDelta = 0
    var encryptedReadbackVerified = false
    var referencesUnchanged = false
    var observations: [ReplayPageProof] = []
    var milliseconds = 0
    var diagnostic: ReplayDiagnostic?
}
// Only closed categories, booleans and counts leave the in-memory callback.
private struct ReplayDiagnostic: Codable {
    var learningStatus = "absent"
    var storeAvailable = false
    var storeErrorPresent = false
    var browserErrorPresent = false
    var referenceValid = false
    var goalUnchanged = false
    var routeIdentityUnchanged = false
    var observationsNewerThanRoute = false
    var goalSHA256 = ""
    var wireOutcome = "undecodable"
    var wireEvidenceCount = 0
    var quotesAbsentFromObservation = 0
    var quotesContainingURLAlias = 0
    var productionOutcome = "unavailable"
    var productionSkipReason = "unavailable"
    var productionCitationCount = 0
    var parserReplayMatched = false
}
/// Replays the retained reply through the REAL production assessment/parser,
/// without HTTP or persistence. Its only normalization is the newly generated
/// random URL-alias nonce; all other request bytes must match the actual call.
private actor ReplayJudgeProbe: ChatModelClient {
    let messages: [ModelMessage]
    let reply: String
    private(set) var matched = false
    init(messages: [ModelMessage], reply: String) { self.messages = messages; self.reply = reply }
    static func nonce(_ messages: [ModelMessage]) throws -> String {
        let text = messages.map(\.content).joined()
        let regex = try NSRegularExpression(pattern: "⟦WOOW_URL_([A-F0-9]{32})_[0-9]+⟧")
        let values = Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        })
        guard values.count == 1, let value = values.first else { throw ReplayLiveFailure.inputBoundary }
        return value
    }
    func complete(messages new: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        guard !matched else { throw ReplayLiveFailure.inputBoundary }
        let oldNonce = try Self.nonce(messages), newNonce = try Self.nonce(new)
        let normalized = messages.map { ModelMessage(role: $0.role, content: $0.content.replacingOccurrences(of: oldNonce, with: newNonce)) }
        guard normalized == new else { throw ReplayLiveFailure.inputBoundary }
        matched = true
        return reply.replacingOccurrences(of: oldNonce, with: newNonce)
    }
}
private actor ReplayJudgeFixture: ChatModelClient {
    let reply: String
    private(set) var messages: [ModelMessage] = []
    init(reply: String) { self.reply = reply }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        self.messages = messages; return reply
    }
}
private struct ReplayLiveReport: Codable {
    var passed = false
    var failure: ReplayLiveFailure = .none
    var preparation: [ReplayPageProof] = []
    var cases: [ReplayLiveCaseReport] = []
    var clientAttempts = 0
    var clientResponses = 0
    var milliseconds = 0
}
private func replayDigest(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
}
private func replayMilliseconds(_ start: ContinuousClock.Instant) -> Int {
    let value = start.duration(to: .now).components
    return Int(value.seconds * 1000 + value.attoseconds / 1_000_000_000_000_000)
}
private actor ReplayLiveBudget {
    private(set) var attempts = 0
    private(set) var responses = 0
    let journal: URL
    let maximum: Int
    init(journal: URL, priorAttempts: Int = 0) { self.journal = journal; maximum = max(0, 8 - priorAttempts) }
    func claim() throws {
        try Task.checkCancellation()
        guard attempts < maximum else { throw ReplayLiveFailure.modelBudget }
        attempts += 1
        try save() // Persist the count BEFORE the actual client is invoked.
    }
    func responded() throws { responses += 1; try save() }
    private func save() throws {
        let data = try JSONSerialization.data(withJSONObject: ["attempts": attempts, "responses": responses])
        try data.write(to: journal, options: .atomic)
    }
}
private actor ReplayLiveModel: ChatModelClient {
    let reference: RunReferenceContext
    let goal: String
    let budget: ReplayLiveBudget
    private let client = HTTPChatModelClient()
    private(set) var attempts = 0
    private(set) var responses = 0
    private(set) var errors: [ReplayHTTPFailure] = []
    private(set) var answerVerified = false
    private(set) var judgeVerified = false
    private(set) var boundaryFailed = false
    private var judgeMessages: [ModelMessage] = []
    private var judgeReply: String?
    init(reference: RunReferenceContext, goal: String, budget: ReplayLiveBudget) {
        self.reference = reference; self.goal = goal; self.budget = budget
    }
    static func answerBoundary(_ messages: [ModelMessage], reference: RunReferenceContext, goal: String) throws -> Bool {
        guard messages.count == 4, messages[1] == reference.message, messages[1].role == "user",
              messages[2].role == "user", messages[2].content == goal,
              messages.filter({ $0.role == "system" }).count == 1,
              messages.reduce(0, { $0 + $1.content.count }) <= MultiSourceResearchRunner.maximumContextCharacters,
              try JSONEncoder().encode(messages).count <= MultiSourceResearchRunner.maximumContextUTF8Bytes,
              let observations = try? JSONDecoder().decode([WebObservation].self, from: Data(messages[3].content.utf8)),
              observations.count == 2 else { return false }
        return zip(observations, LiveReplayReferencesAppSmoke.roots).allSatisfy {
            $0.url.absoluteString == $1 && !$0.text.contains(LiveReplayReferencesAppSmoke.marker)
        }
    }
    static func judgeBoundary(_ messages: [ModelMessage]) -> Bool {
        guard messages.count == 2, messages[0].role == "system", messages[0].content.hasPrefix("Assess whether"),
              messages[1].role == "user",
              let object = try? JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any],
              let rows = object["observations"] as? [[String: Any]], rows.count == 2 else { return false }
        return rows.enumerated().allSatisfy { index, row in
            guard row["id"] as? String == "action-\(index)", let text = row["result"] as? String,
                  let source = row["sourceURLIdentity"] as? String, !source.isEmpty else { return false }
            return !text.contains(LiveReplayReferencesAppSmoke.marker)
                && !text.contains(LiveReplayReferencesAppSmoke.savedPrefix)
        }
    }
    func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
        if attempts == 0 { answerVerified = try Self.answerBoundary(messages, reference: reference, goal: goal) }
        else if attempts == 1 { judgeVerified = Self.judgeBoundary(messages) }
        else { boundaryFailed = true; throw ReplayLiveFailure.inputBoundary }
        guard attempts == 0 ? answerVerified : judgeVerified else {
            boundaryFailed = true; throw ReplayLiveFailure.inputBoundary
        }
        try Task.checkCancellation()
        try await budget.claim(); attempts += 1
        do {
            let answer = try await client.complete(messages: messages, configuration: configuration, apiKey: apiKey)
            responses += 1; try await budget.responded()
            if attempts == 2 { judgeMessages = messages; judgeReply = answer }
            return answer // No raw request/reply/error is printed or written.
        } catch {
            if let known = error as? HTTPChatModelError { errors.append(.init(known)) }
            throw error
        }
    }
    func takeJudgeProbe() -> ReplayJudgeProbe? {
        guard let reply = judgeReply else { return nil }
        defer { judgeReply = nil; judgeMessages = [] }
        return ReplayJudgeProbe(messages: judgeMessages, reply: reply)
    }
}
private final class ReplayLiveKeys: LearningKeyStore {
    private var values: [String: Data] = [:]
    func read(id: String) throws -> Data? { values[id] }
    func insert(_ key: Data, id: String) throws { values[id] = key }
    func remove(id: String) throws { values.removeValue(forKey: id) }
    func removeAll(except id: String) throws { values = values.filter { $0.key == id } }
}

@main private enum LiveReplayReferencesAppSmoke {
    static let roots = ["https://www.iana.org/domains/reserved", "https://www.iana.org/help/example-domains"]
    static let savedPrefix = "PREFERENCE_APPLIED:"
    static let currentPrefix = "CURRENT_REQUEST:"
    static let marker = "SYNTHETIC_REPLAY_NOTE_58B1"

    @MainActor private final class Host {
        let browser = BrowserSession(dataStore: .nonPersistent())
        let window: NSWindow
        init() {
            let web = browser.webView; web.frame = CGRect(x: 0, y: 0, width: 900, height: 700)
            window = NSWindow(contentRect: web.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = web; window.orderFront(nil)
            browser.canPresentUI = { false }
        }
        func load(_ address: String) async throws -> WebObservation {
            guard roots.contains(address) else { throw ReplayLiveFailure.sources }
            browser.address = address; browser.openAddress()
            let end = ContinuousClock.now.advanced(by: .seconds(75))
            while ContinuousClock.now < end {
                try Task.checkCancellation()
                if let page = browser.current, page.url.absoluteString == address, !browser.webView.isLoading {
                    guard page.text.contains("example.com"), !page.text.contains(marker) else { throw ReplayLiveFailure.sources }
                    return page
                }
                if browser.error != nil { throw ReplayLiveFailure.sources }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw ReplayLiveFailure.sources
        }
        func close() { browser.cancel(); browser.webView.stopLoading(); window.close(); window.contentView = nil }
    }
    @MainActor private final class Store {
        let root: URL, url: URL, learning: LearningStore
        let keys = ReplayLiveKeys()
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("woow-live-replay-vault-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            url = root.appendingPathComponent("learning.vault")
            learning = LearningStore(vault: .init(url: url, keys: keys))
            guard learning.available,
                  learning.mutateProfile({ _ = try $0.add(text: "For example-domain answers, begin the response with exactly PREFERENCE_APPLIED: and then use Traditional Chinese.") }),
                  learning.mutateMemory({ _ = try $0.add(kind: .preference, content: "\(marker): saved personal notes are not evidence from public pages.") }) else { throw ReplayLiveFailure.storage }
        }
        func record(pages: [WebObservation], goal: String) throws -> WebRoute {
            let steps = try pages.map { page -> WebRouteStep in
                guard let range = page.text.range(of: "example.com") else { throw ReplayLiveFailure.sources }
                return try .init(kind: .navigate, snapshot: .init(url: page.url, title: page.title, visibleText: page.text, capturedAt: page.capturedAt), evidenceQuote: String(page.text[range]))
            }
            // Harness explicitly confirms its actual observed read-only route.
            let proof = try WebTaskEvidence(outcome: .succeeded, confirmed: true, summary: "Harness observed both approved public pages.")
            guard learning.mutateWeb({ _, routes in _ = try routes.record(intent: goal, steps: steps, task: proof) }),
                  let route = learning.routes.routes.first(where: { $0.originalGoal == goal }) else { throw ReplayLiveFailure.storage }
            return route
        }
        func close() { try? FileManager.default.removeItem(at: root) }
    }
    static func proof(_ page: WebObservation, index: Int) throws -> ReplayPageProof {
        guard roots.indices.contains(index), page.url.absoluteString == roots[index],
              let range = page.text.range(of: "example.com") else { throw ReplayLiveFailure.sources }
        return .init(index: index, url: page.url.absoluteString, textSHA256: replayDigest(page.text),
                     quoteSHA256: replayDigest(String(page.text[range])), textCharacters: page.text.count,
                     capturedAt: page.capturedAt.timeIntervalSince1970)
    }
    static func prefix(_ answer: String, expected: String) -> Bool {
        answer.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(expected)
    }
    private struct WireJudge: Decodable {
        struct Citation: Decodable { let actionID: String; let quote: String }
        let outcome: String
        let evidence: [Citation]?
    }
    static func wireFacts(_ probe: ReplayJudgeProbe, into value: inout ReplayDiagnostic) {
        var raw = probe.reply.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.hasPrefix("```"), raw.hasSuffix("```"), let newline = raw.firstIndex(of: "\n") {
            raw = String(raw[raw.index(after: newline)...].dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let wire = try? JSONDecoder().decode(WireJudge.self, from: Data(raw.utf8)) else { return }
        let outcome = wire.outcome.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        value.wireOutcome = ["done", "partial", "not_possible", "unknown"].contains(outcome) ? outcome : "unrecognized"
        value.wireEvidenceCount = min(wire.evidence?.count ?? 0, 1024)
        let object = try? JSONSerialization.jsonObject(with: Data(probe.messages[1].content.utf8)) as? [String: Any]
        let observations = object?["observations"] as? [[String: Any]] ?? []
        for citation in (wire.evidence ?? []).prefix(1024) {
            let quote = citation.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            let observation = observations.first { $0["id"] as? String == citation.actionID }
            if !(observation?["result"] as? String ?? "").contains(quote) { value.quotesAbsentFromObservation += 1 }
            if quote.contains("⟦WOOW_URL_") { value.quotesContainingURLAlias += 1 }
        }
    }
    @MainActor private static func diagnose(client: ReplayLiveModel, browser: BrowserSession, store: Store,
                                            route: WebRoute, reference: LearningRunSnapshot, goal: String,
                                            configuration: ModelConfiguration, key: String) async -> ReplayDiagnostic {
        var result = ReplayDiagnostic()
        switch browser.learningStatus {
        case "路線核對與成果判定完成；未重複產生技能。": result.learningStatus = "saved"
        case "成果已交付；路線結果未儲存。": result.learningStatus = "writeFailed"
        case "頁面已核對，但原任務尚未確認完成；未增加成功次數。": result.learningStatus = "notConfirmed"
        case nil: result.learningStatus = "absent"
        default: result.learningStatus = "other"
        }
        result.storeAvailable = store.learning.available; result.storeErrorPresent = store.learning.error != nil
        result.browserErrorPresent = browser.error != nil
        do { try reference.check(); result.referenceValid = true } catch { result.referenceValid = false }
        result.goalSHA256 = replayDigest(goal)
        let current = store.learning.routes.routes.first { $0.id == route.id }
        result.goalUnchanged = browser.goal == goal && route.originalGoal == goal && current?.originalGoal == goal
        result.routeIdentityUnchanged = current?.id == route.id && current?.origin == route.origin && current?.steps == route.steps
        result.observationsNewerThanRoute = browser.actions.count == 2 && browser.actions.allSatisfy { $0.observation.capturedAt > route.lastUsedAt }
        guard let answer = browser.answer, let probe = await client.takeJudgeProbe() else { return result }
        wireFacts(probe, into: &result)
        let actions = browser.actions.enumerated().map { index, action in
            SkillExecutedAction(id: "action-\(index)", toolName: action.tool,
                kind: action.tool == "browser_open_link" ? .navigation : .observation,
                arguments: ["url": action.observation.url.absoluteString, "input": action.argument],
                result: action.observation.text, succeeded: true, observedURL: action.observation.url)
        }
        do {
            let assessment = try await SkillLearningService(client: probe).assess(goal: goal, answer: answer,
                actions: actions, context: .init(replayMatched: true), state: store.learning.skills,
                availableToolNames: ["browser_open_link"], allowDraft: false, configuration: configuration, apiKey: key)
            result.parserReplayMatched = await probe.matched
            if result.parserReplayMatched {
                result.productionOutcome = assessment.judgment.outcome.rawValue
                result.productionSkipReason = assessment.skipReason?.rawValue ?? "none"
                result.productionCitationCount = assessment.judgment.citations.count
            }
        } catch { result.productionSkipReason = "replayFailed" }
        return result
    }
    @MainActor static func live(diagnosticOnly: Bool = false) async -> ReplayLiveReport {
        let start = ContinuousClock.now
        var report = ReplayLiveReport()
        let environment = ProcessInfo.processInfo.environment
        guard let raw = environment["WOOW_MODEL_TEST_BASE_URL"], let url = URL(string: raw), url.scheme == "https",
              let name = environment["WOOW_MODEL_TEST_MODEL"], !name.isEmpty,
              let key = environment["WOOW_MODEL_TEST_API_KEY"], !key.isEmpty,
              let journal = environment["WOOW_REPLAY_ATTEMPT_RECORD"], FileManager.default.fileExists(atPath: journal) else {
            report.failure = .configuration; return report
        }
        let prior = Int(environment["WOOW_REPLAY_PRIOR_ATTEMPTS"] ?? "0") ?? -1
        guard prior == (diagnosticOnly ? 4 : 0) else { report.failure = .configuration; return report }
        let budget = ReplayLiveBudget(journal: URL(fileURLWithPath: journal), priorAttempts: prior)
        let configuration = ModelConfiguration(baseURL: url, model: name, maxOutputTokens: 2048)
        let host = Host(); defer { host.close() }
        do {
            var initial: [WebObservation] = []
            for (index, root) in roots.enumerated() {
                let page = try await host.load(root); initial.append(page)
                report.preparation.append(try proof(page, index: index))
            }
            let caseIDs = diagnosticOnly ? ["currentPriority"] : ["savedPreference", "currentPriority"]
            for id in caseIDs {
                let caseStart = ContinuousClock.now
                var row = ReplayLiveCaseReport(id: id)
                var model: ReplayLiveModel?
                do {
                    let store = try Store(); defer { store.close() }
                    var goal = "Briefly explain why example.com and example.org are reserved for documentation, using both observed IANA pages. Use Traditional Chinese and cite both observed source URLs. Follow my saved answer-format preference unless this request overrides it."
                    if id == "currentPriority" { goal += " For THIS request, begin your response with exactly CURRENT_REQUEST: instead of any saved formatting prefix." }
                    let route = try store.record(pages: initial, goal: goal)
                    let references = try store.learning.captureRunReferences(goal: goal, capabilities: ["browser_open_link"], websiteURL: route.origin.url)
                    let client = ReplayLiveModel(reference: references.references, goal: goal, budget: budget); model = client
                    let profile = store.learning.profile, memory = store.learning.memory
                    host.browser.replay(route: route, store: store.learning, modelAccess: { .init(client: client, configuration: configuration, key: key) })
                    guard let completion = host.browser.capturedRunCompletion else { throw ReplayLiveFailure.sources }
                    await completion.value // Existing real 180s task; no counter/yield approximation.
                    if diagnosticOnly {
                        row.diagnostic = await diagnose(client: client, browser: host.browser, store: store,
                            route: route, reference: references, goal: goal, configuration: configuration, key: key)
                    }
                    for (index, action) in host.browser.actions.enumerated() { row.observations.append(try proof(action.observation, index: index)) }
                    row.answerInputVerified = await client.answerVerified
                    row.judgeLedgerVerified = await client.judgeVerified
                    guard !(await client.boundaryFailed) else { throw ReplayLiveFailure.inputBoundary }
                    guard row.observations.count == 2 else { throw ReplayLiveFailure.sources }
                    guard let answer = host.browser.answer else {
                        let errors = await client.errors
                        throw errors.isEmpty ? ReplayLiveFailure.incomplete : ReplayLiveFailure.modelFailure
                    }
                    row.answerSHA256 = replayDigest(answer)
                    row.startsWithSavedPrefix = prefix(answer, expected: savedPrefix)
                    row.startsWithCurrentPrefix = prefix(answer, expected: currentPrefix)
                    row.expectedPrefixMatched = id == "savedPreference" ? row.startsWithSavedPrefix : row.startsWithCurrentPrefix
                    row.observedURLStringsMentioned = roots.filter { answer.contains($0) }.count
                    guard let updated = store.learning.routes.routes.first(where: { $0.id == route.id }) else { throw ReplayLiveFailure.storage }
                    row.routeSuccessDelta = updated.successes - route.successes
                    row.referencesUnchanged = store.learning.profile == profile && store.learning.memory == memory
                    let disk = LearningStore(vault: .init(url: store.url, keys: store.keys))
                    row.encryptedReadbackVerified = disk.available && disk.routes == store.learning.routes && disk.profile == profile && disk.memory == memory
                    // Preserve actual independent judgment/storage measurements
                    // even if the answer fails this smoke's prefix expectation.
                    guard row.expectedPrefixMatched else { throw id == "savedPreference" ? ReplayLiveFailure.preference : ReplayLiveFailure.currentPriority }
                    guard row.observedURLStringsMentioned == 2 else { throw ReplayLiveFailure.incomplete }
                    guard row.routeSuccessDelta == 1, row.judgeLedgerVerified else { throw ReplayLiveFailure.judgment }
                    guard row.answerInputVerified, row.referencesUnchanged, row.encryptedReadbackVerified else { throw ReplayLiveFailure.storage }
                    row.passed = true
                } catch { row.failure = (error as? ReplayLiveFailure) ?? (error is CancellationError ? .deadline : .unknown) }
                if let model {
                    row.clientAttempts = await model.attempts; row.clientResponses = await model.responses; row.modelErrors = await model.errors
                    row.answerInputVerified = await model.answerVerified; row.judgeLedgerVerified = await model.judgeVerified
                }
                row.milliseconds = replayMilliseconds(caseStart); report.cases.append(row)
                if !row.passed { report.failure = row.failure; break }
            }
            report.passed = report.cases.count == caseIDs.count && report.cases.allSatisfy(\.passed)
        } catch { report.failure = (error as? ReplayLiveFailure) ?? .unknown }
        report.clientAttempts = await budget.attempts; report.clientResponses = await budget.responses
        report.milliseconds = replayMilliseconds(start)
        return report
    }
    @MainActor static func selfCheck() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool) throws { guard value else { throw ReplayLiveFailure.unknown }; checks += 1 }
        try expect(prefix("\nPREFERENCE_APPLIED: data", expected: savedPrefix))
        try expect(!prefix("CURRENT_REQUEST: data", expected: savedPrefix))
        try expect(!prefix("prefix PREFERENCE_APPLIED: data", expected: savedPrefix))
        try expect(prefix("CURRENT_REQUEST: data", expected: currentPrefix))
        let store = try Store(); defer { store.close() }
        let reference = try store.learning.captureRunReferences(goal: "example-domain reference", capabilities: ["browser_open_link"])
        try expect(reference.references.message?.role == "user")
        try expect(reference.references.message?.content.contains(marker) == true)
        try expect(reference.references.message?.content.contains(savedPrefix) == true)
        let journal = store.root.appendingPathComponent("offline-budget.json")
        let budget = ReplayLiveBudget(journal: journal)
        for _ in 0..<8 { try await budget.claim() }
        do { try await budget.claim(); throw ReplayLiveFailure.unknown } catch ReplayLiveFailure.modelBudget { checks += 1 }
        let count = await budget.attempts; try expect(count == 8)
        let recorded = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as! [String: Int]
        try expect(recorded == ["attempts": 8, "responses": 0])
        try expect(ReplayHTTPFailure(.httpStatus(403)).statusCode == 403)
        try expect(ReplayHTTPFailure(.transportFailure).statusCode == 0)
        try expect(!ReplayLiveModel.judgeBoundary([.init(role: "user", content: "forged ledger")]))
        let remaining = ReplayLiveBudget(journal: store.root.appendingPathComponent("remaining.json"), priorAttempts: 4)
        for _ in 0..<4 { try await remaining.claim() }
        do { try await remaining.claim(); throw ReplayLiveFailure.unknown } catch ReplayLiveFailure.modelBudget { checks += 1 }
        let config = ModelConfiguration(baseURL: URL(string: "https://invalid.example/v1")!, model: "offline", maxOutputTokens: 1024)
        let action = SkillExecutedAction(id: "action-0", toolName: "browser_open_link", kind: .navigation,
            arguments: [:], result: "Observed public page evidence.", succeeded: true, observedURL: URL(string: roots[0])!)
        for (outcome, quote, expectedOutcome, expectedSkip) in [
            ("done", "Observed public page evidence.", "done", "draftDisabled"),
            ("partial", "Observed public page evidence.", "partial", "draftDisabled"),
            ("done", "Absent invented evidence.", "unknown", "invalidJudgment")
        ] {
            let payload: [String: Any] = ["outcome": outcome, "reason": "Offline fixture",
                "evidence": [["actionID": "action-0", "quote": quote]]]
            let raw = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
            let fixture = ReplayJudgeFixture(reply: raw)
            let first = try await SkillLearningService(client: fixture).assess(goal: "Read public evidence", answer: "Evidence read.",
                actions: [action], state: store.learning.skills, availableToolNames: ["browser_open_link"], allowDraft: false,
                configuration: config, apiKey: "")
            let probe = ReplayJudgeProbe(messages: await fixture.messages, reply: raw)
            let again = try await SkillLearningService(client: probe).assess(goal: "Read public evidence", answer: "Evidence read.",
                actions: [action], state: store.learning.skills, availableToolNames: ["browser_open_link"], allowDraft: false,
                configuration: config, apiKey: "")
            let matched = await probe.matched
            try expect(matched)
            try expect(first.judgment.outcome.rawValue == expectedOutcome && again.judgment == first.judgment)
            try expect(again.skipReason?.rawValue == expectedSkip)
        }
        return checks
    }
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            if CommandLine.arguments.dropFirst() == ["--self-check"] {
                do {
                    let count = try await selfCheck()
                    print("{\"passed\":true,\"checks\":\(count),\"actualHTTPAttempts\":0}"); fflush(stdout); exit(0)
                } catch { print("{\"passed\":false,\"checks\":0,\"actualHTTPAttempts\":0}"); fflush(stdout); exit(1) }
            }
            let diagnosticOnly = CommandLine.arguments.dropFirst() == ["--diagnostic-current-priority"]
            guard diagnosticOnly || CommandLine.arguments.dropFirst() == ["--live"] else { exit(2) }
            let result = await live(diagnosticOnly: diagnosticOnly)
            if let data = try? JSONEncoder().encode(result) { print(String(decoding: data, as: UTF8.self)); fflush(stdout) }
            exit(result.passed ? 0 : 1)
        }
        app.run()
    }
}
