import Foundation

/// Ephemeral method evidence, never persisted or inferred from an address.
/// A policy action has no WKNavigation identifier. Bind its evidence only to
/// the next uncontested start, then require that exact object at commit/finish.
/// Overlap, redirects, missing callbacks and uncertain methods fail closed.
public struct BrowserSiteModeReloadState {
    private struct Request {
        let url: URL
        let expectedNavigation: AnyObject?
    }
    private struct Document {
        let navigation: AnyObject
        let url: URL
    }
    private var awaitingStart = false
    private var pending: Request?
    private var inFlight: AnyObject?
    private var candidate: Document?
    private var committed: Document?
    private var finished: Document?

    public init() {}

    public mutating func observePolicy(url: URL?, method: String?, hasBody: Bool,
                                      manual: Bool, allowed: Bool, expectedNavigation: AnyObject? = nil) {
        let uncontested = !awaitingStart && inFlight == nil
        finished = nil; committed = nil; candidate = nil
        awaitingStart = true; pending = nil
        if uncontested, allowed, manual, method == "GET", !hasBody, let url {
            pending = Request(url: url, expectedNavigation: expectedNavigation)
        }
    }

    public mutating func start(_ navigation: AnyObject) {
        let request = pending
        pending = nil; finished = nil; committed = nil; candidate = nil
        inFlight = navigation
        if awaitingStart, let request,
           request.expectedNavigation == nil || request.expectedNavigation === navigation {
            candidate = Document(navigation: navigation, url: request.url)
        }
        awaitingStart = false
    }

    public mutating func commit(_ navigation: AnyObject, url: URL?) {
        guard inFlight === navigation, !awaitingStart, let candidate,
              candidate.navigation === navigation, candidate.url == url else { return }
        committed = candidate
    }

    public mutating func finish(_ navigation: AnyObject, url: URL?) {
        guard inFlight === navigation else { return }
        if !awaitingStart, let committed, committed.navigation === navigation, committed.url == url {
            finished = committed
        }
        inFlight = nil; candidate = nil; committed = nil
    }

    public mutating func redirect(_ navigation: AnyObject) {
        guard inFlight === navigation else { return }
        pending = nil; candidate = nil; committed = nil; finished = nil
    }

    public func allowsReload(navigation: AnyObject?, url: URL?) -> Bool {
        guard !awaitingStart, inFlight == nil, let navigation, let finished else { return false }
        return finished.navigation === navigation && finished.url == url
    }

    public mutating func invalidate() { self = .init() }
}
