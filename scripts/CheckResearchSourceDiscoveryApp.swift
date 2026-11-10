#if RESEARCH_DISCOVERY_APP_STANDALONE || canImport(WoowAssistant)
@testable import AssistantBrowser
import Foundation
import WebKit
#if !RESEARCH_DISCOVERY_APP_STANDALONE
import XCTest
@testable import WoowAssistant
#endif

// App-state checks only. The production Session is unchanged. Synthetic DOM
// data enters the real internal acceptance function, never a public candidate
// initializer. The real WKWebView properties are never loaded or navigated.
private struct DiscoveryAppFailure: Error { let label: String }
private enum DiscoveryOpaqueFailure: Error { case synthetic }

private actor DiscoveryAppGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { continuation in
            if opened { continuation.resume() } else { waiters.append(continuation) }
        }
    }
    func release() {
        opened = true
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}

@MainActor private final class DiscoveryAppBrowser: ResearchSourceDiscovering {
    let webView: WKWebView
    private let gate: DiscoveryAppGate?
    private let failure: Error?
    private(set) var queries: [String] = []
    private(set) var cancellations = 0
    private(set) var produced: ResearchSourceDiscoveryResult?
    init(gate: DiscoveryAppGate? = nil, failure: Error? = nil) {
        self.gate = gate; self.failure = failure
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
    }
    func search(query: String) async throws -> ResearchSourceDiscoveryResult {
        queries.append(query)
        // Intentionally ignore cancellation while waiting, to exercise the
        // actual Session's operation ID and original Task completion fences.
        if let gate { await gate.wait() }
        if let failure { throw failure }
        let result = try Self.acceptedFixture(query: query)
        produced = result
        return result
    }
    func cancel() { cancellations += 1 }
    private static func acceptedFixture(query: String) throws -> ResearchSourceDiscoveryResult {
        let provider = ResearchSourceDiscoveryProvider.duckDuckGoHTML
        let expected = try provider.searchURL(query: query)
        let addresses = ["https://www.apple.com/first", "https://www.apple.com/second",
                         "https://www.mozilla.org/third", "https://www.w3.org/fourth", "https://www.swift.org/fifth"]
        let data = try JSONSerialization.data(withJSONObject: [
            "url": expected.absoluteString, "title": "Synthetic discovery DOM", "htmlBytes": 900,
            "oversized": false, "challenge": false, "resultsPresent": true, "truncated": false,
            "links": addresses.enumerated().map { ["index": $0.offset, "title": "Candidate \($0.offset)", "href": $0.element] as [String: Any] }
        ], options: [.sortedKeys])
        return try ResearchSourceDiscoveryDOM.accept(data, provider: provider, query: query, expected: expected)
    }
}

@MainActor private final class DiscoveryAppFactory {
    private let queued: [DiscoveryAppBrowser]
    private(set) var created: [DiscoveryAppBrowser] = []
    init(_ queued: [DiscoveryAppBrowser]) { self.queued = queued }
    func make() -> any ResearchSourceDiscovering {
        // Record unexpected factory calls too; returning an offline client
        // cannot hide a failed count assertion or accidentally access a service.
        let next = created.count < queued.count ? queued[created.count] : DiscoveryAppBrowser(failure: DiscoveryOpaqueFailure.synthetic)
        created.append(next)
        return next
    }
}

