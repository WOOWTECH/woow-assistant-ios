import AppKit
import Combine
import CryptoKit
import Foundation
import WebKit
@testable import AssistantBrowser

// Real App Session + real adapter. The factory only mounts the adapter's own
// view in a private nonpersistent macOS window; it never supplies results, DOM,
// scripts, credentials, cookies, model replies or candidate URLs.
private struct LiveDiscoveryFailure: Error { let code: String }

@MainActor private final class LiveDiscoveryWindows {
    private(set) var adapters: [ResearchSourceDiscoveryWebKit] = []
    private var windows: [NSWindow] = []
    func make() -> any ResearchSourceDiscovering {
        let adapter = ResearchSourceDiscoveryWebKit()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = adapter.webView
        window.orderFront(nil)
        adapters.append(adapter); windows.append(window)
        return adapter
    }
    var requests: Int { adapters.reduce(0) { $0 + $1.requestsStarted } }
    func close() {
        adapters.forEach { $0.cancel() }
        windows.forEach { $0.orderOut(nil); $0.contentView = nil; $0.close() }
        windows = []
    }
}

@main private enum LiveResearchSourceDiscoveryAppSmoke {
    static let query = "Swift concurrency documentation"
    static let changedQuery = "Swift language documentation"
    @MainActor static var passed = 0
    @MainActor static var stage = "consent"
    @MainActor static var groups: [String: Int] = [:]
    @MainActor static var observations: [[String: Any]] = []
    @MainActor static let factory = LiveDiscoveryWindows()

