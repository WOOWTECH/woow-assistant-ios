import Foundation

/// Tracks the initiating navigation, not the task's current `isRunning` flag.
/// A cancelled research response cannot turn into a manual download afterward.
public struct BrowserNavigationIntent {
    /// Pass the actual policy-delegate object again in its didBecome callback.
    /// Retaining it prevents ObjectIdentifier address reuse while a permit lives.
    public enum DownloadSource {
        case action(AnyObject)
        case response(AnyObject)

        fileprivate func matches(_ other: DownloadSource) -> Bool {
            switch (self, other) {
            case let (.action(lhs), .action(rhs)), let (.response(lhs), .response(rhs)):
                return ObjectIdentifier(lhs) == ObjectIdentifier(rhs)
            default:
                return false
            }
        }
    }

    private var generation = UUID()
    private var manualURLs: Set<URL> = []
    private var pendingDownload: (generation: UUID, url: URL, source: DownloadSource, expires: Date)?
    public init() {}
    public mutating func beginManual(_ url: URL) {
        invalidate()
        if Self.allowsManual(url) { manualURLs.insert(url) }
    }
    public mutating func recordManualRedirect(_ url: URL) {
        guard !manualURLs.isEmpty, manualURLs.count < 16, Self.allowsManual(url) else { return }
        manualURLs.insert(url)
    }
    private static func allowsManual(_ url: URL) -> Bool {
        #if DEBUG && canImport(Network)
        if BrowserDownloadedPDFFixture.enabled?.allowsNavigation(url) == true { return true }
        #endif
        return BrowserManualNavigationPolicy.allows(url)
    }
    public mutating func invalidate() {
        generation = UUID(); manualURLs = []; pendingDownload = nil
    }
    @discardableResult public mutating func authorizeDownload(_ url: URL, source: DownloadSource, now: Date = .now) -> Bool {
        guard manualURLs.contains(url) else { return false }
        pendingDownload = (generation, url, source, now.addingTimeInterval(30)); return true
    }
    public mutating func consumeDownload(_ url: URL?, source: DownloadSource, now: Date = .now) -> Bool {
        // A stale or unrelated callback must not consume a newer grant, even
        // when both downloads use the same URL. Only its issuer may consume it.
        guard let permit = pendingDownload, permit.source.matches(source) else { return false }
        pendingDownload = nil
        guard permit.generation == generation, now < permit.expires, url == permit.url else { return false }
        return true
    }
}