#if RESEARCH_DISCOVERY_APP_STANDALONE
@main
#endif
private enum ResearchSourceDiscoveryAppChecks {
    @MainActor static var assertions = 0
    @MainActor static var groups: [String: Int] = [:]
    static let query = "Synthetic public-source research"
    @MainActor static func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
        assertions += 1
        if try !value() { throw DiscoveryAppFailure(label: label) }
    }
    @MainActor static func task(_ session: ResearchSourceDiscoverySession) throws -> Task<Void, Never> {
        guard let task = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value as? Task<Void, Never> else {
            throw DiscoveryAppFailure(label: "Observe actual discovery App task")
        }
        return task
    }
    @MainActor static func start(_ session: ResearchSourceDiscoverySession) throws -> Task<Void, Never> {
        session.search()
        try check(session.running, "Explicit valid search starts the actual App task")
        return try task(session)
    }
    @MainActor static func until(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw DiscoveryAppFailure(label: "Discovery App did not reach bounded state") }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
    @MainActor static func candidates(_ session: ResearchSourceDiscoverySession) throws -> [ResearchSourceDiscoveryCandidate] {
        guard let result = session.result, result.candidates.count == 5 else {
            throw DiscoveryAppFailure(label: "Actual accepted fixture result required")
        }
        return result.candidates
    }
    @MainActor static func unloaded(_ browsers: [DiscoveryAppBrowser]) throws {
        for browser in browsers {
            try check(browser.webView.url == nil && !browser.webView.isLoading, "App state actions never navigate the real fixture WebView")
            try check(!browser.webView.configuration.websiteDataStore.isPersistent, "Fixture WebView uses an isolated nonpersistent store")
        }
    }

    @MainActor static func explicitSearchAndInvalidQueries() async throws {
        let browser = DiscoveryAppBrowser(), factory = DiscoveryAppFactory([])
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
        try check(factory.created.isEmpty && session.browser == nil && !session.running, "Constructing a Session is not search consent")
        session.setQuery("Another pending query")
        session.toggle(UUID())
        try check(factory.created.isEmpty && session.result == nil && session.selectedSources() == nil, "Editing or invalid selection does not create a browser or search")
        for invalid in ["", " \t ", String(repeating: "界", count: 86), "query\u{0000}"] {
            session.setQuery(invalid); session.search()
            try check(factory.created.isEmpty && !session.running && session.browser == nil, "Invalid query is rejected before creating an adapter")
            try check(session.error != nil && session.query == invalid && !session.canApply, "Invalid query retains editable input without candidate authority")
        }
        let validFactory = DiscoveryAppFactory([browser])
        let valid = ResearchSourceDiscoverySession(query: query, makeBrowser: validFactory.make)
        let request = try start(valid); await request.value
        try check(validFactory.created.count == 1 && browser.queries == [query], "Only explicit search forwards exact query once")
        try check(valid.result?.query == query && !valid.running && valid.browser == nil && browser.cancellations == 1, "Completion drops and cancels its browser while retaining candidates")
        try check(valid.result?.grantsResearchAuthorization == false && valid.selectedIDs.isEmpty && !valid.canApply, "Completed search is neither selection nor research approval")
        try unloaded([browser])
    }

    @MainActor static func orderedOriginSelectionAndApply() async throws {
        let browser = DiscoveryAppBrowser()
        let actualFactory = DiscoveryAppFactory([browser])
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: actualFactory.make)
        let request = try start(session); await request.value
        let rows = try candidates(session)
        try check(!session.canApply && session.selectedSources() == nil, "Zero selected sources cannot apply")
        session.toggle(rows[0].id)
        try check(session.selectedIDs == [rows[0].id] && !session.canApply && session.selectedSources() == nil, "One source remains below App apply minimum")
        session.toggle(rows[1].id)
        try check(session.selectedIDs == [rows[0].id] && session.error != nil, "Same-origin candidate cannot silently alter selection")
        session.toggle(rows[2].id)
        try check(session.error == nil && session.canApply && session.selectedSources()?.map(\.id) == [rows[0].id, rows[2].id], "Two distinct origins apply in explicit selection order")
        session.toggle(rows[3].id)
        let selected = [rows[0].id, rows[2].id, rows[3].id]
        try check(session.selectedIDs == selected && session.canApply, "Three different origins are allowed")
        session.toggle(rows[4].id)
        try check(session.selectedIDs == selected && session.error != nil, "A fourth origin does not alter the accepted three")
        session.toggle(UUID())
        try check(session.selectedIDs == selected, "Unknown candidate IDs cannot enter App selection")
        let first = session.selectedSources(), second = session.selectedSources()
        try check(first == second && first?.map(\.url) == [rows[0].url, rows[2].url, rows[3].url], "Apply returns the exact immutable candidates, not rewritten addresses")
        try check(actualFactory.created.count == 1 && browser.queries == [query] && browser.cancellations == 1, "Applying candidates starts no new search or adapter operation")
        try unloaded([browser])
        session.toggle(rows[0].id)
        try check(session.selectedIDs == [rows[2].id, rows[3].id] && session.canApply && session.error == nil, "Deselect preserves remaining order and clears selection error")
        session.toggle(rows[2].id)
        try check(!session.canApply && session.selectedSources() == nil, "Dropping below two disables apply again")
    }

    @MainActor static func lateSuccessCannotOverwriteRestart() async throws {
        let gate = DiscoveryAppGate()
        let old = DiscoveryAppBrowser(gate: gate), fresh = DiscoveryAppBrowser()
        let factory = DiscoveryAppFactory([old, fresh])
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
        let original = try start(session)
        try await until { old.queries.count == 1 }
        session.cancel()
        try check(!session.running && session.browser == nil && session.query == query && session.result == nil, "Cancel retains query and removes pending adapter")
        try check(old.cancellations == 1 && session.status == "搜尋已取消，搜尋詞仍保留。", "Cancellation reaches the actual owned adapter")
        let replacement = try start(session); await replacement.value
        let rows = try candidates(session)
        session.toggle(rows[0].id); session.toggle(rows[2].id)
        let resultID = session.result?.id, selected = session.selectedIDs, status = session.status
        await gate.release(); await original.value
        try check(old.produced != nil && old.produced?.id != resultID, "Old cancellation-insensitive browser really returned a different result")
        try check(session.result?.id == resultID && session.selectedIDs == selected && session.status == status && session.error == nil, "Late old success cannot overwrite replacement result or selection")
        try check(factory.created.count == 2 && old.queries == [query] && fresh.queries == [query] && fresh.cancellations == 1, "Restart uses exactly one fresh adapter")
        try unloaded([old, fresh])
    }

    @MainActor static func completedResultCancellation() async throws {
        for notice in [false, true] {
            let browser = DiscoveryAppBrowser()
            let actualFactory = DiscoveryAppFactory([browser])
            let session = ResearchSourceDiscoverySession(query: query, makeBrowser: actualFactory.make)
            let request = try start(session); await request.value
            let rows = try candidates(session)
            session.toggle(rows[0].id); session.toggle(rows[2].id)
            let captured = session.selectedSources()
            try check(session.canApply && captured?.map(\.id) == [rows[0].id, rows[2].id], "Cancellation regression starts with a genuinely applicable completed result")
            session.cancel(notice: notice)
            try check(session.result == nil && session.selectedIDs.isEmpty && !session.canApply && session.selectedSources() == nil, "Leaving or backgrounding revokes completed-result apply capability")
            try check(session.query == query && !session.running && session.browser == nil, "Completed cancellation preserves query without active work")
            if notice { try check(session.status == "搜尋已取消，搜尋詞仍保留。", "Background cancellation also updates completed-result status") }
            session.toggle(rows[0].id); session.toggle(rows[2].id)
            try check(session.selectedIDs.isEmpty && session.selectedSources() == nil, "Old candidate IDs cannot restore a cancelled completed selection")
            try check(captured?.map(\.url) == [rows[0].url, rows[2].url], "A native apply action that captured sources before closing retains its immutable values")
            try check(actualFactory.created.count == 1 && browser.queries == [query] && browser.cancellations == 1, "Completed cancellation does not create a browser or re-search")
            try unloaded([browser])
        }
    }

    @MainActor static func queryChangesAndLateFailure() async throws {
        let gate = DiscoveryAppGate()
        let old = DiscoveryAppBrowser(gate: gate, failure: ResearchSourceDiscoveryError.navigationFailed)
        let fresh = DiscoveryAppBrowser(), factory = DiscoveryAppFactory([old, fresh])
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
        let original = try start(session)
        try await until { old.queries.count == 1 }
        session.setQuery("Replacement query")
        try check(session.query == "Replacement query" && session.result == nil && session.selectedIDs.isEmpty && session.error == nil && session.browser == nil && !session.running, "Changing pending query revokes the old operation and presentation")
        let replacement = try start(session); await replacement.value
        let rows = try candidates(session)
        session.toggle(rows[0].id); session.toggle(rows[2].id)
        let resultID = session.result?.id, selected = session.selectedIDs
        await gate.release(); await original.value
        try check(session.result?.id == resultID && session.selectedIDs == selected && session.error == nil && session.canApply, "Late old failure cannot poison the newer successful query")
        session.setQuery("Replacement query")
        try check(session.result?.id == resultID && session.selectedIDs == selected, "Unchanged editor text preserves current selection")
        session.setQuery("Third query")
        try check(session.result == nil && session.selectedIDs.isEmpty && !session.canApply && session.selectedSources() == nil && session.status == "尚未搜尋", "A changed query clears results and selection before another search")
        try check(factory.created.count == 2 && fresh.queries == ["Replacement query"], "Changing query does not perform an implicit search")
        try unloaded([old, fresh])
    }

    @MainActor static func failureCancellationAndExplicitRetry() async throws {
        let failures: [Error] = [ResearchSourceDiscoveryError.noCandidates, DiscoveryOpaqueFailure.synthetic]
        for error in failures {
            let first = DiscoveryAppBrowser(failure: error), second = DiscoveryAppBrowser()
            let factory = DiscoveryAppFactory([first, second])
            let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
            let failed = try start(session); await failed.value
            try check(!session.running && session.result == nil && session.selectedIDs.isEmpty && session.browser == nil && !session.canApply, "Failure cannot publish candidates or apply authority")
            try check(session.query == query && session.error != nil && first.cancellations == 1 && factory.created.count == 1, "Failure retains exact query and performs cleanup without automatic retry")
            if error is DiscoveryOpaqueFailure {
                try check(session.error == "搜尋未能完成，請稍後再試。", "Unknown adapter errors use fixed App text")
            } else {
                try check(session.error == ResearchSourceDiscoveryError.noCandidates.errorDescription, "Known failure remains an explicit no-candidates outcome")
            }
            session.cancel()
            try check(session.query == query && factory.created.count == 1 && first.queries == [query], "Cancel after failure preserves query and does not retry")
            let retry = try start(session); await retry.value
            try check(session.result != nil && session.error == nil && session.query == query && second.queries == [query] && factory.created.count == 2, "Only explicit retry creates a new adapter and clears prior error")
            try unloaded([first, second])
        }
    }

    @MainActor static func runningBlocksSelectionAndDuplicateSearch() async throws {
        let gate = DiscoveryAppGate()
        let pending = DiscoveryAppBrowser(gate: gate)
        let actualFactory = DiscoveryAppFactory([pending])
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: actualFactory.make)
        let original = try start(session)
        try await until { pending.queries.count == 1 }
        session.search(); session.toggle(UUID())
        try check(actualFactory.created.count == 1 && pending.queries == [query], "Duplicate start while running creates no request")
        try check(session.running && session.result == nil && session.selectedIDs.isEmpty && !session.canApply && session.selectedSources() == nil, "Pending results cannot be selected or applied")
        session.cancel(); session.cancel()
        try check(pending.cancellations == 1 && !session.running && session.query == query, "Repeated cancel does not revive or re-cancel a dropped adapter")
        await gate.release(); await original.value
        try check(pending.produced != nil && session.result == nil && session.selectedSources() == nil, "Actual late completion after cancellation cannot publish candidates")
        try unloaded([pending])
    }

    #if RESEARCH_DISCOVERY_APP_STANDALONE
    @MainActor static func main() async {
        do {
            let cases: [(String, () async throws -> Void)] = [
                ("explicitSearchAndInvalidQueries", explicitSearchAndInvalidQueries),
                ("orderedOriginSelectionAndApply", orderedOriginSelectionAndApply),
                ("lateSuccessCannotOverwriteRestart", lateSuccessCannotOverwriteRestart),
                ("completedResultCancellation", completedResultCancellation),
                ("queryChangesAndLateFailure", queryChangesAndLateFailure),
                ("failureCancellationAndExplicitRetry", failureCancellationAndExplicitRetry),
                ("runningBlocksSelectionAndDuplicateSearch", runningBlocksSelectionAndDuplicateSearch)]
            for (name, body) in cases { let before = assertions; try await body(); groups[name] = assertions - before }
            let output = try JSONSerialization.data(withJSONObject: ["passed": assertions, "failed": 0, "groups": groups,
                "actual_app_session": true, "core_dom_acceptance": true, "network_requests": 0,
                "actual_search_service": false, "native_ios_ui": false], options: [.sortedKeys])
            print(String(decoding: output, as: UTF8.self))
        } catch {
            let label = (error as? DiscoveryAppFailure)?.label ?? "Unexpected offline discovery App failure"
            if let output = try? JSONSerialization.data(withJSONObject: ["failure": label, "failed": 1, "passed": assertions], options: [.sortedKeys]) {
                print(String(decoding: output, as: UTF8.self))
            }
            exit(1)
        }
    }
    #endif
}

