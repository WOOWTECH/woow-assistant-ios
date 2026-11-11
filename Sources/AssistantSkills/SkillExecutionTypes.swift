import CryptoKit
import Foundation

public enum SkillExecutionError: String, Error, Equatable, LocalizedError, Sendable {
    case unavailable, invalidSelection, fileTooLarge, invalidPDF, passwordRequired
    case invalidPages, tooManyPages, outputTooLarge, approvalRequired, expiredApproval
    case stalePlan, busy, cancelled, workerFailed, invalidWorkerResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "這項執行能力尚未連接。"
        case .invalidSelection: return "請重新選取可讀取的單一 PDF 檔案。"
        case .fileTooLarge: return "檔案超過 10 MiB，請先縮小檔案。"
        case .invalidPDF: return "這個檔案不是可讀取的 PDF。"
        case .passwordRequired: return "PDF 已鎖定，請提供正確密碼後重新建立計畫。"
        case .invalidPages: return "頁碼格式或範圍不正確，請使用例如 1,3-5 的格式。"
        case .tooManyPages: return "一次最多處理 200 頁。"
        case .outputTooLarge: return "文字結果超過 2 MiB，請縮小頁碼範圍。"
        case .approvalRequired: return "此步驟尚未取得單次核准，或核准已使用。"
        case .expiredApproval: return "核准已逾期，請重新檢視此步驟。"
        case .stalePlan: return "計畫已變更或結束，請重新建立計畫。"
        case .busy: return "此計畫正在執行，請等候完成。"
        case .cancelled: return "執行已取消。"
        case .workerFailed: return "工作服務未完成擷取，未自動重試或改用其他服務。"
        case .invalidWorkerResponse: return "工作服務回應無法驗證，未採用結果。"
        }
    }
}

public enum SkillExecutionLimits {
    public static let fileBytes = 10 * 1024 * 1024
    public static let outputBytes = 2 * 1024 * 1024
    public static let pages = 200
}

public struct SkillExecutionProvenance: Equatable, Sendable {
    public let repository: String
    public let revision: String
    public let path: String
    public let sha256: String
    init(_ document: SkillCatalogDocument) {
        repository = BundledSkillCatalog.repository; revision = BundledSkillCatalog.pinnedCommit
        path = document.path; sha256 = document.sha256
    }
}

public enum SkillExecutionCapability: String, Sendable {
    case selectedPDFRead, nativePDFText, originalPDFWorker
}

public struct SkillExecutionAvailability: Equatable, Sendable {
    public let capability: SkillExecutionCapability
    public let available: Bool
    public let detail: String
}

/// Values are constructed by reviewed code, never decoded from Markdown/model output.
public struct SkillExecutionStep: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let capability: SkillExecutionCapability
    public let title: String
    public let disclosure: String
    public let availability: SkillExecutionAvailability
    public let provenance: [SkillExecutionProvenance]
    public var requiresAuthorization: Bool { true }
}

public struct SkillExecutionPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let skillID: String
    public let filename: String
    public let pages: String?
    public let metadataOnly: Bool
    public let includesPassword: Bool
    public let steps: [SkillExecutionStep]
    /// Hash of the exact reviewed plan, including source hashes and selected-file ID.
    public let fingerprint: String
    public var grantsAuthorization: Bool { false }
}

/// Opaque, in-memory, one-use grant. No Codable/public initializer.
public struct SkillExecutionApproval: Sendable {
    let id: UUID
    let planID: UUID
    let stepID: UUID
    let expiresAt: Date
}

/// Both constructors are trusted UI boundaries, never model/worker/persisted input.
/// Neither selection grants permission to read bytes or execute an extraction.
public struct SkillExecutionSelectedFile: Sendable {
    let id = UUID()
    let url: URL
    let browserDownloadID: UUID?
    var accessDetail: String {
        browserDownloadID == nil ? "需要系統檔案選擇器授予存取權。" :
            "使用者從此 App 的已完成下載選取；仍須另行核准讀取。"
    }

    /// Construct only from the actual fileImporter/document-picker callback.
    public init(userSelectedURL: URL) throws {
        try Self.validate(userSelectedURL)
        url = userSelectedURL; browserDownloadID = nil
    }

