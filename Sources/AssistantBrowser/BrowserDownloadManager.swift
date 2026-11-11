#if canImport(WebKit) && canImport(Combine)
import Combine
import Foundation
import WebKit

/// Own ONE instance per workspace and retain it for all originating web views.
/// Never copy Cookie/Authorization to URLSession or recreate the request.
///
/// BrowserSession integration (in addition to its normal URL/navigation policy):
///
///     // In decidePolicyFor navigationAction, AFTER existing URL/method checks:
///     if navigationAction.shouldPerformDownload {
///         decisionHandler(researchNavigation ? .cancel : .download); return
///     }
///     // In decidePolicyFor navigationResponse, AFTER existing URL checks:
///     if BrowserDownloadPolicy.isAttachment(navigationResponse.response)
///         || !navigationResponse.canShowMIMEType {
///         decisionHandler(researchNavigation ? .cancel : .download); return
///     }
///
///     func webView(_ view: WKWebView, navigationAction: WKNavigationAction,
///                  didBecome download: WKDownload) {
///         downloads.accept(download, sourceURL: navigationAction.request.url,
///                          allowsDownload: !researchNavigation)
///     }
///     func webView(_ view: WKWebView, navigationResponse: WKNavigationResponse,
///                  didBecome download: WKDownload) {
///         downloads.accept(download, sourceURL: navigationResponse.response.url,
///                          allowsDownload: !researchNavigation)
///     }
///
/// `researchNavigation` MUST be latched to the navigation that issued the request,
/// including cancelled/timed-out research and route replay. Do not derive it only
/// from the current isRunning flag: a late callback can arrive after it resets.
/// Research must cancel attachment/unsupported-MIME responses even when displayable.
/// Keep prior URL/redirect policy checks; deciding to download is not permission
/// to navigate to a previously forbidden URL. Final manager validation is additive.
///
/// No pause/resume/background guarantee. Partial data is removed on cancellation,
/// failure, and next launch. File-size polling can overshoot before cancellation;
/// completion verifies the actual on-disk size before publishing or sharing.
@MainActor
public final class BrowserDownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    @Published public private(set) var items: [BrowserDownloadItem] = []
    @Published public private(set) var errorMessage: String?
    public let limits: BrowserDownloadLimits
    private let store: BrowserDownloadStore?
    private let allowsURL: (URL) -> Bool
    private var transfers: [ObjectIdentifier: Transfer] = [:]
    private var polling: Task<Void, Never>?

    private final class Transfer {
        let id: UUID
        let download: WKDownload
        let started = ProcessInfo.processInfo.systemUptime
        var redirects = 0
        var terminalStatus: BrowserDownloadStatus?
        init(id: UUID, download: WKDownload) { self.id = id; self.download = download }
    }

    public convenience init(directory: URL? = nil, limits: BrowserDownloadLimits = .init()) {
        let root = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("BrowserDownloads", isDirectory: true)
        #if DEBUG && canImport(Network)
        self.init(directory: root, limits: limits, allowsURL: { url in
            BrowserDownloadPolicy.allows(url) || BrowserDownloadedPDFFixture.enabled?.allowsDownload(url) == true
        })
        #else
        self.init(directory: root, limits: limits, allowsURL: BrowserDownloadPolicy.allows)
        #endif
    }

    // Only @testable hosted tests can substitute an exact loopback fixture URL.
    // The public initializer always enforces the production HTTPS policy.
    init(directory: URL?, limits: BrowserDownloadLimits, allowsURL: @escaping (URL) -> Bool) {
        self.limits = limits; self.allowsURL = allowsURL
        do {
            guard let directory else { throw BrowserDownloadError.unavailable }
            let storage = try BrowserDownloadStore(directory: directory, limits: limits)
            store = storage
            super.init()
            items = storage.completed.sorted { ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt) }
        } catch {
            store = nil
            super.init()
            errorMessage = Self.message(error)
        }
    }

    deinit {
        polling?.cancel()
        // No resume data is retained; startup cleanup handles process termination.
        let downloads = transfers.values.map(\.download)
        Task { @MainActor in
            for download in downloads { download.cancel(nil) }
        }
    }

    /// Call synchronously in BOTH WKNavigationDelegate didBecome callbacks.
    /// `allowsDownload` is explicit and mandatory; research always passes false.
    @discardableResult
    public func accept(_ download: WKDownload, sourceURL: URL?, allowsDownload: Bool) -> UUID? {
        let key = ObjectIdentifier(download)
        if let existing = transfers[key] {
            if !allowsDownload {
                stop(existing, status: .failed, failure: BrowserDownloadError.researchDisabled)
                return nil
            }
            return existing.id
        }
        let failure: BrowserDownloadError?
        if !allowsDownload { failure = .researchDisabled }
        else if store == nil { failure = .unavailable }
        else if sourceURL.map(allowsURL) != true || download.originalRequest?.url.map(allowsURL) == false {
            failure = .unsafeURL
        } else if transfers.count >= limits.maximumActive ||
                    items.filter({ $0.status.isActive || $0.status == .completed }).count >= limits.maximumCount {
            failure = .tooMany
        } else { failure = nil }
        if let failure {
            errorMessage = failure.localizedDescription
            download.cancel(nil)
            return nil
        }
        // Terminal failures are session-only and can be evicted without deleting files.
        while items.count >= limits.maximumCount,
              let index = items.lastIndex(where: { $0.status == .failed || $0.status == .cancelled }) {
            items.remove(at: index)
        }
        let item = BrowserDownloadItem()
        items.insert(item, at: 0)
        transfers[key] = Transfer(id: item.id, download: download)
        download.delegate = self
        startPolling()
        return item.id
    }

    public func cancel(id: UUID) {
        guard let transfer = transfers.values.first(where: { $0.id == id }), transfer.terminalStatus == nil else { return }
        stop(transfer, status: .cancelled, failure: nil)
    }

    /// A completed, regular, unmodified private file only. The caller presents a
    /// user-initiated share sheet; the manager never executes or opens anything.
    public func fileURL(id: UUID) throws -> URL {
        guard items.first(where: { $0.id == id })?.status == .completed,
              let store else { throw BrowserDownloadError.missingFile }
        return try store.fileURL(id: id)
    }

    public func delete(id: UUID, confirmed: Bool) throws {
        guard confirmed else { throw BrowserDownloadError.confirmationRequired }
        guard let item = items.first(where: { $0.id == id }) else { return }
        guard !item.status.isActive else { throw BrowserDownloadError.stillRunning }
        guard let store else { throw BrowserDownloadError.unavailable }
        do {
            try store.delete(id: id, confirmed: true)
            items.removeAll { $0.id == id }
        } catch {
            errorMessage = Self.message(error)
            throw BrowserDownloadError.unavailable
        }
    }

    public func clearError() { errorMessage = nil }

    public func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                         suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        guard let transfer = transfers[ObjectIdentifier(download)], transfer.terminalStatus == nil,
              let store else { completionHandler(nil); return }
        do {
            guard let url = response.url, allowsURL(url) else { throw BrowserDownloadError.unsafeURL }
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                throw BrowserDownloadError.network
            }
            let expected = response.expectedContentLength
            guard expected <= limits.maximumFileBytes,
                  expected < 0 || store.completedBytes + expected <= limits.maximumTotalBytes else {
                throw BrowserDownloadError.tooLarge
            }
            let urlOnDisk = try store.destination(id: transfer.id, suggestedFilename: suggestedFilename)
            update(transfer.id) {
                $0.fileName = urlOnDisk.lastPathComponent; $0.status = .downloading
                $0.totalBytes = expected >= 0 ? expected : nil
            }
            completionHandler(urlOnDisk)
        } catch {
            completionHandler(nil)
            stop(transfer, status: .failed, failure: error)
        }
    }

    public func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                         newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
        guard let transfer = transfers[ObjectIdentifier(download)], transfer.terminalStatus == nil else {
            decisionHandler(.cancel); return
        }
        transfer.redirects += 1
        let failure: BrowserDownloadError?
        if transfer.redirects > limits.maximumRedirects { failure = .redirectLimit }
        else if response.url.map(allowsURL) != true || request.url.map(allowsURL) != true { failure = .unsafeURL }
        else { failure = nil }
        if let failure {
            decisionHandler(.cancel)
            stop(transfer, status: .failed, failure: failure)
        } else { decisionHandler(.allow) }
    }

    public func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                         completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // System trust evaluation only. No trust bypass, copied credentials, or
        // infinite authentication retries. Existing WebKit session cookies remain its own.
        completionHandler(challenge.previousFailureCount == 0 ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let transfer = transfers[ObjectIdentifier(download)], transfer.terminalStatus == nil,
              let item = items.first(where: { $0.id == transfer.id }), let store else { return }
        do {
            let finished = try store.finish(item)
            update(item.id) { $0 = finished }
            release(transfer)
        } catch {
            update(item.id) { $0.status = .failed; $0.failureMessage = Self.message(error) }
            cleanup(transfer)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let transfer = transfers[ObjectIdentifier(download)] else { return }
        // Raw errors/resume data can contain signed URLs or session credentials.
        update(transfer.id) {
            $0.status = transfer.terminalStatus ?? .failed
            if $0.status == .failed && $0.failureMessage == nil { $0.failureMessage = BrowserDownloadError.network.localizedDescription }
        }
        cleanup(transfer)
    }

    private func stop(_ transfer: Transfer, status: BrowserDownloadStatus, failure: Error?) {
        guard transfer.terminalStatus == nil else { return }
        transfer.terminalStatus = status
        update(transfer.id) {
            $0.status = .cancelling
            $0.failureMessage = failure.map { Self.message($0) }
        }
        transfer.download.cancel { [weak self, weak transfer] _ in
            Task { @MainActor in
                guard let self, let transfer, self.transfers[ObjectIdentifier(transfer.download)] === transfer else { return }
                self.update(transfer.id) { $0.status = status }
                // Wait for WebKit's acknowledgement before unlinking a partial;
                // otherwise the network process can recreate a cancelled file.
                self.cleanup(transfer)
            }
        }
    }

    private func cleanup(_ transfer: Transfer) {
        do { try store?.discardPartial(id: transfer.id) }
        catch { errorMessage = "未能清除未完成檔案，將在下次啟動時重試。" }
        release(transfer)
    }

    private func release(_ transfer: Transfer) {
        transfer.download.delegate = nil
        transfers.removeValue(forKey: ObjectIdentifier(transfer.download))
        if transfers.isEmpty { polling?.cancel(); polling = nil }
    }

    private func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
                guard self?.pollProgress() == true else { return }
            }
        }
    }

    private func pollProgress() -> Bool {
        guard let store else { return false }
        var total = store.completedBytes
        for transfer in Array(transfers.values) where transfer.terminalStatus == nil {
            do {
                let progress = transfer.download.progress
                let received = max(0, max(progress.completedUnitCount, try store.partialBytes(id: transfer.id)))
                let expected = progress.totalUnitCount
                guard received <= limits.maximumFileBytes, expected <= limits.maximumFileBytes else {
                    throw BrowserDownloadError.tooLarge
                }
                total += received
                guard total <= limits.maximumTotalBytes else { throw BrowserDownloadError.tooLarge }
                guard ProcessInfo.processInfo.systemUptime - transfer.started < 600 else { throw BrowserDownloadError.network }
                update(transfer.id) {
                    $0.receivedBytes = received
                    if expected > 0 { $0.totalBytes = expected }
                }
            } catch { stop(transfer, status: .failed, failure: error) }
        }
        return !transfers.isEmpty
    }

    private func update(_ id: UUID, _ change: (inout BrowserDownloadItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private static func message(_ error: Error) -> String {
        (error as? BrowserDownloadError)?.localizedDescription ?? BrowserDownloadError.unavailable.localizedDescription
    }
}
#endif