#if !RESEARCH_DISCOVERY_APP_STANDALONE
final class ResearchSourceDiscoveryAppIntegrationTests: XCTestCase {
    @MainActor func testExplicitSearchAndInvalidQueriesMakeNoImplicitRequest() async throws { try await ResearchSourceDiscoveryAppChecks.explicitSearchAndInvalidQueries() }
    @MainActor func testTwoToThreeDistinctOriginsAndApplyPreservesCandidates() async throws { try await ResearchSourceDiscoveryAppChecks.orderedOriginSelectionAndApply() }
    @MainActor func testCancelledLateSuccessCannotOverwriteRestart() async throws { try await ResearchSourceDiscoveryAppChecks.lateSuccessCannotOverwriteRestart() }
    @MainActor func testCompletedResultCannotApplyAfterLeaveOrBackground() async throws { try await ResearchSourceDiscoveryAppChecks.completedResultCancellation() }
    @MainActor func testQueryChangesClearSelectionAndRejectLateFailure() async throws { try await ResearchSourceDiscoveryAppChecks.queryChangesAndLateFailure() }
    @MainActor func testFailureCancellationAndExplicitRetryPreserveQuery() async throws { try await ResearchSourceDiscoveryAppChecks.failureCancellationAndExplicitRetry() }
    @MainActor func testRunningBlocksDuplicateSearchSelectionAndApply() async throws { try await ResearchSourceDiscoveryAppChecks.runningBlocksSelectionAndDuplicateSearch() }
}
#endif
#endif
