#if os(iOS) && canImport(XCTest) && DEBUG
import AssistantBrowser
import AssistantModels
import UIKit
import WebKit
import XCTest
@testable import WoowAssistant

/// Real WebKit HTML documents, separate stores, real navigation delegates and
/// citation validation. Synthetic model replies; no public HTTPS fetch claim.
final class MultiSourceResearchIntegrationTests: XCTestCase {
    @MainActor func testTwoActualWebKitSourcesNavigateAndProduceExactReceipts() async throws {
        let host = try Host(); defer { host.close() }
        let model = Model()
        let result = try await MultiSourceResearchRunner(client: model).run(plan: host.plan, browser: host,
            configuration: ModelConfiguration(baseURL: URL(string: "https://synthetic-model.invalid/v1")!, model: "fixture"), apiKey: "synthetic")
        XCTAssertFalse(result.partial)
        XCTAssertEqual(result.citedSourceCount, 2)
        XCTAssertEqual(result.receipts.count, 3)
        XCTAssertEqual(result.receipts.map(\.sourceID), ["source-1", "source-2", "source-1"])
        XCTAssertEqual(result.receipts.map { $0.observation.url.absoluteString }, [
            "https://research.example.invalid/start", "https://comparison.example.invalid/start", "https://research.example.invalid/details"])
        XCTAssertTrue(result.receipts[2].observation.text.contains("DETAIL_OBSERVED"))
        XCTAssertEqual(result.findings[0].citations.map(\.quote), ["SOURCE_ALPHA_OBSERVED", "SOURCE_BETA_OBSERVED"])
        for citation in result.findings[0].citations {
            XCTAssertTrue(citation.receipt.observation.text.contains(citation.quote))
            XCTAssertLessThanOrEqual(citation.receipt.observation.capturedAt, Date())
            XCTAssertEqual(citation.receipt.observation.capturedAt,
                           result.receipts.first(where: { $0.id == citation.receipt.id })?.observation.capturedAt)
        }
        let first = host.browsers[0].webView, second = host.browsers[1].webView
        XCTAssertFalse(first.configuration.websiteDataStore === second.configuration.websiteDataStore)
        XCTAssertFalse(first.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(second.configuration.websiteDataStore.isPersistent)
        let set = try await first.evaluateJavaScript("document.cookie='multi_source_only=synthetic; Domain=example.invalid; Path=/; Secure'; document.cookie") as? String
        XCTAssertTrue(try XCTUnwrap(set).contains("multi_source_only=synthetic"))
        let other = try await second.evaluateJavaScript("document.cookie") as? String
        XCTAssertFalse(try XCTUnwrap(other).contains("multi_source_only="), "Each source owns a distinct actual cookie store")
    }

    @MainActor func testOtherApprovedOriginStillCannotRedirectOrRebindThisWebView() async throws {
        let host = try Host(); defer { host.close() }
        let first = host.browsers[0]
        _ = try await host.loadRoot(source: host.plan.sources[0])
        // Actual WebKit navigation action, not a fabricated URL-policy object.
        _ = try await first.webView.evaluateJavaScript("window.location.href='https://comparison.example.invalid/start'; 'requested'")
        let end = ProcessInfo.processInfo.systemUptime + 5
        while first.error == nil && ProcessInfo.processInfo.systemUptime < end { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(first.error, "The actual cross-source action must be rejected")
        XCTAssertEqual(first.webView.url, host.plan.sources[0].rootURL)
        let unchanged = try await first.inspect()
        XCTAssertTrue(unchanged.text.contains("SOURCE_ALPHA_OBSERVED"))
        XCTAssertFalse(unchanged.text.contains("SOURCE_BETA_OBSERVED"))
        first.cancel()
        XCTAssertTrue(first.automationOwnsDocument, "Cancel cannot grant manual policy to an automation document")
        do {
            _ = try await first.loadResearchRoot(approvedSource: host.plan.sources[1])
            XCTFail("A completed/cancelled session must not acquire another source")
        } catch let error as WebResearchError { XCTAssertEqual(error, .unsafeNavigation) }
    }

    @MainActor func testPersistentManualStoreCannotBeUsedForApprovedResearchRoots() async throws {
        let source = try MultiSourceResearchPlan(goal: "Read", rootAddresses: Host.roots).sources[0]
        let browser = BrowserSession(dataStore: .default())
        do { _ = try await browser.loadResearchRoot(approvedSource: source); XCTFail("Must not use the manual cookie store") }
        catch let error as WebResearchError { XCTAssertEqual(error, .unsafeNavigation) }
        XCTAssertNil(browser.loadedURL)
        XCTAssertFalse(browser.isRunning)
    }

    private actor Model: ChatModelClient {
        private var count = 0
        func complete(messages: [ModelMessage], configuration: ModelConfiguration, apiKey: String) async throws -> String {
            count += 1
            guard messages.contains(where: { $0.content.contains("SOURCE_ALPHA_OBSERVED") && $0.content.contains("SOURCE_BETA_OBSERVED") }) else {
                throw WebResearchError.noPage
            }
            if count == 1 { return #"{"action":"open","sourceID":"source-1","observationID":"page-1","linkID":0}"# }
            return #"{"action":"finish","findings":[{"kind":"finding","text":"兩份實際 WebKit 文件均已讀取。","citations":[{"observationID":"page-3","quote":"SOURCE_ALPHA_OBSERVED"},{"observationID":"page-2","quote":"SOURCE_BETA_OBSERVED"}]}],"limitations":[]}"#
        }
    }

    @MainActor private final class Host: MultiSourceResearchExecuting {
        static let roots = ["https://research.example.invalid/start", "https://comparison.example.invalid/start"]
        let plan: MultiSourceResearchPlan
        let browsers: [BrowserSession]
        private let window: UIWindow
        private let previous: UIWindow?
        init() throws {
            plan = try MultiSourceResearchPlan(goal: "Compare the actual source markers", rootAddresses: Self.roots)
            browsers = plan.sources.map { _ in BrowserSession(dataStore: .nonPersistent()) }
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            previous = scene.windows.first(where: \.isKeyWindow)
            window = UIWindow(windowScene: scene)
            let controller = UIViewController()
            let stack = UIStackView(arrangedSubviews: browsers.map(\.webView)); stack.axis = .vertical; stack.distribution = .fillEqually
            controller.view = stack; window.rootViewController = controller; window.makeKeyAndVisible()
            for browser in browsers { browser.canPresentUI = { false } }
        }
        func loadRoot(source: MultiSourceResearchSource) async throws -> WebObservation {
            let index = try XCTUnwrap(plan.sources.firstIndex(of: source))
            return try await browsers[index].loadResearchFixtureRoot(approvedSource: source)
        }
        func openLink(sourceID: String, id: Int) async throws -> WebObservation {
            let index = try XCTUnwrap(plan.sources.firstIndex(where: { $0.id == sourceID }))
            return try await browsers[index].openLink(id: id)
        }
        func close() {
            for browser in browsers { browser.cancel(); browser.webView.navigationDelegate = nil }
            window.isHidden = true; window.rootViewController = nil; previous?.makeKey()
        }
    }
}
#endif