    @MainActor static func check(_ condition: @autoclosure () throws -> Bool, _ code: String) throws {
        guard try condition() else { throw LiveDiscoveryFailure(code: code) }
        passed += 1
    }
    @MainActor static func originalTask(_ session: ResearchSourceDiscoverySession) throws -> Task<Void, Never> {
        guard let task = Mirror(reflecting: session).children.first(where: { $0.label == "task" })?.value as? Task<Void, Never> else {
            throw LiveDiscoveryFailure(code: "session_task_missing")
        }
        return task
    }
    @MainActor static func cookies(_ view: WKWebView) async -> [HTTPCookie] {
        await withCheckedContinuation { continuation in
            view.configuration.websiteDataStore.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    @MainActor static func actualSearchAndSelection(_ session: ResearchSourceDiscoverySession) async throws -> [ResearchSourceDiscoveryCandidate] {
        let beforeRequests = factory.requests, beforeAdapters = factory.adapters.count
        try check(session.result == nil && session.selectedIDs.isEmpty && !session.canApply && session.selectedSources() == nil,
                  "unconfirmed_result_or_selection")
        try check(!session.running && session.browser == nil && session.query == query, "unconfirmed_browser_or_query")
        var observedDOM: Data?
        var observedID: UUID?
        // Published delivery runs synchronously before finish() retires the
        // adapter and clears its DOM. Copy only the actual observation bytes.
        let subscription = session.$result.sink { result in
            guard let result else { return }
            observedID = result.id
            observedDOM = factory.adapters.last?.lastDOMSnapshot
        }
        defer { withExtendedLifetime(subscription) {}; subscription.cancel() }
        stage = "search"
        session.search()
        let task = try originalTask(session)
        try check(factory.adapters.count == beforeAdapters + 1 && session.running, "explicit_search_factory_count")
        let adapter = factory.adapters[beforeAdapters]
        try check(session.browser === adapter && adapter.webView.window != nil, "actual_adapter_not_mounted")
        try check(adapter.requestsStarted == 0 && adapter.webView.url == nil, "request_before_session_task")
        try check(!adapter.webView.configuration.websiteDataStore.isPersistent
                  && !adapter.webView.configuration.defaultWebpagePreferences.allowsContentJavaScript
                  && !adapter.webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically,
                  "adapter_privacy_configuration")
        await task.value
        guard let result = session.result else { throw LiveDiscoveryFailure(code: "provider_search_failed") }
        stage = "actual_result"
        try check(session.error == nil && !session.running && session.browser == nil, "session_did_not_finish")
        try check(adapter.requestsStarted == 1 && factory.requests == beforeRequests + 1 && adapter.httpStatus == 200,
                  "provider_status_or_main_request_count")
        try check(result.query == query && result.pageURL == (try session.provider.searchURL(query: query)), "result_query_binding")
        try check(!result.grantsResearchAuthorization && result.candidates.count >= 2 && result.candidates.count <= 30,
                  "candidate_count_or_authority")
        guard let bytes = observedDOM else { throw LiveDiscoveryFailure(code: "actual_dom_missing") }
        let page = try JSONDecoder().decode(ResearchSourceDiscoveryDOM.self, from: bytes)
        try check(observedID == result.id && bytes.count <= 64 * 1024
                  && SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == result.observationSHA256,
                  "actual_dom_digest_binding")
        try check(page.url == result.pageURL.absoluteString && page.htmlBytes == result.htmlByteCount
                  && page.resultsPresent && !page.challenge && !page.oversized, "actual_dom_page_binding")
        try check(result.candidates.allSatisfy { candidate in
            candidate.observationID == result.id && page.links.contains {
                $0.index == candidate.domIndex && $0.title == candidate.title && $0.href == candidate.url.absoluteString
            }
        }, "candidate_not_observed_in_actual_dom")
        try check(adapter.lastDOMSnapshot == nil, "finished_adapter_retains_dom")
        let currentCookies = await cookies(adapter.webView)
        try check(currentCookies.isEmpty, "ephemeral_store_received_cookies")

        stage = "selection_apply"
        var origins = Set<WebsiteOrigin>(), chosen: [ResearchSourceDiscoveryCandidate] = []
        for candidate in result.candidates {
            if origins.insert(try WebsiteOrigin(url: candidate.url)).inserted { chosen.append(candidate) }
            if chosen.count == 2 { break }
        }
        try check(chosen.count == 2, "insufficient_distinct_origins")
        session.toggle(chosen[0].id)
        try check(session.selectedIDs == [chosen[0].id] && !session.canApply && session.selectedSources() == nil, "single_origin_apply_allowed")
        session.toggle(chosen[1].id)
        try check(session.canApply && session.selectedIDs == chosen.map(\.id), "two_origin_selection_rejected")
        let firstApply = session.selectedSources(), secondApply = session.selectedSources()
        try check(firstApply == chosen && secondApply == chosen && firstApply?.map(\.url) == chosen.map(\.url), "apply_rewrote_observed_candidates")
        try check(factory.requests == beforeRequests + 1 && factory.adapters.count == beforeAdapters + 1
                  && session.browser == nil && !session.running, "apply_started_additional_work")
        observations.append(["query": query, "provider": result.provider.rawValue,
                             "http_status": adapter.httpStatus ?? 0, "main_load_requests": adapter.requestsStarted,
                             "candidate_count": result.candidates.count, "distinct_origin_count": Set(try result.candidates.map { try WebsiteOrigin(url: $0.url) }).count,
                             "html_bytes": result.htmlByteCount, "dom_sha256": result.observationSHA256,
                             "observed_at": ISO8601DateFormatter().string(from: result.observedAt),
                             "selected_public_urls": chosen.map { $0.url.absoluteString },
                             "selected_dom_indices": chosen.map(\.domIndex)])
        return chosen
    }

    @MainActor static func queryChangeRevokesActualResult() async throws {
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
        defer { session.cancel(notice: false) }
        let chosen = try await actualSearchAndSelection(session)
        let requests = factory.requests, count = factory.adapters.count
        stage = "query_change"
        session.setQuery(changedQuery)
        try check(session.query == changedQuery && session.result == nil && session.selectedIDs.isEmpty
                  && !session.canApply && session.selectedSources() == nil, "query_change_kept_old_apply_authority")
        chosen.forEach { session.toggle($0.id) }
        try check(session.selectedIDs.isEmpty && session.selectedSources() == nil, "old_ids_reselected_after_query_change")
        try check(factory.requests == requests && factory.adapters.count == count, "query_change_started_search")
    }

    @MainActor static func leavingRevokesActualResult() async throws {
        let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
        defer { session.cancel(notice: false) }
        let chosen = try await actualSearchAndSelection(session)
        let requests = factory.requests, count = factory.adapters.count
        stage = "leave"
        // Same production Session entry point used by the View's onDisappear.
        session.cancel(notice: false)
        try check(session.result == nil && session.selectedIDs.isEmpty && !session.canApply && session.selectedSources() == nil,
                  "leave_kept_old_apply_authority")
        chosen.forEach { session.toggle($0.id) }
        try check(session.selectedIDs.isEmpty && session.selectedSources() == nil && session.query == query,
                  "old_ids_reselected_after_leaving")
        try check(factory.requests == requests && factory.adapters.count == count, "leave_started_additional_work")
    }

    @MainActor static func lateCancelledTasksCannotPublish() async throws {
        stage = "late_cancelled_tasks"
        for changeQuery in [false, true] {
            let session = ResearchSourceDiscoverySession(query: query, makeBrowser: factory.make)
            let requests = factory.requests, count = factory.adapters.count
            session.search()
            let old = try originalTask(session)
            let adapter = factory.adapters[count]
            // Still on the same MainActor turn: the real scheduled search task
            // has not started. Revocation must stop it even when it later runs.
            if changeQuery { session.setQuery(changedQuery) } else { session.cancel() }
            try check(!session.running && session.browser == nil && session.result == nil && !session.canApply,
                      "cancel_did_not_revoke_pending_session")
            await old.value
            try check(adapter.requestsStarted == 0 && factory.requests == requests, "cancelled_task_started_provider_request")
            try check(session.result == nil && session.selectedIDs.isEmpty && session.selectedSources() == nil
                      && session.error == nil && session.query == (changeQuery ? changedQuery : query),
                      "late_cancelled_task_published_state")
            session.cancel(notice: false)
        }
    }

    @MainActor static func main() {
        guard CommandLine.arguments == [CommandLine.arguments[0], "--live"] else {
            print(#"{"status":"FAIL","failure":"live_consent_required","stage":"consent","passed":0,"groups":{},"main_load_requests":0}"#)
            exit(1)
        }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        Task { @MainActor in
            var status = "FAIL", failure = "unclassified"
            let started = Date()
            do {
                try check(factory.adapters.isEmpty && factory.requests == 0, "initial_factory_request")
                for (name, body) in [("actualResultQueryChange", queryChangeRevokesActualResult),
                                     ("actualResultLeaving", leavingRevokesActualResult),
                                     ("lateCancelledTasks", lateCancelledTasksCannotPublish)] {
                    let before = passed
                    try await body()
                    groups[name] = passed - before
                }
                try check(factory.requests == 2 && factory.adapters.count == 4 && observations.count == 2, "unexpected_total_operations")
                status = "PASS"; failure = "none"
            } catch {
                failure = (error as? LiveDiscoveryFailure)?.code ?? "unclassified"
            }
            factory.close()
            let record: [String: Any] = ["status": status, "failure": failure, "stage": stage,
                "passed": passed, "groups": groups, "observations": observations,
                "main_load_requests": factory.requests, "adapters_created": factory.adapters.count,
                "seconds": Date().timeIntervalSince(started), "query": query,
                "actual_app_session": true, "actual_webkit": true, "fabricated_dom": false,
                "model_requests": 0, "candidate_body_reads": 0, "personal_webkit_store": false,
                "native_ios_execution": false, "retries": 0]
            if let data = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) {
                print(String(decoding: data, as: UTF8.self))
            }
            fflush(stdout); exit(status == "PASS" ? 0 : 1)
        }
        application.run()
    }
}
