import Foundation

/// Created only from the user's confirmed seed addresses, never a model reply.
public struct MultiSourceResearchPlan: Sendable {
    public let goal: String
    public let sources: [MultiSourceResearchSource]

    public init(goal: String, rootAddresses: [String]) throws {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goal.isEmpty, goal.utf16.count <= 4000, (2...3).contains(rootAddresses.count) else {
            throw MultiSourceResearchError.invalidPlan
        }
        var sources: [MultiSourceResearchSource] = []
        for address in rootAddresses {
            let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.utf8.count <= 2048, case .allow(let url) = BrowserPolicy.evaluate(address: text),
                  MultiSourceResearchSource.isPublicResearchURL(url), let origin = try? WebsiteOrigin(url: url),
                  !sources.contains(where: { $0.origin == origin }) else {
                throw MultiSourceResearchError.invalidPlan
            }
            sources.append(MultiSourceResearchSource(id: "source-\(sources.count + 1)", rootURL: url, origin: origin))
        }
        self.goal = goal; self.sources = sources
    }
}

public struct MultiSourceResearchSource: Sendable, Equatable, Identifiable {
    public let id: String
    public let rootURL: URL
    public let origin: WebsiteOrigin
    fileprivate init(id: String, rootURL: URL, origin: WebsiteOrigin) {
        self.id = id; self.rootURL = rootURL; self.origin = origin
    }
    public func allows(_ url: URL) -> Bool {
        Self.isPublicResearchURL(url) && (try? WebsiteOrigin(url: url)) == origin
    }
    fileprivate static func isPublicResearchURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", (try? WebsiteOrigin(url: url)) != nil else { return false }
        var path = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
        for _ in 0..<3 { path = path.removingPercentEncoding ?? path }
        let accountPaths: Set<String> = ["login", "signin", "sign-in", "sign_in", "signup", "sign-up", "register",
            "account", "accounts", "auth", "oauth", "oauth2", "callback", "authorize", "authentication"]
        return !path.lowercased().split(separator: "/").contains { accountPaths.contains(String($0)) }
    }
}

/// One executor per task; implementations keep each source in its own WebKit
/// session and enforce its origin again at navigation action/response time.
public protocol MultiSourceResearchExecuting: Sendable {
    func loadRoot(source: MultiSourceResearchSource) async throws -> WebObservation
    func openLink(sourceID: String, id: Int) async throws -> WebObservation
}

public struct MultiSourceResearchReceipt: Sendable, Identifiable, Encodable {
    public let id: String
    public let sourceID: String
    public let observation: WebObservation
}

public struct MultiSourceResearchCitation: Sendable {
    public let receipt: MultiSourceResearchReceipt
    public let quote: String
}

public struct MultiSourceResearchFinding: Sendable, Identifiable {
    public enum Kind: String, Decodable, Sendable { case finding, inference }
    public let id: Int
    public let kind: Kind
    public let text: String
    public let citations: [MultiSourceResearchCitation]
}

public struct MultiSourceResearchResult: Sendable {
    public let findings: [MultiSourceResearchFinding]
    public let receipts: [MultiSourceResearchReceipt]
    public let limitations: [String]
    public let partial: Bool
    /// Refers to distinct approved origins, not independent publishers.
    public let citedSourceCount: Int
}

public enum MultiSourceResearchEvent: Sendable {
    case observed(MultiSourceResearchReceipt)
    case sourceUnavailable(String)
}

public enum MultiSourceResearchError: Error, Sendable, Equatable, LocalizedError {
    case invalidPlan, invalidCommand, invalidModelJSON, invalidCitation, unsafeObservation, staleObservation, deadline
    public var errorDescription: String? {
        switch self {
        case .invalidPlan: return "請填寫研究問題與 2 至 3 個不同網站的公開 HTTPS 起始網址；不可包含帳密、查詢參數或登入路徑。"
        case .invalidCommand: return "模型回傳了不支援的研究指令；已停止，保留實際讀取紀錄。"
        case .invalidModelJSON: return "模型回傳的研究指令格式仍無法辨識，已停止研究。"
        case .invalidCitation: return "模型引用無法對應這次讀到的原文；未將該回答當成研究成果。"
        case .unsafeObservation: return "頁面離開已確認的來源範圍；已停止讀取。"
        case .staleObservation: return "模型使用了過期的頁面或連結編號；未執行該導覽。"
        case .deadline: return "多網站研究已達整體時間限制；已讀取紀錄保留。"
        }
    }
}
