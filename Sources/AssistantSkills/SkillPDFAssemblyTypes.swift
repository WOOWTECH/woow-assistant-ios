import Foundation

public enum SkillPDFAssemblyLimits {
    public static let files = 3
    public static let inputBytes = SkillExecutionLimits.fileBytes
    public static let totalInputBytes = files * inputBytes
    /// Aggregate pages across all inputs, and separately the output page count.
    public static let pages = SkillExecutionLimits.pages
    public static let outputBytes = 20 * 1024 * 1024
}

/// File IO and authorization also use the existing SkillExecutionError cases.
public enum SkillPDFAssemblyError: String, Error, Equatable, LocalizedError, Sendable {
    case invalidSources, protectedPDF, unsupportedDocument, serialization, verification, outputTooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidSources: return "請選取一至三個不同的 PDF，再逐一核准讀取。"
        case .protectedPDF: return "這個 PDF 有加密或複製／組裝限制；此功能不會移除保護。"
        case .unsupportedDocument: return "此版本不處理含表單、註記、附件、書籤、標記結構、圖層或互動功能的頁面／文件。"
        case .serialization: return "無法產生新的 PDF；原檔未修改。"
        case .verification: return "新 PDF 的頁數、旋轉或尺寸驗證失敗，未交付結果。"
        case .outputTooLarge: return "新 PDF 超過 20 MiB，請減少頁數或來源檔案。"
        }
    }
}

/// Trusted file-picker selection only; no URL is exposed to a model or a plan.
public struct SkillPDFAssemblySource: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let filename: String
    public var disclosure: String { "只讀取這個選取的 PDF，最多 10 MiB；不會掃描資料夾或上傳。" }
}

public struct SkillPDFAssemblyReceipt: Identifiable, Equatable, Sendable {
    public var id: UUID { source.id }
    public let source: SkillPDFAssemblySource
    public let pageCount: Int
    public let byteCount: Int
    public let sha256: String
}

/// One-based page number. Order and repeated pages are intentional, never sorted.
public struct SkillPDFAssemblyPage: Equatable, Sendable {
    public let sourceID: UUID
    public let number: Int
    public init(sourceID: UUID, number: Int) { self.sourceID = sourceID; self.number = number }
}

public struct SkillPDFAssemblyPlan: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let inputs: [SkillPDFAssemblyReceipt]
    public let order: [SkillPDFAssemblyPage]
    public let fingerprint: String
    public let provenance: [SkillExecutionProvenance]
    public var grantsAuthorization: Bool { false }
    public var disclosure: String {
        "以已核准的檔案快照，依顯示的頁序產生新 PDF；不修改原檔、不上傳。使用 Apple PDFKit，並非原版 Python 工具；不提供 OCR。"
    }
}

/// Opaque, in-memory, single-use grant. Host calls authorize only after an
/// explicit user action reviewing this source/plan. Never decode model output.
public struct SkillPDFAssemblyApproval: Sendable {
    let id: UUID
    let runtimeID: UUID
    let target: UUID
    let assembly: Bool
    let expiresAt: Date
}

/// No output is written or opened automatically. Host provides a separate
/// user-selected export destination. Replacing an existing destination requires
/// native explicit user confirmation; assembly itself never modifies originals.
public struct SkillPDFAssemblyResult: Sendable {
    public let data: Data
    public let plan: SkillPDFAssemblyPlan
    public let sha256: String
    public var pageCount: Int { plan.order.count }
    public var suggestedFilename: String { "組裝文件-\(plan.id.uuidString).pdf" }
    public var engine: String { "Apple PDFKit" }
    public var originalScriptSHA256: String? { nil }
    public var notice: String {
        "請對照原頁核對結果。已驗證頁數、旋轉、尺寸及各頁框的相對位置；PDFKit 可能正規化頁框原點與文件編碼，不保證位元相同或保留文件層級中繼資料。"
    }
}

struct SkillPDFAssemblySnapshot: Sendable {
    let receipt: SkillPDFAssemblyReceipt
    let data: Data
}
