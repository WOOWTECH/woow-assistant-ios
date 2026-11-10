#if canImport(WebKit)
import Foundation
import WebKit

/// One user-triggered search. Mount `webView` in the scene before calling search.
/// A fresh nonpersistent store and fixed content rules are installed before any
/// request. No API accepts cookies, headers, scripts, arbitrary URLs or clicks.
@MainActor public final class ResearchSourceDiscoveryWebKit {
    public let provider: ResearchSourceDiscoveryProvider
    public let webView: WKWebView
    private let delegate = ResearchSourceDiscoveryDelegate()
    private var used = false
    private var active = false
    private var retired = false
    private var terminalError: ResearchSourceDiscoveryError?
    private var expectedURL: URL?
    private var navigation: WKNavigation?
    private var navigationWaiter: CheckedContinuation<Void, Error>?
    private var scriptWaiter: CheckedContinuation<String, Error>?
    private var configurationWaiter: CheckedContinuation<WKContentRuleList, Error>?
    private var timeout: Task<Void, Never>?
    // Read-only test evidence, never a source receipt/model tool or user log.
    private(set) var lastDOMSnapshot: Data?
    private(set) var httpStatus: Int?
    private(set) var requestsStarted = 0
    private var lifetimeNanoseconds: UInt64 = 45_000_000_000

    public init(provider: ResearchSourceDiscoveryProvider = .duckDuckGoHTML) {
        self.provider = provider
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        delegate.owner = self
        webView.navigationDelegate = delegate; webView.uiDelegate = delegate
    }