    /// Construct only after an explicit user selection from the App download
    /// manager. The host must revalidate ownership/identity and revoke on deletion.
    /// This does not represent a system picker callback or security-scope grant.
    public init(userSelectedBrowserDownloadURL: URL, downloadID: UUID) throws {
        try Self.validate(userSelectedBrowserDownloadURL)
        url = userSelectedBrowserDownloadURL; browserDownloadID = downloadID
    }

    private static func validate(_ url: URL) throws {
        guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else {
            throw SkillExecutionError.invalidSelection
        }
    }
}

/// Passwords are transient input: never put them in a plan, log, hash or filename.
public struct SkillExecutionPDFOptions: Sendable {
    public let pages: String?
    public let metadataOnly: Bool
    public let password: String?
    public init(pages: String? = nil, metadataOnly: Bool = false, password: String? = nil) throws {
        let trimmed = pages?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty { _ = try SkillExecutionPageRange.parse(trimmed, pageCount: Int.max) }
        guard (password?.utf8.count ?? 0) <= 1024 else { throw SkillExecutionError.passwordRequired }
        self.pages = trimmed?.isEmpty == false ? trimmed : nil
        self.metadataOnly = metadataOnly; self.password = password
    }
}

public struct SkillExecutionPDFPage: Equatable, Sendable {
    public let number: Int
    public let text: String
    public init(number: Int, text: String) { self.number = number; self.text = text }
}

public struct SkillExecutionPDFResult: Equatable, Sendable {
    public let pageCount: Int
    public let pages: [SkillExecutionPDFPage]
    public let metadata: [String: String]
    public let emptyPages: [Int]
    public let inputSHA256: String
    public let engine: String
    public let originalScriptSHA256: String?
    public init(pageCount: Int, pages: [SkillExecutionPDFPage], metadata: [String: String], emptyPages: [Int],
                inputSHA256: String, engine: String, originalScriptSHA256: String?) {
        self.pageCount = pageCount; self.pages = pages; self.metadata = metadata; self.emptyPages = emptyPages
        self.inputSHA256 = inputSHA256; self.engine = engine; self.originalScriptSHA256 = originalScriptSHA256
    }
    public var needsOCR: Bool { !pages.isEmpty && emptyPages.count == pages.count }
    public var text: String { pages.map { "--- page \($0.number) ---\n\($0.text)\n" }.joined(separator: "\n") }
    public var notice: String {
        if needsOCR { return "選取頁面沒有可擷取的文字，可能需要 OCR；此能力不提供 OCR。" }
        if !emptyPages.isEmpty { return "部分頁面沒有文字：\(emptyPages.map(String.init).joined(separator: ", "))。" }
        return "請對照原頁核對表格、多欄文字與引用；此結果未保證版面順序。"
    }
}

public enum SkillExecutionStepResult: Sendable {
    case selectedFileRead(byteCount: Int, sha256: String)
    case pdf(SkillExecutionPDFResult)
}

enum SkillExecutionPageRange {
    static func parse(_ spec: String?, pageCount: Int) throws -> [Int] {
        guard pageCount > 0 else { throw SkillExecutionError.invalidPDF }
        guard let spec else {
            guard pageCount <= SkillExecutionLimits.pages else { throw SkillExecutionError.tooManyPages }
            return Array(1...pageCount)
        }
        guard spec.utf8.count <= 1024 else { throw SkillExecutionError.invalidPages }
        var result: [Int] = []
        for component in spec.split(separator: ",", omittingEmptySubsequences: false) {
            let fields = component.trimmingCharacters(in: .whitespaces).split(separator: "-", omittingEmptySubsequences: false)
            guard (1...2).contains(fields.count), fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && $0.isNumber }) }),
                  let first = Int(fields[0]), let last = Int(fields.last!), first >= 1, last >= first,
                  last <= pageCount else { throw SkillExecutionError.invalidPages }
            guard last - first < SkillExecutionLimits.pages, result.count + (last - first + 1) <= SkillExecutionLimits.pages else {
                throw SkillExecutionError.tooManyPages
            }
            result.append(contentsOf: first...last)
        }
        guard !result.isEmpty else { throw SkillExecutionError.invalidPages }
        return result
    }
}

func skillExecutionDigest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
