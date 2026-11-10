import CryptoKit
import Foundation

/// An explicit provider choice, never a model-provided endpoint. This first
/// adapter supports only the official non-JavaScript HTML search interface.
public enum ResearchSourceDiscoveryProvider: String, CaseIterable, Sendable, Identifiable {
    case duckDuckGoHTML
    public var id: String { rawValue }
    public var title: String { "DuckDuckGo（HTML 搜尋）" }
    public var origin: URL { URL(string: "https://html.duckduckgo.com")! }
    public var disclosure: String {
        "按下搜尋後，搜尋詞會傳送至 html.duckduckgo.com；不會傳送模型金鑰或既有網站登入狀態。搜尋摘要只用來尋找來源，尚未讀取候選網頁正文。"
    }
    public func searchURL(query: String) throws -> URL {
        let query = try ResearchSourceDiscoveryPolicy.query(query)
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        parts.path = "/html/"; parts.queryItems = [.init(name: "q", value: query)]
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = parts.url, url.absoluteString.utf8.count <= 2048 else { throw ResearchSourceDiscoveryError.invalidQuery }
        return url
    }
}

public enum ResearchSourceDiscoveryError: String, Error, Equatable, Sendable, LocalizedError {
    case invalidQuery, alreadyUsed, cancelled, deadline, notMounted, privacyConfiguration
    case navigationRejected, navigationFailed, responseRejected, pageTooLarge, pageChanged
    case unavailable, noCandidates, invalidSelection
    public var errorDescription: String? {
        switch self {
        case .invalidQuery: return "搜尋詞過長或含有無法處理的字元，請縮短後再試。"
        case .alreadyUsed: return "這次搜尋已結束，請重新建立搜尋。"
        case .cancelled: return "搜尋已取消，晚到的頁面不會加入候選來源。"
        case .deadline: return "搜尋超過時間限制，未自動重試或改用其他服務。"
        case .notMounted: return "搜尋頁尚未顯示，請重新開啟來源探索。"
        case .privacyConfiguration: return "無法建立獨立搜尋環境，尚未傳送搜尋詞。"
        case .navigationRejected: return "搜尋頁要求離開已確認的供應者或執行不支援的操作，已停止。"
        case .navigationFailed: return "搜尋頁未能載入，未產生候選來源。"
        case .responseRejected: return "搜尋服務未回傳可讀取的 HTML 頁面。"
        case .pageTooLarge: return "搜尋頁超過可檢查的大小限制，未產生候選來源。"
        case .pageChanged: return "擷取搜尋結果時頁面已變更，未採用候選來源。"
        case .unavailable: return "搜尋服務要求驗證、登入或未提供可辨識的結果；這次無法探索來源。"
        case .noCandidates: return "這次未找到符合現有研究網址政策的直接連結；不能據此判斷網路上沒有相關資料。"
        case .invalidSelection: return "請從本次結果選取最多三個不同網站的來源。"
        }
    }
}

/// URL/title come solely from an actual visible search-result anchor. No public
/// initializer/decoder accepts model-generated URLs. Not a body-read receipt.
public struct ResearchSourceDiscoveryCandidate: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let url: URL
    public let observedAt: Date
    public let observationID: UUID
    public let domIndex: Int
}

public struct ResearchSourceDiscoveryResult: Identifiable, Sendable {
    public let id: UUID
    public let provider: ResearchSourceDiscoveryProvider
    public let query: String
    public let pageURL: URL
    public let observedAt: Date
    public let htmlByteCount: Int
    public let observationSHA256: String
    public let candidates: [ResearchSourceDiscoveryCandidate]
    public let rejectedLinkCount: Int
    public let truncated: Bool
    public var grantsResearchAuthorization: Bool { false }

    /// Call only for an explicit native selection/apply action. This returns
    /// immutable addresses to review; it never starts research or reads a page.
    public func selected(candidateIDs: [UUID]) throws -> [ResearchSourceDiscoveryCandidate] {
        guard (1...3).contains(candidateIDs.count), Set(candidateIDs).count == candidateIDs.count else {
            throw ResearchSourceDiscoveryError.invalidSelection
        }
        var selected: [ResearchSourceDiscoveryCandidate] = [], origins = Set<WebsiteOrigin>()
        for id in candidateIDs {
            guard let candidate = candidates.first(where: { $0.id == id && $0.observationID == self.id }),
                  let origin = try? WebsiteOrigin(url: candidate.url), origins.insert(origin).inserted else {
                throw ResearchSourceDiscoveryError.invalidSelection
            }
            selected.append(candidate)
        }
        return selected
    }
}

