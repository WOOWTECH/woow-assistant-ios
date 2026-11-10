import Foundation

public enum BrowserDownloadStatus: String, Codable, Sendable {
    case waiting, downloading, cancelling, completed, cancelled, failed

    public var isActive: Bool { self == .waiting || self == .downloading || self == .cancelling }
    public var title: String {
        switch self {
        case .waiting: return "等待下載"
        case .downloading: return "下載中"
        case .cancelling: return "正在取消"
        case .completed: return "已完成"
        case .cancelled: return "已取消"
        case .failed: return "下載失敗"
        }
    }
}

public struct BrowserDownloadItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public internal(set) var fileName: String
    public internal(set) var status: BrowserDownloadStatus
    public internal(set) var receivedBytes: Int64
    public internal(set) var totalBytes: Int64?
    public let createdAt: Date
    public internal(set) var completedAt: Date?
    public internal(set) var failureMessage: String?

    // Deliberately no URL, query, headers, cookies, resume data, or raw server error.
    public var fractionCompleted: Double? {
        if status == .completed { return 1 }
        guard let totalBytes, totalBytes > 0 else { return nil }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    init(id: UUID = UUID(), fileName: String = "下載檔案", createdAt: Date = Date()) {
        self.id = id; self.fileName = fileName; self.createdAt = createdAt
        status = .waiting; receivedBytes = 0
    }
}

/// Hard ceilings also apply to caller-supplied limits. No silent eviction of completed files.
public struct BrowserDownloadLimits: Sendable {
    public let maximumCount: Int
    public let maximumActive: Int
    public let maximumFileBytes: Int64
    public let maximumTotalBytes: Int64
    public let maximumMetadataBytes = 65_536
    public let maximumRedirects = 5

    public init(maximumCount: Int = 50, maximumActive: Int = 3,
                maximumFileBytes: Int64 = 100 * 1_024 * 1_024,
                maximumTotalBytes: Int64 = 500 * 1_024 * 1_024) {
        self.maximumCount = max(1, min(50, maximumCount))
        self.maximumActive = max(1, min(3, maximumActive))
        self.maximumFileBytes = max(1, min(100 * 1_024 * 1_024, maximumFileBytes))
        self.maximumTotalBytes = max(1, min(500 * 1_024 * 1_024, maximumTotalBytes))
    }
}

public enum BrowserDownloadError: Error, LocalizedError, Equatable {
    case unavailable, unsafeURL, researchDisabled, tooMany, tooLarge, invalidFile, invalidMetadata
    case confirmationRequired, stillRunning, missingFile, network, redirectLimit

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "下載儲存空間目前無法使用。請稍後再試。"
        case .unsafeURL: return "無法下載此網址，或重新導向不符合下載規則。"
        case .researchDisabled: return "研究模式不會下載檔案；請回到瀏覽器手動下載。"
        case .tooMany: return "下載數量已達上限，請先取消下載或刪除不需要的檔案。"
        case .tooLarge: return "檔案或下載資料夾已超過容量上限。"
        case .invalidFile: return "下載檔案路徑或內容無法驗證。"
        case .invalidMetadata: return "下載紀錄無法讀取，已保留原有檔案。"
        case .confirmationRequired: return "請先確認是否刪除檔案。"
        case .stillRunning: return "請先取消下載，再刪除紀錄。"
        case .missingFile: return "找不到已完成的下載檔案。"
        case .network: return "下載未完成，請檢查連線後重新從網頁下載。"
        case .redirectLimit: return "下載重新導向次數過多，已停止。"
        }
    }
}

public enum BrowserDownloadPolicy {
    /// HTTPS and URL-level host validation only. WebKit owns DNS, TLS and cookies;
    /// this is not a DNS-rebinding/connection-level private-address guarantee.
    public static func allows(_ url: URL) -> Bool {
        guard url.absoluteString.utf8.count <= 8_192, url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              host.contains("."),
              !["lan", "internal", "intranet", "home.arpa"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
        else { return false }
        if case .allow = BrowserPolicy.evaluate(url) { return true }
        return false
    }

    public static func isAttachment(_ response: URLResponse) -> Bool {
        guard let http = response as? HTTPURLResponse,
              let disposition = http.value(forHTTPHeaderField: "Content-Disposition") else { return false }
        return disposition.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "attachment"
    }

    /// No decoding after sanitization; encoded separators are made inert too.
    /// Limits UTF-8 bytes (filesystem limit), retaining short extensions.
    public static func sanitizedFilename(_ suggestion: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|%")
            .union(.controlCharacters).union(.illegalCharacters)
        var cleaned = String(String.UnicodeScalarView(suggestion.unicodeScalars.prefix(2_048).map {
            bad.contains($0) || $0.properties.generalCategory == .format ? UnicodeScalar(95)! : $0
        }))
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        if cleaned.isEmpty { cleaned = "下載檔案" }
        let ext = (cleaned as NSString).pathExtension
        let suffix = !ext.isEmpty && ext.utf8.count <= 16 ? "." + ext : ""
        let base = suffix.isEmpty ? cleaned : String(cleaned.dropLast(suffix.count))
        var prefix = ""
        for character in base {
            if prefix.utf8.count + String(character).utf8.count > 120 - suffix.utf8.count { break }
            prefix.append(character)
        }
        if prefix.isEmpty { prefix = "下載檔案" }
        return prefix + suffix
    }
}