    public func search(query: String) async throws -> ResearchSourceDiscoveryResult {
        guard !retired else { throw ResearchSourceDiscoveryError.cancelled }
        guard !used else { throw ResearchSourceDiscoveryError.alreadyUsed }
        let url = try provider.searchURL(query: query)
        used = true; active = true; expectedURL = url
        timeout = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await Task.sleep(nanoseconds: lifetimeNanoseconds) } catch { return }
            fail(.deadline)
        }
        return try await withTaskCancellationHandler {
            do {
                // SwiftUI may attach the representable on the next render pass.
                // This is a local mount wait; no request/retry occurs here.
                let mountDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while webView.window == nil, ContinuousClock.now < mountDeadline {
                    try check(); try await Task.sleep(nanoseconds: 20_000_000)
                }
                try check()
                guard webView.window != nil else { throw ResearchSourceDiscoveryError.notMounted }
                let rules = try await compileRules()
                try check(); webView.configuration.userContentController.add(rules)
                try await load(url)
                try check()
                guard webView.url == url else { throw ResearchSourceDiscoveryError.pageChanged }
                let text = try await observe()
                try check()
                guard webView.url == url else { throw ResearchSourceDiscoveryError.pageChanged }
                let bytes = Data(text.utf8)
                guard bytes.count <= ResearchSourceDiscoveryPolicy.maximumSnapshotBytes else { throw ResearchSourceDiscoveryError.pageTooLarge }
                lastDOMSnapshot = bytes
                let result = try ResearchSourceDiscoveryDOM.accept(bytes, provider: provider, query: query, expected: url)
                try check(); active = false; timeout?.cancel(); timeout = nil
                webView.stopLoading()
                return result
            } catch {
                let safe = terminalError ?? (error as? ResearchSourceDiscoveryError)
                    ?? (error is CancellationError ? .cancelled : .navigationFailed)
                fail(safe); throw safe
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }

    /// Permanent revocation. The owner must drop this adapter/representable and
    /// create a new instance for another explicit search. Late delegates cannot
    /// complete a previous continuation or reopen an external page.
    public func cancel() {
        guard !retired else { return }
        retired = true; fail(.cancelled); lastDOMSnapshot = nil
        // Fixed local empty document releases the retained search DOM. Keep the
        // closed delegate attached so a retained view gains no manual rights.
        webView.loadHTMLString("", baseURL: nil)
    }

    private func check() throws {
        if let terminalError { throw terminalError }
        guard active, !Task.isCancelled else { throw ResearchSourceDiscoveryError.cancelled }
    }
    private func fail(_ error: ResearchSourceDiscoveryError) {
        if terminalError == nil { terminalError = error }
        active = false; timeout?.cancel(); timeout = nil; webView.stopLoading()
        let navigation = navigationWaiter, script = scriptWaiter, configuration = configurationWaiter
        navigationWaiter = nil; scriptWaiter = nil; configurationWaiter = nil
        navigation?.resume(throwing: terminalError!); script?.resume(throwing: terminalError!); configuration?.resume(throwing: terminalError!)
    }
    private func compileRules() async throws -> WKContentRuleList {
        try check()
        return try await withCheckedThrowingContinuation { continuation in
            configurationWaiter = continuation
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "woow-research-source-discovery-v1",
                encodedContentRuleList: Self.contentRules) { [weak self] rules, _ in
                Task { @MainActor in
                    guard let self, let waiter = self.configurationWaiter else { return }
                    self.configurationWaiter = nil
                    if let rules, self.active { waiter.resume(returning: rules) }
                    else { waiter.resume(throwing: self.terminalError ?? ResearchSourceDiscoveryError.privacyConfiguration) }
                }
            }
        }
    }
    private func load(_ url: URL) async throws {
        try check()
        try await withCheckedThrowingContinuation { continuation in
            navigationWaiter = continuation
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 45)
            request.httpShouldHandleCookies = false
            requestsStarted += 1
            navigation = webView.load(request)
            if navigation == nil { fail(.navigationFailed) }
        }
    }
    private func observe() async throws -> String {
        try check()
        return try await withCheckedThrowingContinuation { continuation in
            scriptWaiter = continuation
            webView.evaluateJavaScript(Self.observationScript, in: nil, in: .defaultClient) { [weak self] outcome in
                Task { @MainActor in
                    guard let self, let waiter = self.scriptWaiter else { return }
                    self.scriptWaiter = nil
                    guard self.active else { waiter.resume(throwing: self.terminalError ?? ResearchSourceDiscoveryError.cancelled); return }
                    if case .success(let value) = outcome, let text = value as? String { waiter.resume(returning: text) }
                    else { waiter.resume(throwing: ResearchSourceDiscoveryError.pageChanged) }
                }
            }
        }
    }

    fileprivate func action(_ action: WKNavigationAction, decide: @escaping (WKNavigationActionPolicy) -> Void) {
        if retired, action.request.url?.absoluteString == "about:blank" { decide(.allow); return }
        guard active, let expectedURL, let url = action.request.url,
              ResearchSourceDiscoveryPolicy.navigation(url, expected: expectedURL), action.request.httpMethod == "GET",
              action.targetFrame?.isMainFrame == true, action.navigationType == .other, !action.shouldPerformDownload else {
            decide(.cancel)
            if active { fail(.navigationRejected) }
            return
        }
        decide(.allow)
    }
    fileprivate func response(_ response: WKNavigationResponse, decide: @escaping (WKNavigationResponsePolicy) -> Void) {
        if retired, response.response.url?.absoluteString == "about:blank" { decide(.allow); return }
        guard active, response.isForMainFrame, let expectedURL, let url = response.response.url,
              ResearchSourceDiscoveryPolicy.navigation(url, expected: expectedURL) else {
            decide(.cancel); if active { fail(.navigationRejected) }; return
        }
        httpStatus = (response.response as? HTTPURLResponse)?.statusCode
        guard httpStatus == 200, response.canShowMIMEType,
              ["text/html", "application/xhtml+xml"].contains(response.response.mimeType?.lowercased() ?? ""),
              (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") == nil else {
            decide(.cancel); fail(.responseRejected); return
        }
        guard response.response.expectedContentLength <= ResearchSourceDiscoveryPolicy.maximumHTMLBytes else {
            decide(.cancel); fail(.pageTooLarge); return
        }
        decide(.allow)
    }
    fileprivate func completed(_ navigation: WKNavigation?) {
        guard active, let navigation, self.navigation === navigation, let waiter = navigationWaiter else { return }
        navigationWaiter = nil; waiter.resume()
    }
    fileprivate func failed(_ navigation: WKNavigation?) {
        guard active, let navigation, self.navigation === navigation else { return }
        fail(.navigationFailed)
    }
    fileprivate func terminated() { if active { fail(.navigationFailed) } }

    // First deny all resources; only this exact host's documents/CSS can load.
    // Navigation delegates further restrict documents to the exact requested
    // page. Cookie blocking is LAST so the allow rule cannot disable it.
    static let contentRules = #"""
    [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
     {"trigger":{"url-filter":"^https://html\\.duckduckgo\\.com/","resource-type":["document","style-sheet"]},"action":{"type":"ignore-previous-rules"}},
     {"trigger":{"url-filter":".*"},"action":{"type":"block-cookies"}}]
    """#

    // Fixed application script, never a model argument. Only actual visible
    // organic-result anchors are candidates. Search text cannot mint a URL.
    // The DOM size check bounds accepted HTML, NOT total WebKit network bytes
    // when a server streams/chunks or compresses an unknown-length response.
    static let observationScript = #"""
    (() => {
      const max=1048576;
      const base={url:location.href,title:document.title.slice(0,200),htmlBytes:0,oversized:false,
        challenge:false,resultsPresent:false,truncated:false,links:[]};
      const html=document.documentElement.outerHTML;
      if(html.length>max) return JSON.stringify({...base,htmlBytes:max+1,oversized:true});
      const bytes=new TextEncoder().encode(html).length;
      if(bytes>max) return JSON.stringify({...base,htmlBytes:bytes,oversized:true});
      base.htmlBytes=bytes;
      base.challenge=!!document.querySelector('#challenge-form,.anomaly-modal,form[action*="anomaly"],input[type="password"]');
      base.resultsPresent=!!document.querySelector('#links,.results,.no-results');
      const all=document.querySelectorAll('a.result__a[href]');
      if(document.getElementsByTagName('*').length>10000) return JSON.stringify({...base,oversized:true});
      const visible=a=>{
        if(!a.getClientRects().length || a.hasAttribute('download') || a.closest('[hidden],[aria-hidden="true"],[contenteditable]')) return false;
        for(let n=a;n;n=n.parentElement) {
          const s=getComputedStyle(n);
          if(s.display==='none'||s.visibility==='hidden'||s.visibility==='collapse'||Number(s.opacity)===0) return false;
        }
        return true;
      };
      for(let i=0;i<all.length;i++) {
        const a=all[i]; if(!visible(a)) continue;
        if(base.links.length===30) {base.truncated=true;break;}
        const title=Array.from(a.innerText.trim()).slice(0,200).join('');
        if(a.href.length>4096) continue;
        base.links.push({index:i,title,href:a.href});
      }
      return JSON.stringify(base);
    })()
    """#
}

/// Explicit actor hop accommodates older macOS WebKit SDKs whose ObjC delegate
/// requirements were not annotated @MainActor. All state stays on MainActor.
private final class ResearchSourceDiscoveryDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    weak var owner: ResearchSourceDiscoveryWebKit?
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        Task { @MainActor [weak owner] in
            guard let owner else { decisionHandler(.cancel); return }
            owner.action(navigationAction, decide: decisionHandler)
        }
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        Task { @MainActor [weak owner] in
            guard let owner else { decisionHandler(.cancel); return }
            owner.response(navigationResponse, decide: decisionHandler)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor [weak owner] in owner?.completed(navigation) }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak owner] in owner?.failed(navigation) }
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor [weak owner] in owner?.failed(navigation) }
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Task { @MainActor [weak owner] in owner?.terminated() }
    }
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Normal TLS trust uses the platform verifier. Never supply credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? { nil }
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) { completionHandler() }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) { completionHandler(false) }
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) { completionHandler(nil) }
}
#endif