enum ResearchSourceDiscoveryPolicy {
    static let maximumHTMLBytes = 1024 * 1024
    static let maximumSnapshotBytes = 64 * 1024
    static let maximumLinks = 30
    static func query(_ query: String) throws -> String {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 256,
              !query.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ResearchSourceDiscoveryError.invalidQuery
        }
        // Preserve exact user input. URLComponents encodes it; never concatenate.
        return query
    }
    static func navigation(_ url: URL, expected: URL) -> Bool {
        // An intentionally narrow query exception confined to this adapter.
        // Existing BrowserSession/WebsiteOrigin policies are unchanged.
        url == expected && url.scheme == "https" && url.user == nil && url.password == nil
            && url.fragment == nil && url.port == nil && (url.host == "html.duckduckgo.com")
            // URL.path drops the trailing slash on older Foundation versions.
            // Compare the serialized path without broadening the exact endpoint.
            && URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath == "/html/"
            && { if case .allow = BrowserPolicy.evaluate(url) { return true }; return false }()
    }
    static func candidate(_ address: String) -> URL? {
        guard address.utf8.count <= 2048, case .allow(let url) = BrowserPolicy.evaluate(address: address),
              url.scheme == "https", (try? WebsiteOrigin(url: url)) != nil,
              let host = url.host?.lowercased(), host != "duckduckgo.com", !host.hasSuffix(".duckduckgo.com") else { return nil }
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        for _ in 0..<3 { path = path.removingPercentEncoding ?? path }
        let accountPaths: Set<String> = ["login", "signin", "sign-in", "sign_in", "signup", "sign-up", "register",
            "account", "accounts", "auth", "oauth", "oauth2", "callback", "authorize", "authentication"]
        guard !path.lowercased().split(separator: "/").contains(where: { accountPaths.contains(String($0)) }) else { return nil }
        // Do not strip parameters, decode tracking redirects or invent a root.
        return url
    }
}

struct ResearchSourceDiscoveryDOM: Decodable {
    let url: String
    let title: String
    let htmlBytes: Int
    let oversized: Bool
    let challenge: Bool
    let resultsPresent: Bool
    let truncated: Bool
    let links: [Link]
    struct Link: Decodable { let index: Int; let title: String; let href: String }

    static func accept(_ data: Data, provider: ResearchSourceDiscoveryProvider, query: String,
                       expected: URL, observedAt: Date = Date()) throws -> ResearchSourceDiscoveryResult {
        guard data.count <= ResearchSourceDiscoveryPolicy.maximumSnapshotBytes else { throw ResearchSourceDiscoveryError.pageTooLarge }
        guard let page = try? JSONDecoder().decode(Self.self, from: data), let url = URL(string: page.url),
              ResearchSourceDiscoveryPolicy.navigation(url, expected: expected),
              observedAt.timeIntervalSince1970.isFinite else { throw ResearchSourceDiscoveryError.pageChanged }
        guard !page.oversized, (0...ResearchSourceDiscoveryPolicy.maximumHTMLBytes).contains(page.htmlBytes),
              page.links.count <= ResearchSourceDiscoveryPolicy.maximumLinks else { throw ResearchSourceDiscoveryError.pageTooLarge }
        guard !page.challenge, page.resultsPresent else { throw ResearchSourceDiscoveryError.unavailable }
        let id = UUID()
        var seen = Set<URL>(), indices = Set<Int>(), candidates: [ResearchSourceDiscoveryCandidate] = [], rejected = 0
        for link in page.links {
            guard (0..<10000).contains(link.index), indices.insert(link.index).inserted,
                  link.title.utf8.count <= 800, link.href.utf8.count <= 4096 else { throw ResearchSourceDiscoveryError.pageChanged }
            guard !link.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !link.title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }),
                  let target = ResearchSourceDiscoveryPolicy.candidate(link.href) else { rejected += 1; continue }
            guard seen.insert(target).inserted else { continue }
            candidates.append(.init(id: UUID(), title: link.title, url: target, observedAt: observedAt, observationID: id, domIndex: link.index))
        }
        guard !candidates.isEmpty else { throw ResearchSourceDiscoveryError.noCandidates }
        return .init(id: id, provider: provider, query: query, pageURL: url, observedAt: observedAt,
            htmlByteCount: page.htmlBytes, observationSHA256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            candidates: candidates, rejectedLinkCount: rejected, truncated: page.truncated)
    }
}
