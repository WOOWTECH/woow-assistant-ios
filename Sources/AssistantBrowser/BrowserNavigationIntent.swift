import Foundation

/// Tracks the initiating navigation, not the task's current `isRunning` flag.
/// A cancelled research response cannot turn into a manual download afterward.
public struct BrowserNavigationIntent {
    private var generation = UUID()
    private var manualURLs: Set<URL> = []
    private var pendingDownload: (generation: UUID, url: URL, expires: Date)?
    public init() {}
    public mutating func beginManual(_ url: URL) {
        invalidate()
        if BrowserManualNavigationPolicy.allows(url) { manualURLs.insert(url) }
    }
    public mutating func recordManualRedirect(_ url: URL) {
        guard !manualURLs.isEmpty, manualURLs.count < 16, BrowserManualNavigationPolicy.allows(url) else { return }
        manualURLs.insert(url)
    }
    public mutating func invalidate() {
        generation = UUID(); manualURLs = []; pendingDownload = nil
    }
    @discardableResult public mutating func authorizeDownload(_ url: URL, now: Date = .now) -> Bool {
        guard manualURLs.contains(url) else { return false }
        pendingDownload = (generation, url, now.addingTimeInterval(30)); return true
    }
    public mutating func consumeDownload(_ url: URL?, now: Date = .now) -> Bool {
        let permit = pendingDownload; pendingDownload = nil
        guard let permit, permit.generation == generation, now < permit.expires, url == permit.url else { return false }
        return true
    }
}
